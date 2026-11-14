import Foundation
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

final class XGatewayUserCacheExchangeTests: XCTestCase {
  func testPersistsAcrossNewInstancesAndMergesIndependentGuestAdditions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try exchange(root)
    let second = try exchange(root)
    XCTAssertEqual(try snapshot(first), "[]")
    XCTAssertEqual(try snapshot(second), "[]")
    for (memory, id) in [(first, "1"), (second, "2"), (first, "1")] {
      let result = try memory.consume(response(id: id))
      XCTAssertFalse(result.contains("userMemory"))
      XCTAssertTrue(result.contains("accountMe"))
    }
    let restarted = try exchange(root)
    let json = try snapshot(restarted)
    let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]])
    XCTAssertEqual(Set(rows.compactMap { $0["id"] }), ["1", "2"])
    XCTAssertEqual(rows.count, 2)
  }

  func testRejectsUnsupportedImageAndCredentialFieldsWithoutPersisting() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let memory = try exchange(root)
    XCTAssertThrowsError(try memory.consume(#"{"ok":true,"data":{"data":{}}}"#))
    XCTAssertThrowsError(try memory.consume(#"{"ok":true,"data":{"data":{},"extensions":{"userMemory":[{"id":"1","username":"valid","token":"secret"}]}}}"#))
    XCTAssertEqual(try snapshot(memory), "[]")
  }

  func testLargeMemoryIsSplitBelowLinuxPerEnvironmentValueLimit() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let memory = try exchange(root)
    let rows = (1...500).map { ["id": String($0), "username": "user_\($0)", "name": String(repeating: "名", count: 100)] }
    let data: [String: Any] = ["ok": true, "data": ["data": [:], "extensions": ["userMemory": rows]]]
    _ = try memory.consume(XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: data), encoding: .utf8)))
    let bindings = try memory.bindings()
    XCTAssertGreaterThan(try snapshot(memory).utf8.count, 131_072)
    XCTAssertTrue(bindings.values.allSatisfy { $0.utf8.count <= 80_000 })
    XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(snapshot(memory).utf8)) as? [[String: String]])?.count, 500)
  }

  func testUserTTLIsNotRenewedByReadingAndArticleCacheIsIndependent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let base = Date()
    let first = try exchange(root, at: base)
    _ = try first.consume(response(id: "1"))
    let articleStore = RielaCacheStore(rootDirectory: root.path)
    _ = try articleStore.configure(cacheId: "art-x-retrieval", policy: .init(ttlSeconds: 1, maxBytes: 100))
    _ = try articleStore.prune(cacheId: "art-x-retrieval")
    XCTAssertFalse(try snapshot(first).isEmpty)
    let later = try exchange(root, at: base.addingTimeInterval(29 * 86_400))
    XCTAssertTrue(try snapshot(later).contains("user_1"))
    let expired = try exchange(root, at: base.addingTimeInterval(31 * 86_400))
    XCTAssertEqual(try snapshot(expired), "[]")
    XCTAssertEqual(XGatewayUserCacheExchange.cacheId, "x-gateway-users")
    XCTAssertNotEqual(try articleStore.databasePath(cacheId: "art-x-retrieval"),
      try articleStore.databasePath(cacheId: XGatewayUserCacheExchange.cacheId))
  }

  func testOnlyBooleanFlagIsRequiredAndDisabledCreatesNoCache() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let input = WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "read", nodeId: "read",
      addon: .init(name: "riela/x-gateway-reader", config: ["userCache": .bool(false)]))
    XCTAssertNil(try XGatewayUserCacheExchange(input: input, workingDirectory: root,
      environment: ["RIELA_CACHE_ROOT": root.path]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }

  func testOlderConcurrentReplyCannotReplaceNewerUserOrDiscardPosts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let base = Date()
    let older = try exchange(root, at: base)
    let newer = try exchange(root, at: base.addingTimeInterval(10))
    _ = try newer.consume(response(id: "1").replacingOccurrences(of: "Name", with: "New name"))
    let output = try older.consume(response(id: "1"))
    XCTAssertTrue(output.contains("accountMe"))
    XCTAssertTrue(output.contains("ok"))
    XCTAssertTrue(try snapshot(newer).contains("New name"))
  }

  func testCacheWriteFailureReturnsPostsWithFiniteDiagnostic() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let memory = try exchange(root)
    let database = try memory.store.databasePath(cacheId: XGatewayUserCacheExchange.cacheId)
    try FileManager.default.removeItem(atPath: database)
    try FileManager.default.createDirectory(atPath: database, withIntermediateDirectories: false)
    XCTAssertEqual(try snapshot(memory), "[]")
    let output = try memory.consume(response(id: "1"))
    XCTAssertTrue(output.contains("accountMe"))
    XCTAssertTrue(output.contains("write-unavailable"))
    XCTAssertFalse(output.contains(root.path))
  }

  func testUnavailableCacheRootDegradesToEmptyExchange() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("not a directory".utf8).write(to: file)
    let memory = try exchange(file)
    XCTAssertEqual(try snapshot(memory), "[]")
    let output = try memory.consume(response(id: "1"))
    XCTAssertTrue(output.contains("accountMe"))
    XCTAssertTrue(output.contains("write-unavailable"))
  }

  func testSnapshotDoesNotChangeLRUButReturnedAuthorsDo() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try exchange(root)
    _ = try cache.consume(response(id: "1"))
    _ = try cache.consume(response(id: "2"))
    func keys() throws -> [String] {
      try cache.store.keys(cacheId: XGatewayUserCacheExchange.cacheId, scope: XGatewayUserCacheExchange.scope)
    }
    XCTAssertEqual(try keys(), ["2", "1"])
    _ = try cache.bindings()
    XCTAssertEqual(try keys(), ["2", "1"])
    _ = try cache.consume(#"{"ok":true,"data":{"data":{"homeTimeline":{"posts":[{"author":{"id":"1"}}]}},"extensions":{"userMemory":[]}}}"#)
    XCTAssertEqual(try keys(), ["1", "2"])
  }

  private func snapshot(_ memory: XGatewayUserCacheExchange) throws -> String {
    let bindings = try memory.bindings()
    let count = try XCTUnwrap(Int(bindings["X_GW_USER_MEMORY_PARTS"] ?? ""))
    return try (0..<count).map { try XCTUnwrap(bindings["X_GW_USER_MEMORY_JSON_\($0)"]) }.joined()
  }

  private func response(id: String) -> String {
    #"{"ok":true,"data":{"data":{"accountMe":{"id":"9"}},"extensions":{"userMemory":[{"id":""# + id + #"","username":"user_"# + id + #"","name":"Name"}]}}}"#
  }

  private func exchange(_ root: URL, at date: Date = Date()) throws -> XGatewayUserCacheExchange {
    let input = WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "read", nodeId: "read",
      addon: .init(name: "riela/x-gateway-reader", config: ["userCache": .bool(true)]))
    return try XCTUnwrap(XGatewayUserCacheExchange(input: input, workingDirectory: root,
      environment: ["RIELA_CACHE_ROOT": root.path], clock: { date }))
  }
}
