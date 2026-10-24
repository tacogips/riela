import Foundation
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

final class XGatewayUsageCacheExchangeTests: XCTestCase {
  func testSuccessfulAndFailedInvocationsPersistOnlyNormalizedUsageInSeparateCache() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try exchange(root)
    let usage = #"""
    {
      "version": 1,
      "basis": "upstream-response",
      "billingStatus": "not-reported",
      "httpResponses": 1,
      "successfulResponses": 1,
      "unclassifiedResources": 0,
      "resources": [
        {
          "kind": "post",
          "idHash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "utcDay": "2026-10-24"
        }
      ],
      "privateText": "DO NOT STORE"
    }
    """#
    let good = "{\"ok\":true,\"data\":{\"extensions\":{\"resourceUsage\":" + usage + "}}}"
    let failed = "{\"ok\":false,\"error\":{\"resourceUsage\":" + usage + "}}"
    for (stdout, stderr) in [(good, ""), ("", failed)] {
      XCTAssertEqual(cache.record(stdout: stdout, stderr: stderr,
        environment: ["X_GW_CONSUMER_KEY": "PRIVATE KEY"]), .stored)
    }
    let keys = try cache.store.keys(cacheId: XGatewayUsageCacheExchange.cacheId, scope: XGatewayUsageCacheExchange.scope)
    XCTAssertEqual(keys.count, 2)
    let rows = try cache.store.get(cacheId: XGatewayUsageCacheExchange.cacheId,
      scope: XGatewayUsageCacheExchange.scope, keys: keys)
    let text = try XCTUnwrap(String(data: JSONEncoder().encode(rows), encoding: .utf8))
    XCTAssertFalse(text.contains("PRIVATE KEY"))
    XCTAssertFalse(text.contains("DO NOT STORE"))
    XCTAssertTrue(text.contains("not-reported"))
    XCTAssertNotEqual(try cache.store.databasePath(cacheId: XGatewayUsageCacheExchange.cacheId),
      try cache.store.databasePath(cacheId: XGatewayUserCacheExchange.cacheId))
    _ = try cache.store.configure(cacheId: "art-x-retrieval", policy: .init(ttlSeconds: 1, maxBytes: 100))
    _ = try cache.store.prune(cacheId: "art-x-retrieval")
    XCTAssertEqual(try cache.store.keys(cacheId: XGatewayUsageCacheExchange.cacheId,
      scope: XGatewayUsageCacheExchange.scope).count, 2)
  }

  func testUnsupportedAndInvalidMetricsNeverBecomeZeroCostRecords() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try exchange(root)
    XCTAssertEqual(cache.record(stdout: #"{"ok":true,"data":{}}"#, stderr: "",
      environment: ["X_GW_CONSUMER_KEY": "fixture"]), .unsupported)
    XCTAssertNotEqual(cache.record(stdout: #"{"data":{"extensions":{"resourceUsage":{"version":1}}}}"#,
      stderr: "", environment: ["X_GW_CONSUMER_KEY": "fixture"]), .stored)
    XCTAssertEqual(try cache.store.keys(cacheId: XGatewayUsageCacheExchange.cacheId,
      scope: XGatewayUsageCacheExchange.scope).count, 2)
  }

  private static let singleLineUsage = #"{"version":1,"basis":"upstream-response","billingStatus":"not-reported","httpResponses":1,"#
    + #""successfulResponses":1,"unclassifiedResources":0,"resources":[{"kind":"post","#
    + #""idHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","utcDay":"2026-10-24"}]}"#

  func testHostKeepsGuestInvalidStatusAndStoresForwardedObservation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try XGatewayUsageCacheExchange(scope: "fixture-app", environment: ["RIELA_CACHE_ROOT": root.path])
    let collector = XGatewayUsageExportCollector(cache: cache)
    let prefix = XGatewayUsageTransport.prefix
    collector.accept(prefix + #"{"data":{"extensions":{"resourceUsage":null,"usageObservationStatus":"invalid"}}}"#)
    collector.accept(prefix + #"{"data":{"extensions":{"resourceUsage":"# + Self.singleLineUsage
      + #","usageObservationStatus":"stored"}}}"#)
    collector.accept(prefix + #"{"data":{"extensions":{"resourceUsage":null,"usageObservationStatus":"unsupported"}}}"#)
    collector.accept("unrelated stderr line")
    let statuses = try rowsByStatus(cache)
    XCTAssertEqual(statuses["invalid"]?.count, 1)
    XCTAssertEqual(statuses["unsupported"]?.count, 1)
    let stored = try XCTUnwrap(statuses["stored"]?.first)
    guard case let .object(observation)? = stored["observation"], case let .array(resources)? = observation["resources"] else {
      return XCTFail("stored observation missing")
    }
    XCTAssertEqual(resources.count, 1)
    XCTAssertEqual(stored["scopeKind"], .string("configured-application"))
    XCTAssertEqual(collector.metadata["statuses"],
      .object(["invalid": .integer(1), "stored": .integer(1), "unsupported": .integer(1)]))
    XCTAssertNil(collector.metadata["droppedRecords"])
  }

  func testSideChannelBoundsRecordsPerRunAndResourcesPerRecord() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try XGatewayUsageCacheExchange(scope: "fixture-app", environment: ["RIELA_CACHE_ROOT": root.path])
    let resource = #"{"kind":"post","idHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","utcDay":"2026-10-24"}"#
    let oversized = #"{"version":1,"basis":"upstream-response","billingStatus":"not-reported","httpResponses":1,"successfulResponses":1,"unclassifiedResources":0,"resources":["#
      + Array(repeating: resource, count: XGatewayUsageTransport.maximumResourcesPerRecord + 1).joined(separator: ",") + "]}"
    let prefix = XGatewayUsageTransport.prefix
    XCTAssertEqual(XGatewayUsageTransport.consume(prefix + #"{"data":{"extensions":{"resourceUsage":"# + oversized + "}}}",
      cache: cache), .invalid)
    XCTAssertNil(XGatewayUsageTransport.consume(prefix + String(repeating: " ", count: XGatewayUsageTransport.maximumLineBytes),
      cache: cache))
    XCTAssertEqual(XGatewayUsageTransport.consume(prefix + "{", cache: cache), .invalid)
    let collector = XGatewayUsageExportCollector(cache: cache, maximumRecords: 2)
    for _ in 0..<5 {
      collector.accept(prefix + #"{"data":{"extensions":{"resourceUsage":"# + Self.singleLineUsage + "}}}")
    }
    XCTAssertEqual(collector.metadata["statuses"], .object(["stored": .integer(2)]))
    XCTAssertEqual(collector.metadata["droppedRecords"], .integer(3))
    XCTAssertEqual(try rowsByStatus(cache)["stored"]?.count, 2)
    XCTAssertEqual(try rowsByStatus(cache)["invalid"]?.count, 2)
  }

  func testDirectScopeInitializerValidatesTheApplicationScope() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertThrowsError(try XGatewayUsageCacheExchange(scope: "bad scope", environment: ["RIELA_CACHE_ROOT": root.path]))
    let cache = try XGatewayUsageCacheExchange(scope: nil, environment: ["RIELA_CACHE_ROOT": root.path])
    XCTAssertEqual(cache.record(stdout: "", stderr: "", environment: [:]), .unavailable)
  }

  private func rowsByStatus(_ cache: XGatewayUsageCacheExchange) throws -> [String: [JSONObject]] {
    let keys = try cache.store.keys(cacheId: XGatewayUsageCacheExchange.cacheId, scope: XGatewayUsageCacheExchange.scope)
    let rows = try cache.store.get(cacheId: XGatewayUsageCacheExchange.cacheId, scope: XGatewayUsageCacheExchange.scope,
      keys: keys).results.compactMap { $0.entry?.payload }
    var result: [String: [JSONObject]] = [:]
    for row in rows {
      guard case let .object(entry) = jsonValue(from: row), case let .string(status)? = entry["telemetryStatus"] else { continue }
      result[status, default: []].append(entry)
    }
    return result
  }

  private func exchange(_ root: URL) throws -> XGatewayUsageCacheExchange {
    let input = WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "read", nodeId: "read",
      addon: .init(name: "riela/x-gateway-read", config: ["usageCache": .bool(true)]))
    return try XCTUnwrap(XGatewayUsageCacheExchange(input: input, workingDirectory: root,
      environment: ["RIELA_CACHE_ROOT": root.path]))
  }
}
