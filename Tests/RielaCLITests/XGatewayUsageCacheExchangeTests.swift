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

  private func exchange(_ root: URL) throws -> XGatewayUsageCacheExchange {
    let input = WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "read", nodeId: "read",
      addon: .init(name: "riela/x-gateway-read", config: ["usageCache": .bool(true)]))
    return try XCTUnwrap(XGatewayUsageCacheExchange(input: input, workingDirectory: root,
      environment: ["RIELA_CACHE_ROOT": root.path]))
  }
}
