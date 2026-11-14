import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class WebCollectionTests: XCTestCase {
  private let now = ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!

  func testTimestampsPreserveOffsetMicrosecondsAndRejectNaiveOrMalformedDates() {
    XCTAssertEqual(WebCollectionTimestamp("2026-10-25T14:54:18.004Z")?.wire, "2026-10-25T14:54:18.004000+00:00")
    XCTAssertEqual(WebCollectionTimestamp("2026-10-25T14:54:18+09:00")?.wire, "2026-10-25T14:54:18+09:00")
    XCTAssertEqual(WebCollectionTimestamp("Sun, 25 Oct 2026 10:00:00 +0900")?.wire, "2026-10-25T10:00:00+09:00")
    for value in ["2026-10-25", "2026-10-25T12:00:00", "Sun, 25 Oct 2026 10:00:00", "broken", "31 Feb 2026 10:00:00 GMT", "2026-02-30T12:00:00Z", "2026-10-25T24:00:00Z", "25 Oct 26 10:00:00 -0000"] {
      XCTAssertNil(WebCollectionTimestamp(value), value)
    }
  }

  func testRSSAtomAndExplicitEntityMapKeepCDATAAndRejectDTDOrUnknownEntity() throws {
    let raw = "<rss><channel><item><guid>a</guid><title>A&nbsp;B&mdash;&NotEqualTilde;</title>" +
      "<link>https://example.com/a</link><pubDate>Sun, 25 Oct 2026 10:00:00 +0000</pubDate>" +
      "<description><![CDATA[<p>A&nbsp;B</p>]]></description></item></channel></rss>"
    let entries = try WebFeedDocument.parse(Data(raw.utf8), entities: ["nbsp": "\u{00a0}", "mdash": "—", "NotEqualTilde": "\u{2242}\u{0338}"])
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries[0].title, "A\u{00a0}B—\u{2242}\u{0338}")
    XCTAssertEqual(entries[0].body, "<p>A&nbsp;B</p>")
    let atom = "<feed xmlns='http://www.w3.org/2005/Atom'><entry><id>x</id><title>Atom</title>" +
      "<link href='https://example.com/x'/><published>2026-10-25T10:00:00Z</published><summary>Text</summary></entry></feed>"
    let values = try WebFeedDocument.parse(Data(atom.utf8))
    XCTAssertEqual(values[0].url, "https://example.com/x")
    XCTAssertEqual(values[0].identity, "x")
    for value in ["<!DOCTYPE rss [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><rss>&x;</rss>", "<rss>&unknown;</rss>", "<rss>&nbsp</rss>"] {
      XCTAssertThrowsError(try WebFeedDocument.parse(Data(value.utf8), entities: ["nbsp": " "]))
    }
  }

  func testFeedPreservesLegacyFingerprintSkipsUnchangedAndPollsWithoutEmptyHeaders() async throws {
    let raw = feed([item("a"), item("b")])
    let fixture = WebCollectionFixture(responses: ["https://example.com/feed": .init(status: 200, headers: [:], body: Data(raw.utf8), url: "")])
    var options = base("feed")
    let first = try await collector(options, fixture).collect()
    XCTAssertEqual(rows(first).count, 2)
    let state = try XCTUnwrap(object(first["state"]))
    let seen = try XCTUnwrap(object(state["seen"]))
    XCTAssertEqual(object(seen[webCollectionKey("a")])?["fingerprint"], .string(webCollectionKey("Title aExcerpt a2026-10-25T10:00:00+00:00")))
    options["previous"] = .object(state)
    let second = try await collector(options, fixture).collect()
    XCTAssertTrue(rows(second).isEmpty)
    let calls = await fixture.requests
    XCTAssertEqual(calls.count, 2)
    XCTAssertTrue(calls.allSatisfy { $0.headers.isEmpty })
    XCTAssertEqual(object(object(second["state"])?["candidate_selection"])?["ids"],
      .array([.string(webCollectionKey("feed:fixture:a")), .string(webCollectionKey("feed:fixture:b"))]))
  }

  func testFeedUnchangedWindowUses304ButChangedWindowRequiresBody() async throws {
    let raw = feed([item("a")])
    let fixture = WebCollectionFixture(responses: ["https://example.com/feed": .init(status: 200, headers: ["etag": "version"], body: Data(raw.utf8), url: "")])
    var options = base("feed")
    let first = try await collector(options, fixture).collect()
    options["previous"] = first["state"]
    await fixture.setResponse(.init(status: 304, headers: ["etag": "version"], body: Data(), url: ""), for: "https://example.com/feed")
    let second = try await collector(options, fixture).collect()
    XCTAssertTrue(rows(second).isEmpty)
    XCTAssertEqual(object(second["scan"])?["not_modified"], .bool(true))
    var calls = await fixture.requests
    XCTAssertEqual(calls.last?.headers, ["If-None-Match": "version"])
    options["end"] = .string("2026-10-25T12:00:00Z")
    await fixture.setResponse(.init(status: 200, headers: [:], body: Data(raw.utf8), url: ""), for: "https://example.com/feed")
    _ = try await collector(options, fixture).collect()
    calls = await fixture.requests
    XCTAssertTrue(calls.last?.headers.isEmpty == true)
  }

  func testFutureMalformedAndPrivateItemsDoNotEraseValidSibling() async throws {
    let raw = feed([item("valid"), item("future", date: "2026-10-25T13:00:00Z"), item("naive", date: "2026-10-25T10:00:00"),
      item("private", link: "https://127.0.0.1/private")])
    let fixture = WebCollectionFixture(responses: ["https://example.com/feed": .init(status: 200, headers: [:], body: Data(raw.utf8), url: "")])
    let result = try await collector(base("feed"), fixture).collect()
    XCTAssertEqual(rows(result).map { $0["identity"] }, [.string("valid")])
    XCTAssertEqual(result["acquisition_complete"], .bool(true))
    XCTAssertEqual(result["status"], .string("partial_failed"))
    XCTAssertEqual(object(result["scan"])?["rejected_entries"], .integer(2))
    XCTAssertEqual(object(result["scan"])?["future_entries"], .integer(1))
    let requests = await fixture.requests
    XCTAssertEqual(requests.count, 1)
  }

  func testHackerNewsReadsIndependentStoriesConcurrentlyAndKeepsFailurePending() async throws {
    let baseURL = "https://hacker-news.firebaseio.com/v0/"
    var responses: [String: PublicWebHTTPResponse] = [baseURL + "topstories.json": response(.array((1...5).map { .integer(Int64($0)) }))]
    for identity in 1...4 { responses[baseURL + "item/\(identity).json"] = response(story(identity)) }
    let fixture = WebCollectionFixture(responses: responses, delay: .milliseconds(20))
    let first = try await collector(base("hackernews"), fixture).collect()
    XCTAssertEqual(rows(first).count, 4)
    XCTAssertEqual(first["acquisition_complete"], .bool(false))
    XCTAssertEqual(object(first["scan"])?["failed_ids"], .array([.string("5")]))
    let peak = await fixture.peak
    XCTAssertGreaterThanOrEqual(peak, 2); XCTAssertLessThanOrEqual(peak, 4)
    let state = try XCTUnwrap(object(first["state"]))
    XCTAssertNil(object(state["seen"])?["5"])
    await fixture.setResponse(response(story(5)), for: baseURL + "item/5.json")
    var options = base("hackernews"); options["previous"] = .object(state)
    let resumed = try await collector(options, fixture).collect()
    XCTAssertEqual(rows(resumed).map { $0["identity"] }, [.string("5")])
    XCTAssertEqual(resumed["acquisition_complete"], .bool(true))
  }

  func testOptionalArticleFailureRetainsBothAcquiredStoriesAndReportsPartial() async throws {
    let baseURL = "https://hacker-news.firebaseio.com/v0/"
    let fixture = WebCollectionFixture(responses: [baseURL + "topstories.json": response(.array([.integer(1), .integer(2)])),
      baseURL + "item/1.json": response(story(1, url: "https://example.com/fail")),
      baseURL + "item/2.json": response(story(2))])
    var options = base("hackernews"); options["fetchArticles"] = .bool(true); options["pageOptions"] = .object(["mode": .string("http")])
    let result = try await collector(options, fixture).collect()
    XCTAssertEqual(rows(result).count, 2)
    XCTAssertEqual(result["acquisition_complete"], .bool(true))
    XCTAssertEqual(result["status"], .string("partial_failed"))
    XCTAssertEqual(rows(result).first?["text"], .string("Excerpt 1"))
    XCTAssertEqual(object(result["scan"])?["article_failures"], .integer(1))
  }

  func testHistoricalHackerNewsKeepsLegacyIntervalsInertAndDoesNotRefetchSeenStories() async throws {
    var options = base("hackernews"); options["historical"] = .bool(true)
    options["previous"] = .object(["seen": .object(["1": .string("legacy")]), "history": .object(["pending": .array([.integer(9)])])])
    let listing: JSONValue = .object(["hits": .array([.object(["objectID": .string("1"), "points": .integer(50)]),
      .object(["objectID": .string("2"), "points": .integer(19)]), .object(["objectID": .string("3"), "points": .integer(30)])])])
    let fixture = WebCollectionFixture(responses: ["https://hn.algolia.com/api/v1/search": response(listing),
      "https://hacker-news.firebaseio.com/v0/item/3.json": response(story(3))])
    let result = try await collector(options, fixture).collect()
    XCTAssertEqual(rows(result).map { $0["identity"] }, [.string("3")])
    let state = try XCTUnwrap(object(result["state"]))
    XCTAssertEqual(state["history"], object(options["previous"])?["history"])
    XCTAssertEqual(object(state["ranked_selection"])?["ids"], .array([.string("1"), .string("3")]))
    let calls = await fixture.requests
    XCTAssertEqual(calls.count, 2)
    let query = URLComponents(string: calls[0].url)?.queryItems ?? []
    XCTAssertEqual(query.first { $0.name == "query" }?.value, "")
    XCTAssertTrue(query.first { $0.name == "numericFilters" }?.value?.contains("points>=20") == true)
  }

  func testOutputBudgetDefersEntriesWithoutAdvancingTheirSeenCheckpoint() async throws {
    let fixture = WebCollectionFixture(responses: ["https://example.com/feed": .init(status: 200, headers: ["etag": "version"],
      body: Data(feed(["a", "b", "c"].map { item($0).replacingOccurrences(of: "Excerpt " + $0, with: String(repeating: "😀", count: 50_000)) }).utf8), url: "")])
    var firstCollector = try collector(base("feed"), fixture); firstCollector.outputByteBudget = 1_400_100
    let result = try await firstCollector.collect()
    XCTAssertLessThan(rows(result).count, 3)
    XCTAssertEqual(result["acquisition_complete"], .bool(false))
    let seen = object(object(result["state"])?["seen"]) ?? [:]
    XCTAssertEqual(seen.count, rows(result).count)
    var options = base("feed"); options["previous"] = result["state"]
    let resumed = try await collector(options, fixture).collect()
    XCTAssertEqual(rows(resumed).count + rows(result).count, 3)
    let calls = await fixture.requests
    XCTAssertTrue(calls.last?.headers.isEmpty == true)
  }

  func testFeedTimezoneDayCapAndScopeResetRemainIndependentOfConcurrency() async throws {
    var options = base("feed"); options["maximumItems"] = .integer(2); options["timezone"] = .string("Asia/Tokyo")
    let entries = (0..<6).map { item(String($0), date: $0 < 3 ? "2026-10-24T14:00:00Z" : "2026-10-24T16:00:00Z") }
    options["start"] = .string("2026-10-24T00:00:00Z")
    let fixture = WebCollectionFixture(responses: ["https://example.com/feed": .init(status: 200, headers: [:], body: Data(feed(entries).utf8), url: "")])
    let first = try await collector(options, fixture).collect()
    XCTAssertEqual(rows(first).map { $0["identity"] }, [.string("0"), .string("1"), .string("3"), .string("4")])
    options["previous"] = first["state"]; options["maxConcurrency"] = .integer(1)
    let second = try await collector(options, fixture).collect()
    XCTAssertTrue(rows(second).isEmpty)
    options["selectionKeyPrefix"] = .string("another-source:")
    let third = try await collector(options, fixture).collect()
    XCTAssertEqual(rows(third).count, 4)
  }

  func testCancellationDoesNotReturnAnAdvancedCheckpoint() async throws {
    let baseURL = "https://hacker-news.firebaseio.com/v0/"
    let fixture = WebCollectionFixture(responses: [baseURL + "topstories.json": response(.array([.integer(1)])),
      baseURL + "item/1.json": response(story(1))], delay: .seconds(2))
    let value = try collector(base("hackernews"), fixture)
    let task = Task { try await value.collect() }
    try await Task.sleep(for: .milliseconds(20)); task.cancel()
    do { _ = try await task.value; XCTFail("cancelled collection returned a checkpoint") } catch { XCTAssertTrue(error is CancellationError) }
  }

  func testCLIKeepsLiteralContextAndDispatchesWebCollectorWithoutProviderProcesses() async throws {
    let instant = Date()
    let published = WebCollectionTimestamp.wire(instant.addingTimeInterval(-60))
    let fixture = WebCollectionFixture(responses: ["https://example.com/feed": .init(status: 200, headers: [:],
      body: Data(feed([item("a", date: published)]).utf8), url: "")])
    var options = base("feed")
    options["start"] = .string(WebCollectionTimestamp.wire(instant.addingTimeInterval(-3600)))
    options["end"] = .string(WebCollectionTimestamp.wire(instant))
    try await PublicWebExecutionContext.$transport.withValue({ try await fixture.read($0) }, operation: {
      let config: JSONObject = ["options": .string("{{request}}"), "context": .string("{{opaque}}"),
        "postprocess": .array([.object(["pick": .string("/acquisition_complete")])])]
      let variables: JSONObject = ["request": .object(options), "opaque": .object(["cursor": .string("{{literal}}")])]
      let result = await RielaCLIApplication().run(["node", "run", "riela/web-collect", "--config",
        try JSONValue.object(config).compactJSONString(), "--variables", try JSONValue.object(variables).compactJSONString(), "--output", "json"],
        environment: ["HOME": "/tmp", "PATH": ""])
      XCTAssertEqual(result.exitCode, .success, result.stdout + result.stderr)
      let output = try JSONDecoder().decode(NodeRunCommandResult.self, from: Data(result.stdout.utf8))
      XCTAssertEqual(output.payload["context"], variables["opaque"])
      XCTAssertEqual(output.payload["processed"], .bool(true))
      XCTAssertEqual(rows(output.payload).count, 1)
    })
  }

  func testMismatchedProviderIdentityStaysPendingAndNeverEntersSeen() async throws {
    let baseURL = "https://hacker-news.firebaseio.com/v0/"
    let fixture = WebCollectionFixture(responses: [baseURL + "topstories.json": response(.array([.integer(1)])),
      baseURL + "item/1.json": response(story(2))])
    let result = try await collector(base("hackernews"), fixture).collect()
    XCTAssertTrue(rows(result).isEmpty)
    XCTAssertEqual(result["acquisition_complete"], .bool(false))
    XCTAssertEqual(object(result["scan"])?["failed_ids"], .array([.string("1")]))
    XCTAssertTrue((object(object(result["state"])?["seen"]) ?? [:]).isEmpty)
  }

  func testUnsolicited304CannotCompleteAnUnscannedWindow() async throws {
    let fixture = WebCollectionFixture(responses: ["https://example.com/feed": .init(status: 304, headers: [:], body: Data(), url: "")])
    do { _ = try await collector(base("feed"), fixture).collect(); XCTFail("unsolicited 304 accepted") } catch { XCTAssertEqual(error as? PublicWebError, .invalidDocument) }
  }

  func testFilteredHNItemsCompleteCurrentPollAndCanBecomeStoriesOnLaterPoll() async throws {
    let url = "https://hacker-news.firebaseio.com/v0/"
    let job: JSONValue = .object(["id": .integer(1), "type": .string("job"), "title": .string("job")])
    let fixture = WebCollectionFixture(responses: [url + "topstories.json": response(.array([.integer(1), .integer(2), .integer(3)])),
      url + "item/1.json": response(job), url + "item/2.json": response(.null), url + "item/3.json": response(story(3))])
    let first = try await collector(base("hackernews"), fixture).collect()
    XCTAssertEqual(first["acquisition_complete"], .bool(true))
    XCTAssertEqual(rows(first).map { $0["identity"] }, [.string("3")])
    XCTAssertNil(object(object(first["state"])?["seen"])?["1"])
    XCTAssertNil(object(object(first["state"])?["seen"])?["2"])
    await fixture.setResponse(response(story(1)), for: url + "item/1.json")
    await fixture.setResponse(response(story(2)), for: url + "item/2.json")
    var options = base("hackernews"); options["previous"] = first["state"]
    let second = try await collector(options, fixture).collect()
    XCTAssertEqual(rows(second).map { $0["identity"] }, [.string("1"), .string("2")])
  }

  func testDeterministicFeedRejectionsDoNotConsumeCandidateCapOrBlockConditionalPolls() async throws {
    let raw = feed([item("private", link: "https://127.0.0.1/a"), item("naive", date: "2026-10-25T10:00:00"), item("valid")])
    let fixture = WebCollectionFixture(responses: ["https://example.com/feed": .init(status: 200, headers: ["etag": "version"], body: Data(raw.utf8), url: "")])
    var options = base("feed"); options["maximumItems"] = .integer(1)
    let first = try await collector(options, fixture).collect()
    XCTAssertEqual(rows(first).map { $0["identity"] }, [.string("valid")])
    XCTAssertEqual(first["acquisition_complete"], .bool(true))
    XCTAssertEqual(first["status"], .string("partial_failed"))
    options["previous"] = first["state"]
    await fixture.setResponse(.init(status: 304, headers: [:], body: Data(), url: ""), for: "https://example.com/feed")
    let second = try await collector(options, fixture).collect()
    XCTAssertEqual(second["acquisition_complete"], .bool(true))
    XCTAssertEqual(second["status"], .string("partial_failed"))
    let calls = await fixture.requests
    XCTAssertEqual(calls.last?.headers["If-None-Match"], "version")
  }

  func testFutureEntryBecomesEligibleWithoutChangingFeedETag() async throws {
    let raw = feed([item("future", date: "2026-10-25T13:00:00Z")])
    let fixture = WebCollectionFixture(responses: ["https://example.com/feed": .init(status: 200, headers: ["etag": "version"], body: Data(raw.utf8), url: "")])
    var options = base("feed")
    let first = try await collector(options, fixture).collect()
    XCTAssertTrue(rows(first).isEmpty)
    options["previous"] = first["state"]
    var later = try collector(options, fixture); later.clock = { [now] in now.addingTimeInterval(2 * 3600) }
    let second = try await later.collect()
    XCTAssertEqual(rows(second).map { $0["identity"] }, [.string("future")])
    let calls = await fixture.requests
    XCTAssertTrue(calls.last?.headers.isEmpty == true)
  }

  func testOversizedInitialStateFailsBeforeHTTPInsteadOfDeferringForever() async throws {
    let fixture = WebCollectionFixture(responses: [:])
    var options = base("feed"); options["previous"] = .object(["opaque": .string(String(repeating: "x", count: 7_000_000))])
    do { _ = try await collector(options, fixture).collect(); XCTFail("state accepted without record capacity") } catch { XCTAssertEqual(error as? PublicWebError, .invalidInput) }
    let calls = await fixture.requests
    XCTAssertTrue(calls.isEmpty)
  }

  func testMalformedPresentHNTypeCannotBecomeAnAcquiredStory() async throws {
    let url = "https://hacker-news.firebaseio.com/v0/"
    for type in [JSONValue.integer(7), .null, .string(""), .string("unknown")] {
      var value = try XCTUnwrap(object(story(1))); value["type"] = type
      let fixture = WebCollectionFixture(responses: [url + "topstories.json": response(.array([.integer(1)])),
        url + "item/1.json": response(.object(value))])
      let result = try await collector(base("hackernews"), fixture).collect()
      XCTAssertTrue(rows(result).isEmpty)
      XCTAssertEqual(result["acquisition_complete"], .bool(false))
      XCTAssertEqual(object(result["scan"])?["failed_ids"], .array([.string("1")]))
      XCTAssertTrue((object(object(result["state"])?["seen"]) ?? [:]).isEmpty)
    }
  }

  private func base(_ kind: String) -> JSONObject {
    var value: JSONObject = ["kind": .string(kind), "start": .string("2026-10-25T00:00:00Z"), "end": .string("2026-10-26T00:00:00Z"),
      "fetchArticles": .bool(false), "selectionPolicy": .string("ranked-news-v1"), "selectionKeyPrefix": .string("feed:fixture:"),
      "selectionSignature": .string("signature")]
    if kind == "feed" { value["url"] = .string("https://example.com/feed") }; return value
  }
  private func collector(_ value: JSONObject, _ fixture: WebCollectionFixture) throws -> WebCollector {
    WebCollector(options: try .init(value), reader: .init(transport: { try await fixture.read($0) }, browser: { _, _, _, _ in
      throw PublicWebError.transport
    }), clock: { [now] in now })
  }
  private func feed(_ values: [String]) -> String { "<rss><channel>" + values.joined() + "</channel></rss>" }
  private func item(_ id: String, date: String = "2026-10-25T10:00:00Z", link: String? = nil) -> String {
    "<item><guid>\(id)</guid><title>Title \(id)</title><description>Excerpt \(id)</description>" +
      "<link>\(link ?? "https://example.com/" + id)</link><pubDate>\(date)</pubDate></item>"
  }
  private func story(_ id: Int, url: String? = nil) -> JSONValue {
    var value: JSONObject = ["id": .integer(Int64(id)), "title": .string("Title \(id)"), "text": .string("Excerpt \(id)"),
      "time": .integer(Int64(now.timeIntervalSince1970) - 3600), "score": .integer(100)]
    if let url { value["url"] = .string(url) }; return .object(value)
  }
  private func response(_ value: JSONValue) -> PublicWebHTTPResponse {
    .init(status: 200, headers: [:], body: (try? JSONEncoder().encode(value)) ?? Data(), url: "")
  }
  private func object(_ value: JSONValue?) -> JSONObject? { if case let .object(value)? = value { return value }; return nil }
  private func rows(_ value: JSONObject) -> [JSONObject] {
    guard case let .array(rows)? = value["records"] else { return [] }; return rows.compactMap { object($0) }
  }
}

private actor WebCollectionFixture {
  var responses: [String: PublicWebHTTPResponse]
  var requests: [PublicWebHTTPRequest] = []
  var active = 0, peak = 0
  let delay: Duration
  init(responses: [String: PublicWebHTTPResponse], delay: Duration = .zero) { self.responses = responses; self.delay = delay }
  func setResponse(_ value: PublicWebHTTPResponse, for url: String) { responses[url] = value }
  func read(_ request: PublicWebHTTPRequest) async throws -> PublicWebHTTPResponse {
    requests.append(request); active += 1; peak = max(peak, active)
    defer { active -= 1 }
    if delay > .zero { try await Task.sleep(for: delay) }
    guard let value = responses[request.url] ?? responses[request.url.components(separatedBy: "?")[0]] else { throw PublicWebError.transport }; return value
  }
}
