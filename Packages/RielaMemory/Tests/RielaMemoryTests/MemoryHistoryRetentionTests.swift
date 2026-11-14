import Foundation
import SQLite3
import XCTest
@testable import RielaMemory

final class MemoryHistoryRetentionTests: XCTestCase {
  func testDefaultRetentionBoundsLargeMemoryHistoryAtOnePreviousVersion() throws {
    let root = try repositoryScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.appendingPathComponent("db").path)
    var record = try store.save(memoryId: "large", workflowId: "test", payload: largePayload(step: 0))
    for step in 1...1_000 {
      record = try store.update(memoryId: "large", recordId: record.recordId, payload: largePayload(step: step))
    }
    let versions = try store.evolutionHistory(memoryId: "large", recordId: record.recordId)
    XCTAssertEqual(versions.count, 2)
    let previous = try XCTUnwrap(versions.last?.storage)
    let compressedFull = try VersionedHistoryCodec.compressed(Data(try encodedJSONString(record).utf8)).0
    XCTAssertLessThanOrEqual(previous.storedBytes, Int64(compressedFull.count))
    XCTAssertThrowsError(try store.recordVersion(memoryId: "large", recordId: record.recordId, version: 1))
    let db = try store.openDatabase(memoryId: "large", readOnly: true)
    defer { sqlite3_close(db) }
    let row = try queryRows(db, sql: "SELECT revision,head_version FROM memory_history_heads WHERE key=?",
      bindings: [.text(String(record.recordId))]).first
    XCTAssertEqual(row?.columns["revision"], "1001")
    XCTAssertEqual(row?.columns["head_version"], "1001")
    XCTAssertEqual(try queryRows(db, sql: "SELECT COUNT(*) AS n FROM memory_history_versions WHERE key=? AND version<>1001",
      bindings: [.text(String(record.recordId))]).first?.columns["n"], "1")
  }

  func testRetentionDeleteReclaimsDatabasePages() throws {
    let root = try repositoryScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    let databaseId = "vacuum"
    let freshDatabase = try store.openDatabase(memoryId: databaseId)
    XCTAssertEqual(try queryRows(freshDatabase, sql: "PRAGMA auto_vacuum", bindings: []).first?.columns["auto_vacuum"], "2")
    sqlite3_close(freshDatabase)

    let first = try store.save(memoryId: databaseId, workflowId: "test", payload: noisyPayload(seed: 1))
    _ = try store.update(memoryId: databaseId, recordId: first.recordId, payload: noisyPayload(seed: 2))
    let historicalBlobBytes = try historyBlobBytes(store: store, memoryId: databaseId, recordId: first.recordId)
    let pageSize = try databasePageSize(store: store, memoryId: databaseId)
    let expectedFreedPages = max(historicalBlobBytes / pageSize, 1)
    let fileSizeBeforeDelete = try databaseFileSize(store: store, memoryId: databaseId)

    _ = try store.update(memoryId: databaseId, recordId: first.recordId, payload: noisyPayload(seed: 3))

    let freelistCountAfterDelete = try databaseFreelistCount(store: store, memoryId: databaseId)
    let fileSizeAfterDelete = try databaseFileSize(store: store, memoryId: databaseId)
    XCTAssertLessThan(freelistCountAfterDelete, expectedFreedPages,
      "incremental vacuum should reclaim most pages from the deleted history BLOB")
    XCTAssertLessThanOrEqual(fileSizeAfterDelete, fileSizeBeforeDelete, "retention reclamation should not grow the database file")
  }

  func testExplicitRetentionAndInvalidValues() throws {
    let root = try repositoryScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    var record = try store.save(memoryId: "custom", workflowId: "test", payload: .number(0), historyRetention: 5)
    for value in 1...9 {
      record = try store.update(memoryId: "custom", recordId: record.recordId, payload: .number(Double(value)), historyRetention: 5)
    }
    XCTAssertEqual(try store.evolutionHistory(memoryId: "custom", recordId: record.recordId).map(\.version), [10, 9, 8, 7, 6])
    XCTAssertThrowsError(try store.update(memoryId: "custom", recordId: record.recordId, payload: .number(10), historyRetention: 0)) {
      XCTAssertEqual($0 as? RielaMemoryError, .invalidHistoryRetention(0))
    }
    XCTAssertThrowsError(try store.save(memoryId: "invalid", workflowId: "test", payload: .null, historyRetention: 1_001)) {
      XCTAssertEqual($0 as? RielaMemoryError, .invalidHistoryRetention(1_001))
    }
    let unchanged = try store.update(memoryId: "custom", recordId: record.recordId, payload: record.payload, historyRetention: 3)
    XCTAssertEqual(unchanged, record)
    XCTAssertEqual(try store.evolutionHistory(memoryId: "custom", recordId: record.recordId).count, 3)
    let target = try store.recordVersion(memoryId: "custom", recordId: record.recordId, version: 9)
    let restored = try store.restoreRecordVersion(memoryId: "custom", recordId: record.recordId, version: 9,
      expectedHeadVersion: 10, historyRetention: 5)
    XCTAssertEqual(restored, target)
  }

  func testUndoRedoRevisionAndSharedStructuralDiff() throws {
    let root = try repositoryScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    let first = try store.save(memoryId: "moves", workflowId: "test", payload: .object(["state": .string("old")]))
    let second = try store.update(memoryId: "moves", recordId: first.recordId, payload: .object(["state": .string("new")]))
    let diff = try store.recordDiff(memoryId: "moves", recordId: first.recordId, fromVersion: 1, toVersion: nil)
    XCTAssertEqual(diff.map(\.path), ["/payload/state"])
    let undone = try store.undoRecord(memoryId: "moves", recordId: first.recordId, expectedHeadVersion: 2)
    XCTAssertEqual(undone.record.payload, first.payload)
    XCTAssertEqual(undone.revision, 3)
    XCTAssertThrowsError(try store.undoRecord(memoryId: "moves", recordId: first.recordId, expectedHeadVersion: 3))
    let redone = try store.redoRecord(memoryId: "moves", recordId: first.recordId, expectedHeadVersion: 3)
    XCTAssertEqual(redone.record.payload, second.payload)
    XCTAssertEqual(redone.revision, 4)
    XCTAssertThrowsError(try store.redoRecord(memoryId: "moves", recordId: first.recordId, expectedHeadVersion: 3))
  }

  func testSchemaSixLegacyRowsRemainReadableThenConvertOnWriteAndInBatches() throws {
    let root = try repositoryScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.appendingPathComponent("db").path)
    let first = try store.save(memoryId: "legacy", workflowId: "test", payload: .string("one"))
    let second = try store.update(memoryId: "legacy", recordId: first.recordId, payload: .string("two"))
    let pending = try store.save(memoryId: "legacy", workflowId: "test", payload: .string("pending"))
    let db = try store.openDatabase(memoryId: "legacy")
    try execute(db, "DELETE FROM memory_history_versions WHERE key IN (?,?)", bindings: [.text(String(first.recordId)), .text(String(pending.recordId))])
    try execute(db, "DELETE FROM memory_history_heads WHERE key IN (?,?)", bindings: [.text(String(first.recordId)), .text(String(pending.recordId))])
    try installLegacyChain(db: db, first: first, latest: second)
    try installLegacyChain(db: db, first: pending, latest: pending)
    try execute(db, "PRAGMA user_version=6")
    sqlite3_close(db)

    XCTAssertEqual(try store.evolutionHistory(memoryId: "legacy", recordId: first.recordId).map(\.version), [2, 1])
    _ = try store.update(memoryId: "legacy", recordId: first.recordId, payload: .string("three"))
    XCTAssertEqual(try store.evolutionHistory(memoryId: "legacy", recordId: first.recordId).map(\.version), [3, 2])
    let converted = try store.convertLegacyHistory(memoryId: "legacy", maxRecords: 10)
    XCTAssertEqual(converted.converted, 1)
    XCTAssertEqual(converted.remaining, 0)
    let inspect = try store.openDatabase(memoryId: "legacy", readOnly: true)
    defer { sqlite3_close(inspect) }
    XCTAssertEqual(try queryRows(inspect, sql: "PRAGMA user_version", bindings: []).first?.columns["user_version"], "7")
  }

  func testSnapshotWritesKeepNoUnpinnedHistoryAndRetainPinnedValue() throws {
    let root = try repositoryScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    let vacuum = try store.openDatabase(memoryId: "fresh")
    XCTAssertEqual(try queryRows(vacuum, sql: "PRAGMA auto_vacuum", bindings: []).first?.columns["auto_vacuum"], "2")
    sqlite3_close(vacuum)
    var unretained = try store.commitSnapshot(memoryId: "unretained", workflowId: "test", nodeId: "node", tag: "checkpoint",
      expectedHead: nil, payload: .string("unretained-0"))
    for index in 1...50 {
      unretained = try store.commitSnapshot(memoryId: "unretained", workflowId: "test", nodeId: "node", tag: "checkpoint",
        expectedHead: unretained.head, payload: .string("unretained-\(index)"))
    }
    let unretainedDB = try store.openDatabase(memoryId: "unretained", readOnly: true)
    XCTAssertEqual(try queryRows(unretainedDB, sql: "SELECT COUNT(*) AS n FROM memory_history_versions WHERE key=? AND version<>51",
      bindings: [.text(String(unretained.head.recordId))]).first?.columns["n"], "0")
    sqlite3_close(unretainedDB)
    var snapshot = try store.commitSnapshot(memoryId: "state", workflowId: "test", nodeId: "node", tag: "checkpoint",
      expectedHead: nil, payload: .string("state-0"))
    _ = try store.retainSnapshot(memoryId: "state", workflowId: "test", nodeId: "node", tag: "checkpoint",
      label: "consumer", expectedHead: snapshot.head)
    for index in 1...50 {
      snapshot = try store.commitSnapshot(memoryId: "state", workflowId: "test", nodeId: "node", tag: "checkpoint",
        expectedHead: snapshot.head, payload: .string("state-\(index)"))
    }
    XCTAssertEqual(try store.recordVersion(memoryId: "state", recordId: snapshot.head.recordId, version: 1).payload, .string("state-0"))
    let db = try store.openDatabase(memoryId: "state", readOnly: true)
    defer { sqlite3_close(db) }
    XCTAssertEqual(try queryRows(db, sql: "SELECT COUNT(*) AS n FROM memory_history_versions WHERE key=? AND version<>51",
      bindings: [.text(String(snapshot.head.recordId))]).first?.columns["n"], "1")
  }

  private func largePayload(step: Int) -> MemoryJSONValue {
    .object(["header": .number(Double(step)), "document": .string(String(repeating: "x", count: 660_000)),
      "items": .array((0...step).map { .number(Double($0)) })])
  }

  private func noisyPayload(seed: UInt64) -> MemoryJSONValue {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" )
    var state = seed
    var characters: [Character] = []
    characters.reserveCapacity(256_000)
    for _ in 0..<256_000 {
      state ^= state << 13
      state ^= state >> 7
      state ^= state << 17
      characters.append(alphabet[Int(state % UInt64(alphabet.count))])
    }
    return .string(String(characters))
  }

  private func databaseFreelistCount(store: RielaMemoryStore, memoryId: String) throws -> Int64 {
    let db = try store.openDatabase(memoryId: memoryId, readOnly: true)
    defer { sqlite3_close(db) }
    return try XCTUnwrap(queryRows(db, sql: "PRAGMA freelist_count", bindings: []).first?.columns["freelist_count"].flatMap(Int64.init))
  }

  private func historyBlobBytes(store: RielaMemoryStore, memoryId: String, recordId: Int64) throws -> Int64 {
    let db = try store.openDatabase(memoryId: memoryId, readOnly: true)
    defer { sqlite3_close(db) }
    let row = try queryRows(db, sql: "SELECT COALESCE(SUM(length(blob)),0) AS bytes FROM memory_history_versions WHERE key=? AND version<?",
      bindings: [.text(String(recordId)), .int64(2)]).first
    return try XCTUnwrap(row?.columns["bytes"].flatMap(Int64.init))
  }

  private func databasePageSize(store: RielaMemoryStore, memoryId: String) throws -> Int64 {
    let db = try store.openDatabase(memoryId: memoryId, readOnly: true)
    defer { sqlite3_close(db) }
    return try XCTUnwrap(queryRows(db, sql: "PRAGMA page_size", bindings: []).first?.columns["page_size"].flatMap(Int64.init))
  }

  private func databaseFileSize(store: RielaMemoryStore, memoryId: String) throws -> UInt64 {
    let path = try store.databasePath(memoryId: memoryId)
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return try XCTUnwrap((attributes[.size] as? NSNumber)?.uint64Value)
  }

  private func installLegacyChain(db: OpaquePointer?, first: MemoryRecord, latest: MemoryRecord) throws {
    try execute(db, "DELETE FROM memory_evolution WHERE record_id=?", bindings: [.int64(first.recordId)])
    try execute(db, "INSERT INTO memory_evolution(record_id,version,recorded_at,reverse_delta_json) VALUES(?,1,?,NULL)",
      bindings: [.int64(first.recordId), .text(currentTimestamp())])
    guard first != latest else { return }
    let delta = try EvolutionReverseDelta(previous: Data(try encodedJSONString(first).utf8),
      next: Data(try encodedJSONString(latest).utf8), nextVersion: 2)
    try execute(db, "INSERT INTO memory_evolution(record_id,version,recorded_at,reverse_delta_json) VALUES(?,2,?,?)",
      bindings: [.int64(first.recordId), .text(currentTimestamp()), .text(try encodedJSONString(delta))])
  }

  private func repositoryScratchRoot() throws -> URL {
    var repository = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let root = repository.appendingPathComponent("tmp/efficient-history/eh-03-memory-history/test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
