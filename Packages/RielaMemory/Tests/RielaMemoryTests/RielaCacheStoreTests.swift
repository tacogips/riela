import Foundation
import SQLite3
import XCTest
@testable import RielaMemory

private final class CacheTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var seconds = 1_800_000_000.0
  func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: seconds) }
  func advance(_ amount: Double) { lock.lock(); defer { lock.unlock() }; seconds += amount }
}

final class RielaCacheStoreTests: XCTestCase {
  private func fixture() -> (RielaCacheStore, CacheTestClock, URL) {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/cache-tests/\(UUID().uuidString)")
    let clock = CacheTestClock()
    return (RielaCacheStore(rootDirectory: root.path, clock: { clock.now() }), clock, root)
  }
  private func entry(_ key: String, _ clock: CacheTestClock, count: Int = 10) -> CachePut {
    .init(key: key, fetchedAt: cacheTimestamp(Int64(clock.now().timeIntervalSince1970 * 1000)),
      payload: .string(String(repeating: "x", count: count)))
  }

  func testReadsAndIdempotentReplayDoNotExtendTTL() throws {
    let (store, clock, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try store.configure(cacheId: "cache", policy: .init(ttlSeconds: 10, maxBytes: 4096))
    let value = entry("a", clock)
    let first = try store.put(cacheId: "cache", scope: "scope", entries: [value])
    clock.advance(8)
    let repeated = try store.put(cacheId: "cache", scope: "scope", entries: [value])
    XCTAssertEqual(first.results.first?.entry?.revision, repeated.results.first?.entry?.revision)
    XCTAssertEqual(first.results.first?.entry?.expiresAt, repeated.results.first?.entry?.expiresAt)
    XCTAssertEqual(try store.get(cacheId: "cache", scope: "scope", keys: ["a"]).results[0].status, "hit")
    clock.advance(2)
    let expired = try store.get(cacheId: "cache", scope: "scope", keys: ["a"])
    XCTAssertEqual(expired.results[0].reason, "expired")
    XCTAssertNil(expired.results[0].entry)
    XCTAssertEqual(expired.stats.entryCount, 0)
    XCTAssertThrowsError(try store.put(cacheId: "cache", scope: "scope", entries: [value]))
  }

  func testLRUAndBatchOverflowAreAtomicAndBudgetSharedAcrossScopes() throws {
    let (store, clock, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try store.configure(cacheId: "cache", policy: .init(maxBytes: 1100))
    _ = try store.put(cacheId: "cache", scope: "one", entries: [entry("a", clock), entry("b", clock)])
    XCTAssertThrowsError(try store.put(cacheId: "cache", scope: "two", entries: [entry("c", clock), entry("d", clock), entry("e", clock)]))
    XCTAssertThrowsError(try store.put(cacheId: "cache", scope: "two", entries: [entry("c", clock, count: 2000)]))
    _ = try store.get(cacheId: "cache", scope: "one", keys: ["a"])
    let inserted = try store.put(cacheId: "cache", scope: "two", entries: [entry("c", clock)])
    XCTAssertEqual(inserted.stats.evictedCount, 1)
    XCTAssertLessThanOrEqual(inserted.stats.byteCount, 1100)
    XCTAssertEqual(try store.get(cacheId: "cache", scope: "one", keys: ["a", "b", "c"]).results.map(\.status), ["hit", "miss", "miss"])
    XCTAssertEqual(try store.get(cacheId: "cache", scope: "two", keys: ["c"]).results[0].status, "hit")
  }

  func testCompareDeleteIsAtomicIdempotentAndProtectsRefreshedRevision() throws {
    let (store, clock, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try store.put(cacheId: "cache", scope: "s", entries: [entry("a", clock), entry("b", clock)])
    let deletes = original.results.map { CacheDelete(key: $0.key, revision: $0.entry!.revision) }
    clock.advance(1)
    let refreshed = try store.put(cacheId: "cache", scope: "s", entries: [entry("b", clock, count: 20)])
    XCTAssertThrowsError(try store.delete(cacheId: "cache", scope: "s", entries: deletes))
    XCTAssertEqual(try store.get(cacheId: "cache", scope: "s", keys: ["a", "b"]).stats.entryCount, 2)
    let current = [deletes[0], CacheDelete(key: "b", revision: refreshed.results[0].entry!.revision)]
    XCTAssertEqual(try store.delete(cacheId: "cache", scope: "s", entries: current).deletedCount, 2)
    XCTAssertEqual(try store.delete(cacheId: "cache", scope: "s", entries: current).deletedCount, 0)
  }

  func testOutputOverflowRollsBackTouchAndOlderWriteCannotReplaceNewerValue() throws {
    let (store, clock, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try store.configure(cacheId: "cache", policy: .init(maxBytes: 1100))
    let old = entry("a", clock)
    _ = try store.put(cacheId: "cache", scope: "s", entries: [old, entry("b", clock)])
    XCTAssertThrowsError(try store.get(cacheId: "cache", scope: "s", keys: ["a"], maxOutputBytes: 1))
    _ = try store.put(cacheId: "cache", scope: "s", entries: [entry("c", clock)])
    XCTAssertEqual(try store.get(cacheId: "cache", scope: "s", keys: ["a"]).results[0].status, "miss")
    clock.advance(1)
    _ = try store.put(cacheId: "cache", scope: "s", entries: [entry("a", clock)])
    XCTAssertThrowsError(try store.put(cacheId: "cache", scope: "s", entries: [old]))
  }

  func testPruningPhysicallyReclaimsDiskWithoutTouchingDurableMemory() throws {
    let (store, clock, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let durable = RielaMemoryStore(rootDirectory: root.path)
    _ = try durable.save(memoryId: "cache", workflowId: "workflow", payload: .string("durable"))
    _ = try store.configure(cacheId: "cache", policy: .init(ttlSeconds: 1, maxBytes: 100_000))
    _ = try store.put(cacheId: "cache", scope: "s", entries: [entry("a", clock, count: 50_000)])
    let path = try store.databasePath(cacheId: "cache")
    func size() throws -> Int { (try FileManager.default.attributesOfItem(atPath: path)[.size] as! NSNumber).intValue }
    let before = try size()
    clock.advance(1)
    XCTAssertEqual(try store.prune(cacheId: "cache").stats.expiredCount, 1)
    XCTAssertLessThan(try size(), before)
    XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-wal"))
    XCTAssertEqual(try durable.load(memoryId: "cache", workflowId: "workflow").count, 1)
    XCTAssertEqual(try store.prune(cacheId: "cache").stats.entryCount, 0)
  }

  func testPolicyChangeDoesNotResurrectExpiredDataAndRejectsInvalidBounds() throws {
    let (store, clock, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try store.configure(cacheId: "cache", policy: .init(ttlSeconds: 1, maxBytes: 4096))
    _ = try store.put(cacheId: "cache", scope: "s", entries: [entry("a", clock)])
    clock.advance(2)
    XCTAssertEqual(try store.configure(cacheId: "cache", policy: .init(ttlSeconds: 100, maxBytes: 4096)).stats.entryCount, 0)
    for policy in [CachePolicy(ttlSeconds: 0), .init(maxBytes: 0), .init(ttlSeconds: 31_536_001)] {
      XCTAssertThrowsError(try store.configure(cacheId: "cache", policy: policy))
    }
    XCTAssertThrowsError(try store.put(cacheId: "../durable", scope: "s", entries: [entry("a", clock)]))
    XCTAssertThrowsError(try store.put(cacheId: "cache", scope: "s", entries: [entry("a", clock), entry("a", clock)]))
  }
  func testForeignDatabaseAndFutureSchemaAreRejectedWithoutDeletingRows() throws {
    let (store, _, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let path = try store.databasePath(cacheId: "foreign")
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    try execute(db, "CREATE TABLE durable(value TEXT)")
    try execute(db, "INSERT INTO durable VALUES('preserve')")
    XCTAssertThrowsError(try store.prune(cacheId: "foreign")) { error in
      XCTAssertEqual(error as? RielaCacheError, .foreignDatabase)
    }
    XCTAssertEqual(try queryRows(db, sql: "SELECT value FROM durable", bindings: []).first?.columns["value"], "preserve")
    try execute(db, "PRAGMA application_id = 1380533064")
    try execute(db, "PRAGMA user_version = 2")
    XCTAssertThrowsError(try store.prune(cacheId: "foreign"))
  }

}
