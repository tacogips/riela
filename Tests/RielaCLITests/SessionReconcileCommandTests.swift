import Foundation
import RielaCore
import RielaSQLite
import XCTest
@testable import RielaCLI

final class SessionReconcileCommandTests: XCTestCase {
  func testDryRunLeavesStoreUnchangedAndReportsOrphanAndLiveCandidates() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("session-reconcile-dry-run")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    for (id, status) in [("orphan-a", WorkflowSessionStatus.running), ("live-b", .running),
                         ("created-c", .created), ("suspended-d", .suspended), ("completed-e", .completed)] {
      try save(id: id, status: status, store: store)
    }
    let before = try recordJSON(root: root.path, ids: ["orphan-a", "live-b", "created-c", "suspended-d", "completed-e"])
    let owner = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
    try owner.acquire(sessionId: "live-b")

    let result = await RielaCLIApplication().run(["session", "reconcile", "--session-store", root.path])

    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let report = try JSONDecoder().decode(ReconcileReport.self, from: Data(result.stdout.utf8))
    XCTAssertTrue(report.dryRun)
    XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(report.nestedInvocations, [])
    XCTAssertEqual(Dictionary(uniqueKeysWithValues: report.sessions.map { ($0.sessionId, $0.verdict) }), [
      "orphan-a": "orphaned", "live-b": "live"
    ])
    XCTAssertEqual(try recordJSON(root: root.path, ids: Array(before.keys)), before)
  }

  func testApplyCancelsOrphanAndLeavesLiveSessionByteIdentical() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("session-reconcile-apply")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    try save(id: "orphan-a", status: .running, store: store)
    try save(id: "live-b", status: .running, store: store)
    let beforeLive = try recordJSON(root: root.path, ids: ["live-b"])
    let owner = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
    try owner.acquire(sessionId: "live-b")

    let result = await RielaCLIApplication().run([
      "session", "reconcile", "--session-store", root.path, "--apply"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let report = try JSONDecoder().decode(ReconcileReport.self, from: Data(result.stdout.utf8))
    XCTAssertFalse(report.dryRun)
    XCTAssertEqual(report.sessions.first(where: { $0.sessionId == "orphan-a" })?.verdict, "orphaned")
    XCTAssertEqual(report.sessions.first(where: { $0.sessionId == "orphan-a" })?.applied, true)
    let record = try store.load(sessionId: "orphan-a")
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path)
    ).load(sessionId: "orphan-a")
    for session in [record.session, snapshot.session] {
      XCTAssertEqual(session.status, .cancelled)
      XCTAssertEqual(session.failureKind, .cancelled)
      XCTAssertEqual(session.failureReason, Self.reason)
      XCTAssertEqual(session.executions.map(\.status), [.cancelled])
      XCTAssertEqual(session.executions.first?.failureReason, Self.reason)
    }
    XCTAssertEqual(try recordJSON(root: root.path, ids: ["live-b"]), beforeLive)
  }

  func testApplyAbandonsOldNestedRowInTheSamePassThatCancelsParent() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("session-reconcile-nested-apply")
    defer { try? FileManager.default.removeItem(at: root) }
    let old = Date().addingTimeInterval(-25 * 3600)
    var parent = makeSession(id: "orphan-parent", status: .running)
    parent.updatedAt = old
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    let record = PersistedCLIWorkflowSession(workflowName: parent.workflowId, session: parent,
      resolution: WorkflowResolutionOptions(workflowName: parent.workflowId))
    try store.save(record, runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: parent))
    let db = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path))
    try insertNested("old-nested", parent: parent.sessionId, updatedAt: old, db: db)

    let result = await RielaCLIApplication().run([
      "session", "reconcile", "--session-store", root.path, "--abandoned-after-hours", "24", "--apply"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let report = try JSONDecoder().decode(ReconcileReport.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(report.sessions.first(where: { $0.sessionId == parent.sessionId })?.verdict, "orphaned")
    XCTAssertEqual(report.sessions.first(where: { $0.sessionId == parent.sessionId })?.applied, true)
    XCTAssertEqual(report.nestedInvocations.first(where: { $0.invocationKey == "old-nested" })?.verdict, "abandoned")
    XCTAssertEqual(report.nestedInvocations.first(where: { $0.invocationKey == "old-nested" })?.applied, true)
    XCTAssertNotNil(try db.query("SELECT abandoned_at FROM workflow_nested_invocations WHERE invocation_key='old-nested'").first?["abandoned_at"])
  }

  func testDryRunPredictsAbandonmentForParentItWouldCancel() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("session-reconcile-nested-dry")
    defer { try? FileManager.default.removeItem(at: root) }
    let old = Date().addingTimeInterval(-25 * 3600)
    var parent = makeSession(id: "orphan-parent", status: .running)
    parent.updatedAt = old
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    try store.save(PersistedCLIWorkflowSession(workflowName: parent.workflowId, session: parent,
      resolution: WorkflowResolutionOptions(workflowName: parent.workflowId)),
      runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: parent))
    let db = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path))
    try insertNested("old-nested", parent: parent.sessionId, updatedAt: old, db: db)

    let result = await RielaCLIApplication().run(["session", "reconcile", "--session-store", root.path])

    let report = try JSONDecoder().decode(ReconcileReport.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(report.sessions.first?.verdict, "orphaned")
    XCTAssertEqual(report.nestedInvocations.first?.verdict, "abandoned")
    XCTAssertNil(try db.query("SELECT abandoned_at FROM workflow_nested_invocations WHERE invocation_key='old-nested'").first?["abandoned_at"])
    XCTAssertEqual(try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path)
    ).load(sessionId: parent.sessionId).session.status, .running)
  }

  func testSelectedReconcileDoesNotTreatOtherRunningParentAsOrphaned() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("session-reconcile-selected-parent-safety")
    defer { try? FileManager.default.removeItem(at: root) }
    let old = Date().addingTimeInterval(-25 * 3600)
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    for id in ["A", "B"] {
      var session = makeSession(id: id, status: .running)
      session.updatedAt = old
      try store.save(PersistedCLIWorkflowSession(workflowName: session.workflowId, session: session,
        resolution: WorkflowResolutionOptions(workflowName: session.workflowId)),
        runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: session))
    }
    let child = makeSession(id: "B-child", status: .created)
    try store.save(PersistedCLIWorkflowSession(workflowName: child.workflowId, session: child,
      resolution: WorkflowResolutionOptions(workflowName: child.workflowId)),
      runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: child))
    let db = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path))
    try insertNested("B-nested", parent: "B", childSessionId: "B-child", updatedAt: old, db: db)

    let result = await RielaCLIApplication().run([
      "session", "reconcile", "--session-store", root.path, "--session", "A", "--apply"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let report = try JSONDecoder().decode(ReconcileReport.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(report.sessions.first(where: { $0.sessionId == "A" })?.verdict, "orphaned")
    XCTAssertEqual(report.nestedInvocations.first(where: { $0.invocationKey == "B-nested" })?.verdict, "skipped")
    XCTAssertEqual(report.nestedInvocations.first(where: { $0.invocationKey == "B-nested" })?.reason,
      "parent is absent or nonterminal")
    XCTAssertNil(try db.query("SELECT abandoned_at FROM workflow_nested_invocations WHERE invocation_key='B-nested'").first?[
      "abandoned_at"])
    XCTAssertEqual(try store.load(sessionId: "B-child").session.status, .created)
    XCTAssertEqual(try store.load(sessionId: "B").session.status, .running)
  }

  func testSelectedNonRunningSessionIsReportedAndCanonicalOnlySnapshotIsApplied() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("session-reconcile-canonical-only")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    try save(id: "completed-session", status: .completed, store: store)
    let canonical = SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path)
    )
    let session = makeSession(id: "canonical-only", status: .running)
    try canonical.save(WorkflowRuntimePersistenceSnapshot(session: session))

    let result = await RielaCLIApplication().run([
      "session", "reconcile", "--session-store", root.path, "--session", "completed-session",
      "--session", "canonical-only", "--apply"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let report = try JSONDecoder().decode(ReconcileReport.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(report.sessions.first(where: { $0.sessionId == "completed-session" })?.verdict, "notRunning")
    XCTAssertEqual(report.sessions.first(where: { $0.sessionId == "canonical-only" })?.applied, true)
    XCTAssertEqual(try canonical.load(sessionId: "canonical-only").session.status, .cancelled)
  }

  func testReconcileParserRejectsUnknownOptionAndHelpListsCommand() async {
    let help = await RielaCLIApplication().run(["session", "reconcile", "--help"])
    XCTAssertEqual(help.exitCode, .success)
    XCTAssertTrue(help.stdout.contains("riela session reconcile"))
    let invalid = await RielaCLIApplication().run(["session", "reconcile", "--unknown"])
    XCTAssertEqual(invalid.exitCode, .usage)
    let invalidHours = await RielaCLIApplication().run(["session", "reconcile", "--abandoned-after-hours", "0"])
    XCTAssertEqual(invalidHours.exitCode, .usage)
    let validHours = await RielaCLIApplication().run(["session", "reconcile", "--help"])
    XCTAssertTrue(validHours.stdout.contains("abandoned-after-hours"))
  }

  func testTombstonedRunningSessionIsRetired() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("session-reconcile-retired")
    defer { try? FileManager.default.removeItem(at: root) }
    try save(id: "retired-session", status: .running, store: CLIWorkflowSessionStore(rootDirectory: root.path))
    let db = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path))
    try db.execute("CREATE TABLE session_retention_tombstones(session_id TEXT PRIMARY KEY)")
    try db.execute("INSERT INTO session_retention_tombstones(session_id) VALUES(?)", bindings: [.text("retired-session")])

    let result = await RielaCLIApplication().run(["session", "reconcile", "--session-store", root.path])

    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let report = try JSONDecoder().decode(ReconcileReport.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(report.sessions.first?.verdict, "retired")
  }

  func testCancelledSessionCannotResumeOrCreateAnotherExecution() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("session-reconcile-cancelled-resume")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    try save(id: "cancelled-session", status: .cancelled, store: store)

    let result = await SessionResumeCommand().run(SessionResumeOptions(
      sessionId: "cancelled-session",
      output: .json,
      scope: .project,
      workingDirectory: root.path,
      sessionStore: root.path
    ))

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stdout.contains("cannot be resumed normally"), result.stdout + result.stderr)
    XCTAssertEqual(try store.load(sessionId: "cancelled-session").session.executions.count, 1)
  }

  func testCancelledSessionRunsTerminalPersistenceHookOnce() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("session-reconcile-terminal-hook")
    defer { try? FileManager.default.removeItem(at: root) }
    let backing = InMemoryWorkflowRuntimeStore()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let session = try await backing.createSession(WorkflowSessionCreateInput(workflowId: "workflow", entryStepId: "step"))
    let hookCount = ReconcileHookCounter()
    let store = FailClosedSQLiteWorkflowRuntimeStore(
      backing: backing,
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path),
      beforeTerminalPersistence: { hookCount.increment() }
    )
    _ = try await store.markSessionFailed(WorkflowSessionFailureInput(
      sessionId: session.sessionId, reason: Self.reason, failureKind: .cancelled, failedAt: now
    ))

    XCTAssertEqual(hookCount.value, 1)
    XCTAssertEqual(try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path)
    ).load(sessionId: session.sessionId).session.status, .cancelled)
  }

  private static let reason = "runner process lost; reconciled by riela session reconcile"

  private func save(id: String, status: WorkflowSessionStatus, store: CLIWorkflowSessionStore) throws {
    let session = makeSession(id: id, status: status)
    let record = PersistedCLIWorkflowSession(
      workflowName: session.workflowId,
      session: session,
      resolution: WorkflowResolutionOptions(workflowName: session.workflowId)
    )
    try store.save(record, runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: session))
  }

  private func makeSession(id: String, status: WorkflowSessionStatus) -> WorkflowSession {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let execution = WorkflowStepExecution(
      executionId: "execution-\(id)", stepId: "step", nodeId: "node", attempt: 1,
      status: .running, createdAt: now, updatedAt: now
    )
    return WorkflowSession(
      workflowId: "workflow-\(id)", sessionId: id, status: status,
      entryStepId: "step", currentStepId: "step", createdAt: now, updatedAt: now,
      executions: [execution], rootSessionId: id
    )
  }

  private func insertNested(_ key: String, parent: String, childSessionId: String? = nil,
                            updatedAt: Date, db: SQLiteDatabase) throws {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let timestamp = formatter.string(from: updatedAt)
    let childId = childSessionId ?? "missing-\(key)"
    let json = "{\"parentSessionId\":\"\(parent)\",\"childSnapshot\":{\"session\":{\"sessionId\":\"\(childId)\"}}}"
    try db.execute("INSERT INTO workflow_nested_invocations(invocation_key,reservation_json,created_at,updated_at) VALUES(?,jsonb(?),?,?)",
      bindings: [.text(key), .text(json), .text(timestamp), .text(timestamp)])
  }

  private func recordJSON(root: String, ids: [String]) throws -> [String: String] {
    let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root)
    let db = try SQLiteDatabase.open(path: path, mode: .readOnly, options: .readOnlyDefault)
    var records: [String: String] = [:]
    for id in ids {
      records[id] = try XCTUnwrap(db.query(
        "SELECT record_json FROM cli_workflow_sessions WHERE session_id=?", bindings: [.text(id)]
      ).first?["record_json"])
    }
    return records
  }
}

private struct ReconcileReport: Decodable {
  struct Session: Decodable {
    var sessionId: String
    var verdict: String
    var applied: Bool
  }
  var dryRun: Bool
  var sessions: [Session]
  var nestedInvocations: [SessionNestedInvocationVerdict]
}

private final class ReconcileHookCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    defer { lock.unlock() }
    count += 1
  }
}
