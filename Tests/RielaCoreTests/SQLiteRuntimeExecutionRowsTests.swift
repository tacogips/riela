import Foundation
import RielaSQLite
import XCTest
@testable import RielaCore

final class SQLiteRuntimeExecutionRowsTests: XCTestCase {
  func testHeaderRowsPayloadDedupeCleanupAndCascade() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let repeated = execution(id: "same-execution", output: "same", date: date)
    let first = snapshot(id: "session-rows", executions: [repeated, repeated], date: date)

    try store.save(first)
    XCTAssertEqual(try store.loadStrictReadOnly(sessionId: first.session.sessionId), first)
    XCTAssertEqual(try store.executionIdentities(sessionId: first.session.sessionId), ["same-execution", "same-execution"])

    let db = try database(root: root)
    let header = try XCTUnwrap(db.query(
      "SELECT json_type(session_json, '$.executions') AS executions, json_extract(session_json, '$._rielaExecutionStorage') AS marker FROM workflow_runtime_snapshots WHERE workflow_execution_id=?",
      bindings: [.text(first.session.sessionId)]
    ).first)
    XCTAssertNil(header["executions"])
    XCTAssertEqual(header["marker"], "rows")
    XCTAssertEqual(try scalar(db, "SELECT COUNT(*) AS value FROM workflow_runtime_payloads"), 1)
    XCTAssertEqual(try scalar(db, "SELECT COUNT(*) AS value FROM workflow_runtime_executions"), 2)

    let changed = execution(id: "same-execution", output: "changed", date: date)
    try store.save(snapshot(id: first.session.sessionId, executions: [changed, repeated], date: date))
    XCTAssertEqual(try scalar(db, "SELECT COUNT(*) AS value FROM workflow_runtime_payloads"), 2)
    try store.save(snapshot(id: first.session.sessionId, executions: [changed, execution(id: "same-execution", output: "third", date: date)], date: date))
    XCTAssertEqual(try scalar(db, "SELECT COUNT(*) AS value FROM workflow_runtime_payloads"), 2)

    try db.execute("DELETE FROM workflow_runtime_snapshots WHERE workflow_execution_id=?", bindings: [.text(first.session.sessionId)])
    XCTAssertEqual(try scalar(db, "SELECT COUNT(*) AS value FROM workflow_runtime_executions"), 0)
  }

  func testLegacyInlineSessionLoadsAndConvertsOnFirstSave() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let original = snapshot(id: "legacy-session", executions: [execution(id: "legacy-exec", output: "legacy", date: Date(timeIntervalSince1970: 1_700_000_000))], date: Date(timeIntervalSince1970: 1_700_000_000))
    try store.save(original)
    let db = try database(root: root)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = RuntimeSnapshotDates.encoding
    let legacyJSON = String(data: try encoder.encode(original.session), encoding: .utf8)!
    try db.execute(
      "UPDATE workflow_runtime_snapshots SET session_json=jsonb(?) WHERE workflow_execution_id=?",
      bindings: [.text(legacyJSON), .text(original.session.sessionId)]
    )

    XCTAssertEqual(try store.load(sessionId: original.session.sessionId).session, original.session)
    XCTAssertEqual(try store.legacyInlineSessionIds(limit: 10), [original.session.sessionId])
    XCTAssertTrue(try store.convertLegacySession(sessionId: original.session.sessionId))
    XCTAssertEqual(try store.load(sessionId: original.session.sessionId), original)
    XCTAssertTrue(try store.legacyInlineSessionIds(limit: 10).isEmpty)
  }

  func testNestedReservationAndTerminalSnapshotsUseReferencesAndRoundTrip() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let child = WorkflowSession(
      workflowId: "child", sessionId: "child-session", status: .created, entryStepId: "start",
      createdAt: date, updatedAt: date, executions: [execution(id: "child-exec", output: "result", date: date)],
      parentSessionId: "parent-session", rootSessionId: "parent-session"
    )
    let reservation = WorkflowNestedInvocationReservation(
      parentSessionId: "parent-session", parentStepId: "parent-step", resumeStepId: "resume-step",
      sourceStepExecutionId: "source-exec", branchId: "branch-1",
      childSnapshot: WorkflowRuntimePersistenceSnapshot(session: child)
    )
    _ = try store.reserveNestedInvocation(reservation)
    XCTAssertEqual(try store.nestedInvocationRecord(reservation), WorkflowNestedInvocationRecord(
      reservation: reservation, childTerminalSnapshot: nil, parentMessage: nil, recoveryReason: nil
    ))

    let db = try database(root: root)
    XCTAssertEqual(try scalar(db, "SELECT COUNT(*) AS value FROM workflow_runtime_payloads WHERE root_session_id='parent-session'"), 3)
    XCTAssertEqual(try scalar(db, "SELECT COUNT(*) AS value FROM workflow_nested_invocation_refs WHERE role='reservation' AND ordinal=0"), 1)
    var terminalSession = child
    terminalSession.status = .completed
    terminalSession.updatedAt = date.addingTimeInterval(1)
    let terminal = WorkflowRuntimePersistenceSnapshot(session: terminalSession, rootOutput: ["answer": .string("ok")], diagnostics: ["done"])
    _ = try store.recordNestedChildTerminal(reservation: reservation, terminalSnapshot: terminal)
    XCTAssertEqual(try store.nestedInvocationRecord(reservation)?.childTerminalSnapshot, terminal)

    XCTAssertGreaterThan(try scalar(db, "SELECT COUNT(*) AS value FROM workflow_nested_invocation_refs"), 0)
    let stored = try XCTUnwrap(db.query(
      "SELECT json(reservation_json) AS reservation FROM workflow_nested_invocations LIMIT 1"
    ).first?["reservation"])
    XCTAssertEqual(try JSONDecoder().decode(JSONObject.self, from: Data(stored.utf8))["childSnapshotStorage"], .string("refs"))
  }

  func testPayloadReleaseIsRootScopedAndReturnsBytes() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let db = try database(root: root)
    try store.prepareSchema(in: db)
    try db.execute(
      "INSERT INTO workflow_runtime_payloads(root_session_id,digest,bytes,byte_count) VALUES('root-a','orphan-a',jsonb('{\"data\":\"a\"}'),9),('root-b','orphan-b',jsonb('{\"data\":\"b\"}'),9)"
    )

    XCTAssertEqual(try store.releaseUnreferencedPayloads(rootSessionId: "root-a"), 9)
    XCTAssertEqual(try scalar(db, "SELECT COUNT(*) AS value FROM workflow_runtime_payloads WHERE root_session_id='root-a'"), 0)
    XCTAssertEqual(try scalar(db, "SELECT COUNT(*) AS value FROM workflow_runtime_payloads WHERE root_session_id='root-b'"), 1)
  }

  func testLegacyEmbeddedNestedInvocationConvertsToReferences() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let child = WorkflowSession(
      workflowId: "child", sessionId: "legacy-child", status: .created, entryStepId: "start",
      createdAt: date, updatedAt: date, executions: [execution(id: "legacy-child-exec", output: "saved", date: date)],
      parentSessionId: "legacy-parent", rootSessionId: "legacy-parent"
    )
    let reservation = WorkflowNestedInvocationReservation(
      parentSessionId: "legacy-parent", parentStepId: "parent-step", resumeStepId: "resume-step",
      sourceStepExecutionId: "legacy-source", branchId: "legacy-branch",
      childSnapshot: WorkflowRuntimePersistenceSnapshot(session: child)
    )
    _ = try store.reserveNestedInvocation(reservation)
    let db = try database(root: root)
    let key = try XCTUnwrap(db.query("SELECT invocation_key FROM workflow_nested_invocations LIMIT 1").first?["invocation_key"])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let legacy = String(data: try encoder.encode(reservation), encoding: .utf8)!
    try db.execute("UPDATE workflow_nested_invocations SET reservation_json=jsonb(?) WHERE invocation_key=?", bindings: [.text(legacy), .text(key)])
    try db.execute("DELETE FROM workflow_nested_invocation_refs WHERE invocation_key=? AND role='reservation'", bindings: [.text(key)])

    XCTAssertEqual(try store.legacyEmbeddedNestedInvocationKeys(limit: 10), [key])
    XCTAssertEqual(try store.nestedInvocationRecord(reservation)?.reservation, reservation)
    XCTAssertTrue(try store.convertLegacyNestedInvocation(invocationKey: key))
    XCTAssertTrue(try store.legacyEmbeddedNestedInvocationKeys(limit: 10).isEmpty)
    XCTAssertEqual(try store.nestedInvocationRecord(reservation)?.reservation, reservation)
  }

  func testTerminalSaveReleasesOrphanPayloadsOnlyInItsFamily() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let execution = execution(id: "terminal-exec", output: "kept", date: date)
    try store.save(snapshot(id: "terminal-session", executions: [execution], date: date))
    let db = try database(root: root)
    try db.execute(
      "INSERT INTO workflow_runtime_payloads(root_session_id,digest,bytes,byte_count) "
        + "VALUES('terminal-session','orphan-local',jsonb('{\"data\":\"local\"}'),11), "
        + "('elsewhere','orphan-foreign',jsonb('{\"data\":\"foreign\"}'),13)"
    )
    var terminal = snapshot(id: "terminal-session", executions: [execution], date: date)
    terminal.session.status = .completed
    terminal.session.updatedAt = date.addingTimeInterval(1)
    try store.save(terminal)

    XCTAssertEqual(try scalar(db, "SELECT COUNT(*) AS value FROM workflow_runtime_payloads WHERE digest='orphan-local'"), 0)
    XCTAssertEqual(try scalar(db, "SELECT COUNT(*) AS value FROM workflow_runtime_payloads WHERE digest='orphan-foreign'"), 1)
    XCTAssertEqual(try scalar(db, "SELECT COUNT(*) AS value FROM workflow_runtime_payloads WHERE digest=(SELECT payload_digest FROM workflow_runtime_executions WHERE workflow_execution_id='terminal-session')"), 1)
  }

  private func snapshot(id: String, executions: [WorkflowStepExecution], date: Date) -> WorkflowRuntimePersistenceSnapshot {
    WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(
      workflowId: "workflow", sessionId: id, status: .running, entryStepId: "step-0",
      currentStepId: "step-current", createdAt: date, updatedAt: date, executions: executions
    ))
  }

  private func execution(id: String, output: String, date: Date) -> WorkflowStepExecution {
    WorkflowStepExecution(
      executionId: id, stepId: "step", nodeId: "node", attempt: 1,
      inputSnapshot: ["input": .string(String(repeating: "x", count: 128))],
      status: .completed, failureReason: output, createdAt: date, updatedAt: date
    )
  }

  private func temporaryDirectory() -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/efficient-history/eh-05-session-rows/tests/\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func database(root: URL) throws -> SQLiteDatabase {
    try SQLiteDatabase.open(
      path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path),
      mode: .readWriteCreate,
      options: .writableRuntimeStoreDefault
    )
  }

  private func scalar(_ db: SQLiteDatabase, _ sql: String) throws -> Int {
    try XCTUnwrap(db.query(sql).first?["value"].flatMap(Int.init))
  }
}
