import Foundation
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

final class CacheReadScanTests: XCTestCase {
  func testMissingPrefixDoesNotHideAvailableShortBatch() async throws {
    let root = scratch();defer { try? FileManager.default.removeItem(at: root) }
    let cache = try exchange(root)
    let refs = try put(cache, [("gone1", "old"), ("gone2", "old"), ("one", "first"), ("two", "second")])
    _ = try cache.store.delete(cacheId: "bodies", scope: "account", entries: ["gone1", "gone2"].map {
      CacheDelete(key: $0, revision: refs[$0]!.revision)
    })
    let result = try await scan(root, ["gone1", "gone2", "one", "two"].map { refs[$0]! })
    XCTAssertEqual(result["hitCount"], .integer(2));XCTAssertEqual(result["examinedCount"], .integer(4))
    XCTAssertEqual(result["complete"], .bool(true));XCTAssertEqual(result["nextIndex"], .integer(4))
    XCTAssertEqual(try statuses(result), ["missing", "missing", "hit", "hit"])
  }

  func testOversizedBodyAndStaleVersionDoNotBlockPeer() async throws {
    let root = scratch();defer { try? FileManager.default.removeItem(at: root) }
    let cache = try exchange(root)
    let refs = try put(cache, [("large", String(repeating: "x", count: 20_000)), ("changed", "old"), ("one", "first")])
    _ = try put(cache, [("changed", "new")])
    let result = try await scan(root, ["large", "changed", "one"].map { refs[$0]! }, extra: ["maxItemBytes": .integer(128)])
    XCTAssertEqual(try statuses(result), ["oversized", "missing", "hit"])
    XCTAssertEqual(result["hitCount"], .integer(1));XCTAssertEqual(result["complete"], .bool(true))
  }

  func testOutputBudgetResumesAtUnconsumedHit() async throws {
    let root = scratch();defer { try? FileManager.default.removeItem(at: root) }
    let cache = try exchange(root), refs = try put(cache, [("one", String(repeating: "a", count: 400)), ("two", String(repeating: "b", count: 400))])
    let requests = [refs["one"]!, refs["two"]!]
    let first = try await scan(root, requests, extra: ["maxOutputBytes": .integer(1024)])
    XCTAssertEqual(first["nextIndex"], .integer(1));XCTAssertEqual(first["stopReason"], .string("output-budget"))
    let second = try await scan(root, requests, extra: ["maxOutputBytes": .integer(1024), "startIndex": first["nextIndex"]!])
    XCTAssertEqual(second["nextIndex"], .integer(2));XCTAssertEqual(second["complete"], .bool(true))
    XCTAssertEqual(try ids(first), ["one"]);XCTAssertEqual(try ids(second), ["two"])
  }

  func testItemLargerThanWholeOutputBudgetIsSkipped() async throws {
    let root = scratch();defer { try? FileManager.default.removeItem(at: root) }
    let cache = try exchange(root), refs = try put(cache, [("large", String(repeating: "a", count: 2000)), ("one", "first")])
    let result = try await scan(root, [refs["large"]!, refs["one"]!], extra: ["maxOutputBytes": .integer(1024)])
    XCTAssertEqual(try statuses(result), ["oversized", "hit"]);XCTAssertEqual(result["complete"], .bool(true))
  }

  func testHitAndScanLimitsAreIndependent() async throws {
    let root = scratch();defer { try? FileManager.default.removeItem(at: root) }
    let refs = try put(exchange(root), [("one", "first"), ("two", "second")])
    let requests = [refs["one"]!, refs["two"]!]
    let hit = try await scan(root, requests, extra: ["maxHits": .integer(1)])
    XCTAssertEqual(hit["nextIndex"], .integer(1));XCTAssertEqual(hit["stopReason"], .string("hit-limit"))
    let examined = try await scan(root, requests, extra: ["maxExamined": .integer(1)])
    XCTAssertEqual(examined["nextIndex"], .integer(1));XCTAssertEqual(examined["stopReason"], .string("scan-limit"))
  }

  func testInvalidUnreadTailIsRefusedBeforeCreatingCache() async throws {
    let root = scratch();defer { try? FileManager.default.removeItem(at: root) }
    let valid = CacheBodyReference(key: "one", revision: String(repeating: "a", count: 64), fetchedAt: "2026-10-01T00:00:00Z",
      payloadSHA256: String(repeating: "b", count: 64), byteCount: 100)
    var invalid = valid;invalid.key = "two";invalid.revision = "invalid"
    do { _ = try await scan(root, [valid, invalid], extra: ["maxExamined": .integer(1)]);XCTFail("invalid tail accepted") } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }

  func testEmptyScanIsCompleteWithoutCreatingCache() async throws {
    let root = scratch();defer { try? FileManager.default.removeItem(at: root) }
    let result = try await scan(root, [])
    XCTAssertEqual(result["complete"], .bool(true));XCTAssertEqual(result["nextIndex"], .integer(0))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }

  func testExpiredDeadlineRefusesBeforeCacheMutation() async throws {
    let root = scratch();defer { try? FileManager.default.removeItem(at: root) }
    do {
      _ = try await scan(root, [], deadline: Date().addingTimeInterval(-1))
      XCTFail("expired scan accepted")
    } catch { XCTAssertTrue(error is AdapterExecutionError) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }

  private func scan(_ root: URL, _ refs: [CacheBodyReference], extra: JSONObject = [:], deadline: Date? = nil) async throws -> JSONObject {
    var config: JSONObject = ["action": .string("read-scan"), "stores": .object(["articles": .object([
      "cacheId": .string("bodies"), "scope": .string("account"), "cacheRoot": .string(root.path)])]),
      "requests": .array(try refs.map { ref in .object(["id": .string(ref.key), "store": .string("articles"),
        "reference": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(ref))]) })]
    config.merge(extra) { _, new in new }
    return try await BuiltinWorkflowAddonResolver(environment: [:]).execute(.init(workflowId: "fixture", stepId: "read", nodeId: "read",
      addon: .init(name: "riela/cache-exchange", config: config)), context: .init(deadline: deadline)).payload
  }

  private func put(_ cache: RielaCacheExchange, _ entries: [(String, String)]) throws -> [String: CacheBodyReference] {
    let time = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5))
    return try cache.put(entries.map { .init(key: $0.0, fetchedAt: time, payload: .string($0.1)) })
  }
  private func exchange(_ root: URL) throws -> RielaCacheExchange {
    try .init(store: .init(rootDirectory: root.path), cacheId: "bodies", scope: "account")
  }
  private func statuses(_ result: JSONObject) throws -> [String] { try rows(result).map { try XCTUnwrap($0["status"]?.stringValue) } }
  private func ids(_ result: JSONObject) throws -> [String] { try rows(result).map { try XCTUnwrap($0["id"]?.stringValue) } }
  private func rows(_ result: JSONObject) throws -> [JSONObject] {
    guard case let .array(values)? = result["results"] else { throw NSError(domain: "fixture", code: 1) }
    return try values.map { guard case let .object(row) = $0 else { throw NSError(domain: "fixture", code: 2) };return row }
  }
  private func scratch() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
}
