import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class XCollectionSamplingTests: XCTestCase {
  func testDeterministicDrawAndDistribution() throws {
    let first = try XCollectionSampling.drawValue(handle: "Bob", end: "2026-10-22T01:00:00Z")
    XCTAssertEqual(first, try XCollectionSampling.drawValue(handle: "bob", end: "2026-10-22T01:00:00+00:00"))
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let formatter = ISO8601DateFormatter()
    var count = 0
    for index in 0..<4_000 {
      let end = formatter.string(from: start.addingTimeInterval(Double(index)))
      let value = try XCollectionSampling.drawValue(handle: "bob", end: end)
      XCTAssertFalse(XCollectionSampling.drawn(probability: 0, value: value))
      XCTAssertTrue(XCollectionSampling.drawn(probability: 1, value: value))
      if XCollectionSampling.drawn(probability: 0.25, value: value) { count += 1 }
    }
    XCTAssertTrue((880...1_120).contains(count), "drawn: \(count)")
  }

  private func input() -> JSONObject {
    ["expectedHandle": .string("owner"), "authorHandles": .array([.string("alice"), .string("bob")]),
      "start": .string("2026-10-22T00:00:00Z"), "end": .string("2026-10-23T00:00:00Z"),
      "earliest": .string("2026-10-21T00:00:00Z"), "pageSize": .integer(10), "maxPosts": .integer(20)]
  }

  private func object(_ value: JSONValue?) throws -> JSONObject {
    guard case let .object(object)? = value else { throw xCollectionInvalid() }
    return object
  }

  private func rows(_ value: JSONValue?) throws -> [JSONObject] {
    guard case let .array(values)? = value else { throw xCollectionInvalid() }
    return try values.map { try object($0) }
  }

  private func post(_ id: String, author: String, time: String = "2026-10-22T12:00:00Z") -> JSONValue {
    .object(["id": .string(id), "text": .string("post"), "createdAt": .string(time),
      "author": .object(["username": .string(author)])])
  }

  private func collector(_ input: JSONObject) throws -> XAuthorCollector {
    var value = XAuthorCollector(options: try .init(input))
    value.clock = { Date(timeIntervalSince1970: 1_800_000_000) }
    return value
  }

  func testExplicitSamplingFreshReadAndTruncation() async throws {
    var values = input(); values["authorSampling"] = .object(["Bob": .integer(1)])
    var requests: [JSONObject] = []
    let result = try await collector(values).collect { operation, args, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      requests.append(args)
      if args["query"] == .string("from:bob") {
        return ["posts": .array([self.post("123", author: "bob")]), "pageInfo": .object(["nextToken": .string("leftover")])]
      }
      return ["posts": .array([self.post("124", author: "alice")]), "pageInfo": .object(["nextToken": .null])]
    }
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[0]["query"], .string("from:alice"))
    XCTAssertEqual(requests[1]["query"], .string("from:bob"))
    XCTAssertEqual(requests[1]["startTime"], values["start"]); XCTAssertEqual(requests[1]["endTime"], values["end"])
    XCTAssertEqual(requests[1]["maxResults"], .integer(10)); XCTAssertNil(requests[1]["nextToken"]); XCTAssertNil(requests[1]["sinceId"])
    let checkpoint = try object(result["checkpoint"])
    XCTAssertEqual(checkpoint["author_query"], .string("from:alice")); XCTAssertNil(checkpoint["pending_scan"])
    let posts = try rows(result["posts"]); XCTAssertEqual(posts.count, 2)
    XCTAssertEqual(posts.last?["_account_id"], .string("7")); XCTAssertNotNil(posts.last?["_fetched_at"])
    let metadata = try object(result["sampling"]); let handles = try rows(metadata["handles"])
    XCTAssertEqual(handles.count, 1); XCTAssertEqual(handles[0]["status"], .string("drawn"))
    XCTAssertEqual(handles[0]["truncated"], .bool(true)); XCTAssertEqual(handles[0]["fetchedCount"], .integer(1))
  }

  func testSkippedAndAllSampled() async throws {
    var values = input(); values["authorSampling"] = .object(["alice": .integer(0), "bob": .integer(0)])
    var searches = 0
    let result = try await collector(values).collect { operation, _, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      searches += 1; return [:]
    }
    XCTAssertEqual(searches, 0); XCTAssertEqual(result["complete"], .bool(true))
    let checkpoint = try object(result["checkpoint"]); XCTAssertEqual(checkpoint["author_query"], .string(""))
    XCTAssertEqual(try object(checkpoint["coverage"])["complete"], .bool(true))
    let handles = try rows(try object(result["sampling"])["handles"])
    XCTAssertEqual(handles.count, 2); XCTAssertTrue(handles.allSatisfy { $0["status"] == .string("skipped") })
  }

  func testSampledFailureDoesNotFailRegularCollection() async throws {
    var values = input(); values["authorSampling"] = .object(["bob": .integer(1)])
    let result = try await collector(values).collect { operation, args, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      if args["query"] == .string("from:bob") { throw xCollectionInvalid() }
      return ["posts": .array([]), "pageInfo": .object(["nextToken": .null])]
    }
    XCTAssertEqual(result["complete"], .bool(true))
    XCTAssertEqual(try rows(result["failures"]).first?["stage"], .string("sampled"))
  }

  func testSamplingChangeDropsOldCursor() async throws {
    var values = input(); values["authorSampling"] = .object(["bob": .integer(0)])
    values["previous"] = .object(["account_id": .string("7"), "author_query": .string("from:alice OR from:bob"),
      "pending_scan": .object(["next_token": .string("old")])])
    var searches = 0
    _ = try await collector(values).collect { operation, args, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      searches += 1; XCTAssertEqual(args["query"], .string("from:alice")); XCTAssertNil(args["nextToken"])
      XCTAssertNil(args["sinceId"]); XCTAssertEqual(args["startTime"], values["start"])
      return ["posts": .array([]), "pageInfo": .object(["nextToken": .null])]
    }
    XCTAssertEqual(searches, 1)
  }

  func testMalformedStateRejectedOrDropped() async throws {
    var values = input(); values["previous"] = .object(["author_sampling": .string("bad")])
    values["authorDailyPostThreshold"] = .integer(10)
    var searches = 0
    do {
      _ = try await collector(values).collect { operation, _, _ in
        if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
        searches += 1; return [:]
      }
      XCTFail("malformed state accepted")
    } catch { XCTAssertEqual(searches, 0) }
    values.removeValue(forKey: "authorDailyPostThreshold")
    let result = try await collector(values).collect { operation, _, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      return ["posts": .array([]), "pageInfo": .object(["nextToken": .null])]
    }
    XCTAssertNil(try object(result["checkpoint"])["author_sampling"]); XCTAssertNil(result["sampling"])
  }

  func testAutoSamplingAndExplicitOverride() async throws {
    let state: JSONObject = ["version": .integer(1), "timezone": .string("UTC"), "auto_day": .string("2026-10-22"),
      "auto": .object([:]), "through": .object([:]), "pending": .object([:]),
      "days": .object(["2026-10-22": .object(["bob": .object(["posts": .integer(40), "seconds": .integer(86400)])])])]
    for explicit in [false, true] {
      var values = input(); values["authorDailyPostThreshold"] = .integer(10)
      values["previous"] = .object(["author_sampling": .object(state)])
      if explicit { values["authorSampling"] = .object(["bob": .number(0.5)]) }
      let result = try await collector(values).collect { operation, _, _ in
        if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
        return ["posts": .array([]), "pageInfo": .object(["nextToken": .null])]
      }
      let handles = try rows(try object(result["sampling"])["handles"])
      let bob = try XCTUnwrap(handles.first { $0["handle"] == .string("bob") })
      XCTAssertEqual(bob["source"], .string(explicit ? "explicit" : "auto"))
      XCTAssertEqual(bob["probability"], .number(explicit ? 0.5 : 0.25))
      XCTAssertEqual(bob["observedDailyVolume"], .number(40))
    }
  }

  func testReplayDoesNotDoubleCountAndAutoSetFrozen() async throws {
    let state: JSONObject = ["version": .integer(1), "timezone": .string("UTC"), "auto_day": .string("2026-10-23"),
      "auto": .object(["bob": .object(["probability": .number(0.25), "observed_daily_volume": .number(40)])]),
      "through": .object(["alice": .string("2026-10-23T00:00:00Z")]), "pending": .object([:]),
      "days": .object(["2026-10-23": .object(["alice": .object(["posts": .integer(40), "seconds": .integer(86400)]),
        "bob": .object(["posts": .integer(100), "seconds": .integer(86400)])])])]
    var values = input(); values["authorDailyPostThreshold"] = .integer(10)
    values["previous"] = .object(["author_sampling": .object(state)])
    let result = try await collector(values).collect { operation, _, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      return ["posts": .array([]), "pageInfo": .object(["nextToken": .null])]
    }
    let handles = try rows(try object(result["sampling"])["handles"])
    let bob = try XCTUnwrap(handles.first { $0["handle"] == .string("bob") })
    XCTAssertEqual(bob["probability"], .number(0.25))
    let after = try object(try object(result["checkpoint"])["author_sampling"])
    let days = try object(after["days"]); let day = try object(days["2026-10-23"])
    let alice = try object(day["alice"])
    XCTAssertEqual(alice["posts"], .integer(40)); XCTAssertEqual(alice["seconds"], .integer(86400))
  }

  func testTruncatedSampleCountsOnlyObservedSuffix() async throws {
    var values = input(); values["authorDailyPostThreshold"] = .integer(10)
    values["authorSampling"] = .object(["bob": .integer(1), "alice": .integer(0)])
    let result = try await collector(values).collect { operation, _, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      return ["posts": .array([self.post("123", author: "bob", time: "2026-10-22T22:30:00Z")]),
        "pageInfo": .object(["nextToken": .string("more")])]
    }
    let state = try object(try object(result["checkpoint"])["author_sampling"])
    let day = try object(try object(state["days"])["2026-10-23"])
    let bob = try object(day["bob"])
    XCTAssertEqual(bob["posts"], .integer(1)); XCTAssertEqual(bob["seconds"], .integer(5400))
  }

  func testNoSamplingOptionsPreservesCheckpointAndOutput() async throws {
    let values = input(); let parsed = try XCollectionOptions(values)
    let result = try await collector(values).collect { operation, _, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      return ["posts": .array([]), "pageInfo": .object(["nextToken": .null])]
    }
    var baselineOptions = parsed
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
    baselineOptions.billingDayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    var window = try XCollectionWindow(options: baselineOptions, query: "from:alice OR from:bob", account: "7", previous: [:])
    let timestamp = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_800_000_000))
    try window.accept(["posts": .array([]), "pageInfo": .object(["nextToken": .null])], at: timestamp)
    XCTAssertEqual(result["checkpoint"], .object(try window.result(at: timestamp)))
    XCTAssertNil(result["sampling"])
  }

  func testCollectorUsesUTCClockDayForCompletedCoverage() async throws {
    var values = input()
    values["previous"] = .object(["account_id": .string("7"), "author_query": .string("from:alice OR from:bob"),
      "coverage": .object(["version": .integer(1), "account_id": .string("7"), "expected_handle": .string("owner"),
        "start": .string("2026-10-22T00:00:00Z"), "end": .string("2026-10-22T12:00:00Z"), "complete": .bool(true)])])
    var value = try collector(values); let now = try xInstant("2026-10-23T12:00:00Z"); value.clock = { now }
    var searches = 0
    _ = try await value.collect { operation, args, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      searches += 1; XCTAssertEqual(args["startTime"], .string("2026-10-22T12:00:00Z"))
      return ["posts": .array([]), "pageInfo": .object(["nextToken": .null])]
    }
    XCTAssertEqual(searches, 1)
  }

  func testRemovingHandlePrunesSamplingState() async throws {
    var values = input()
    values["authorHandles"] = .array([.string("alice"), .string("bob"), .string("carol")])
    values["authorDailyPostThreshold"] = .integer(10)
    let first = try await collector(values).collect { operation, _, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      return ["posts": .array([]), "pageInfo": .object(["nextToken": .null])]
    }
    var checkpoint = try object(first["checkpoint"])
    var state = try object(checkpoint["author_sampling"])
    XCTAssertNotNil(try object(state["through"])["carol"])
    state["auto"] = .object(["carol": .object(["probability": .number(0.25), "observed_daily_volume": .number(40)])])
    state["pending"] = .object([String(repeating: "a", count: 24): .object([
      "start": values["start"] ?? .null, "end": values["end"] ?? .null, "posts": .object(["carol": .integer(3)])])])
    checkpoint["author_sampling"] = .object(state)
    values["authorHandles"] = .array([.string("alice"), .string("bob")])
    values["previous"] = .object(checkpoint)
    var searches = 0
    let second = try await collector(values).collect { operation, args, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      searches += 1
      XCTAssertEqual(args["query"], .string("from:alice OR from:bob"))
      XCTAssertNil(args["nextToken"]); XCTAssertNil(args["sinceId"])
      XCTAssertEqual(args["startTime"], values["start"])
      return ["posts": .array([]), "pageInfo": .object(["nextToken": .null])]
    }
    XCTAssertEqual(searches, 1)
    let saved = try object(try object(second["checkpoint"])["author_sampling"])
    XCTAssertNil(try object(saved["auto"])["carol"])
    XCTAssertNil(try object(saved["through"])["carol"])
    for (_, bucket) in try object(saved["days"]) { XCTAssertNil(try object(bucket)["carol"]) }
    for (_, pending) in try object(saved["pending"]) { XCTAssertNil(try object(try object(pending)["posts"])["carol"]) }
  }

  func testTimezoneChangeStartsFreshSamplingState() async throws {
    let oldState: JSONObject = ["version": .integer(1), "timezone": .string("UTC"), "auto_day": .string("2026-10-23"),
      "auto": .object(["bob": .object(["probability": .number(0.25), "observed_daily_volume": .number(40)])]),
      "through": .object(["bob": .string("2026-10-23T00:00:00Z")]), "pending": .object([:]),
      "days": .object(["2026-10-23": .object(["bob": .object(["posts": .integer(40), "seconds": .integer(86400)])])])]
    var values = input(); values["authorDailyPostThreshold"] = .integer(10)
    values["timezone"] = .string("Asia/Tokyo")
    values["authorSampling"] = .object(["alice": .integer(0), "bob": .integer(0)])
    values["previous"] = .object(["author_sampling": .object(oldState)])
    let result = try await collector(values).collect { operation, _, _ in
      if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
      XCTFail("no sampled handle should be drawn"); return [:]
    }
    let state = try object(try object(result["checkpoint"])["author_sampling"])
    XCTAssertEqual(state["timezone"], .string("Asia/Tokyo")); XCTAssertEqual(state["auto_day"], .string("2026-10-23"))
    for key in ["auto", "through", "pending", "days"] { XCTAssertTrue(try object(state[key]).isEmpty) }
  }

  func testMalformedRemovedHandleStillRejected() async throws {
    let state: JSONObject = ["version": .integer(1), "timezone": .string("UTC"), "auto_day": .string("2026-10-23"),
      "auto": .object([:]), "through": .object(["carol": .integer(4)]), "pending": .object([:]), "days": .object([:])]
    var values = input(); values["authorDailyPostThreshold"] = .integer(10)
    values["previous"] = .object(["author_sampling": .object(state)])
    var calls = 0
    do {
      _ = try await collector(values).collect { _, _, _ in calls += 1; return [:] }
      XCTFail("malformed stale entry accepted")
    } catch { XCTAssertEqual(calls, 0) }
  }

}
