import Foundation
import RielaAddonSupport
import RielaCore

struct XCollectionOptions {
  let expected: String
  var handles: [String]
  var start: String
  let requestedStart: String
  var end: String
  let earliest: String
  let bounded: Bool
  var maximum: Int
  var maxPages: Int
  let pageSize: Int
  var fresh: Bool
  let timezone: String
  var signatureContext: JSONObject
  let selection: JSONObject
  let previous: JSONObject

  init(_ values: JSONObject) throws {
    guard Set(values.keys).isSubset(of: ["expectedHandle", "authorHandles", "start", "end", "earliest", "bounded",
      "maxPosts", "maxPages", "pageSize", "freshPage", "timezone", "signatureContext", "select", "previous",
      "includeStatusLinks", "includeCoverageMetadata", "requestedStart"]),
      case let .string(expected)? = values["expectedHandle"], xMatches(.string(expected), #"^[A-Za-z0-9_]{1,15}$"#),
      case let .array(authors)? = values["authorHandles"], (1...100).contains(authors.count),
      authors.allSatisfy({ xMatches($0, #"^[A-Za-z0-9_]{1,15}$"#) }),
      case let .string(start)? = values["start"], case let .string(end)? = values["end"],
      case let .string(earliest)? = values["earliest"],
      case let .string(requestedStart) = values["requestedStart"] ?? .string(start),
      try xInstant(requestedStart) <= xInstant(start),
      try xInstant(earliest) <= xInstant(start), try xInstant(start) < xInstant(end),
      case let .object(previous) = values["previous"] ?? .object([:]),
      case let .bool(links) = values["includeStatusLinks"] ?? .bool(false),
      case let .bool(coverage) = values["includeCoverageMetadata"] ?? .bool(false),
      case let .object(signatureContext) = values["signatureContext"] ?? .object([:]),
      case let .bool(fresh) = values["freshPage"] ?? .bool(false),
      case let .bool(bounded) = values["bounded"] ?? .bool(true),
      case let .string(timezone) = values["timezone"] ?? .string("UTC"), TimeZone(identifier: timezone) != nil
    else { throw xCollectionInvalid() }
    self.expected = expected; self.start = start; self.requestedStart = requestedStart; self.end = end; self.earliest = earliest
    self.handles = authors.compactMap { nonEmptyString($0) }
    guard Set(handles.map { $0.lowercased() }).count == handles.count else { throw xCollectionInvalid() }
    self.maximum = try Self.integer(values, "maxPosts", fallback: 100, range: 5...5000)
    self.maxPages = try Self.integer(values, "maxPages", fallback: 1, range: 1...1000)
    self.pageSize = try Self.integer(values, "pageSize", fallback: 25, range: 10...100)
    let selection: JSONObject
    if let value = values["select"] {
      guard case let .object(fields) = value else { throw xCollectionInvalid() }; selection = fields
    } else {
      selection = ["posts": .object(Self.postFields(depth: 0, links: links, coverage: coverage)),
        "pageInfo": .object(["nextToken": .bool(true)])]
    }
    self.previous = previous; self.selection = selection; self.signatureContext = signatureContext
    self.fresh = fresh; self.bounded = bounded; self.timezone = timezone
    guard !fresh || (maxPages == 1 && maximum >= 2 * pageSize) else { throw xCollectionInvalid() }
  }

  var groups: [[String]] {
    var groups: [[String]] = [[]]
    for handle in handles {
      if (groups[groups.count - 1] + [handle]).map({ "from:" + $0 }).joined(separator: " OR ").utf8.count > 512 {
        groups.append([])
      }
      groups[groups.count - 1].append(handle)
    }
    return groups
  }

  var scope: String { String(JSONCanonical.sha256Hex(Data(("authors:" + handles.map { $0.lowercased() }.joined(separator: ",")).utf8)).prefix(24)) }

  func headSignature(account: String, checkpoint: JSONObject, probeStart: String) throws -> String {
    var values: JSONObject = ["account_id": .string(account), "expected_handle": .string(expected.lowercased()),
      "requested_start": .string(requestedStart), "probe_start": .string(probeStart), "requested_end": .string(end),
      "since_id": checkpoint["since_id"] ?? .null, "settings": .object(signatureContext),
      "fields": .object(selection), "floor": .string(earliest), "timezone": .string(timezone)]
    if let settings = signatureContext["settings"], let fields = signatureContext["fields"] {
      values["settings"] = settings; values["fields"] = fields
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return JSONCanonical.sha256Hex(try encoder.encode(values))
  }

  func closed(at date: Date) -> Bool {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timezone) ?? .gmt
    return (try? xInstant(end)) .map { $0 <= calendar.startOfDay(for: date) } ?? false
  }

  private static func integer(_ values: JSONObject, _ key: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
    guard case let .integer(value) = values[key] ?? .integer(Int64(fallback)), range.contains(Int(value)) else { throw xCollectionInvalid() }
    return Int(value)
  }

  static func postFields(depth: Int, links: Bool, coverage: Bool) -> JSONObject {
    func fields(_ names: [String]) -> JSONValue { .object(Dictionary(uniqueKeysWithValues: names.map { ($0, .bool(true)) })) }
    var value: JSONObject = ["id": .bool(true), "text": .bool(true), "createdAt": .bool(true),
      "author": fields(["id", "username", "name"]), "media": fields(["kind", "contentType", "sourceUrl", "previewImageUrl"])]
    if depth < 2 {
      value["references"] = fields(["id", "relation"])
      let child = JSONValue.object(postFields(depth: depth + 1, links: links, coverage: coverage))
      value["quote"] = child; value["repost"] = child
    }
    if links { value["urlEntities"] = fields(["url", "expandedUrl", "displayUrl", "source"]) }
    if coverage {
      value["mediaAvailability"] = fields(["mediaKey", "status", "reason"]); value["mediaCoverageComplete"] = .bool(true)
      value["referenceAvailability"] = fields(["postId", "relation", "status", "reason"]); value["referenceCoverageComplete"] = .bool(true)
    }
    return value
  }
}
