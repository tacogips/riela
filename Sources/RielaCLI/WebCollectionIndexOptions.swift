import Foundation
import RielaCore

/// Authored source policy, independent of publisher names or application code.
struct WebCollectionIndexOptions: Sendable {
  let linkPattern: String
  let maximumArticles: Int
  let maximumSeenEntries: Int
  let metadataOnly: Bool
  let publicationJSONLDType: String?

  init(_ value: JSONObject) throws {
    guard Set(value.keys).isSubset(of: ["linkPattern", "maximumArticles", "metadataOnly", "publicationJSONLDType", "maximumSeenEntries"]),
      let pattern = webCollectionText(value["linkPattern"]), pattern.hasPrefix("^"), pattern.hasSuffix("$"),
      pattern.utf8.count <= 512, (try? NSRegularExpression(pattern: pattern)) != nil else { throw PublicWebError.invalidInput }
    let type: String?
    if let raw = value["publicationJSONLDType"] {
      guard case let .string(text) = raw, text.range(of: #"^[A-Za-z][A-Za-z0-9]{0,63}$"#, options: .regularExpression) != nil else {
        throw PublicWebError.invalidInput
      }
      type = text
    } else { type = nil }
    let metadata = try WebCollectionOptions.boolean(value, "metadataOnly", fallback: false)
    guard !metadata || type == nil else { throw PublicWebError.invalidInput }
    linkPattern = pattern
    maximumArticles = try WebCollectionOptions.integer(value, "maximumArticles", fallback: 20, range: 1...20)
    maximumSeenEntries = try WebCollectionOptions.integer(value, "maximumSeenEntries", fallback: 1000, range: 20...10_000)
    metadataOnly = metadata; publicationJSONLDType = type
  }

  var scope: JSONObject {
    ["linkPattern": .string(linkPattern), "metadataOnly": .bool(metadataOnly),
     "publicationJSONLDType": publicationJSONLDType.map(JSONValue.string) ?? .null]
  }

  /// These are terminal dedup hints, never pending acquisition/publication
  /// receipts. Eviction permits a future refetch; it acknowledges nothing.
  func boundedSeen(_ seen: JSONObject, current: Set<String> = []) -> JSONObject {
    guard seen.count > maximumSeenEntries else { return seen }
    let entries = seen.map { key, value -> WebIndexSeenHint in
      let date: Date
      if case let .object(row) = value {
        date = webCollectionText(row["last_seen_at"] ?? row["seen_at"]).flatMap(WebCollectionTimestamp.init)?.date ?? .distantPast
      } else { date = .distantPast }
      return .init(key: key, value: value, date: date)
    }.sorted { lhs, rhs in
      if current.contains(lhs.key) != current.contains(rhs.key) { return current.contains(lhs.key) }
      return lhs.date == rhs.date ? lhs.key < rhs.key : lhs.date > rhs.date
    }.prefix(maximumSeenEntries)
    return Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
  }

  func articleURL(_ source: String, listing: String) -> String? {
    guard source.utf8.count <= 4096, let base = URL(string: listing),
      let url = URL(string: source, relativeTo: base)?.absoluteURL,
      var parts = URLComponents(url: url, resolvingAgainstBaseURL: true), parts.scheme == "https",
      parts.host?.lowercased() == base.host?.lowercased(), parts.user == nil, parts.password == nil,
      parts.port == nil || parts.port == 443,
      let regex = try? NSRegularExpression(pattern: linkPattern),
      let match = regex.firstMatch(in: parts.path, range: NSRange(parts.path.startIndex..., in: parts.path)),
      match.range == NSRange(parts.path.startIndex..., in: parts.path) else { return nil }
    parts.host = parts.host?.lowercased(); parts.port = nil; parts.query = nil; parts.fragment = nil
    while parts.path.hasSuffix("/") { parts.path.removeLast() }
    return parts.url?.absoluteString
  }
}

private struct WebIndexSeenHint: Sendable {
  let key: String
  let value: JSONValue
  let date: Date
}
