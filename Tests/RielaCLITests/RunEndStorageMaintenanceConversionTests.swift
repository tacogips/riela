import Foundation
import RielaCore
import RielaSQLite
import XCTest
@testable import RielaCLI

final class RunEndStorageMaintenanceConversionTests: XCTestCase {
  func testProfileBudgets() {
    XCTAssertEqual(StorageMaintenanceProfile.runEnd.total, .init(conversions: 16, rowsExamined: 256, wallSeconds: 2))
    XCTAssertEqual(StorageMaintenanceProfile.runEnd.retryShare, .init(conversions: 8, rowsExamined: 128, wallSeconds: 1))
    XCTAssertEqual(StorageMaintenanceProfile.scheduled.total, .init(conversions: 64, rowsExamined: 1024, wallSeconds: 10))
    XCTAssertEqual(StorageMaintenanceProfile.scheduled.retryShare, .init(conversions: 32, rowsExamined: 512, wallSeconds: 5))
    XCTAssertEqual(StorageMaintenanceProfile.runEnd.vacuumPageCap, 4096)
    XCTAssertEqual(StorageMaintenanceProfile.scheduled.vacuumPageCap, 65536)
  }

  func testCompletedCursorDoesNotOpenStore() throws {
    let root = try makeRielaCLITestTemporaryDirectory("conversion-fast-path")
    defer { try? FileManager.default.removeItem(at: root) }
    var queue = StorageMaintenanceCursor.Queue()
    queue.complete = true
    queue.parked = [.init(key: "parked", error: "failure")]
    try StorageMaintenanceCursor(queues: ["snapshots": queue, "cliRecords": queue, "nested": queue])
      .write(stateDirectory: root.path)
    let held = try XCTUnwrap(RetentionTargetLock.tryAcquire(stateDirectory: root.path))
    defer { withExtendedLifetime(held) {} }
    let missingStore = root.appendingPathComponent("missing").path
    var observed: StorageMaintenancePassStats?
    let warnings = StorageMaintenanceConversion.run(sessionStoreRoot: missingStore, stateDirectory: root.path,
      profile: .runEnd, observe: { observed = $0 })
    XCTAssertTrue(warnings.isEmpty)
    XCTAssertEqual(observed, StorageMaintenancePassStats())
    XCTAssertFalse(FileManager.default.fileExists(atPath: missingStore))
  }
}

private final class ConversionFixture {
  let root: URL
  let runtime: SQLiteWorkflowRuntimePersistenceStore
  let db: SQLiteDatabase
  let targetLock: RetentionTargetLock
  let date = Date(timeIntervalSince1970: 1_700_000_000)

  init() throws {
    let directory = try makeRielaCLITestTemporaryDirectory("conversion-fixture")
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: directory.path))
    let instant = Date(timeIntervalSince1970: 1_700_000_000)
    let seed = WorkflowSession(workflowId: "flow", sessionId: "seed", status: .completed,
      entryStepId: "start", createdAt: instant, updatedAt: instant)
    try store.save(WorkflowRuntimePersistenceSnapshot(session: seed))
    root = directory
    runtime = store
    db = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: directory.path))
    targetLock = try XCTUnwrap(RetentionTargetLock.tryAcquire(stateDirectory: directory.path))
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  func insert(_ id: String, status: WorkflowSessionStatus = .completed, malformed: Bool = false) throws {
    let session = WorkflowSession(workflowId: "flow", sessionId: id, status: status,
      entryStepId: "start", createdAt: date, updatedAt: date)
    try runtime.save(WorkflowRuntimePersistenceSnapshot(session: session))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var json = try XCTUnwrap(String(data: encoder.encode(session), encoding: .utf8))
    if malformed { json = #"{"workflowId":"flow","status":"completed","executions":[]}"# }
    try db.execute("UPDATE workflow_runtime_snapshots SET session_json=jsonb(?) WHERE workflow_execution_id=?",
      bindings: [.text(json), .text(id)])
  }

  func pass(_ profile: StorageMaintenanceProfile = .runEnd) -> ([String], StorageMaintenancePassStats) {
    var stats = StorageMaintenancePassStats()
    let warnings = StorageMaintenanceConversion.run(sessionStoreRoot: root.path, stateDirectory: root.path,
      profile: profile, observe: { stats = $0 })
    return (warnings, stats)
  }

  func queue() throws -> StorageMaintenanceCursor.Queue {
    try XCTUnwrap(StorageMaintenanceCursor.read(stateDirectory: root.path)?.queues["snapshots"])
  }
}

extension RunEndStorageMaintenanceConversionTests {
  func testSnapshotBudgetAndResume() throws {
    let fixture = try ConversionFixture()
    for index in 0..<40 { try fixture.insert(String(format: "row-%03d", index)) }
    var counts: [Int] = []
    for _ in 0..<10 {
      let (warnings, stats) = fixture.pass()
      XCTAssertTrue(warnings.isEmpty, "\(warnings)")
      XCTAssertLessThanOrEqual(stats.converted, 16)
      counts.append(stats.converted)
      if try fixture.queue().complete { break }
    }
    print("legacy conversion per-pass counts: \(counts)")
    XCTAssertEqual(counts.reduce(0, +), 40)
    XCTAssertTrue(try fixture.runtime.legacyInlineSessionIds(limit: 100).isEmpty)
    XCTAssertTrue(try fixture.queue().complete)
    XCTAssertEqual(fixture.pass().1.forwardRowsExamined, 0)
  }

  func testBusyRowRetriesAfterLockReleased() throws {
    let fixture = try ConversionFixture()
    try fixture.insert("busy")
    let lock = SessionExecutionLockRegistry(sessionStoreRoot: fixture.root.path)
    try lock.acquire(sessionId: "busy")
    let first = fixture.pass()
    XCTAssertTrue(first.0.isEmpty)
    XCTAssertEqual(try fixture.queue().busy, ["busy"])
    XCTAssertEqual(try fixture.runtime.legacyInlineSessionIds(limit: 10), ["busy"])
    lock.release(sessionId: "busy")
    XCTAssertTrue(fixture.pass().0.isEmpty)
    XCTAssertTrue(try fixture.queue().busy.isEmpty)
    XCTAssertTrue(try fixture.runtime.legacyInlineSessionIds(limit: 10).isEmpty)
  }

  func testNonterminalRowsAreSkipped() throws {
    let fixture = try ConversionFixture()
    try fixture.insert("running", status: .running)
    try fixture.insert("suspended", status: .suspended)
    XCTAssertTrue(fixture.pass().0.isEmpty)
    let queue = try fixture.queue()
    XCTAssertTrue(queue.complete)
    XCTAssertTrue(queue.busy.isEmpty)
    XCTAssertTrue(queue.failed.isEmpty)
    XCTAssertEqual(Set(try fixture.runtime.legacyInlineSessionIds(limit: 10)), Set(["running", "suspended"]))
  }

  func testFailureParksAfterThreeAttemptsAndWarnsOnce() throws {
    let fixture = try ConversionFixture()
    try fixture.insert("bad", malformed: true)
    try fixture.insert("good")
    var warnings: [String] = []
    for _ in 0..<4 { warnings += fixture.pass().0 }
    let queue = try fixture.queue()
    XCTAssertEqual(queue.parked.map(\.key), ["bad"])
    XCTAssertTrue(queue.failed.isEmpty)
    XCTAssertEqual(warnings.count, 1)
    XCTAssertTrue(warnings[0].contains("legacy snapshots row bad parked after 3 failed conversions"))
    XCTAssertTrue(warnings[0].contains("run riela storage compact --apply"))
    print("legacy conversion parked warning: \(warnings[0])")
    XCTAssertEqual(try fixture.runtime.legacyInlineSessionIds(limit: 10), ["bad"])
    XCTAssertTrue(fixture.pass().0.isEmpty)
  }

  func testRetiredRowAndCorruptCursorRestart() throws {
    let fixture = try ConversionFixture()
    try fixture.insert("retired")
    try fixture.insert("valid")
    try fixture.db.execute("""
      CREATE TABLE IF NOT EXISTS session_retention_tombstones(
        session_id TEXT PRIMARY KEY, workflow_id TEXT NOT NULL, root_id TEXT NOT NULL, pruned_at TEXT NOT NULL,
        artifact_root TEXT NOT NULL, memory_root TEXT NOT NULL, payload_bytes INTEGER NOT NULL, cleanup_pending INTEGER NOT NULL)
      """)
    try fixture.db.execute("INSERT INTO session_retention_tombstones VALUES ('retired','flow','retired','now','','',0,0)")
    try Data("{".utf8).write(to: fixture.root.appendingPathComponent(StorageMaintenanceCursor.fileName))
    XCTAssertTrue(fixture.pass().0.isEmpty)
    let queue = try fixture.queue()
    XCTAssertTrue(queue.complete)
    XCTAssertTrue(queue.busy.isEmpty)
    XCTAssertTrue(queue.failed.isEmpty)
    XCTAssertTrue(queue.parked.isEmpty)
    XCTAssertEqual(try fixture.runtime.legacyInlineSessionIds(limit: 10), ["retired"])
  }
}

extension RunEndStorageMaintenanceConversionTests {
  func testScheduledBudget() throws {
    let fixture = try ConversionFixture()
    for index in 0..<70 { try fixture.insert(String(format: "scheduled-%03d", index)) }
    let first = fixture.pass(.scheduled)
    XCTAssertTrue(first.0.isEmpty, "\(first.0)")
    XCTAssertLessThanOrEqual(first.1.converted, 64)
    var count = first.1.converted
    for _ in 0..<4 {
      if try fixture.queue().complete { break }
      let result = fixture.pass(.scheduled)
      XCTAssertTrue(result.0.isEmpty, "\(result.0)")
      XCTAssertLessThanOrEqual(result.1.converted, 64)
      count += result.1.converted
    }
    XCTAssertEqual(count, 70)
    XCTAssertTrue(try fixture.runtime.legacyInlineSessionIds(limit: 100).isEmpty)
  }

  func testBusyOverflowRescansAndRetryShareIsBounded() throws {
    let fixture = try ConversionFixture()
    let registry = SessionExecutionLockRegistry(sessionStoreRoot: fixture.root.path)
    let ids = (0..<257).map { String(format: "busy-%03d", $0) }
    for id in ids {
      try fixture.insert(id)
      try registry.acquire(sessionId: id)
    }
    var queue = StorageMaintenanceCursor.Queue()
    queue.after = ids[255]
    queue.busy = Array(ids.prefix(256))
    try StorageMaintenanceCursor(queues: ["snapshots": queue]).write(stateDirectory: fixture.root.path)
    let first = fixture.pass()
    XCTAssertTrue(first.0.isEmpty, "\(first.0)")
    XCTAssertLessThanOrEqual(first.1.retryRowsExamined, 128)
    XCTAssertLessThanOrEqual(first.1.retryConversions, 8)
    XCTAssertGreaterThanOrEqual(first.1.forwardRowsExamined, 1)
    let afterOverflow = try fixture.queue()
    XCTAssertTrue(afterOverflow.rescanNeeded || (!afterOverflow.complete && afterOverflow.after == nil))
    for id in ids { registry.release(sessionId: id) }
    var counts: [Int] = []
    for _ in 0..<80 {
      let result = fixture.pass()
      XCTAssertTrue(result.0.isEmpty, "\(result.0)")
      XCTAssertLessThanOrEqual(result.1.retryRowsExamined, 128)
      XCTAssertLessThanOrEqual(result.1.retryConversions, 8)
      XCTAssertLessThanOrEqual(result.1.converted, 16)
      counts.append(result.1.converted)
      if try fixture.queue().complete && fixture.queue().busy.isEmpty { break }
    }
    XCTAssertEqual(counts.reduce(0, +), 257)
    XCTAssertTrue(try fixture.runtime.legacyInlineSessionIds(limit: 300).isEmpty)
  }

  func testRetryWallTimeStillAllowsForwardProgress() throws {
    let fixture = try ConversionFixture()
    try fixture.insert("busy")
    try fixture.insert("forward")
    let registry = SessionExecutionLockRegistry(sessionStoreRoot: fixture.root.path)
    try registry.acquire(sessionId: "busy")
    defer { registry.release(sessionId: "busy") }
    var queue = StorageMaintenanceCursor.Queue()
    queue.after = "busy"
    queue.busy = ["busy"]
    try StorageMaintenanceCursor(queues: ["snapshots": queue]).write(stateDirectory: fixture.root.path)
    var calls = 0
    var stats = StorageMaintenancePassStats()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let warnings = StorageMaintenanceConversion.run(sessionStoreRoot: fixture.root.path, stateDirectory: fixture.root.path,
      profile: .runEnd, now: {
        calls += 1
        return start.addingTimeInterval(calls > 2 ? 3 : 0)
      }, observe: { stats = $0 })
    XCTAssertTrue(warnings.isEmpty, "\(warnings)")
    XCTAssertEqual(stats.retryRowsExamined, 1)
    XCTAssertGreaterThanOrEqual(stats.forwardRowsExamined, 1)
    XCTAssertEqual(try fixture.queue().after, "forward")
  }

  func testLegacyCLIAndNestedRowsConvert() throws {
    let fixture = try ConversionFixture()
    let cli = CLIWorkflowSessionStore(rootDirectory: fixture.root.path)
    let session = WorkflowSession(workflowId: "flow", sessionId: "cli-parent", status: .completed,
      entryStepId: "start", createdAt: fixture.date, updatedAt: fixture.date)
    let record = PersistedCLIWorkflowSession(workflowName: "flow", session: session,
      resolution: WorkflowResolutionOptions(workflowName: "flow", workingDirectory: fixture.root.path))
    try cli.save(record, runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: session))
    var child = WorkflowSession(workflowId: "child", sessionId: "nested-child", status: .created,
      entryStepId: "start", createdAt: fixture.date, updatedAt: fixture.date,
      parentSessionId: session.sessionId, rootSessionId: session.sessionId)
    let reservation = WorkflowNestedInvocationReservation(parentSessionId: session.sessionId,
      parentStepId: "parent-step", resumeStepId: "resume-step", sourceStepExecutionId: "source",
      branchId: "branch", childSnapshot: WorkflowRuntimePersistenceSnapshot(session: child))
    _ = try fixture.runtime.reserveNestedInvocation(reservation)
    child.status = .completed
    try fixture.runtime.save(WorkflowRuntimePersistenceSnapshot(session: child))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let recordJSON = try XCTUnwrap(String(data: encoder.encode(record), encoding: .utf8))
    let reservationJSON = try XCTUnwrap(String(data: encoder.encode(reservation), encoding: .utf8))
    try fixture.db.execute("UPDATE cli_workflow_sessions SET record_json=jsonb(?) WHERE session_id=?",
      bindings: [.text(recordJSON), .text(session.sessionId)])
    let key = try XCTUnwrap(fixture.db.query("SELECT invocation_key FROM workflow_nested_invocations").first?["invocation_key"])
    try fixture.db.execute("UPDATE workflow_nested_invocations SET reservation_json=jsonb(?) WHERE invocation_key=?",
      bindings: [.text(reservationJSON), .text(key)])
    try fixture.db.execute("DELETE FROM workflow_nested_invocation_refs WHERE invocation_key=? AND role='reservation'",
      bindings: [.text(key)])
    XCTAssertEqual(try cli.legacyFullRecordIds(limit: 10), [session.sessionId])
    XCTAssertEqual(try fixture.runtime.legacyEmbeddedNestedInvocationKeys(limit: 10), [key])
    let result = fixture.pass()
    XCTAssertTrue(result.0.isEmpty, "\(result.0)")
    XCTAssertTrue(try cli.legacyFullRecordIds(limit: 10).isEmpty)
    XCTAssertTrue(try fixture.runtime.legacyEmbeddedNestedInvocationKeys(limit: 10).isEmpty)
  }
}

extension RunEndStorageMaintenanceConversionTests {
  func testMixedLegacyQueuesConvertAcrossBoundedPasses() throws {
    let fixture = try ConversionFixture()
    let cli = CLIWorkflowSessionStore(rootDirectory: fixture.root.path)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    for index in 0..<14 { try fixture.insert(String(format: "inline-%02d", index)) }
    for index in 0..<13 {
      let parentId = String(format: "parent-%02d", index)
      let session = WorkflowSession(workflowId: "flow", sessionId: parentId, status: .completed,
        entryStepId: "start", createdAt: fixture.date, updatedAt: fixture.date)
      let record = PersistedCLIWorkflowSession(workflowName: "flow", session: session,
        resolution: WorkflowResolutionOptions(workflowName: "flow", workingDirectory: fixture.root.path))
      try cli.save(record, runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: session))
      var child = WorkflowSession(workflowId: "child", sessionId: "child-\(index)", status: .created,
        entryStepId: "start", createdAt: fixture.date, updatedAt: fixture.date,
        parentSessionId: parentId, rootSessionId: parentId)
      let reservation = WorkflowNestedInvocationReservation(parentSessionId: parentId,
        parentStepId: "parent-step", resumeStepId: "resume-step", sourceStepExecutionId: "source",
        branchId: "branch", childSnapshot: WorkflowRuntimePersistenceSnapshot(session: child))
      _ = try fixture.runtime.reserveNestedInvocation(reservation)
      child.status = .completed
      try fixture.runtime.save(WorkflowRuntimePersistenceSnapshot(session: child))
      let recordJSON = try XCTUnwrap(String(data: encoder.encode(record), encoding: .utf8))
      let reservationJSON = try XCTUnwrap(String(data: encoder.encode(reservation), encoding: .utf8))
      try fixture.db.execute("UPDATE cli_workflow_sessions SET record_json=jsonb(?) WHERE session_id=?",
        bindings: [.text(recordJSON), .text(parentId)])
      let key = try XCTUnwrap(fixture.db.query("""
        SELECT invocation_key FROM workflow_nested_invocations
        WHERE json_extract(reservation_json,'$.parentSessionId')=?
        """, bindings: [.text(parentId)]).first?["invocation_key"])
      try fixture.db.execute("UPDATE workflow_nested_invocations SET reservation_json=jsonb(?) WHERE invocation_key=?",
        bindings: [.text(reservationJSON), .text(key)])
      try fixture.db.execute("DELETE FROM workflow_nested_invocation_refs WHERE invocation_key=? AND role='reservation'",
        bindings: [.text(key)])
    }
    XCTAssertEqual(try fixture.runtime.legacyInlineSessionIds(limit: 100).count, 14)
    XCTAssertEqual(try cli.legacyFullRecordIds(limit: 100).count, 13)
    XCTAssertEqual(try fixture.runtime.legacyEmbeddedNestedInvocationKeys(limit: 100).count, 13)
    var counts: [Int] = []
    for _ in 0..<30 {
      let (warnings, stats) = fixture.pass()
      XCTAssertTrue(warnings.isEmpty, "\(warnings)")
      XCTAssertLessThanOrEqual(stats.converted, 16)
      counts.append(stats.converted)
      let cursor = try XCTUnwrap(StorageMaintenanceCursor.read(stateDirectory: fixture.root.path))
      if ["snapshots", "cliRecords", "nested"].allSatisfy({ cursor.queues[$0]?.complete == true }) { break }
    }
    print("mixed legacy conversion per-pass counts: \(counts)")
    XCTAssertEqual(counts.reduce(0, +), 40)
    XCTAssertTrue(try fixture.runtime.legacyInlineSessionIds(limit: 100).isEmpty)
    XCTAssertTrue(try cli.legacyFullRecordIds(limit: 100).isEmpty)
    XCTAssertTrue(try fixture.runtime.legacyEmbeddedNestedInvocationKeys(limit: 100).isEmpty)
    let final = try XCTUnwrap(StorageMaintenanceCursor.read(stateDirectory: fixture.root.path))
    for name in ["snapshots", "cliRecords", "nested"] { XCTAssertEqual(final.queues[name]?.complete, true) }
    let fast = fixture.pass()
    XCTAssertTrue(fast.0.isEmpty)
    XCTAssertEqual(fast.1.forwardRowsExamined, 0)
    XCTAssertEqual(fast.1.retryRowsExamined, 0)
  }
}

extension RunEndStorageMaintenanceConversionTests {
  func testCompletedChildOfRunningRootIsNotRewritten() throws {
    let fixture = try ConversionFixture()
    let root = WorkflowSession(workflowId: "flow", sessionId: "active-root", status: .running,
      entryStepId: "start", createdAt: fixture.date, updatedAt: fixture.date)
    let child = WorkflowSession(workflowId: "flow", sessionId: "terminal-child", status: .completed,
      entryStepId: "start", createdAt: fixture.date, updatedAt: fixture.date,
      parentSessionId: root.sessionId, rootSessionId: root.sessionId)
    try fixture.runtime.save(WorkflowRuntimePersistenceSnapshot(session: root))
    try fixture.runtime.save(WorkflowRuntimePersistenceSnapshot(session: child))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let json = try XCTUnwrap(String(data: encoder.encode(child), encoding: .utf8))
    try fixture.db.execute("UPDATE workflow_runtime_snapshots SET session_json=jsonb(?) WHERE workflow_execution_id=?",
      bindings: [.text(json), .text(child.sessionId)])
    XCTAssertTrue(fixture.pass().0.isEmpty)
    XCTAssertEqual(try fixture.runtime.legacyInlineSessionIds(limit: 10), [child.sessionId])
  }

  func testCompletedChildIsRetriedWhenRootCompletes() throws {
    let fixture = try ConversionFixture()
    var root = WorkflowSession(workflowId: "flow", sessionId: "active-root", status: .running,
      entryStepId: "start", createdAt: fixture.date, updatedAt: fixture.date)
    let child = WorkflowSession(workflowId: "flow", sessionId: "terminal-child", status: .completed,
      entryStepId: "start", createdAt: fixture.date, updatedAt: fixture.date,
      parentSessionId: root.sessionId, rootSessionId: root.sessionId)
    try fixture.runtime.save(WorkflowRuntimePersistenceSnapshot(session: root))
    try fixture.runtime.save(WorkflowRuntimePersistenceSnapshot(session: child))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let json = try XCTUnwrap(String(data: encoder.encode(child), encoding: .utf8))
    try fixture.db.execute("UPDATE workflow_runtime_snapshots SET session_json=jsonb(?) WHERE workflow_execution_id=?",
      bindings: [.text(json), .text(child.sessionId)])
    XCTAssertTrue(fixture.pass().0.isEmpty)
    let before = try XCTUnwrap(StorageMaintenanceCursor.read(stateDirectory: fixture.root.path))
    XCTAssertEqual(before.queues["snapshots"]?.busy, [child.sessionId])
    XCTAssertEqual(try fixture.runtime.legacyInlineSessionIds(limit: 10), [child.sessionId])
    root.status = .completed
    try fixture.runtime.save(WorkflowRuntimePersistenceSnapshot(session: root))
    let result = fixture.pass()
    XCTAssertTrue(result.0.isEmpty)
    XCTAssertEqual(result.1.retryConversions, 1)
    XCTAssertTrue(try fixture.runtime.legacyInlineSessionIds(limit: 10).isEmpty)
    let after = try XCTUnwrap(StorageMaintenanceCursor.read(stateDirectory: fixture.root.path))
    XCTAssertEqual(after.queues["snapshots"]?.busy, [])
  }

}
