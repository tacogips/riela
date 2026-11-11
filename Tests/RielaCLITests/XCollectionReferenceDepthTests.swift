import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class XCollectionReferenceDepthTests: XCTestCase {
  private func options() -> JSONObject {
    ["expectedHandle": .string("owner"), "authorHandles": .array([.string("bob")]),
      "start": .string("2026-10-22T00:00:00Z"), "end": .string("2026-10-22T01:00:00Z"),
      "earliest": .string("2026-10-21T00:00:00Z")]
  }

  func testSelectionAndDefaults() throws {
    for links in [false, true] {
      for coverage in [false, true] {
        for depth: JSONValue? in [nil, .integer(2)] {
          var input = options(); input["referenceDepth"] = depth
          input["includeStatusLinks"] = .bool(links); input["includeCoverageMetadata"] = .bool(coverage)
          let parsed = try XCollectionOptions(input)
          XCTAssertEqual(parsed.selection, ["posts": .object(XCollectionOptions.postFields(depth: 0, links: links, coverage: coverage)),
            "pageInfo": .object(["nextToken": .bool(true)])])
          XCTAssertNil(parsed.billingDayStart); XCTAssertNil(parsed.authorSampling); XCTAssertNil(parsed.authorDailyPostThreshold)
        }
      }
    }
    for depth in 0...1 {
      let root = XCollectionOptions.postFields(level: 0, referenceDepth: depth, links: false, coverage: false)
      XCTAssertNotNil(root["references"])
      if depth == 0 { XCTAssertNil(root["quote"]); XCTAssertNil(root["repost"]) } else {
        guard case let .object(child)? = root["quote"] else { return XCTFail("missing quote") }
        XCTAssertNil(child["quote"]); XCTAssertNil(child["repost"]); XCTAssertNil(child["references"])
        XCTAssertEqual(root["quote"], root["repost"])
      }
    }
  }

  func testValidation() throws {
    let invalid: [(String, JSONValue)] = [
      ("referenceDepth", .integer(3)), ("referenceDepth", .integer(-1)), ("referenceDepth", .string("2")),
      ("referenceDepth", .number(1.5)), ("authorSampling", .object(["unknown": .number(0.5)])),
      ("authorSampling", .object(["Bob": .number(0.5), "bob": .number(0.2)])),
      ("authorSampling", .object(["bob": .number(1.5)])), ("authorSampling", .object(["bob": .number(-0.1)])),
      ("authorSampling", .object(["bob": .string("0.5")])), ("authorSampling", .array([])),
      ("authorDailyPostThreshold", .integer(0)), ("authorDailyPostThreshold", .integer(100001)),
      ("authorDailyPostThreshold", .number(2.5))]
    for (key, value) in invalid {
      var input = options(); input[key] = value
      XCTAssertThrowsError(try XCollectionOptions(input), "\(key): \(value)")
    }
    var custom = options(); custom["select"] = .object([:]); custom["referenceDepth"] = .integer(2)
    XCTAssertThrowsError(try XCollectionOptions(custom))
    for (key, value, expected) in [("BOB", JSONValue.integer(0), 0.0), ("bob", .integer(1), 1.0), ("bob", .number(0.25), 0.25)] {
      var input = options(); input["authorSampling"] = .object([key: value]); input["authorDailyPostThreshold"] = .integer(1)
      let parsed = try XCollectionOptions(input)
      XCTAssertEqual(parsed.authorSampling, ["bob": expected]); XCTAssertEqual(parsed.authorDailyPostThreshold, 1)
    }
  }

  private func previous() -> JSONObject {
    ["account_id": .string("7"), "author_query": .string("from:bob"), "since_id": .string("50"),
      "pending_scan": .object(["start": .string("2026-10-22T00:00:00Z"), "end": .string("2026-10-22T01:00:00Z"),
        "since_id": .string("50"), "max_id": .string("90"), "next_token": .string("token"),
        "page_size": .integer(25), "page_count": .integer(1), "visited_tokens": .array([.string(String(repeating: "a", count: 64))]),
        "recent_ids": .array([])])]
  }

  func testDepthCheckpointContinuationAndReset() async throws {
    let cases: [((Int?, Int?), (Bool, Bool))] = [((0, nil), (true, true)), ((1, nil), (false, true)),
      ((0, 0), (true, false)), ((2, nil), (true, false)), ((nil, nil), (true, false))]
    for ((depth, savedDepth), (pending, reset)) in cases {
      var input = options(); if let depth { input["referenceDepth"] = .integer(Int64(depth)) }
      var saved = previous(); if !pending { saved.removeValue(forKey: "pending_scan") }
      if let savedDepth { saved["reference_depth"] = .integer(Int64(savedDepth)) }; input["previous"] = .object(saved)
      var collector = XAuthorCollector(options: try .init(input))
      collector.clock = { Date(timeIntervalSince1970: 1_800_000_000) }
      var searches = 0
      let result = try await collector.collect { operation, arguments, _ in
        if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
        searches += 1
        if reset {
          XCTAssertNil(arguments["nextToken"]); XCTAssertNil(arguments["sinceId"])
          XCTAssertEqual(arguments["startTime"], .string("2026-10-22T00:00:00Z"))
        } else { XCTAssertEqual(arguments["nextToken"], .string("token")) }
        return ["posts": .array([]), "pageInfo": .object(["nextToken": .null])]
      }
      XCTAssertEqual(searches, 1)
      guard case let .object(checkpoint)? = result["checkpoint"] else { return XCTFail("missing checkpoint") }
      XCTAssertEqual(checkpoint["reference_depth"], depth == 0 || depth == 1 ? .integer(Int64(depth ?? 2)) : nil)
    }
  }

  func testInvalidCheckpointDepthBeforeSearch() async throws {
    for value: JSONValue in [.integer(2), .string("0")] {
      var input = options(); var saved = previous(); saved["reference_depth"] = value; input["previous"] = .object(saved)
      var collector = XAuthorCollector(options: try .init(input)); collector.clock = { Date(timeIntervalSince1970: 1_800_000_000) }
      var searches = 0
      do {
        _ = try await collector.collect { operation, _, _ in
          if operation == "accountMe" { return ["id": .string("7"), "username": .string("owner")] }
          searches += 1; return [:]
        }
        XCTFail("invalid depth accepted")
      } catch { XCTAssertEqual(searches, 0) }
    }
  }
}
