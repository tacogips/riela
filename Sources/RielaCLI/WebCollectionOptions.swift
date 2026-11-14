import Foundation
import RielaCore

struct WebCollectionOptions: Sendable {
  let kind: String
  let url: String?
  let start: WebCollectionTimestamp
  let end: WebCollectionTimestamp
  let timezone: String
  let maximum: Int
  let minimumPoints: Int
  let concurrency: Int
  let fetchArticles: Bool
  let historical: Bool
  let policy: String
  let selectionPrefix: String
  let selectionSignature: String
  let entities: [String: String]
  let blockedHosts: [String]
  let pageOptions: PublicWebPageOptions
  let previous: JSONObject
  let scope: String
  let index: WebCollectionIndexOptions?

  init(_ values: JSONObject) throws {
    guard Set(values.keys).isSubset(of: ["kind", "url", "start", "end", "timezone", "maximumItems", "minimumPoints",
      "maxConcurrency", "fetchArticles", "historical", "selectionPolicy", "selectionKeyPrefix", "selectionSignature",
      "xmlEntities", "blockedHosts", "pageOptions", "previous", "index"]),
      let kind = webCollectionText(values["kind"]), ["feed", "hackernews", "index"].contains(kind),
      let rawStart = webCollectionText(values["start"]), let start = WebCollectionTimestamp(rawStart),
      let rawEnd = webCollectionText(values["end"]), let end = WebCollectionTimestamp(rawEnd), start.date < end.date,
      case let .object(previous) = values["previous"] ?? .object([:]) else { throw PublicWebError.invalidInput }
    let timezone = try Self.text(values, "timezone", fallback: "UTC")
    guard TimeZone(identifier: timezone) != nil else { throw PublicWebError.invalidInput }
    let url = webCollectionText(values["url"])
    let blocked = try values["blockedHosts"].map { try JSONDecoder().decode([String].self, from: JSONEncoder().encode($0)) } ?? []
    if kind != "hackernews" {
      guard let url else { throw PublicWebError.invalidInput }
      _ = try PublicWebHTTP.destination(url, blockedHosts: blocked)
    } else { guard values["url"] == nil, blocked.isEmpty, values["xmlEntities"] == nil else { throw PublicWebError.invalidInput } }
    let index: WebCollectionIndexOptions?
    if kind == "index" {
      guard case let .object(value)? = values["index"], values["xmlEntities"] == nil else { throw PublicWebError.invalidInput }
      index = try WebCollectionIndexOptions(value)
    } else {
      guard values["index"] == nil else { throw PublicWebError.invalidInput }
      index = nil
    }
    let policy = try Self.text(values, "selectionPolicy", fallback: "publisher-order-v1")
    let prefix = try Self.text(values, "selectionKeyPrefix", fallback: "", allowEmpty: true)
    let signature = try Self.text(values, "selectionSignature", fallback: "", allowEmpty: true)
    guard policy.utf8.count <= 128, prefix.utf8.count <= 1024, signature.utf8.count <= 256 else { throw PublicWebError.invalidInput }
    let entities = try values["xmlEntities"].map { try JSONDecoder().decode([String: String].self, from: JSONEncoder().encode($0)) } ?? [:]
    guard WebFeedDocument.validEntities(entities) else { throw PublicWebError.invalidInput }
    let pageValues: JSONObject
    switch values["pageOptions"] {
    case nil: pageValues = [:]
    case let .object(value)?: pageValues = value
    default: throw PublicWebError.invalidInput
    }
    guard Set(pageValues.keys).isSubset(of: ["mode", "minTextChars", "waitMs", "timeoutMs", "maxTextChars"]) else { throw PublicWebError.invalidInput }
    var page = PublicWebPageOptions()
    page.mode = try Self.text(pageValues, "mode", fallback: "auto")
    guard ["auto", "http", "browser"].contains(page.mode) else { throw PublicWebError.invalidInput }
    page.minimumTextCharacters = try Self.integer(pageValues, "minTextChars", fallback: 400, range: 0...20_000)
    page.waitMs = try Self.integer(pageValues, "waitMs", fallback: 1500, range: 0...5000)
    page.timeoutMs = try Self.integer(pageValues, "timeoutMs", fallback: 20_000, range: 1000...30_000)
    page.maximumTextCharacters = try Self.integer(pageValues, "maxTextChars", fallback: 20_000, range: 1...50_000)
    let maximum = try Self.integer(values, "maximumItems", fallback: 20, range: 1...20)
    let minimum = try Self.integer(values, "minimumPoints", fallback: 20, range: 0...10_000)
    let fetch = try Self.boolean(values, "fetchArticles", fallback: true)
    let historical = try Self.boolean(values, "historical", fallback: false)
    guard !historical || kind != "hackernews" || end.date.timeIntervalSince(start.date) <= 25 * 3600 else { throw PublicWebError.invalidInput }
    var scopeValues: JSONObject = ["kind": .string(kind), "url": url.map(JSONValue.string) ?? .null,
      "timezone": .string(timezone), "maximum": .integer(Int64(maximum)), "minimumPoints": .integer(Int64(minimum)),
      "fetchArticles": .bool(fetch), "historical": .bool(historical), "policy": .string(policy),
      "selectionPrefix": .string(prefix), "entities": .object(entities.mapValues(JSONValue.string)),
      "blockedHosts": .array(blocked.map(JSONValue.string)), "page": .object(["mode": .string(page.mode),
        "minimum": .integer(Int64(page.minimumTextCharacters)), "waitMs": .integer(Int64(page.waitMs)),
        "timeoutMs": .integer(Int64(page.timeoutMs)), "maximum": .integer(Int64(page.maximumTextCharacters))])]
    if let index { scopeValues["index"] = .object(index.scope) }
    self.index = index
    self.scope = JSONCanonical.sha256Hex(try JSONCanonical.encode(scopeValues))
    self.kind = kind; self.url = url; self.start = start; self.end = end; self.timezone = timezone
    self.maximum = maximum; self.minimumPoints = minimum
    self.concurrency = try Self.integer(values, "maxConcurrency", fallback: 4, range: 1...4)
    self.fetchArticles = fetch; self.historical = historical; self.policy = policy
    self.selectionPrefix = prefix; self.selectionSignature = signature; self.entities = entities
    self.blockedHosts = blocked; self.pageOptions = page; self.previous = previous
  }

  static func integer(_ values: JSONObject, _ key: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
    guard let raw = values[key] else { return fallback }
    guard case let .integer(number) = raw, let result = Int(exactly: number), range.contains(result) else { throw PublicWebError.invalidInput }
    return result
  }
  static func text(_ values: JSONObject, _ key: String, fallback: String, allowEmpty: Bool = false) throws -> String {
    guard let raw = values[key] else { return fallback }
    guard case let .string(text) = raw, allowEmpty || !text.isEmpty else { throw PublicWebError.invalidInput }
    return text
  }
  static func boolean(_ values: JSONObject, _ key: String, fallback: Bool) throws -> Bool {
    guard let raw = values[key] else { return fallback }
    guard case let .bool(result) = raw else { throw PublicWebError.invalidInput }; return result
  }
}
