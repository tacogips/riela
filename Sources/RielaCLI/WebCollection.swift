import Foundation
import RielaCore

struct WebCollectionCandidate: Sendable {
  var identity: String
  var title: String
  var text: String
  var url: String
  var published: String
  var fingerprint: String?
  var optionalArticle: Bool
}

struct WebCollectionItemResult: Sendable {
  let index: Int
  let candidate: WebCollectionCandidate?
  let record: JSONObject?
  let articleFailed: Bool
}

struct WebCollector: Sendable {
  static let metadataReserve = 1_000_000
  static let minimumRecordBudget = 400_000
  let options: WebCollectionOptions
  let reader: PublicWebReader
  var deadline: Date?
  var clock: @Sendable () -> Date = { Date() }
  var outputByteBudget = 8_000_000

  func collect() async throws -> JSONObject {
    try checkDeadline()
    guard try recordBudget(state: initialState()) >= Self.minimumRecordBudget else { throw PublicWebError.invalidInput }
    if options.kind == "feed" { return try await collectFeed() }
    if options.kind == "index" { return try await collectIndex() }
    return try await collectHackerNews()
  }

  func initialState() -> JSONObject {
    var value = options.previous
    if case let .object(marker)? = value["_webCollection"], marker["scope"] != .string(options.scope) {
      for key in ["seen", "etag", "last_modified", "candidate_selection", "ranked_selection", "after_window", "article_attempts", "last_scan"] { value.removeValue(forKey: key) }
    }
    if let policy = options.index, case let .object(seen)? = value["seen"] { value["seen"] = .object(policy.boundedSeen(seen)) }
    return value
  }

  func marker() -> JSONValue {
    .object(["scope": .string(options.scope), "start": .string(options.start.wire), "end": .string(options.end.wire)])
  }

  func checkDeadline() throws {
    try Task.checkCancellation()
    if let deadline, clock() >= deadline { throw PublicWebError.timeout }
  }

  func readJSON(_ url: String) async throws -> JSONValue {
    try checkDeadline()
    let response = try await PublicWebHTTP.read(url, deadline: deadline, transport: reader.transport)
    guard response.status == 200 else { throw PublicWebError.httpStatus(response.status) }
    return try JSONDecoder().decode(JSONValue.self, from: response.body)
  }

  func records(_ candidates: [WebCollectionCandidate]) async throws -> [WebCollectionItemResult] {
    try await bounded(candidates) { index, candidate in
      var text = candidate.text, scope = options.kind == "feed" ? "feed-excerpt" : "title-and-excerpt", failed = false
      if options.fetchArticles && candidate.optionalArticle {
        do {
          try checkDeadline()
          let page = try await reader.page(url: candidate.url, options: options.pageOptions, blockedHosts: options.blockedHosts,
            metadataOnly: false, includeRaw: false, linkPattern: nil, deadline: deadline)
          guard let body = webCollectionText(page["text"]) else { throw PublicWebError.invalidDocument }
          text = body; scope = page["method"] == .string("browser") ? "rendered-article" : "article-body"
        } catch { failed = true }
      }
      let value: JSONObject = ["identity": .string(candidate.identity), "title": .string(PublicWebDocument.compact(candidate.title, limit: 500)),
        "text": .string(String(String.UnicodeScalarView(text.unicodeScalars.prefix(50_000)))), "url": .string(candidate.url),
        "published_at": .string(candidate.published), "fetched_at": .string(WebCollectionTimestamp.wire(clock())),
        "content_scope": .string(scope)]
      return .init(index: index, candidate: candidate, record: value, articleFailed: failed)
    }
  }

  func bounded<Input: Sendable, Output: Sendable>(
    _ values: [Input], operation: @escaping @Sendable (Int, Input) async -> Output
  ) async throws -> [Output] {
    let results = await withTaskGroup(of: IndexedCollectionResult<Output>.self) { group in
      var next = 0, results: [IndexedCollectionResult<Output>] = []
      func add() {
        let index = next; next += 1
        group.addTask { .init(index: index, value: await operation(index, values[index])) }
      }
      for _ in 0..<min(options.concurrency, values.count) { add() }
      while let result = await group.next() {
        results.append(result)
        if next < values.count { add() }
      }
      return results.sorted { $0.index < $1.index }.map(\.value)
    }
    try Task.checkCancellation()
    return results
  }

  func recordBudget(state: JSONObject) throws -> Int {
    max(0, outputByteBudget - (try JSONEncoder().encode(state).count) - Self.metadataReserve)
  }

  func output(records: [JSONObject], state: JSONObject, scan: JSONObject, complete: Bool) throws -> JSONObject {
    let failedArticles: Int64 = (scan["article_failures"].flatMap { if case let .integer(value) = $0 { return value }; return nil }) ?? 0
    let rejected: Int64 = (scan["rejected_entries"].flatMap { if case let .integer(value) = $0 { return value }; return nil }) ?? 0
    let result: JSONObject = ["kind": .string("web-collection"), "records": .array(records.map(JSONValue.object)),
      "state": .object(state), "scan": .object(scan), "acquisition_complete": .bool(complete), "has_progress": .bool(!records.isEmpty),
      "status": .string(complete && failedArticles == 0 && rejected == 0 ? "completed" : "partial_failed")]
    guard try JSONEncoder().encode(result).count <= outputByteBudget else { throw PublicWebError.oversized }
    return result
  }
}

func webCollectionKey(_ value: String) -> String { String(JSONCanonical.sha256Hex(Data(value.utf8)).prefix(24)) }

func webCollectionText(_ value: JSONValue?) -> String? {
  guard case let .string(text)? = value, !text.isEmpty else { return nil }; return text
}

private struct IndexedCollectionResult<Value: Sendable>: Sendable {
  let index: Int
  let value: Value
}
