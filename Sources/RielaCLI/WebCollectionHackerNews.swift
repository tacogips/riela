import Foundation
import RielaCore

extension WebCollector {
  func collectHackerNews() async throws -> JSONObject {
    var state = initialState()
    var seen: JSONObject
    if case let .object(value)? = state["seen"] { seen = value } else { seen = [:] }
    let identities: [String]
    var rankingInvalid = false
    if options.historical {
      var components = URLComponents(string: "https://hn.algolia.com/api/v1/search")!
      let start = Int64(ceil(options.start.date.timeIntervalSince1970)), end = Int64(ceil(options.end.date.timeIntervalSince1970))
      components.queryItems = [URLQueryItem(name: "query", value: ""), .init(name: "tags", value: "story"),
        .init(name: "numericFilters", value: "created_at_i>=\(start),created_at_i<\(end),points>=\(options.minimumPoints)"),
        .init(name: "hitsPerPage", value: String(options.maximum)), .init(name: "page", value: "0")]
      guard let url = components.url?.absoluteString, case let .object(page) = try await readJSON(url),
        case let .array(hits)? = page["hits"] else { throw PublicWebError.invalidDocument }
      var result: [String] = []
      for value in hits.prefix(options.maximum) {
        guard case let .object(hit) = value, let identity = webCollectionText(hit["objectID"]), Self.hnIdentity(identity),
          case let .integer(score)? = hit["points"] else { rankingInvalid = true; continue }
        if score >= options.minimumPoints, !result.contains(identity) { result.append(identity) }
      }
      identities = result
    } else {
      guard case let .array(ids) = try await readJSON("https://hacker-news.firebaseio.com/v0/topstories.json") else {
        throw PublicWebError.invalidDocument
      }
      var result: [String] = []
      for value in ids.prefix(options.maximum) {
        guard case let .integer(identity) = value, identity > 0 else { rankingInvalid = true; continue }
        let text = String(identity)
        if !result.contains(text) { result.append(text) }
      }
      identities = result
    }
    let frozenSeen = seen
    let stories: [WebCollectionItemResult] = try await bounded(identities) { index, identity in
      if options.historical, frozenSeen[identity] != nil {
        return .init(index: index, candidate: nil, record: [:], articleFailed: false)
      }
      do {
        let value = try await readJSON("https://hacker-news.firebaseio.com/v0/item/" + identity + ".json")
        if value == .null { return .init(index: index, candidate: nil, record: [:], articleFailed: false) }
        guard case let .object(story) = value,
          case let .integer(returnedID)? = story["id"], String(returnedID) == identity else { throw PublicWebError.invalidDocument }
        if story["deleted"] == .bool(true) || story["dead"] == .bool(true) {
          return .init(index: index, candidate: nil, record: [:], articleFailed: false)
        }
        if let rawType = story["type"] {
          guard case let .string(type) = rawType, ["story", "job", "poll", "pollopt", "comment"].contains(type) else {
            throw PublicWebError.invalidDocument
          }
          if type != "story" { return .init(index: index, candidate: nil, record: [:], articleFailed: false) }
        }
        guard          case let .integer(score)? = story["score"], case let .integer(seconds)? = story["time"],
          seconds >= 0, seconds <= 253_402_300_799, let title = webCollectionText(story["title"]) else { throw PublicWebError.invalidDocument }
        let published = Date(timeIntervalSince1970: Double(seconds))
        guard score >= options.minimumPoints, published >= options.start.date, published < options.end.date, published <= clock() else {
          return .init(index: index, candidate: nil, record: [:], articleFailed: false)
        }
        let rawURL = webCollectionText(story["url"])
        let url = rawURL.flatMap { (try? PublicWebHTTP.destination($0, blockedHosts: []))?.url } ?? "https://news.ycombinator.com/item?id=" + identity
        let candidate = WebCollectionCandidate(identity: identity, title: title, text: webCollectionText(story["text"]) ?? "", url: url,
          published: WebCollectionTimestamp.wire(published), optionalArticle: rawURL != nil)
        return .init(index: index, candidate: candidate, record: frozenSeen[identity] == nil ? nil : [:], articleFailed: false)
      } catch { return .init(index: index, candidate: nil, record: nil, articleFailed: false) }
    }
    let selected = options.historical ? identities : stories.compactMap { $0.candidate?.identity }
    let candidates = stories.compactMap { $0.record == nil ? $0.candidate : nil }
    let results = try await records(candidates)
    var found: [JSONObject] = [], failedArticles = 0, deferred: [String] = []
    var remaining = try recordBudget(state: state)
    for result in results {
      guard let record = result.record, let candidate = result.candidate else { continue }
      let bytes = try JSONEncoder().encode(record).count + 1
      guard bytes <= remaining else { deferred.append(candidate.identity); continue }
      remaining -= bytes
      found.append(record); seen[candidate.identity] = .string(WebCollectionTimestamp.wire(clock()))
      if result.articleFailed { failedArticles += 1 }
    }
    let failed = stories.filter { $0.candidate == nil && $0.record == nil }.map { identities[$0.index] } + deferred
    state["seen"] = .object(seen); state["_webCollection"] = marker()
    state["ranked_selection"] = .object(["policy": .string(options.policy), "ids": .array(selected.map(JSONValue.string)),
      "start": .integer(Int64(ceil(options.start.date.timeIntervalSince1970))), "end": .integer(Int64(ceil(options.end.date.timeIntervalSince1970))),
      "minimum_points": .integer(Int64(options.minimumPoints)), "candidate_cap": .integer(Int64(options.maximum))])
    let scan: JSONObject = ["coverage": .string(options.historical ? "algolia-popularity-top-candidates" : "current-top-listing-only"),
      "selection_policy": .string(options.policy), "selection_order": .string(options.historical ? "empty-query-points-then-comments" : "HN-topstories-order"),
      "minimum_points": .integer(Int64(options.minimumPoints)), "candidate_cap": .integer(Int64(options.maximum)),
      "requests": .integer(Int64(1 + identities.filter { !options.historical || frozenSeen[$0] == nil }.count)), "discovered": .integer(Int64(selected.count)),
      "pending_intervals": .integer(0), "window_limited": .bool(!deferred.isEmpty), "exhaustive_index_complete": .bool(false),
      "candidate_selection_complete": .bool(failed.isEmpty && !rankingInvalid), "failed_ids": .array(failed.map(JSONValue.string)),
      "article_failures": .integer(Int64(failedArticles))]
    state["last_scan"] = .object(scan.merging(["acquisition_complete": .bool(failed.isEmpty && !rankingInvalid),
      "has_progress": .bool(!found.isEmpty)]) { _, new in new })
    return try output(records: found, state: state, scan: scan, complete: failed.isEmpty && !rankingInvalid)
  }

  private static func hnIdentity(_ value: String) -> Bool {
    (1...32).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
  }
}
