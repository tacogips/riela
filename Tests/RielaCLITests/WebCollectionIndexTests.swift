import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class WebCollectionIndexTests: XCTestCase {
  private let listing = "https://example.com/newest"
  private let instant = ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!
  private func link(_ id: Int) -> String { "https://example.com/news/\(id)" }
  private func options(maximum: Int = 3) -> JSONObject {
    ["kind": .string("index"), "url": .string(listing), "start": .string("2026-10-25T00:00:00Z"),
     "end": .string("2026-10-26T00:00:00Z"), "selectionKeyPrefix": .string("feed:fixture:"),
     "pageOptions": .object(["mode": .string("http")]),
     "index": .object(["linkPattern": .string("^/news/[0-9]+/?$"), "maximumArticles": .integer(Int64(maximum))])]
  }
  private func page(_ date: String = "2026-10-25T10:00:00Z", text: String = "Concrete public article") -> String {
    "<html><head><title>Product release</title><meta property='article:published_time' content='\(date)'></head>" +
      "<body><article>\(text)</article></body></html>"
  }
  private func fixture(_ count: Int, pages: [Int: String] = [:], delay: Duration = .zero) -> IndexFixture {
    var values = [listing: (1...max(1, count)).map { "<a href='\(link($0))'>Article</a>" }.joined()]
    for id in 1...max(1, count) { values[link(id)] = pages[id] ?? page() }
    return IndexFixture(values: values, delay: delay)
  }
  private func collector(_ value: JSONObject, _ fixture: IndexFixture) throws -> WebCollector {
    .init(options: try .init(value), reader: .init(transport: { try await fixture.read($0) }, browser: { _, _, _, _ in
      throw PublicWebError.transport
    }), clock: { [instant] in instant })
  }
  private func object(_ value: JSONValue?) -> JSONObject { if case let .object(value)? = value { return value }; return [:] }
  private func rows(_ value: JSONObject) -> [JSONObject] {
    guard case let .array(values)? = value["records"] else { return [] }; return values.map { object($0) }
  }

  func testTwoPollsKeepLegacySeenAndDoNotFetchAcquiredBodiesAgain() async throws {
    let fixture = fixture(5, delay: .milliseconds(10))
    var config = options()
    let first = try await collector(config, fixture).collect()
    XCTAssertEqual(rows(first).map { $0["identity"] }, (1...3).map { .string(link($0)) })
    XCTAssertEqual(first["acquisition_complete"], .bool(false))
    config["previous"] = first["state"]
    let second = try await collector(config, fixture).collect()
    XCTAssertEqual(rows(second).map { $0["identity"] }, (4...5).map { .string(link($0)) })
    XCTAssertEqual(second["acquisition_complete"], .bool(true))
    config["previous"] = second["state"]
    let third = try await collector(config, fixture).collect()
    XCTAssertTrue(rows(third).isEmpty)
    let calls = await fixture.calls
    XCTAssertEqual(calls.count, 8)
    let peak = await fixture.peak
    XCTAssertGreaterThan(peak, 1); XCTAssertLessThanOrEqual(peak, 4)
    let state = object(third["state"])
    XCTAssertEqual(object(state["seen"]).count, 5)
    XCTAssertFalse(try JSONValue.object(state).compactJSONString().contains("Concrete public article"))
    XCTAssertEqual(object(state["candidate_selection"])["ids"], .array((1...5).map { .string(webCollectionKey("feed:fixture:" + link($0))) }))
  }

  func testLegacyMetadataResumesAndHistoricalDeferredFrontDoesNotStarveLaterLinks() async throws {
    let fixture = fixture(5, pages: [1: page("2026-10-25T10:00:00Z"), 2: page("2026-10-25T10:00:00Z"), 3: page("2026-10-25T10:00:00Z"),
      4: page("2026-10-24T10:00:00Z"), 5: page("2026-10-24T10:00:00Z")])
    var config = options()
    config["start"] = .string("2026-10-24T00:00:00Z"); config["end"] = .string("2026-10-25T00:00:00Z")
    let first = try await collector(config, fixture).collect()
    XCTAssertTrue(rows(first).isEmpty)
    config["previous"] = first["state"]
    let second = try await collector(config, fixture).collect()
    XCTAssertEqual(rows(second).count, 2)
    XCTAssertEqual(second["acquisition_complete"], .bool(true))
    let calls = await fixture.calls
    XCTAssertEqual(calls.count, 7)
    // Import an unmarked legacy seen map without requiring a new receipt.
    config["previous"] = .object(["seen": .object([webCollectionKey(link(4)): .object(["seen_at": .string("legacy")])]),
      "after_window": object(first["state"])["after_window"] ?? .object([:])])
    let legacy = try await collector(config, fixture).collect()
    XCTAssertEqual(rows(legacy).map { $0["identity"] }, [.string(link(5))])
  }

  func testUnavailablePrefixRotatesWhileUndatedFutureAndPrivateRedirectStayUnseen() async throws {
    let fixture = fixture(5)
    for id in 1...3 { await fixture.remove(link(id)) }
    var config = options()
    let first = try await collector(config, fixture).collect()
    config["previous"] = first["state"]
    let second = try await collector(config, fixture).collect()
    XCTAssertEqual(rows(second).map { $0["identity"] }, [.string(link(4)), .string(link(5))])
    XCTAssertEqual(object(second["scan"])["unavailable"], .integer(1))
    XCTAssertEqual(second["acquisition_complete"], .bool(false))
    let other = fixtureForSpecialPages()
    let result = try await collector(options(), other).collect()
    XCTAssertTrue(rows(result).isEmpty)
    XCTAssertEqual(object(result["scan"])["undated"], .integer(1))
    XCTAssertEqual(object(result["scan"])["future"], .integer(1))
    XCTAssertEqual(object(result["scan"])["unavailable"], .integer(1))
    XCTAssertTrue(object(object(result["state"])["seen"]).isEmpty)
  }

  private func fixtureForSpecialPages() -> IndexFixture {
    IndexFixture(values: [listing: (1...3).map { "<a href='\(link($0))'>A</a>" }.joined(),
      link(1): page("invalid"), link(2): page("2026-10-25T13:00:00Z"), link(3): page()],
      finalURLs: [link(3): "https://127.0.0.1/private"])
  }

  func testGrowingAsOfRetriesNewerArticleButNeverRefetchesOlderTombstone() async throws {
    let fixture = fixture(2, pages: [1: page("2026-10-25T11:00:00Z"), 2: page("2026-10-24T22:00:00Z")])
    var config = options(); config["end"] = .string("2026-10-25T10:00:00Z")
    let first = try await collector(config, fixture).collect()
    XCTAssertTrue(rows(first).isEmpty)
    XCTAssertNil(object(object(first["state"])["seen"])[webCollectionKey(link(1))])
    XCTAssertNotNil(object(object(first["state"])["seen"])[webCollectionKey(link(2))])
    config["previous"] = first["state"]; config["end"] = .string("2026-10-25T12:00:00Z")
    let second = try await collector(config, fixture).collect()
    XCTAssertEqual(rows(second).map { $0["identity"] }, [.string(link(1))])
    let calls = await fixture.calls
    XCTAssertEqual(calls.count, 5)
  }

  func testFutureArticleBecomesEligibleOnLaterPollWithoutSeenTombstone() async throws {
    let fixture = fixture(1, pages: [1: page("2026-10-25T13:00:00Z")])
    var config = options()
    let first = try await collector(config, fixture).collect()
    XCTAssertTrue(rows(first).isEmpty)
    config["previous"] = first["state"]
    var later = try collector(config, fixture); later.clock = { [instant] in instant.addingTimeInterval(7200) }
    let second = try await later.collect()
    XCTAssertEqual(rows(second).count, 1)
  }

  func testLinkAdmissionRemovesNavigationBeforeBudgetAndKeepsPublisherTopCandidates() async throws {
    let fixture = fixture(25)
    await fixture.set((0..<200).map { "<a href='/settings/\($0)'>Menu</a>" }.joined() +
      (1...25).map { "<a href='\(link($0))?tracking=1#x'>Article</a>" }.joined(), for: listing)
    var config = options(maximum: 20); config["maximumItems"] = .integer(2)
    let result = try await collector(config, fixture).collect()
    XCTAssertEqual(rows(result).map { $0["identity"] }, [.string(link(1)), .string(link(2))])
    XCTAssertEqual(object(result["scan"])["candidate_omitted"], .integer(23))
    let calls = await fixture.calls
    XCTAssertEqual(calls.count, 3)
    let policy = try XCTUnwrap(WebCollectionOptions(config).index)
    for url in ["http://example.com/news/1", "https://evil.test/news/1", "https://x@example.com/news/1", "https://example.com:444/news/1", "/settings"] {
      XCTAssertNil(policy.articleURL(url, listing: listing), url)
    }
    XCTAssertEqual(policy.articleURL("/news/1/?a=b#x", listing: listing), link(1))
  }

  func testMetadataOnlyIgnoresBodyAndRefusesConflictingCanonical() async throws {
    let fixture = fixture(2, pages: [1: page() + "<meta name='date' content='2025-01-01T00:00:00Z'><p>BODY_SECRET</p>",
      2: "<html><head><title>Public</title><meta name='description' content='Public lead'>" +
        "<meta name='date' content='2026-10-25T10:00:00Z'><link rel='canonical' href='https://example.com/news/3'></head></html>"])
    var config = options(); config["index"] = .object(["linkPattern": .string("^/news/[0-9]+/?$"), "metadataOnly": .bool(true)])
    let result = try await collector(config, fixture).collect()
    XCTAssertEqual(rows(result).count, 1)
    XCTAssertEqual(rows(result).first?["content_scope"], .string("public-headline-and-lead"))
    XCTAssertEqual(rows(result).first?["text"], .string(""))
    XCTAssertEqual(object(result["scan"])["unavailable"], .integer(1))
    XCTAssertFalse(try JSONValue.object(result).compactJSONString().contains("BODY_SECRET"))
  }

  func testURLBoundJSONLDIndexUsesHTTPAndNeverReturnsRawScripts() async throws {
    let date = "2026-10-25T10:00:00.004Z"
    func document(_ id: Int, bound: Int) -> String {
      page("2025-01-01T00:00:00Z") + "<script type='application/ld+json'>{\"@type\":\"BlogPosting\",\"mainEntityOfPage\":{\"@type\":\"WebPage\",\"@id\":\"" +
        link(bound) + "\"},\"datePublished\":\"" + date + "\"}</script>"
    }
    let fixture = fixture(2, pages: [1: document(1, bound: 1), 2: document(2, bound: 9)])
    var config = options(); config["pageOptions"] = .object(["mode": .string("browser")])
    config["index"] = .object(["linkPattern": .string("^/news/[0-9]+/?$"), "publicationJSONLDType": .string("BlogPosting")])
    let result = try await collector(config, fixture).collect()
    XCTAssertEqual(rows(result).map { $0["identity"] }, [.string(link(1))])
    XCTAssertEqual(rows(result).first?["published_at"], .string("2026-10-25T10:00:00.004000+00:00"))
    XCTAssertEqual(object(result["scan"])["undated"], .integer(1))
    let wire = try JSONValue.object(result).compactJSONString()
    XCTAssertFalse(wire.contains("raw_body_base64")); XCTAssertFalse(wire.contains("BlogPosting"))
  }

  func testOutputCapacityDefersWithoutAdvancingExactSeenIDs() async throws {
    let fixture = fixture(3, pages: Dictionary(uniqueKeysWithValues: (1...3).map { ($0, page(text: String(repeating: "😀", count: 50_000))) }))
    var config = options(); config["pageOptions"] = .object(["mode": .string("http"), "maxTextChars": .integer(50_000)])
    var small = try collector(config, fixture); small.outputByteBudget = 1_400_100
    let first = try await small.collect()
    XCTAssertGreaterThan(rows(first).count, 0); XCTAssertLessThan(rows(first).count, 3)
    XCTAssertEqual(object(object(first["state"])["seen"]).count, rows(first).count)
    XCTAssertEqual(first["acquisition_complete"], .bool(false))
    config["previous"] = first["state"]
    let second = try await collector(config, fixture).collect()
    XCTAssertEqual(rows(first).count + rows(second).count, 3)
  }

  func testIndexPolicyRejectsInvalidOptionsBeforeAnyRequest() throws {
    for index: JSONObject in [["linkPattern": .string("/news/.*")], ["linkPattern": .string("^[$")],
      ["linkPattern": .string("^/news/.*$"), "maximumArticles": .bool(true)],
      ["linkPattern": .string("^/news/.*$"), "maximumArticles": .integer(21)],
      ["linkPattern": .string("^/news/.*$"), "metadataOnly": .bool(true), "publicationJSONLDType": .string("BlogPosting")]] {
      var config = options(); config["index"] = .object(index)
      XCTAssertThrowsError(try WebCollectionOptions(config))
    }
  }

  func testEmptyOrOffOriginListingCannotProduceAdvancedCheckpoint() async throws {
    let fixture = fixture(1)
    await fixture.set("<a href='https://evil.test/news/1'>Other origin</a>", for: listing)
    do { _ = try await collector(options(), fixture).collect(); XCTFail("unrecognized listing accepted") } catch {
      XCTAssertEqual(error as? PublicWebError, .invalidDocument)
    }
    let calls = await fixture.calls
    XCTAssertEqual(calls, [listing])
  }

  func testRegisteredCLIIndexRunsWithoutPythonOrProviderProcesses() async throws {
    let now = Date(), fixture = fixture(1)
    await fixture.set(page(WebCollectionTimestamp.wire(now.addingTimeInterval(-60))), for: link(1))
    var config = options()
    config["start"] = .string(WebCollectionTimestamp.wire(now.addingTimeInterval(-3600)))
    config["end"] = .string(WebCollectionTimestamp.wire(now))
    try await PublicWebExecutionContext.$transport.withValue({ try await fixture.read($0) }, operation: {
      let result = await RielaCLIApplication().run(["node", "run", "riela/web-collect", "--config",
        try JSONValue.object(["options": .object(config), "context": .string("{{context}}")]).compactJSONString(),
        "--variables", try JSONValue.object(["context": .object(["literal": .string("{{opaque}}")])]).compactJSONString(),
        "--output", "json"], environment: ["HOME": "/tmp", "PATH": ""])
      XCTAssertEqual(result.exitCode, .success, result.stdout + result.stderr)
      let wire = try JSONDecoder().decode(NodeRunCommandResult.self, from: Data(result.stdout.utf8))
      XCTAssertEqual(rows(wire.payload).count, 1)
      XCTAssertEqual(wire.payload["context"], .object(["literal": .string("{{opaque}}")]))
    })
  }

  func testMinutePrecisionDatesAndLegacyDeferredDatesRemainCompatible() async throws {
    let fixture = fixture(2, pages: [1: page("2026-10-25T10:00+00:00"), 2: page("2026-10-25T19:30+09:00")])
    var config = options()
    config["end"] = .string("2026-10-25T10:15:00Z")
    config["previous"] = .object(["after_window": .object([webCollectionKey(link(2)): .string("2026-10-25T19:30+09:00")])])
    let result = try await collector(config, fixture).collect()
    XCTAssertEqual(rows(result).map { $0["identity"] }, [.string(link(1))])
    let firstCalls = await fixture.calls
    XCTAssertEqual(firstCalls.count, 2)
    config["previous"] = result["state"]; config["end"] = .string("2026-10-25T11:00:00Z")
    let resumed = try await collector(config, fixture).collect()
    XCTAssertEqual(rows(resumed).map { $0["identity"] }, [.string(link(2))])
    XCTAssertEqual(rows(resumed).first?["published_at"], .string("2026-10-25T19:30:00+09:00"))
    XCTAssertEqual(WebCollectionTimestamp("2026-10-25T10:00Z")?.wire, "2026-10-25T10:00:00+00:00")
  }

  func testBoundedSeenRetainsCurrentTerminalHintsAndEvictsOldestWithoutAckingWork() async throws {
    let fixture = fixture(3)
    var config = options()
    var policy = object(config["index"]); policy["maximumSeenEntries"] = .integer(20); config["index"] = .object(policy)
    var seen: JSONObject = [:]
    for id in 1...30 {
      seen[webCollectionKey(link(id))] = .object(["seen_at": .string("2026-10-24T00:00:00Z"), "outcome": .string("inspected-candidate")])
    }
    // A current candidate that is older than all other hints gets refreshed.
    seen[webCollectionKey(link(1))] = .object(["seen_at": .string("2026-10-25T11:00:00Z")])
    config["previous"] = .object(["seen": .object(seen), "pending_receipt": .string("must-survive")])
    let result = try await collector(config, fixture).collect()
    let state = object(result["state"]), retained = object(state["seen"])
    XCTAssertLessThanOrEqual(retained.count, 20)
    for id in 1...3 { XCTAssertNotNil(retained[webCollectionKey(link(id))]) }
    XCTAssertEqual(state["pending_receipt"], .string("must-survive"))
    XCTAssertNil(state["acknowledged"])
    XCTAssertTrue(rows(result).allSatisfy { $0["identity"] != .string(link(1)) })
    let evicted = Set(seen.keys).subtracting(retained.keys)
    XCTAssertGreaterThanOrEqual(evicted.count, 10)
    let id = try XCTUnwrap((4...30).first { evicted.contains(webCollectionKey(link($0))) })
    await fixture.set("<a href='\(link(id))'>Return</a>", for: listing)
    await fixture.set(page(), for: link(id))
    config["previous"] = result["state"]
    let again = try await collector(config, fixture).collect()
    XCTAssertEqual(rows(again).map { $0["identity"] }, [.string(link(id))])
  }

  func testLargeValidLegacySeenIsCompactedBeforeAdmissionGuard() async throws {
    let fixture = fixture(1)
    var config = options()
    let seen = Dictionary(uniqueKeysWithValues: (1...1200).map { id in
      (webCollectionKey(link(id)), JSONValue.object(["seen_at": .string("2026-10-24T00:00:00Z"),
        "outcome": .string("inspected-candidate"), "legacy_padding": .string(String(repeating: "x", count: 5500))]))
    })
    var policy = object(config["index"]); policy["maximumSeenEntries"] = .integer(20); config["index"] = .object(policy)
    config["previous"] = .object(["seen": .object(seen)])
    // Pure metadata compaction must run before large source tasks/contexts are
    // constructed, and must never start HTTP, browser or provider processes.
    try await PublicWebExecutionContext.$transport.withValue({ _ in throw PublicWebError.transport }, operation: {
      let compact = await RielaCLIApplication().run(["node", "run", "riela/web-collect", "--config",
        try JSONValue.object(["action": .string("compact-state"), "options": .string("{{options}}")]).compactJSONString(),
        "--variables", try JSONValue.object(["options": .object(config)]).compactJSONString(), "--output", "json"],
        environment: ["HOME": "/tmp", "PATH": ""])
      XCTAssertEqual(compact.exitCode, .success, compact.stdout + compact.stderr)
      let wire = try JSONDecoder().decode(NodeRunCommandResult.self, from: Data(compact.stdout.utf8))
      XCTAssertLessThanOrEqual(object(object(wire.payload["state"])["seen"]).count, 20)
      XCTAssertLessThan(compact.stdout.utf8.count, 200_000)
    })
    let result = try await collector(config, fixture).collect()
    XCTAssertLessThanOrEqual(object(object(result["state"])["seen"]).count, 20)
    XCTAssertLessThan(try JSONEncoder().encode(result).count, 200_000)
    let calls = await fixture.calls
    XCTAssertFalse(calls.isEmpty)
    // The registered adapter must compact before its own admission check too.
    try await PublicWebExecutionContext.$transport.withValue({ try await fixture.read($0) }, operation: {
      let run = await RielaCLIApplication().run(["node", "run", "riela/web-collect", "--config",
        try JSONValue.object(["options": .string("{{options}}")]).compactJSONString(),
        "--variables", try JSONValue.object(["options": .object(config)]).compactJSONString(), "--output", "json"],
        environment: ["HOME": "/tmp", "PATH": ""])
      XCTAssertEqual(run.exitCode, .success, run.stdout + run.stderr)
      let wire = try JSONDecoder().decode(NodeRunCommandResult.self, from: Data(run.stdout.utf8))
      XCTAssertLessThanOrEqual(object(object(wire.payload["state"])["seen"]).count, 20)
    })
  }

  func testCancellationNeverReturnsAdvancedProposedCheckpoint() async throws {
    let fixture = fixture(3, delay: .seconds(2))
    let collector = try collector(options(), fixture)
    let task = Task { try await collector.collect() }
    try await Task.sleep(for: .milliseconds(20)); task.cancel()
    do { _ = try await task.value; XCTFail("cancelled collection returned") } catch { XCTAssertTrue(error is CancellationError) }
  }
}

private actor IndexFixture {
  var values: [String: String]
  var finalURLs: [String: String]
  var calls: [String] = []
  var active = 0, peak = 0
  let delay: Duration
  init(values: [String: String], finalURLs: [String: String] = [:], delay: Duration = .zero) {
    self.values = values; self.finalURLs = finalURLs; self.delay = delay
  }
  func set(_ value: String, for url: String) { values[url] = value }
  func remove(_ url: String) { values.removeValue(forKey: url) }
  func read(_ request: PublicWebHTTPRequest) async throws -> PublicWebHTTPResponse {
    calls.append(request.url); active += 1; peak = max(peak, active)
    defer { active -= 1 }
    if delay > .zero { try await Task.sleep(for: delay) }
    guard let value = values[request.url] else { throw PublicWebError.transport }
    if let target = finalURLs[request.url] {
      return .init(status: 302, headers: ["location": target], body: Data(), url: request.url)
    }
    return .init(status: 200, headers: [:], body: Data(value.utf8), url: request.url)
  }
}
