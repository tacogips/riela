import Foundation
import RielaCore

extension WebCollector {
  func collectFeed() async throws -> JSONObject {
    var state = initialState()
    let previousMarker = state["_webCollection"]
    var headers: [String: String] = [:]
    let oldScan: JSONObject
    if case let .object(value)? = state["last_scan"] { oldScan = value } else { oldScan = [:] }
    if previousMarker == marker(), oldScan["window_limited"] != .bool(true), oldScan["future_entries"] == .integer(0) {
      for (key, header) in [("etag", "If-None-Match"), ("last_modified", "If-Modified-Since")] {
        if let value = webCollectionText(state[key]), value.utf8.count <= 1024,
          !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) { headers[header] = value }
      }
    }
    let response = try await PublicWebHTTP.read(options.url ?? "", headers: headers,
      blockedHosts: options.blockedHosts, deadline: deadline, transport: reader.transport)
    if response.status == 304 {
      guard !headers.isEmpty else { throw PublicWebError.invalidDocument }
      return try output(records: [], state: state, scan: ["coverage": .string("unchanged-feed"), "not_modified": .bool(true),
        "rejected_entries": oldScan["rejected_entries"] ?? .integer(0)], complete: true)
    }
    let entries = try WebFeedDocument.parse(response.body, entities: options.entities)
    state["etag"] = .string(response.headers["etag"] ?? "")
    state["last_modified"] = .string(response.headers["last-modified"] ?? "")
    var seen: JSONObject
    if case let .object(value)? = state["seen"] { seen = value } else { seen = [:] }
    var counts: [String: Int] = [:], selected: [String] = [], candidates: [WebCollectionCandidate] = []
    var unique = Set<String>(), invalid = 0, future = 0
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: options.timezone) ?? .gmt
    for entry in entries {
      guard !entry.identity.isEmpty, entry.identity.utf8.count <= 4096,
        let stamp = WebCollectionTimestamp(entry.published) else { invalid += 1; continue }
      if stamp.date > clock() { future += 1; continue }
      guard stamp.date >= options.start.date, stamp.date < options.end.date else { continue }
      guard (try? PublicWebHTTP.destination(entry.url, blockedHosts: options.blockedHosts)) != nil else { invalid += 1; continue }
      let parts = calendar.dateComponents([.year, .month, .day], from: stamp.date)
      let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
      guard counts[day, default: 0] < options.maximum else { continue }
      let key = webCollectionKey(entry.identity)
      guard unique.insert(key).inserted else { continue }
      counts[day, default: 0] += 1
      selected.append(webCollectionKey(options.selectionPrefix + entry.identity))
      let fingerprint = webCollectionKey(entry.title + entry.body + stamp.wire)
      if case let .object(previous)? = seen[key], previous["fingerprint"] == .string(fingerprint) { continue }
      candidates.append(.init(identity: entry.identity, title: entry.title, text: entry.body, url: entry.url,
        published: stamp.wire, fingerprint: fingerprint, optionalArticle: true))
    }
    // A feed may cover several days. Keep the entire request under the public
    // collection wire budget rather than accidentally multiplying the cap.
    let admitted = Array(candidates.prefix(200))
    let results = try await records(admitted)
    var found: [JSONObject] = [], failedArticles = 0, deferred = candidates.count - admitted.count
    var remaining = try recordBudget(state: state)
    for result in results {
      guard let item = result.record, let candidate = result.candidate else { continue }
      let bytes = try JSONEncoder().encode(item).count + 1
      guard bytes <= remaining else { deferred += 1; continue }
      remaining -= bytes
      found.append(item); if result.articleFailed { failedArticles += 1 }
      seen[webCollectionKey(candidate.identity)] = .object(["fingerprint": .string(candidate.fingerprint ?? ""),
        "seen_at": .string(WebCollectionTimestamp.wire(clock()))])
    }
    state["seen"] = .object(seen)
    state["_webCollection"] = marker()
    state["candidate_selection"] = .object(["policy": .string(options.policy), "signature": .string(options.selectionSignature),
      "ids": .array(selected.map(JSONValue.string))])
    let complete = deferred == 0
    let scan: JSONObject = ["coverage": .string("current-feed-top-candidates"), "candidate_cap": .integer(Int64(options.maximum)),
      "selection_order": .string("publisher-feed-order"), "candidate_count": .integer(Int64(selected.count)),
      "exhaustive_index_complete": .bool(false), "article_failures": .integer(Int64(failedArticles)),
      "rejected_entries": .integer(Int64(invalid)), "future_entries": .integer(Int64(future)),
      "window_limited": .bool(deferred > 0), "deferred_count": .integer(Int64(deferred))]
    state["last_scan"] = .object(scan.merging(["acquisition_complete": .bool(complete), "has_progress": .bool(!found.isEmpty)]) { _, new in new })
    return try output(records: found, state: state, scan: scan, complete: complete)
  }
}
