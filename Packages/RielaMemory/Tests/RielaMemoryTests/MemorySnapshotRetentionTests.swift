import Foundation
import SQLite3
import XCTest
@testable import RielaMemory

final class MemorySnapshotRetentionTests: XCTestCase {
  private func store() throws -> RielaMemoryStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return RielaMemoryStore(rootDirectory: root.path)
  }

  private func commit(_ store: RielaMemoryStore, _ value: String, head: MemorySnapshotHead? = nil) throws -> MemorySnapshot {
    try store.commitSnapshot(memoryId: "source", workflowId: "poll", nodeId: "collect", tag: "checkpoint",
      expectedHead: head, payload: .string(value))
  }

  private func retain(_ store: RielaMemoryStore, _ head: MemorySnapshotHead, label: String = "batch") throws -> MemorySnapshot {
    try store.retainSnapshot(memoryId: "source", workflowId: "poll", nodeId: "collect", tag: "checkpoint", label: label, expectedHead: head)
  }

  private func load(_ store: RielaMemoryStore, label: String = "batch", workflow: String = "poll", limit: Int = 8_000_000) throws -> MemorySnapshot? {
    try store.loadRetainedSnapshot(memoryId: "source", workflowId: workflow, nodeId: "collect", tag: "checkpoint", label: label, maxPayloadBytes: limit)
  }

  private func release(_ store: RielaMemoryStore, _ head: MemorySnapshotHead, label: String = "batch") throws -> Bool {
    try store.releaseSnapshot(memoryId: "source", workflowId: "poll", nodeId: "collect", tag: "checkpoint", label: label, expectedHead: head)
  }

  func testProducerCanAdvanceWhileConsumerReadsExactOldVersionWithoutRestoringHead() throws {
    let store = try store(); let first = try commit(store, "pending-old")
    XCTAssertEqual(try retain(store, first.head).record, first.record)
    let next = try commit(store, "pending-new", head: first.head)
    XCTAssertEqual(try load(store)?.head, first.head)
    XCTAssertEqual(try load(store)?.record.payload, .string("pending-old"))
    XCTAssertEqual(try store.loadSnapshot(memoryId: "source", workflowId: "poll", nodeId: "collect", tag: "checkpoint")?.head, next.head)
    XCTAssertTrue(try release(store, first.head)); XCTAssertFalse(try release(store, first.head))
    XCTAssertNil(try load(store))
    XCTAssertEqual(try store.recordVersion(memoryId: "source", recordId: first.head.recordId, version: 1), first.record)
  }

  func testStaleRetainScopeAndLabelRebindingCannotReplaceActiveConsumerVersion() throws {
    let store = try store(); let first = try commit(store, "old")
    _ = try retain(store, first.head); let next = try commit(store, "new", head: first.head)
    XCTAssertThrowsError(try retain(store, first.head)) { XCTAssertEqual($0 as? MemorySnapshotError, .conflict) }
    XCTAssertThrowsError(try retain(store, next.head)) { XCTAssertEqual($0 as? MemorySnapshotError, .conflict) }
    XCTAssertThrowsError(try release(store, next.head)) { XCTAssertEqual($0 as? MemorySnapshotError, .conflict) }
    XCTAssertNil(try load(store, workflow: "other"))
    XCTAssertNil(try store.loadRetainedSnapshot(memoryId: "other", workflowId: "poll", nodeId: "collect", tag: "checkpoint", label: "batch"))
    XCTAssertEqual(try load(store)?.head, first.head)
  }

  func testHistoryRetirementHonorsRetainedOldVersionUntilExactRelease() throws {
    let store = try store(); let first = try commit(store, "old"); _ = try retain(store, first.head)
    let next = try commit(store, "new", head: first.head)
    func retire() throws -> MemoryHistoryRetirementReport {
      try store.retireHistory(memoryId: "source", recordId: next.head.recordId, workflowId: "poll", nodeId: "collect",
        requiredTags: ["checkpoint"], expectedHeadVersion: next.head.version, throughVersion: next.head.version - 1, dryRun: false)
    }
    XCTAssertEqual(try retire().status, "retained_snapshot")
    XCTAssertEqual(try load(store)?.record, first.record)
    XCTAssertTrue(try release(store, first.head))
    XCTAssertEqual(try retire().status, "retired")
    XCTAssertThrowsError(try store.recordVersion(memoryId: "source", recordId: first.head.recordId, version: first.head.version))
  }

  func testExpiredReferenceNeverFallsBackToLatestAndStaleReleaseCannotRemoveReusedLabel() throws {
    let store = try store(); let first = try commit(store, "old"); _ = try retain(store, first.head)
    let next = try commit(store, "new", head: first.head)
    let db = try store.openDatabase(memoryId: "source")
    try execute(db, "UPDATE memory_snapshot_retention SET expires_at=0"); sqlite3_close(db)
    XCTAssertNil(try load(store))
    _ = try retain(store, next.head)
    XCTAssertThrowsError(try release(store, first.head))
    XCTAssertEqual(try load(store)?.head, next.head)
    XCTAssertEqual(try store.recordVersion(memoryId: "source", recordId: first.head.recordId, version: 1), first.record)
  }

  func testSchemaFiveUpgradePreservesPayloadAndLiveLabelBoundRejectsWithoutRebinding() throws {
    let store = try store(); let first = try commit(store, "literal-checkpoint")
    let db = try store.openDatabase(memoryId: "source")
    try execute(db, "DROP TABLE memory_snapshot_retention")
    try execute(db, "PRAGMA user_version=5"); sqlite3_close(db)
    for index in 0..<256 { _ = try retain(store, first.head, label: "work-\(index)") }
    XCTAssertThrowsError(try retain(store, first.head, label: "overflow"))
    XCTAssertNil(try load(store, label: "overflow"))
    XCTAssertEqual(try load(store, label: "work-0")?.record, first.record)
    XCTAssertTrue(try release(store, first.head, label: "work-0"))
    XCTAssertNoThrow(try retain(store, first.head, label: "overflow"))
    XCTAssertEqual(try store.loadSnapshot(memoryId: "source", workflowId: "poll", nodeId: "collect", tag: "checkpoint")?.head, first.head)
  }

  func testPayloadBudgetAndInvalidLabelFailWithoutCreatingRetention() throws {
    let store = try store(); let first = try commit(store, String(repeating: "字", count: 100))
    XCTAssertThrowsError(try store.retainSnapshot(memoryId: "source", workflowId: "poll", nodeId: "collect", tag: "checkpoint",
      label: "batch", expectedHead: first.head, maxPayloadBytes: 100))
    XCTAssertNil(try load(store))
    XCTAssertThrowsError(try retain(store, first.head, label: "\u{0}"))
    _ = try retain(store, first.head)
    XCTAssertThrowsError(try load(store, limit: 100))
    XCTAssertEqual(try load(store)?.head, first.head)
  }
}
