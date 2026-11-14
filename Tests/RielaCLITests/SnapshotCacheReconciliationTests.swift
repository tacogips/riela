import Foundation
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI
#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class SnapshotCacheReconciliationTests: XCTestCase {
  func testMissingHeadUsesInitialValueWithoutCreatingSnapshotOrReturningBodies() async throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let exchange = try cache(root)
    _ = try put(exchange, key: "orphan")
    let result = try await Self.run(config(root))
    guard case let .array(items)? = result["items"], case let .object(item)? = items.first else { return XCTFail("missing item") }
    XCTAssertEqual(item["head"], .null)
    XCTAssertEqual(item["value"], .object(["scope": .string("a"), "refs": .array([])]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("memory/journal.sqlite").path))
    XCTAssertEqual(try exchange.store.prune(cacheId: "bodies").stats.protectedByteCount, 0)
    XCTAssertFalse(try JSONValue.object(result).compactJSONString().contains("PRIVATE"))
  }

  func testWrongScopeAndCorruptEnvelopeNeverReleaseProtectedArtifacts() async throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let exchange = try cache(root); _ = try put(exchange, key: "pending")
    let before = try exchange.store.prune(cacheId: "bodies").stats.protectedByteCount
    let store = RielaMemoryStore(rootDirectory: root.appendingPathComponent("memory").path)
    var head: MemorySnapshotHead?
    for payload: MemoryJSONValue in [.object(["scope": .string("wrong"), "refs": .array([])]), .string("corrupt")] {
      let saved = try store.commitSnapshot(memoryId: "journal", workflowId: "work", nodeId: "ready", tag: "checkpoint", expectedHead: head, payload: payload)
      head = saved.head
      do { _ = try await Self.run(config(root)); XCTFail("unsafe snapshot reconciled") } catch {}
      XCTAssertEqual(try exchange.store.prune(cacheId: "bodies").stats.protectedByteCount, before)
      XCTAssertEqual(try store.loadSnapshot(memoryId: "journal", workflowId: "work", nodeId: "ready", tag: "checkpoint")?.head, head)
    }
  }

  func testWriterLeaseIsHeldAcrossFreshReadAndReconciliation() async throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let exchange = try cache(root), old = try put(exchange, key: "old"), new = try put(exchange, key: "new")
    let store = RielaMemoryStore(rootDirectory: root.appendingPathComponent("memory").path)
    let first = try store.commitSnapshot(memoryId: "journal", workflowId: "work", nodeId: "ready", tag: "checkpoint", expectedHead: nil,
      payload: .object(["scope": .string("a"), "refs": .array([try memoryRef(old)])]))
    let descriptor = try writerLock(root); defer { close(descriptor) }
    let configuration = config(root)
    let task = Task.detached { try await SnapshotCacheReconciliationTests.run(configuration) }
    try await Task.sleep(nanoseconds: 100_000_000)
    let latest = try store.commitSnapshot(memoryId: "journal", workflowId: "work", nodeId: "ready", tag: "checkpoint", expectedHead: first.head,
      payload: .object(["scope": .string("a"), "refs": .array([try memoryRef(new)])]))
    _ = flock(descriptor, LOCK_UN)
    let result = try await task.value
    guard case let .array(items)? = result["items"], case let .object(item)? = items.first,
      case let .object(head)? = item["head"] else { return XCTFail("missing head") }
    XCTAssertEqual(head["version"], .integer(latest.head.version))
    let rows = try exchange.store.get(cacheId: "bodies", scope: "a", keys: ["old", "new"]).results
    XCTAssertEqual(rows.first?.entry?.protectFromEviction, false)
    XCTAssertEqual(rows.last?.entry?.protectFromEviction, true)
  }

  func testCancellationWhileWaitingForWriterDoesNotTouchCache() async throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let exchange = try cache(root); _ = try put(exchange, key: "pending")
    let before = try exchange.store.prune(cacheId: "bodies").stats.protectedByteCount
    let descriptor = try writerLock(root); defer { close(descriptor) }
    let configuration = config(root)
    let task = Task.detached { try await SnapshotCacheReconciliationTests.run(configuration) }
    try await Task.sleep(nanoseconds: 100_000_000); task.cancel()
    do { _ = try await task.value; XCTFail("cancelled scan accepted") } catch is CancellationError {}
    XCTAssertEqual(try exchange.store.prune(cacheId: "bodies").stats.protectedByteCount, before)
  }

  func testMalformedBindingsAndInitialSchemaRefuseBeforeLockOrCacheIO() async throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    var invalid = config(root)
    invalid["valueSchema"] = .object(["type": .string("object"), "required": .array([.string("missing")])])
    do { _ = try await Self.run(invalid); XCTFail("invalid initial schema accepted") } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    invalid = config(root); invalid["storage"] = .object(["memoryPrefix": .string("journal"), "memoryRoot": .string(root.appendingPathComponent("memory").path)])
    do { _ = try await Self.run(invalid); XCTFail("prefix reconciliation accepted") } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }

  func testUnsafeLockLeavesNeverReconcileOrAlterTheirTarget() async throws {
    for hardLink in [false, true] {
      let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
      let exchange = try cache(root); _ = try put(exchange, key: "pending")
      let before = try exchange.store.prune(cacheId: "bodies").stats.protectedByteCount
      let locks = root.appendingPathComponent("locks")
      try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
      let target = root.appendingPathComponent("target"), leaf = locks.appendingPathComponent("writer.lock")
      try Data("untouched".utf8).write(to: target)
      if hardLink { try FileManager.default.linkItem(at: target, to: leaf)
      } else { try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: target) }
      do { _ = try await Self.run(config(root)); XCTFail("unsafe lock accepted") } catch {}
      XCTAssertEqual(try Data(contentsOf: target), Data("untouched".utf8))
      XCTAssertEqual(try exchange.store.prune(cacheId: "bodies").stats.protectedByteCount, before)
    }
  }

  func testAliasedCachePoliciesAreRejectedBeforeAnyJournalLease() async throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let exchange = try cache(root); _ = try put(exchange, key: "pending")
    let alias = root.appendingPathComponent("cache-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("cache"))
    var config = config(root)
    guard case var .object(storage)? = config["storage"], case var .object(reconciliation)? = config["cacheReconciliation"],
      case var .object(bindings)? = reconciliation["bindings"], case var .object(second)? = bindings["journal"],
      case var .object(cache)? = second["cache"] else { return XCTFail("fixture") }
    storage["memoryIds"] = .array([.string("journal"), .string("other")])
    cache["cacheRoot"] = .string(alias.path); cache["scope"] = .string("b"); cache["ttlSeconds"] = .integer(1)
    second["cache"] = .object(cache); second["lockName"] = .string("other.lock")
    second["initialValue"] = .object(["scope": .string("b"), "refs": .array([])])
    bindings["other"] = .object(second); reconciliation["bindings"] = .object(bindings)
    config["storage"] = .object(storage); config["cacheReconciliation"] = .object(reconciliation)
    do { _ = try await Self.run(config); XCTFail("conflicting alias policy accepted") } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("locks").path))
    XCTAssertGreaterThan(try exchange.store.prune(cacheId: "bodies").stats.protectedByteCount, 0)
  }

  private func config(_ root: URL) -> JSONObject {
    let initial: JSONValue = .object(["scope": .string("a"), "refs": .array([])])
    return ["storage": .object(["memoryIds": .array([.string("journal")]), "memoryRoot": .string(root.appendingPathComponent("memory").path),
      "workflowId": .string("work"), "nodeId": .string("ready")]),
      "valueSchema": .object(["type": .string("object"), "properties": .object(["scope": .object(["type": .string("string")]), "refs": .object(["type": .string("array")])]),
        "required": .array([.string("scope"), .string("refs")])]),
      "cacheReconciliation": .object(["lockDirectory": .string(root.appendingPathComponent("locks").path), "bindings": .object([
        "journal": .object(["lockName": .string("writer.lock"), "cache": .object(["cacheId": .string("bodies"), "scope": .string("a"),
          "cacheRoot": .string(root.appendingPathComponent("cache").path), "capacityProtection": .bool(true)]),
          "scopeFrom": .string("/scope"), "referencesFrom": .string("/refs"), "initialValue": initial])])])]
  }
  private static func run(_ config: JSONObject, context: AdapterExecutionContext = .init()) async throws -> JSONObject {
    try await BuiltinWorkflowAddonResolver(environment: [:]).execute(.init(workflowId: "work", stepId: "scan", nodeId: "ready",
      addon: .init(name: "riela/snapshot-scan", version: "1", config: config)), context: context).payload
  }
  private func scratch() -> URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/cache-scan-\(UUID().uuidString)") }
  private func cache(_ root: URL) throws -> RielaCacheExchange {
    try .init(store: .init(rootDirectory: root.appendingPathComponent("cache").path), cacheId: "bodies", scope: "a", capacityProtection: true)
  }
  private func put(_ cache: RielaCacheExchange, key: String) throws -> CacheBodyReference {
    try cache.put([.init(key: key, fetchedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5)), payload: .string("PRIVATE"), protectFromEviction: true)])[key]!
  }
  private func memoryRef(_ ref: CacheBodyReference) throws -> MemoryJSONValue {
    try JSONDecoder().decode(MemoryJSONValue.self, from: JSONEncoder().encode(ref))
  }
  private func writerLock(_ root: URL) throws -> Int32 {
    let directory = root.appendingPathComponent("locks")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = open(directory.appendingPathComponent("writer.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard file >= 0, flock(file, LOCK_EX | LOCK_NB) == 0 else { throw NSError(domain: "lock fixture", code: 1) }
    return file
  }
}
