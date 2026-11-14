import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class XCollectionUTCDayTests: XCTestCase {
  private let start = "2026-11-09T00:00:00Z"
  private let end = "2026-11-11T06:00:00Z"
  private let hs = "2026-11-09T12:00:00Z"
  private let he = "2026-11-10T00:00:00Z"
  private let since = "2119852518405046272"

  private func checkpoint(_ first: String, _ last: String) -> JSONObject {
    ["account_id": .string("7"), "author_query": .string("from:bob"), "since_id": .string(since),
      "coverage": .object(["account_id": .string("7"), "start": .string(first), "end": .string(last), "complete": .bool(true)])]
  }

  private func input(_ first: String, _ last: String, _ previous: JSONObject, pages: Int = 2) -> JSONObject {
    ["expectedHandle": .string("owner"), "authorHandles": .array([.string("bob")]), "start": .string(first),
      "end": .string(last), "earliest": .string(first), "previous": .object(previous), "maxPages": .integer(Int64(pages))]
  }

  private func run(_ input: JSONObject, tokens: [String?] = [], failAt: Int? = nil, rows: [[JSONObject]] = []) async throws -> (JSONObject, [JSONObject]) {
    var collector = XAuthorCollector(options: try .init(input))
    collector.clock = { Date(timeIntervalSince1970: 1_794_398_400) }
    var requests: [JSONObject] = []
    let result = try await collector.collect { operation, arguments, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      requests.append(arguments)
      if requests.count == failAt { throw NSError(domain: "fixture", code: 1) }
      let token = requests.count <= tokens.count ? tokens[requests.count - 1] : nil
      let page = requests.count <= rows.count ? rows[requests.count - 1] : []
      return ["posts": .array(page.map(JSONValue.object)), "pageInfo": .object(["nextToken": token.map(JSONValue.string) ?? .null])]
    }
    guard case let .object(saved)? = result["checkpoint"] else { throw NSError(domain: "checkpoint", code: 1) }
    return (saved, requests)
  }

  private func pending(_ checkpoint: JSONObject) throws -> JSONObject {
    guard case let .object(scan)? = checkpoint["pending_scan"] else { throw NSError(domain: "pending", code: 1) }
    return scan
  }

  func testHistoricalPartialDayReplay() async throws {
    let a = "2026-11-10T01:00:00Z", b = "2026-11-10T06:00:00Z"
    let (saved, requests) = try await run(input(a, b, checkpoint(a, b)))
    XCTAssertTrue(requests.isEmpty); XCTAssertEqual(saved["since_id"], .string(since))
    guard case let .object(coverage)? = saved["coverage"] else { return XCTFail("coverage") }
    XCTAssertEqual(coverage["complete"], .bool(true))
  }

  func testHistoricalClosedDayReplay() async throws {
    let (saved, requests) = try await run(input(start, he, checkpoint(start, he)))
    XCTAssertTrue(requests.isEmpty); XCTAssertNil(saved["pending_scan"])
  }

  func testCurrentDayOverlapUsesLegacyRequest() async throws {
    let a = "2026-11-11T01:00:00Z", b = "2026-11-11T05:00:00Z", c = "2026-11-11T08:00:00Z"
    let (_, requests) = try await run(input(a, c, checkpoint(a, b)))
    var options = try XCollectionOptions(input(a, c, checkpoint(a, b)))
    options.billingDayStart = nil
    let legacy = try XCollectionWindow(options: options, query: "from:bob", account: "7", previous: checkpoint(a, b))
    XCTAssertEqual(requests, [try legacy.arguments()])
  }

  func testSuffixOnly() async throws {
    let a = "2026-11-10T00:00:00Z", b = "2026-11-10T12:00:00Z"
    let (_, requests) = try await run(input(a, end, checkpoint(a, b)))
    XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests.first?["startTime"], .string(b))
  }

  func testBothSidesExcludeHistoricalCoverage() async throws {
    let (_, requests) = try await run(input(start, end, checkpoint(hs, he)))
    XCTAssertEqual(requests.count, 2)
    guard requests.count == 2 else { return }
    XCTAssertEqual(requests[0]["startTime"], .string(he)); XCTAssertNil(requests[0]["sinceId"])
    XCTAssertEqual(requests[1]["startTime"], .string(start)); XCTAssertEqual(requests[1]["endTime"], .string(hs))
    XCTAssertNil(requests[1]["sinceId"])
  }

  func testPrefixAndCurrentDayCoveredTail() async throws {
    let (_, requests) = try await run(input(start, end, checkpoint(hs, end)))
    XCTAssertEqual(requests.count, 2); guard requests.count == 2 else { return }
    XCTAssertEqual(requests[0]["startTime"], .string("2026-11-11T00:00:00Z"))
    XCTAssertEqual(requests[1]["endTime"], .string(hs))
  }

  func testPageLimitedSuffixResumesThenPrefix() async throws {
    let (saved, requests) = try await run(input(start, end, checkpoint(hs, he), pages: 1), tokens: ["next"])
    XCTAssertEqual(requests.count, 1); XCTAssertEqual(try pending(saved)["segment"], .string("suffix"))
    let (_, resumed) = try await run(input(start, end, saved), tokens: [nil, nil])
    XCTAssertEqual(resumed.count, 2); guard resumed.count == 2 else { return }
    XCTAssertEqual(resumed[0]["nextToken"], .string("next"))
    XCTAssertEqual(resumed[1]["endTime"], .string(hs)); XCTAssertNil(resumed[1]["nextToken"])
  }

  func testBothSegmentsCompleteWithinBudget() async throws {
    let (saved, requests) = try await run(input(start, end, checkpoint(hs, he)))
    XCTAssertEqual(requests.count, 2); guard requests.count == 2 else { return }
    XCTAssertNil(requests[1]["nextToken"]); XCTAssertNil(saved["pending_scan"])
    guard case let .object(coverage)? = saved["coverage"] else { return XCTFail("coverage") }
    XCTAssertEqual(coverage["complete"], .bool(true))
  }

  func testPrefixStartupAfterBudgetStopAndTokenCycle() async throws {
    let (saved, _) = try await run(input(start, end, checkpoint(hs, he), pages: 1))
    let scan = try pending(saved)
    XCTAssertEqual(scan["segment"], .string("prefix")); XCTAssertEqual(scan["page_count"], .integer(0))
    XCTAssertEqual(scan["next_token"], .null); XCTAssertEqual(scan["visited_tokens"], .array([]))
    let (failed, requests) = try await run(input(start, end, saved), tokens: ["repeat", "repeat"])
    XCTAssertEqual(requests.first?["endTime"], .string(hs)); XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(failed["scan_stop_reason"], .string("gateway-failure"))
  }

  func testSuffixFirstRequestFailurePersists() async throws {
    let (saved, _) = try await run(input(start, end, checkpoint(hs, he)), failAt: 1)
    let scan = try pending(saved)
    XCTAssertEqual(scan["segment"], .string("suffix")); XCTAssertEqual(scan["page_count"], .integer(0))
    XCTAssertEqual(saved["since_id"], .string(since)); XCTAssertEqual(saved["scan_stop_reason"], .string("gateway-failure"))
    let (_, requests) = try await run(input(start, end, saved))
    XCTAssertEqual(requests.first?["startTime"], .string(he))
  }

  func testPrefixFirstRequestFailureResumesPrefix() async throws {
    let newest = "2119852518405047272"
    let post: JSONObject = ["id": .string(newest), "text": .string("suffix"), "createdAt": .string("2026-11-10T01:00:00Z")]
    let (saved, _) = try await run(input(start, end, checkpoint(hs, he)), failAt: 2, rows: [[post]])
    XCTAssertEqual(try pending(saved)["max_id"], .string(newest))
    XCTAssertEqual(try pending(saved)["segment"], .string("prefix")); XCTAssertEqual(saved["since_id"], .string(since))
    let (completed, requests) = try await run(input(start, end, saved))
    XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests.first?["endTime"], .string(hs))
    XCTAssertEqual(completed["since_id"], .string(newest)); XCTAssertNil(completed["pending_scan"])
  }

  func testSegmentFilterAcceptsOlderPrefixPosts() throws {
    let previous = checkpoint(hs, he)
    var options = try XCollectionOptions(input(start, end, previous))
    options.billingDayStart = Date(timeIntervalSince1970: 1_794_355_200)
    var window = try XCollectionWindow(options: options, query: "from:bob", account: "7", previous: previous)
    let old: JSONObject = ["id": .string("1"), "text": .string("prefix"), "createdAt": .string("2026-11-09T01:00:00Z")]
    let spill: JSONObject = ["id": .string("2"), "text": .string("spill"), "createdAt": .string("2026-11-09T02:00:00Z")]
    let newest: JSONObject = ["id": .string("2119852518405047272"), "text": .string("suffix"),
      "createdAt": .string("2026-11-10T01:00:00Z")]
    try window.accept(["posts": .array([.object(spill), .object(newest)]), "pageInfo": .object(["nextToken": .null])], at: end)
    XCTAssertEqual(window.posts.count, 1)
    try window.accept(["posts": .array([.object(old)]), "pageInfo": .object(["nextToken": .null])], at: end)
    XCTAssertEqual(window.posts.map { $0["id"] }, [.string("2119852518405047272"), .string("1")])
    XCTAssertEqual(try window.result(at: end)["since_id"], .string("2119852518405047272"))
  }

  func testNilBillingDayUsesLegacyBehavior() throws {
    let previous = checkpoint(start, he)
    let options = try XCollectionOptions(input(start, he, previous))
    let window = try XCollectionWindow(options: options, query: "from:bob", account: "7", previous: previous)
    XCTAssertTrue(window.needsRequest); XCTAssertNil(window.scan["skip"])
  }
}
