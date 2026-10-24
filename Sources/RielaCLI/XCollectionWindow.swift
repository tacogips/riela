import Foundation
import RielaAddonSupport
import RielaCore

/// Read-only provider cursor policy. The caller commits this metadata only
/// after the enclosing private workflow has inspected the returned posts.
struct XCollectionWindow {
  var checkpoint: JSONObject
  var scan: JSONObject
  let options: XCollectionOptions
  let query: String
  let account: String
  let start: String
  let end: String
  var posts: [JSONObject] = []
  var pages = 0
  var fetched = 0
  var bytes = 0
  var failed = false

  init(options: XCollectionOptions, query: String, account: String, previous: JSONObject) throws {
    self.options = options; self.query = query; self.account = account
    var previous = previous
    if previous["account_id"] != .string(account) || previous["author_query"] != .string(query) {
      previous = previous.filter { $0.key == "config_key" }
    }
    previous["author_query"] = .string(query)
    let since = try xOptionalID(previous["since_id"])
    var scan: JSONObject
    if let saved = previous["pending_scan"] {
      guard case let .object(value) = saved else { throw xCollectionInvalid() }
      scan = value
      let base: Set<String> = ["start", "end", "since_id", "max_id", "next_token", "page_size", "page_count", "visited_tokens", "recent_ids"]
      let keys = Set(scan.keys)
      guard [base, base.union(["wire_start", "wire_end"]), base.union(["wire_start", "wire_end", "search_start"])].contains(keys),
        try xOptionalID(scan["since_id"]) == since,
        case let .string(first)? = scan["start"], case let .string(last)? = scan["end"],
        try xInstant(first) >= xInstant(options.earliest), try xInstant(first) < xInstant(last),
        try xInstant(last) <= xInstant(options.end),
        try !options.bounded || (xInstant(first) == xInstant(options.start)),
        case let .integer(size)? = scan["page_size"], (5...100).contains(size), size <= options.maximum,
        case let .integer(count)? = scan["page_count"], (1...10_000).contains(count),
        case let .string(token)? = scan["next_token"], !token.isEmpty, token.utf8.count <= 8192,
        case let .array(visited)? = scan["visited_tokens"], visited.count == Int(count),
        Set(visited.compactMap { nonEmptyString($0) }).count == visited.count, visited.allSatisfy({ xMatches($0, #"^[0-9a-f]{64}$"#) }),
        !visited.contains(.string(JSONCanonical.sha256Hex(Data(token.utf8)))),
        case let .array(recent)? = scan["recent_ids"], recent.count <= 100,
        recent.allSatisfy({ xMatches($0, #"^[0-9]{1,32}$"#) }) else { throw xCollectionInvalid() }
      _ = try xOptionalID(scan["max_id"])
      start = first; end = last
      if scan["wire_start"] != nil {
        guard scan["wire_start"] == .string(try xWire(first, upper: false)),
          scan["wire_end"] == .string(try xWire(last, upper: true)) else { throw xCollectionInvalid() }
      }
      if let value = scan["search_start"] {
        guard let since, value == .string(try Self.searchStart(since, start: first, end: last)) else { throw xCollectionInvalid() }
      }
    } else {
      start = options.start; end = options.end
      scan = ["start": .string(start), "end": .string(end), "since_id": since.map(JSONValue.string) ?? .null,
        "max_id": since.map(JSONValue.string) ?? .null, "next_token": .null,
        "page_size": .integer(Int64(min(options.pageSize, options.maximum))), "page_count": .integer(0),
        "visited_tokens": .array([]), "recent_ids": .array([]),
        "wire_start": .string(try xWire(start, upper: false)), "wire_end": .string(try xWire(end, upper: true))]
      if let since { scan["search_start"] = .string(try Self.searchStart(since, start: start, end: end)) }
    }
    previous.removeValue(forKey: "fresh_head")
    checkpoint = previous; self.scan = scan
  }

  var cursor: String? { nonEmptyString(scan["next_token"]) }
  var size: Int { Int(xInt(scan["page_size"]) ?? 0) }

  func arguments() throws -> JSONObject {
    let tokenHash = JSONCanonical.sha256Hex(Data((cursor ?? "").utf8))
    guard case let .array(visited)? = scan["visited_tokens"], visited.count < 10_000,
      !visited.contains(.string(tokenHash)) else { throw xCollectionInvalid() }
    var arguments: JSONObject = ["query": .string(query), "maxResults": .integer(Int64(max(10, size))),
      "startTime": .string(try xWire(start, upper: false)), "endTime": .string(try xWire(end, upper: true))]
    if let since = try xOptionalID(scan["since_id"]) {
      if let search = scan["search_start"] { arguments["startTime"] = search }
      else { arguments.removeValue(forKey: "startTime"); arguments["sinceId"] = .string(since) }
    }
    if let cursor { arguments["nextToken"] = .string(cursor) }
    return arguments
  }

  /// A rejected page cannot partially mutate IDs/cursor, even if its last post
  /// or token is malformed. Previously accepted pages remain available.
  mutating func accept(_ response: JSONObject, at timestamp: String) throws {
    var candidate = self
    try candidate.acceptPage(response, at: timestamp)
    self = candidate
  }

  private mutating func acceptPage(_ response: JSONObject, at timestamp: String) throws {
    guard case let .array(rows)? = response["posts"], rows.count <= size,
      case let .object(info)? = response["pageInfo"],
      case let .array(oldRecent)? = scan["recent_ids"],
      case let .array(oldVisited)? = scan["visited_tokens"] else { throw xCollectionInvalid() }
    let token: String?
    switch info["nextToken"] {
    case nil, .null?: token = nil
    case let .string(value)?: token = value.isEmpty ? nil : value
    default: throw xCollectionInvalid()
    }
    let oldHash = JSONCanonical.sha256Hex(Data((cursor ?? "").utf8))
    if let token {
      guard token.utf8.count <= 8192,
        !(oldVisited + [.string(oldHash)]).contains(.string(JSONCanonical.sha256Hex(Data(token.utf8)))) else { throw xCollectionInvalid() }
    }
    var seen = Set(oldRecent.compactMap { nonEmptyString($0) } + posts.compactMap { nonEmptyString($0["id"]) })
    var recent: [String] = []
    for row in rows {
      guard case let .object(post) = row, let id = try xOptionalID(post["id"]),
        case let .string(created)? = post["createdAt"], case .string? = post["text"] else { throw xCollectionInvalid() }
      let identity = xDecimal(id), instant = try xInstant(created)
      recent.append(identity)
      let since = try xOptionalID(scan["since_id"])
      guard !seen.contains(identity), instant >= (try xInstant(start)), instant < (try xInstant(end)),
        since == nil || xGreater(identity, xDecimal(since ?? "0")) else { continue }
      seen.insert(identity)
      bytes += try JSONEncoder().encode(post).count + 512
      guard posts.count < options.maximum, bytes <= 6_000_000 else { throw xCollectionInvalid() }
      let allowed: Set<String> = ["text", "createdAt", "author", "media", "quote", "repost", "references", "urlEntities",
        "mediaAvailability", "mediaCoverageComplete", "referenceAvailability", "referenceCoverageComplete"]
      var value = post.filter { allowed.contains($0.key) }
      value.merge(["id": .string(identity), "_fetched_at": .string(timestamp), "_account_id": .string(account)]) { _, new in new }
      posts.append(value)
      let previous = xDecimal(try xOptionalID(scan["max_id"]) ?? "0")
      scan["max_id"] = .string(xGreater(identity, previous) ? identity : previous)
    }
    var history: [String] = [], known = Set<String>()
    for id in oldRecent.compactMap({ nonEmptyString($0) }) + recent where known.insert(id).inserted { history.append(id) }
    scan["recent_ids"] = .array(history.suffix(100).map(JSONValue.string))
    scan["visited_tokens"] = .array(oldVisited + [.string(oldHash)])
    scan["page_count"] = .integer((xInt(scan["page_count"]) ?? 0) + 1)
    scan["next_token"] = token.map(JSONValue.string) ?? .null
    pages += 1; fetched += rows.count
  }

  func result(at timestamp: String) throws -> JSONObject {
    var result = checkpoint
    let growth = try xInstant(end) < xInstant(options.end)
    result.merge(["account_id": .string(account), "expected_handle": .string(options.expected), "checked_at": .string(timestamp),
      "window_start": .string(start), "window_end": .string(end), "page_count": .integer(Int64(pages)),
      "scan_page_count": scan["page_count"] ?? .integer(0), "catchup_pending": .bool(growth || (failed && pages == 0))]) { _, new in new }
    if cursor != nil {
      result["pending_scan"] = .object(scan)
      result["scan_stop_reason"] = .string(failed ? "gateway-failure" : "page-budget")
    } else if failed && pages == 0 {
      result["scan_stop_reason"] = .string("gateway-failure")
    } else {
      result["since_id"] = scan["max_id"] ?? .null
      result.removeValue(forKey: "pending_scan")
      if growth { result["scan_stop_reason"] = .string("window-growth") } else { result.removeValue(forKey: "scan_stop_reason") }
    }
    result["coverage"] = .object(["version": .integer(1), "account_id": .string(account),
      "expected_handle": .string(options.expected.lowercased()), "start": .string(start), "end": .string(end),
      "complete": .bool(!failed && cursor == nil && !growth)])
    return result
  }

  static func searchStart(_ since: String, start: String, end: String) throws -> String {
    guard let id = UInt64(since) else { return try xWire(start, upper: false) }
    let seconds = ((id >> 22) + 1_288_834_974_657) / 1000
    let date = Date(timeIntervalSince1970: TimeInterval(seconds))
    guard date >= (try xInstant(xWire(start, upper: false))), date < (try xInstant(xWire(end, upper: true))) else {
      return try xWire(start, upper: false)
    }
    return ISO8601DateFormatter().string(from: date)
  }
}

func xCollectionInvalid() -> AdapterExecutionError { .init(.invalidInput, "invalid X collection configuration, cursor or response") }
func xInt(_ value: JSONValue?) -> Int64? { if case let .integer(number)? = value { return number }; return nil }
func xMatches(_ value: JSONValue, _ pattern: String) -> Bool {
  guard case let .string(text) = value else { return false }
  return text.range(of: pattern, options: .regularExpression) != nil
}
func xOptionalID(_ value: JSONValue?) throws -> String? {
  guard let value, value != .null else { return nil }
  guard xMatches(value, #"^[0-9]{1,32}$"#), case let .string(text) = value else { throw xCollectionInvalid() }
  return text
}
func xDecimal(_ value: String) -> String { String(value.drop(while: { $0 == "0" })).isEmpty ? "0" : String(value.drop(while: { $0 == "0" })) }
func xGreater(_ lhs: String, _ rhs: String) -> Bool { lhs.count == rhs.count ? lhs > rhs : lhs.count > rhs.count }
func xInstant(_ value: String) throws -> Date {
  guard value.utf8.count <= 64 else { throw xCollectionInvalid() }
  let formatter = ISO8601DateFormatter()
  if let date = formatter.date(from: value) { return date }
  formatter.formatOptions.insert(.withFractionalSeconds)
  guard let date = formatter.date(from: value) else { throw xCollectionInvalid() }
  return date
}
func xWire(_ value: String, upper: Bool) throws -> String {
  let seconds = try xInstant(value).timeIntervalSince1970
  return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: upper ? ceil(seconds) : floor(seconds)))
}
