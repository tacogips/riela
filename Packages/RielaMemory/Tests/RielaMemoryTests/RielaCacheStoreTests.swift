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

  func testConcurrentProtectedWritersCannotOversubscribeSharedBudget() async throws {
    let (store, clock, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try store.configure(cacheId: "cache", policy: .init(maxBytes: 600))
    let first = CachePut(key: "a", fetchedAt: cacheTimestamp(Int64(clock.now().timeIntervalSince1970 * 1000)),
      payload: .string("pending"), protectFromEviction: true)
    let second = CachePut(key: "b", fetchedAt: first.fetchedAt, payload: first.payload, protectFromEviction: true)
    let admitted = await withTaskGroup(of: Bool.self) { group in
      for value in [first, second] {
        group.addTask {
          do { _ = try store.put(cacheId: "cache", scope: value.key, entries: [value]); return true }
          catch { return false }
        }
      }
      var count = 0
      for await success in group where success { count += 1 }
      return count
    }
    XCTAssertEqual(admitted, 1)
    let stats = try store.prune(cacheId: "cache").stats
    XCTAssertEqual(stats.entryCount, 1)
    XCTAssertEqual(stats.byteCount, stats.protectedByteCount)
    XCTAssertLessThanOrEqual(stats.byteCount, 600)
  }

  func testVersionOneMigrationPreservesEntriesRevisionAndTTL() throws {
    let (store, clock, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let saved = try store.put(cacheId: "cache", scope: "s", entries: [entry("a", clock)]).results[0].entry!
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(try store.databasePath(cacheId: "cache"), &db), SQLITE_OK)
    try execute(db, "ALTER TABLE cache_entries DROP COLUMN protected")
    try execute(db, "PRAGMA user_version = 1")
    sqlite3_close(db)
    let migrated = try store.get(cacheId: "cache", scope: "s", keys: ["a"]).results[0].entry!
    XCTAssertEqual(migrated.revision, saved.revision)
    XCTAssertEqual(migrated.expiresAt, saved.expiresAt)
    XCTAssertEqual(migrated.protectFromEviction, false)
    let protected = try store.protect(cacheId: "cache", scope: "s", entries: [
      .init(key: "a", revision: saved.revision, protectFromEviction: true)])
    XCTAssertEqual(protected.stats.protectedByteCount, saved.byteCount)
    XCTAssertEqual(sqlite3_open(try store.databasePath(cacheId: "cache"), &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    XCTAssertEqual(try queryRows(db, sql: "PRAGMA user_version", bindings: []).first?.columns["user_version"], "2")
  }

  func testMaintenanceUsesOwnedExistingStoresAndPreservesPolicy() throws {
    let (store, clock, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertEqual(try store.maintain(cacheIds: ["missing"]).cacheCount, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    _ = try store.configure(cacheId: "cache", policy: .init(ttlSeconds: 2, maxBytes: 2000))
    _ = try store.put(cacheId: "cache", scope: "s", entries: [entry("old", clock)])
    _ = try store.configure(cacheId: "unowned", policy: .init(ttlSeconds: 3600, maxBytes: 3000))
    _ = try store.put(cacheId: "unowned", scope: "s", entries: [entry("kept", clock)])
    clock.advance(3)
    let foreign = root.appendingPathComponent("foreign.cache.sqlite")
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(foreign.path, &db), SQLITE_OK); sqlite3_close(db)
    let foreignBytes = try Data(contentsOf: foreign)
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("symlink.cache.sqlite").path,
      withDestinationPath: root.appendingPathComponent("unowned.cache.sqlite").path)
    try FileManager.default.linkItem(at: root.appendingPathComponent("unowned.cache.sqlite"),
      to: root.appendingPathComponent("hardlink.cache.sqlite"))
    let result = try store.maintain(cacheIds: ["cache", "missing", "foreign", "symlink", "hardlink"])
    XCTAssertEqual(result.status, "ok"); XCTAssertEqual(result.cacheCount, 1)
    XCTAssertEqual(result.expiredEntryCount, 1)
    XCTAssertEqual(try Data(contentsOf: foreign), foreignBytes)
    XCTAssertEqual(try store.get(cacheId: "unowned", scope: "s", keys: ["kept"]).stats.policy,
      CachePolicy(ttlSeconds: 3600, maxBytes: 3000))
    XCTAssertEqual(try store.prune(cacheId: "cache").stats.policy, CachePolicy(ttlSeconds: 2, maxBytes: 2000))
  }

  func testReferenceSnapshotReleasesSupersededArtifactsAndAtomicAdmissionSurvivesFullCache() throws {
    let (store, clock, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try store.configure(cacheId: "cache", policy: .init(ttlSeconds: 10, maxBytes: 1500))
    var stale = entry("stale", clock); stale.protectFromEviction = true
    var live = entry("live", clock); live.protectFromEviction = true
    let first = try store.put(cacheId: "cache", scope: "s", entries: [stale, live])
    let ref = first.results[1].entry!
    let snapshot: MemoryJSONValue = .object(["active": .object(["ref": .object([
      "key": .string(ref.key), "revision": .string(ref.revision)])])])
    var next = entry("next", clock); next.protectFromEviction = true
    XCTAssertThrowsError(try store.put(cacheId: "cache", scope: "s", entries: [next]))
    let saved = try store.put(cacheId: "cache", scope: "s", entries: [next], retaining: snapshot)
    XCTAssertEqual(saved.stats.evictedCount, 1)
    XCTAssertEqual(try store.get(cacheId: "cache", scope: "s", keys: ["live", "next"]).results.map(\.status), ["hit", "hit"])
    let before = try store.get(cacheId: "cache", scope: "s", keys: ["live"]).results[0].entry!
    let cleared = try store.reconcile(cacheId: "cache", scope: "s", references: .object([:]))
    XCTAssertEqual(cleared.stats.protectedByteCount, 0)
    let after = try store.get(cacheId: "cache", scope: "s", keys: ["live"]).results[0].entry!
    XCTAssertEqual(before.revision, after.revision)
    XCTAssertEqual(before.fetchedAt, after.fetchedAt)
    XCTAssertEqual(before.expiresAt, after.expiresAt)
  }

  func testReferenceSnapshotStaleRevisionRollsBackAdmissionAndDoesNotAffectOtherScopes() throws {
    let (store, clock, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var value = entry("live", clock); value.protectFromEviction = true
    let saved = try store.put(cacheId: "cache", scope: "other", entries: [value])
    _ = try store.put(cacheId: "cache", scope: "s", entries: [value])
    let stale: MemoryJSONValue = .object(["key": .string("live"), "revision": .string(String(repeating: "0", count: 64))])
    XCTAssertThrowsError(try store.put(cacheId: "cache", scope: "s", entries: [entry("new", clock)], retaining: stale))
    XCTAssertEqual(try store.get(cacheId: "cache", scope: "s", keys: ["new"]).results[0].status, "miss")
    _ = try store.reconcile(cacheId: "cache", scope: "s", references: .array([]))
    let other = try store.get(cacheId: "cache", scope: "other", keys: ["live"]).results[0].entry!
    XCTAssertEqual(other.protectFromEviction, true)
    XCTAssertEqual(other.revision, saved.results[0].entry!.revision)
    for malformed in [MemoryJSONValue.null, .string("bad"), .object(["key": .string("live"), "revision": .string("bad")])] {
      XCTAssertThrowsError(try store.reconcile(cacheId: "cache", scope: "other", references: malformed))
    }
    XCTAssertEqual(try store.get(cacheId: "cache", scope: "other", keys: ["live"]).results[0].entry!.protectFromEviction, true)
  }

  func testCapacityProtectionAcrossScopesAndReleaseRetainsOriginalLRUAndTTL() throws {
    let (store, clock, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try store.configure(cacheId: "cache", policy: .init(ttlSeconds: 10, maxBytes: 1100))
    var pending = entry("pending", clock)
    pending.protectFromEviction = true
    let saved = try store.put(cacheId: "cache", scope: "s", entries: [pending]).results[0].entry!
    _ = try store.put(cacheId: "cache", scope: "other", entries: [entry("exported", clock)])
    let fresh = try store.put(cacheId: "cache", scope: "other", entries: [entry("new", clock)])
    XCTAssertEqual(fresh.stats.evictedCount, 1)
    XCTAssertEqual(fresh.stats.protectedByteCount, saved.byteCount)
    // Release neither deletes nor touches LRU: pending is still oldest and is evicted next.
    clock.advance(8)
    let released = try store.protect(cacheId: "cache", scope: "s", entries: [
      .init(key: "pending", revision: saved.revision, protectFromEviction: false)])
    XCTAssertEqual(released.stats.entryCount, 2)
    XCTAssertEqual(released.results[0].entry?.expiresAt, saved.expiresAt)
    _ = try store.put(cacheId: "cache", scope: "other", entries: [entry("latest", clock)])
    XCTAssertEqual(try store.get(cacheId: "cache", scope: "s", keys: ["pending"]).results[0].status, "miss")
  }

  func testProtectedCapacityFailureRollsBackPutAndPolicyShrink() throws {
    let (store, clock, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try store.configure(cacheId: "cache", policy: .init(maxBytes: 1100))
    var first = entry("a", clock); first.protectFromEviction = true
    var second = entry("b", clock); second.protectFromEviction = true
    _ = try store.put(cacheId: "cache", scope: "s", entries: [first, second])
    XCTAssertThrowsError(try store.put(cacheId: "cache", scope: "other", entries: [entry("c", clock)]))
    XCTAssertThrowsError(try store.configure(cacheId: "cache", policy: .init(ttlSeconds: 80000, maxBytes: 600)))
    let result = try store.get(cacheId: "cache", scope: "s", keys: ["a", "b"])
    XCTAssertEqual(result.results.map(\.status), ["hit", "hit"])
    XCTAssertEqual(result.stats.policy, CachePolicy(maxBytes: 1100))
    XCTAssertEqual(result.stats.byteCount, result.stats.protectedByteCount)
  }

  func testStaleProtectionReleaseIsAtomicAndReplacementPreservesProtection() throws {
    let (store, clock, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var first = entry("a", clock); first.protectFromEviction = true
    let original = try store.put(cacheId: "cache", scope: "s", entries: [first, entry("b", clock)])
    let old = original.results[0].entry!
    clock.advance(1)
    let updated = try store.put(cacheId: "cache", scope: "s", entries: [entry("a", clock)]).results[0].entry!
    XCTAssertEqual(updated.protectFromEviction, true)
    XCTAssertThrowsError(try store.protect(cacheId: "cache", scope: "s", entries: [
      .init(key: "b", revision: original.results[1].entry!.revision, protectFromEviction: true),
      .init(key: "a", revision: old.revision, protectFromEviction: false)]))
    let current = try store.get(cacheId: "cache", scope: "s", keys: ["a", "b"])
    XCTAssertEqual(current.results.map { $0.entry!.protectFromEviction }, [true, false])
  }

  func testCapacityProtectionDoesNotOverrideFixedTTL() throws {
    let (store, clock, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try store.configure(cacheId: "cache", policy: .init(ttlSeconds: 10, maxBytes: 1100))
    var value = entry("a", clock); value.protectFromEviction = true
    _ = try store.put(cacheId: "cache", scope: "s", entries: [value])
    clock.advance(10)
    let result = try store.get(cacheId: "cache", scope: "s", keys: ["a"])
    XCTAssertEqual(result.results[0].reason, "expired")
    XCTAssertEqual(result.stats.protectedByteCount, 0)
    XCTAssertEqual(result.stats.byteCount, 0)
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
    try execute(db, "PRAGMA user_version = 3")
    XCTAssertThrowsError(try store.prune(cacheId: "foreign"))
  }

}
