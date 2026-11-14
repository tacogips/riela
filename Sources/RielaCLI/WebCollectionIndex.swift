import Foundation
import RielaCore

private struct WebIndexPageResult: Sendable {
  let link: String
  let outcome: String
  var published: WebCollectionTimestamp?
  var record: JSONObject?
}

extension WebCollector {
  func collectIndex() async throws -> JSONObject {
    guard let policy = options.index, let listingURL = options.url else { throw PublicWebError.invalidInput }
    var state = initialState()
    let listing = try await indexPage(listingURL, policy: policy)
    guard let final = webCollectionText(listing["url"]), URL(string: final)?.host == URL(string: listingURL)?.host,
      case let .array(rawLinks)? = listing["links"] else { throw PublicWebError.invalidDocument }
    if policy.publicationJSONLDType != nil, final != listingURL { throw PublicWebError.invalidDocument }
    var unique = Set<String>()
    let allLinks = rawLinks.compactMap { webCollectionText($0).flatMap { policy.articleURL($0, listing: listingURL) } }
      .filter { unique.insert($0).inserted }
    let links = Array(allLinks.prefix(options.maximum))
    guard !links.isEmpty else { throw PublicWebError.invalidDocument }
    let current = Set(links.map(webCollectionKey))
    var seen = indexObject(state["seen"])
    var deferred = indexObject(state["after_window"]).filter { current.contains($0.key) }
    var attempts = indexObject(state["article_attempts"]).filter { current.contains($0.key) && seen[$0.key] == nil }
    var pending = links.filter { link in
      let key = webCollectionKey(link)
      if seen[key] != nil { return false }
      if let date = webIndexDate(deferred[key]), date.date >= options.end.date { return false }
      return true
    }
    // Stable publisher order for equal attempt counts; unsuccessful leading
    // pages cannot starve untouched candidates on a later invocation.
    pending = pending.enumerated().sorted { lhs, rhs in
      let left = indexAttempts(attempts[webCollectionKey(lhs.element)])
      let right = indexAttempts(attempts[webCollectionKey(rhs.element)])
      return left == right ? lhs.offset < rhs.offset : left < right
    }.map(\.element)
    let selected = Array(pending.prefix(policy.maximumArticles))
    let results: [WebIndexPageResult] = try await bounded(selected) { _, link in await indexArticle(link, policy: policy) }
    var scan: JSONObject = ["coverage": .string("current-index-only"), "selection_order": .string("publisher-index-order"),
      "listing_discovered": .integer(Int64(allLinks.count)), "candidate_cap": .integer(Int64(options.maximum)),
      "candidate_omitted": .integer(Int64(allLinks.count - links.count)), "candidate_selection_policy": .string(options.policy),
      "exhaustive_index_complete": .bool(false), "discovered": .integer(Int64(links.count)),
      "reused": .integer(Int64(links.count - pending.count)), "attempted": .integer(Int64(results.count)),
      "content_scope": .string(policy.metadataOnly ? "public-headline-and-lead" : "public-page")]
    var counts: [String: Int] = ["dated_in_window": 0, "undated": 0, "future": 0, "outside_window": 0, "unavailable": 0, "deferred_count": 0]
    var records: [JSONObject] = [], remaining = try recordBudget(state: state)
    for result in results {
      let key = webCollectionKey(result.link)
      attempts[key] = .integer(Int64(min(indexAttempts(attempts[key]) + 1, 1_000_000)))
      if let record = result.record {
        let bytes = try JSONEncoder().encode(record).count + 1
        guard bytes <= remaining else { counts["deferred_count", default: 0] += 1; continue }
        remaining -= bytes; records.append(record)
      }
      counts[result.outcome, default: 0] += 1
      if let stamp = result.published {
        if result.outcome == "dated_in_window" || (result.outcome == "outside_window" && stamp.date < options.start.date) {
          seen[key] = .object(["seen_at": .string(WebCollectionTimestamp.wire(clock())), "published_at": .string(stamp.wire),
            "outcome": .string(result.outcome == "dated_in_window" ? "inspected-candidate" : "outside-window")])
          deferred.removeValue(forKey: key)
        } else if result.outcome == "outside_window" { deferred[key] = .string(stamp.wire) }
      }
    }
    let limited = pending.count > selected.count || counts["deferred_count", default: 0] > 0
    let complete = !limited && counts["unavailable", default: 0] == 0 && counts["undated", default: 0] == 0
    for (key, value) in counts { scan[key] = .integer(Int64(value)) }
    scan["window_limited"] = .bool(limited)
    for key in current {
      if case var .object(row)? = seen[key] {
        row["last_seen_at"] = .string(WebCollectionTimestamp.wire(clock())); seen[key] = .object(row)
      }
    }
    state["seen"] = .object(policy.boundedSeen(seen, current: current)); state["after_window"] = .object(deferred); state["article_attempts"] = .object(attempts)
    state["_webCollection"] = marker()
    state["candidate_selection"] = .object(["policy": .string(options.policy), "signature": .string(options.selectionSignature),
      "ids": .array(links.map { .string(webCollectionKey(options.selectionPrefix + $0)) })])
    state["last_scan"] = .object(scan.merging(["acquisition_complete": .bool(complete), "has_progress": .bool(!records.isEmpty)]) { _, value in value })
    records.sort { (webCollectionText($0["published_at"]).flatMap(WebCollectionTimestamp.init)?.date ?? .distantPast) >
      (webCollectionText($1["published_at"]).flatMap(WebCollectionTimestamp.init)?.date ?? .distantPast) }
    return try output(records: records, state: state, scan: scan, complete: complete)
  }

  private func indexPage(_ url: String, policy: WebCollectionIndexOptions) async throws -> JSONObject {
    try checkDeadline()
    var pageOptions = options.pageOptions
    if policy.publicationJSONLDType != nil { pageOptions.mode = "http" }
    return try await reader.page(url: url, options: pageOptions, blockedHosts: options.blockedHosts,
      metadataOnly: policy.metadataOnly, includeRaw: policy.publicationJSONLDType != nil,
      linkPattern: policy.linkPattern, deadline: deadline)
  }

  private func indexArticle(_ link: String, policy: WebCollectionIndexOptions) async -> WebIndexPageResult {
    do {
      let page = try await indexPage(link, policy: policy)
      guard let final = webCollectionText(page["url"]), policy.articleURL(final, listing: options.url ?? "") == link else {
        throw PublicWebError.invalidDocument
      }
      if policy.metadataOnly, let canonical = webCollectionText(page["canonical"]),
        policy.articleURL(canonical, listing: options.url ?? "") != link { throw PublicWebError.invalidDocument }
      let published: WebCollectionTimestamp?
      if let type = policy.publicationJSONLDType {
        guard final == link, let raw = webCollectionText(page["raw_body_base64"]), let data = Data(base64Encoded: raw) else {
          throw PublicWebError.invalidDocument
        }
        published = try PublicWebPublication.date(data, url: final, type: type)
      } else { published = webIndexDate(page["published_at"]) }
      guard let published else { return .init(link: link, outcome: "undated") }
      if published.date > clock() { return .init(link: link, outcome: "future", published: published) }
      guard published.date >= options.start.date, published.date < options.end.date else {
        return .init(link: link, outcome: "outside_window", published: published)
      }
      let record: JSONObject = ["identity": .string(link), "url": .string(link), "title": page["title"] ?? .string(""),
        "text": page["text"] ?? .string(""), "published_at": .string(published.wire),
        "fetched_at": .string(WebCollectionTimestamp.wire(clock())),
        "content_scope": .string(policy.metadataOnly ? "public-headline-and-lead" : "public-page")]
      return .init(link: link, outcome: "dated_in_window", published: published, record: record)
    } catch { return .init(link: link, outcome: "unavailable") }
  }
}

private func indexObject(_ value: JSONValue?) -> JSONObject { if case let .object(value)? = value { return value }; return [:] }
private func indexAttempts(_ value: JSONValue?) -> Int {
  guard case let .integer(count)? = value, count >= 0 else { return 0 }; return Int(min(count, 1_000_000))
}

private func webIndexDate(_ value: JSONValue?) -> WebCollectionTimestamp? {
  guard let raw = webCollectionText(value), raw.utf8.count <= 80,
    raw.range(of: #"^\d{4}-\d{2}-\d{2}[Tt ]"#, options: .regularExpression) != nil else { return nil }
  return WebCollectionTimestamp(raw)
}
