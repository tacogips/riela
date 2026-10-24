import Foundation
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

final class CacheReadSetTests: XCTestCase {
  func testFailureLabelsRemainFiniteAndDoNotExposeNativeDetails() {
    let failures: [(RielaCacheError, String)] = [(.busy, "busy"), (.foreignDatabase, "foreignDatabase"),
      (.protectedCapacityExceeded(limit: 1), "protectedCapacityExceeded"), (.oversized(bytes: 2, limit: 1), "oversized"),
      (.expiredInput("PRIVATE"), "expiredInput"), (.revisionConflict("PRIVATE"), "revisionConflict"), (.invalid("PRIVATE"), "invalid")]
    for (failure, label) in failures {
      XCTAssertEqual(cacheExchangeFailure(failure).message, label + ": cache-exchange operation failed")
    }
  }

  func testCollidingPhysicalKeysStayInTheirDeclaredStoresAndOrder() async throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let first = try exchange(root, "first"), second = try exchange(root, "second")
    let time = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5))
    let one = try first.put([.init(key: "same", fetchedAt: time, payload: .string("{{literal}} 日本語"))])["same"]!
    let two = try second.put([.init(key: "same", fetchedAt: time, payload: .string("different"))])["same"]!
    let stale = try first.put([.init(key: "changed", fetchedAt: time, payload: .string("old"))])["changed"]!
    _ = try first.put([.init(key: "changed", fetchedAt: time, payload: .string("new"))])
    let config: JSONObject = ["action": .string("{{operation}}"), "stores": .object([
      "normal": storage(root, "first"), "backfill": storage(root, "second")]), "requests": .array([
        try request("e\u{301}", "backfill", two), try request("é", "normal", one), try request("old", "normal", stale)])]
    let result = try await run(config, variables: ["operation": .string("read-set")])
    XCTAssertEqual(result["results"], .array([
      .object(["id": .string("e\u{301}"), "status": .string("hit"), "payload": .string("different")]),
      .object(["id": .string("é"), "status": .string("hit"), "payload": .string("{{literal}} 日本語")]),
      .object(["id": .string("old"), "status": .string("missing")])]))
  }

  func testInvalidLaterReferenceIsRejectedBeforeAnyCacheIO() async throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let ref = CacheBodyReference(key: "one", revision: String(repeating: "a", count: 64),
      fetchedAt: "2026-10-01T00:00:00Z", payloadSHA256: String(repeating: "b", count: 64), byteCount: 100)
    var bad = ref; bad.revision = "invalid"
    let config: JSONObject = ["action": .string("read-set"), "stores": .object([
      "first": storage(root, "first"), "second": storage(root, "second")]), "requests": .array([
        try request("one", "first", ref), try request("two", "second", bad)])]
    do { _ = try await run(config); XCTFail("invalid reference accepted") } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }

  func testDisposablePolicyReleasesLegacyProtectionBeforeShrinkingLRU() async throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaCacheStore(rootDirectory: root.path)
    let protected = try RielaCacheExchange(store: store, cacheId: "bodies", scope: "account", capacityProtection: true)
    let time = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5))
    let refs = try protected.put(["old", "recent", "new"].map {
      .init(key: $0, fetchedAt: time, payload: .string("checked"), protectFromEviction: true)
    })
    guard case var .object(disposable) = storage(root, "bodies") else { return XCTFail("fixture") }
    var retained = disposable; retained["capacityProtection"] = .bool(true)
    _ = try await run(["action": .string("read-set"), "stores": .object(["staging": .object(retained)]),
      "requests": .array([try request("new", "staging", refs["new"]!)])])
    XCTAssertGreaterThan(try store.prune(cacheId: "bodies").stats.protectedByteCount, 1500)
    disposable["maxBytes"] = .integer(1500)
    let result = try await run(["action": .string("read-set"), "stores": .object(["current": .object(disposable)]),
      "requests": .array(try ["old", "recent", "new"].map { try request($0, "current", refs[$0]!) })])
    guard case let .array(rows)? = result["results"] else { return XCTFail("missing results") }
    XCTAssertEqual(rows[0], .object(["id": .string("old"), "status": .string("missing")]))
    let stats = try store.prune(cacheId: "bodies").stats
    XCTAssertEqual(stats.protectedByteCount, 0)
    XCTAssertLessThanOrEqual(stats.byteCount, 1500)
  }

  func testSymlinkAliasesCannotApplyConflictingPoliciesToOnePhysicalDatabase() async throws {
    let parent = scratch(); defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("real"), alias = parent.appendingPathComponent("alias")
    let cache = try exchange(root, "bodies")
    let time = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5))
    let ref = try cache.put([.init(key: "one", fetchedAt: time, payload: .string("retained"))])["one"]!
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    guard case var .object(changed) = storage(alias, "bodies") else { return XCTFail("fixture") }
    changed["ttlSeconds"] = .integer(1)
    do { _ = try await run(["action": .string("read-set"), "stores": .object([
      "real": storage(root, "bodies"), "alias": .object(changed)]),
      "requests": .array([try request("one", "real", ref)])]); XCTFail("alias conflict accepted") } catch {}
    XCTAssertEqual(try cache.get([ref]).hits["one"], .string("retained"))
  }

  func testUnknownStoreDuplicateIdentityAndConflictingPoliciesFailWithoutIO() async throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let ref = CacheBodyReference(key: "one", revision: String(repeating: "a", count: 64),
      fetchedAt: "2026-10-01T00:00:00Z", payloadSHA256: String(repeating: "b", count: 64), byteCount: 100)
    let one = try request("one", "first", ref)
    for requests in [[one, one], [try request("one", "unknown", ref)]] {
      do { _ = try await run(["action": .string("read-set"), "stores": .object(["first": storage(root, "first")]),
        "requests": .array(requests)]); XCTFail("invalid set accepted") } catch {}
    }
    guard case var .object(changed) = storage(root, "first") else { return XCTFail("fixture") }
    changed["ttlSeconds"] = .integer(2)
    do { _ = try await run(["action": .string("read-set"), "stores": .object([
      "first": storage(root, "first"), "alias": .object(changed)]), "requests": .array([one])]); XCTFail("conflicting policy accepted") } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    guard case var .object(protected) = storage(root, "first") else { return XCTFail("fixture") }
    protected["capacityProtection"] = .bool(true)
    do { _ = try await run(["action": .string("read-set"), "stores": .object([
      "first": storage(root, "first"), "protected": .object(protected)]), "requests": .array([one])]); XCTFail("protection conflict accepted") } catch {}
    let empty = try await run(["action": .string("read-set"), "stores": .object(["first": storage(root, "first")]),
      "requests": .array([])])
    XCTAssertEqual(empty, ["results": .array([])])
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }

  private func run(_ config: JSONObject, variables: JSONObject = [:]) async throws -> JSONObject {
    try await BuiltinWorkflowAddonResolver(environment: [:]).execute(.init(workflowId: "fixture", stepId: "read", nodeId: "read",
      addon: .init(name: "riela/cache-exchange", version: "1", config: config), variables: variables), context: .init()).payload
  }

  private func exchange(_ root: URL, _ name: String) throws -> RielaCacheExchange {
    try .init(store: .init(rootDirectory: root.path), cacheId: name, scope: "account")
  }

  private func storage(_ root: URL, _ name: String) -> JSONValue {
    .object(["cacheId": .string(name), "scope": .string("account"), "cacheRoot": .string(root.path)])
  }

  private func request(_ id: String, _ store: String, _ reference: CacheBodyReference) throws -> JSONValue {
    .object(["id": .string(id), "store": .string(store),
      "reference": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(reference))])
  }

  private func scratch() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
}
