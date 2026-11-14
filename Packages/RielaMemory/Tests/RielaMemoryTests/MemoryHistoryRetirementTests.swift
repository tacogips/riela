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
    return (store, head)
  }

  private func retire(_ store: RielaMemoryStore, _ row: MemoryRecord, dryRun: Bool = false,
                      head: Int64 = 2, workflow: String = "wf") throws -> MemoryHistoryRetirementReport {
    try store.retireHistory(memoryId: "m", recordId: row.recordId, workflowId: workflow, nodeId: "collect",
      requiredTags: ["checkpoint"], expectedHeadVersion: head, throughVersion: head - 1, dryRun: dryRun)
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
      XCTAssertEqual($0 as? MemoryHistoryRetirementError, .retiredVersion)
    }
    XCTAssertThrowsError(try store.restoreRecordVersion(memoryId: "m", recordId: head.recordId, version: 1, expectedHeadVersion: 2)) {
      XCTAssertEqual($0 as? MemoryHistoryRetirementError, .retiredVersion)
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
      tags: ["checkpoint"], relatedRecordIds: [target.recordId], payload: .string("linked"))
    _ = try store.update(memoryId: "m", recordId: head.recordId, workflowId: "wf", nodeId: "collect",
      tags: ["checkpoint"], payload: head.payload)
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
}
