import Foundation
import SQLite3
import XCTest
@testable import RielaMemory

final class MemoryHistoryRetirementTests: XCTestCase {
  private func fixture() throws -> (RielaMemoryStore, MemoryRecord) {
    var repo = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repo.deleteLastPathComponent() }
    let root = repo.appendingPathComponent("tmp/history-retirement/package-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    let first = try store.save(memoryId: "m", workflowId: "wf", nodeId: "collect", tags: ["checkpoint"],
      payload: .object(["body": .string(String(repeating: "OLD_BODY_SECRET_", count: 10000))]))
    let head = try store.update(memoryId: "m", recordId: first.recordId, workflowId: "wf", nodeId: "collect",
      tags: ["checkpoint"], payload: .object(["cursor": .string("keep-cursor")]))
    let db = try store.openDatabase(memoryId: "m")
    try execute(db, "DELETE FROM memory_history_versions WHERE key=?", bindings: [.text(String(first.recordId))])
    try execute(db, "DELETE FROM memory_history_heads WHERE key=?", bindings: [.text(String(first.recordId))])
    try execute(db, "DELETE FROM memory_evolution WHERE record_id=?", bindings: [.int64(first.recordId)])
    let oldBytes = Data(try encodedJSONString(first).utf8)
    let newBytes = Data(try encodedJSONString(head).utf8)
    let delta = try EvolutionReverseDelta(previous: oldBytes, next: newBytes, nextVersion: 2)
    try execute(db, "INSERT INTO memory_evolution(record_id,version,recorded_at,reverse_delta_json) VALUES(?,1,?,NULL)",
      bindings: [.int64(first.recordId), .text(currentTimestamp())])
    try execute(db, "INSERT INTO memory_evolution(record_id,version,recorded_at,reverse_delta_json) VALUES(?,2,?,?)",
      bindings: [.int64(first.recordId), .text(currentTimestamp()), .text(try encodedJSONString(delta))])
    sqlite3_close(db)
    return (store, head)
  }

  private func retire(_ store: RielaMemoryStore, _ row: MemoryRecord, dryRun: Bool = false,
                      head: Int64 = 2, workflow: String = "wf") throws -> MemoryHistoryRetirementReport {
    try store.retireHistory(memoryId: "m", recordId: row.recordId, workflowId: workflow, nodeId: "collect",
      requiredTags: ["checkpoint"], expectedHeadVersion: head, throughVersion: head - 1, dryRun: dryRun)
  }

  func testSinglePassMatchesEverySnapshotAndAppliesEachEdgeOnce() throws {
    let (store, initial) = try fixture()
    var head = initial
    var snapshots = [try store.recordVersion(memoryId: "m", recordId: head.recordId, version: 1), head]
    for version in 3...96 {
      head = try store.update(memoryId: "m", recordId: head.recordId, workflowId: "wf",
        nodeId: "collect", tags: ["checkpoint"], payload: .object(["cursor": .string("cursor-\(version)"),
          "body": .string(String(repeating: "revision-\(version)-", count: 2048))]), historyRetention: 100)
      snapshots.append(head)
      try replaceWithLegacyHistory(store, recordId: head.recordId, records: snapshots)
    }
    let db = try store.openDatabase(memoryId: "m")
    defer { sqlite3_close(db) }
    var visited: [MemoryRecord] = []
    var appliedEdges: [Int64] = []
    XCTAssertTrue(try store.walkHistoricalRecords(current: head, head: 96, floor: 1, db: db,
      onEdge: { appliedEdges.append($0) }, visit: {
      visited.append($0); return true
    }))
    XCTAssertEqual(visited, Array(snapshots.dropLast().reversed()))
    XCTAssertEqual(visited.count, 95)
    // Each reverse delta (version 96 down to 2) is decoded and applied exactly once;
    // reconstructing every version independently would apply ~95*96/2 edges.
    XCTAssertEqual(appliedEdges, Array((2...96).reversed()))
    XCTAssertEqual(try retire(store, head, dryRun: true, head: 96).status, "planned")
    XCTAssertEqual(try retire(store, head, head: 96).status, "retired")
    XCTAssertEqual(try store.recordVersion(memoryId: "m", recordId: head.recordId, version: 96), head)
  }

  func testUndoConvertsLegacyHistoryOnFirstTouch() throws {
    let (store, head) = try fixture()
    let moved = try store.undoRecord(memoryId: "m", recordId: head.recordId, expectedHeadVersion: 2)
    XCTAssertEqual(moved.record.payload, .object(["body": .string(String(repeating: "OLD_BODY_SECRET_", count: 10000))]))
    XCTAssertEqual(moved.headVersion, 1)
    XCTAssertEqual(try store.evolutionHistory(memoryId: "m", recordId: head.recordId).map(\.version), [2, 1])
  }

  func testRepeatedRetirementStartsAtPreviouslyRetainedFloor() throws {
    let (store, initial) = try fixture()
    XCTAssertEqual(try retire(store, initial).status, "retired")
    var head = initial
    for version in 3...5 {
      head = try store.update(memoryId: "m", recordId: head.recordId, workflowId: "wf",
        nodeId: "collect", tags: ["checkpoint"], payload: .string("cursor-\(version)"), historyRetention: 100)
    }
    XCTAssertEqual(try retire(store, head, dryRun: true, head: 5).status, "planned")
    XCTAssertEqual(try retire(store, head, head: 5).status, "retired")
    XCTAssertEqual(try store.recordVersion(memoryId: "m", recordId: head.recordId, version: 5), head)
    XCTAssertThrowsError(try store.recordVersion(memoryId: "m", recordId: head.recordId, version: 2))
  }

  func testMalformedHistoricalDeltaFailsBeforeAnyRetirementMutation() throws {
    let (store, head) = try fixture()
    let db = try store.openDatabase(memoryId: "m")
    try execute(db, "UPDATE memory_evolution SET reverse_delta_json='{}' WHERE record_id=1 AND version=2")
    sqlite3_close(db)
    let url = URL(fileURLWithPath: try store.databasePath(memoryId: "m"))
    let before = try Data(contentsOf: url)
    XCTAssertThrowsError(try retire(store, head, dryRun: true))
    XCTAssertEqual(try Data(contentsOf: url), before)
    XCTAssertThrowsError(try retire(store, head))
    XCTAssertEqual(try Data(contentsOf: url), before)
  }

  func testRetirementPreservesHeadAndMonotonicVersionsAndReclaimsBytes() throws {
    let (store, head) = try fixture()
    let other = try store.save(memoryId: "m", workflowId: "other", payload: .string("preserve-other"))
    let result = try retire(store, head)
    XCTAssertEqual(result.status, "retired")
    XCTAssertTrue(result.reclaimed)
    XCTAssertGreaterThan(result.retiredDeltaBytes, 100000)
    XCTAssertEqual(try store.recordVersion(memoryId: "m", recordId: head.recordId, version: 2), head)
    XCTAssertEqual(try store.recordVersion(memoryId: "m", recordId: other.recordId, version: 1), other)
    XCTAssertThrowsError(try store.recordVersion(memoryId: "m", recordId: head.recordId, version: 1)) {
      guard case .versionNotRetained(version: 1, retained: [2], retainedGenerations: _) = $0 as? VersionedHistoryError else {
        return XCTFail("expected version-not-retained, got \($0)")
      }
    }
    XCTAssertThrowsError(try store.restoreRecordVersion(memoryId: "m", recordId: head.recordId, version: 1, expectedHeadVersion: 2)) {
      guard case .versionNotRetained(version: 1, retained: [2], retainedGenerations: _) = $0 as? VersionedHistoryError else {
        return XCTFail("expected version-not-retained, got \($0)")
      }
    }
    XCTAssertEqual(try store.evolutionHistory(memoryId: "m", recordId: head.recordId).map(\.version), [2])
    XCTAssertNil(try store.evolutionHistory(memoryId: "m", recordId: head.recordId).first?.reverseDelta)
    let disk = try Data(contentsOf: URL(fileURLWithPath: store.databasePath(memoryId: "m")))
    XCTAssertNil(disk.range(of: Data("OLD_BODY_SECRET_".utf8)))
    XCTAssertNil(disk.range(of: Data(Data("OLD_BODY_SECRET_".utf8).base64EncodedString().utf8)))
    _ = try store.update(memoryId: "m", recordId: head.recordId, payload: .string("next"))
    XCTAssertEqual(try store.evolutionHistory(memoryId: "m", recordId: head.recordId).map(\.version), [3, 2])
    XCTAssertEqual(try store.recordVersion(memoryId: "m", recordId: head.recordId, version: 2), head)
  }

  func testDryRunAndOwnershipAndStaleHeadDoNotChangeStore() throws {
    let (store, head) = try fixture()
    let url = URL(fileURLWithPath: try store.databasePath(memoryId: "m"))
    let before = try Data(contentsOf: url)
    XCTAssertEqual(try retire(store, head, dryRun: true).status, "planned")
    XCTAssertEqual(try Data(contentsOf: url), before)
    XCTAssertEqual(try retire(store, head, workflow: "wrong").status, "ownership_mismatch")
    XCTAssertEqual(try retire(store, head, head: 3).status, "stale_head")
    XCTAssertEqual(try Data(contentsOf: url), before)
    XCTAssertNoThrow(try store.recordVersion(memoryId: "m", recordId: head.recordId, version: 1))
  }

  func testIncomingRelatedReferenceBlocksAndIsPreserved() throws {
    let (store, head) = try fixture()
    let reference = try store.save(memoryId: "m", workflowId: "other", relatedRecordIds: [head.recordId], payload: .string("reference"))
    XCTAssertEqual(try retire(store, head).status, "referenced")
    XCTAssertEqual(try store.recordVersion(memoryId: "m", recordId: reference.recordId, version: 1), reference)
    XCTAssertNoThrow(try store.recordVersion(memoryId: "m", recordId: head.recordId, version: 1))
  }

  func testLoadAuditIsPreservedWithoutPinningVersions() throws {
    let (store, head) = try fixture()
    _ = try store.load(memoryId: "m", workflowId: "wf")
    let audit = try store.referenceHistory(memoryId: "m", recordId: head.recordId)
    XCTAssertFalse(audit.isEmpty)
    XCTAssertEqual(try retire(store, head).status, "retired")
    XCTAssertEqual(try store.referenceHistory(memoryId: "m", recordId: head.recordId), audit)
  }

  func testSchemaFourDryRunDoesNotMigrateAndApplyPreservesHistoryFloor() throws {
    let (store, head) = try fixture()
    let db = try store.openDatabase(memoryId: "m")
    try execute(db, "DROP TABLE memory_retirement")
    try execute(db, "PRAGMA user_version=4")
    sqlite3_close(db)
    let url = URL(fileURLWithPath: try store.databasePath(memoryId: "m"))
    let before = try Data(contentsOf: url)
    XCTAssertEqual(try retire(store, head, dryRun: true).status, "planned")
    XCTAssertEqual(try Data(contentsOf: url), before)
    XCTAssertEqual(try retire(store, head).status, "retired")
    XCTAssertThrowsError(try store.recordVersion(memoryId: "m", recordId: head.recordId, version: 1))
  }

  func testWALActiveReaderAndWriterBlockBeforeMutation() throws {
    let (store, head) = try fixture()
    let db = try store.openDatabase(memoryId: "m")
    defer { sqlite3_close(db) }
    _ = try queryRows(db, sql: "PRAGMA journal_mode=WAL", bindings: [])
    try execute(db, "BEGIN")
    _ = try queryRows(db, sql: "SELECT COUNT(*) FROM memory_entries", bindings: [])
    XCTAssertEqual(try retire(store, head).status, "busy")
    try execute(db, "ROLLBACK")
    try execute(db, "BEGIN IMMEDIATE")
    XCTAssertEqual(try retire(store, head).status, "busy")
    try execute(db, "ROLLBACK")
    // Closing the idle WAL connection is required for exclusive WAL admission.
  }

  func testHistoricalRelatedReferencesBlockEvenWhenCurrentHeadClearedThem() throws {
    let (store, head) = try fixture()
    let target = try store.save(memoryId: "m", workflowId: "other", payload: .string("target"))
    _ = try store.update(memoryId: "m", recordId: head.recordId, workflowId: "wf", nodeId: "collect",
      tags: ["checkpoint"], relatedRecordIds: [target.recordId], payload: .string("linked"), historyRetention: 10)
    _ = try store.update(memoryId: "m", recordId: head.recordId, workflowId: "wf", nodeId: "collect",
      tags: ["checkpoint"], payload: head.payload, historyRetention: 10)
    XCTAssertEqual(try retire(store, head, head: 4).status, "historical_references")
    XCTAssertNoThrow(try store.recordVersion(memoryId: "m", recordId: head.recordId, version: 1))
  }

  func testSequentialRetirementOfMultipleHeadsPreservesBothCurrentRecords() throws {
    let (store, first) = try fixture()
    let oldSecond = try store.save(memoryId: "m", workflowId: "wf", nodeId: "collect", tags: ["checkpoint"], payload: .string("second old body"))
    XCTAssertEqual(try retire(store, first).status, "retired")
    let second = try store.update(memoryId: "m", recordId: oldSecond.recordId, workflowId: "wf", nodeId: "collect",
      tags: ["checkpoint"], payload: .string("second checkpoint"))
    XCTAssertEqual(try retire(store, second).status, "retired")
    XCTAssertEqual(try store.recordVersion(memoryId: "m", recordId: first.recordId, version: 2), first)
    XCTAssertEqual(try store.recordVersion(memoryId: "m", recordId: second.recordId, version: 2), second)
    XCTAssertThrowsError(try store.recordVersion(memoryId: "m", recordId: second.recordId, version: 1))
  }

  func testLinkedDatabaseAndCompanionsCannotModifyOutsideCanary() throws {
    for suffix in ["", "-wal", "-shm", "-journal"] {
      let (store, head) = try fixture()
      let path = try store.databasePath(memoryId: "m")
      let canary = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("canary")
      let bytes = Data("external canary must survive".utf8)
      if suffix.isEmpty {
        try FileManager.default.linkItem(atPath: path, toPath: canary.path)
      } else {
        try bytes.write(to: canary)
        try FileManager.default.createSymbolicLink(atPath: path + suffix, withDestinationPath: canary.path)
      }
      let before = try Data(contentsOf: canary)
      XCTAssertThrowsError(try retire(store, head))
      XCTAssertEqual(try Data(contentsOf: canary), before)
      if !suffix.isEmpty { try FileManager.default.removeItem(atPath: path + suffix) }
      XCTAssertNoThrow(try store.recordVersion(memoryId: "m", recordId: head.recordId, version: 1))
    }
  }

  func testNodeAndTagOwnershipMismatchPreserveAllVersions() throws {
    let (store, head) = try fixture()
    for (node, tags) in [("wrong", ["checkpoint"]), ("collect", ["missing"])] {
      let report = try store.retireHistory(memoryId: "m", recordId: head.recordId, workflowId: "wf", nodeId: node,
        requiredTags: tags, expectedHeadVersion: 2, throughVersion: 1, dryRun: false)
      XCTAssertEqual(report.status, "ownership_mismatch")
      XCTAssertNoThrow(try store.recordVersion(memoryId: "m", recordId: head.recordId, version: 1))
    }
  }

  func testPersistentRollbackJournalDoesNotRetainOldPageImages() throws {
    let (store, head) = try fixture()
    let db = try store.openDatabase(memoryId: "m")
    _ = try queryRows(db, sql: "PRAGMA journal_mode=PERSIST", bindings: [])
    sqlite3_close(db)
    XCTAssertEqual(try retire(store, head).status, "retired")
    let journal = try store.databasePath(memoryId: "m") + "-journal"
    if FileManager.default.fileExists(atPath: journal) {
      XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: journal)).count, 0)
    }
  }

  func testCorruptFloorAndMissingBaselineBlockWithoutDiscardingDeltas() throws {
    let (store, head) = try fixture()
    let db = try store.openDatabase(memoryId: "m")
    try execute(db, "INSERT INTO memory_retirement(record_id,retained_floor) VALUES(?,99)", bindings: [.int64(head.recordId)])
    sqlite3_close(db)
    XCTAssertEqual(try retire(store, head).status, "invalid_floor")
    let repair = try store.openDatabase(memoryId: "m")
    try execute(repair, "DELETE FROM memory_retirement")
    try execute(repair, "DELETE FROM memory_evolution WHERE version=1")
    sqlite3_close(repair)
    XCTAssertEqual(try retire(store, head).status, "invalid_chain")
    let inspect = try store.openDatabase(memoryId: "m", readOnly: true)
    defer { sqlite3_close(inspect) }
    XCTAssertEqual(try queryRows(inspect, sql: "SELECT COUNT(*) AS n FROM memory_evolution WHERE version=2", bindings: []).first?.columns["n"], "1")
  }

  func testActiveReaderPreventsRetirement() throws {
    let (store, head) = try fixture()
    let db = try store.openDatabase(memoryId: "m", readOnly: true)
    defer { sqlite3_close(db) }
    try execute(db, "BEGIN")
    _ = try queryRows(db, sql: "SELECT COUNT(*) FROM memory_entries", bindings: [])
    XCTAssertEqual(try retire(store, head).status, "busy")
    try execute(db, "ROLLBACK")
    XCTAssertEqual(try retire(store, head).status, "retired")
  }

  private func replaceWithLegacyHistory(_ store: RielaMemoryStore, recordId: Int64, records: [MemoryRecord]) throws {
    let db = try store.openDatabase(memoryId: "m")
    defer { sqlite3_close(db) }
    try execute(db, "DELETE FROM memory_history_versions WHERE key=?", bindings: [.text(String(recordId))])
    try execute(db, "DELETE FROM memory_history_heads WHERE key=?", bindings: [.text(String(recordId))])
    try execute(db, "DELETE FROM memory_evolution WHERE record_id=?", bindings: [.int64(recordId)])
    try execute(db, "INSERT INTO memory_evolution(record_id,version,recorded_at,reverse_delta_json) VALUES(?,1,?,NULL)",
      bindings: [.int64(recordId), .text(currentTimestamp())])
    for index in 1..<records.count {
      let previous = Data(try encodedJSONString(records[index - 1]).utf8)
      let next = Data(try encodedJSONString(records[index]).utf8)
      let delta = try EvolutionReverseDelta(previous: previous, next: next, nextVersion: Int64(index + 1))
      try execute(db, "INSERT INTO memory_evolution(record_id,version,recorded_at,reverse_delta_json) VALUES(?,?,?,?)",
        bindings: [.int64(recordId), .int64(Int64(index + 1)), .text(currentTimestamp()), .text(try encodedJSONString(delta))])
    }
  }
}
