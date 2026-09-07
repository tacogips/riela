import Foundation
import RielaSQLite
import XCTest
@testable import RielaCore

final class SQLiteRuntimeSchemaMigrationTests: XCTestCase {
  func testGeneration2UpgradesThrough3To4WithoutLosingSnapshot() throws {
    try assertUpgrade(startingAt: 2)
  }

  func testGeneration3UpgradesTo4WithoutLosingSnapshot() throws {
    try assertUpgrade(startingAt: 3)
  }

  func testPreviouslyInterruptedUpgradeResumesFromGeneration3WithRecoveryColumn() throws {
    try assertUpgrade(startingAt: 3, recoveryColumnAlreadyPresent: true)
  }

  private func assertUpgrade(startingAt generation: Int64, recoveryColumnAlreadyPresent: Bool = false) throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/schema-migration/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let original = WorkflowSession(
      workflowId: "legacy", sessionId: "legacy-session", status: .completed,
      entryStepId: "entry", createdAt: date, updatedAt: date
    )
    let path = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    try createHistoricalStore(path: path, session: original, generation: generation)
    if recoveryColumnAlreadyPresent {
      let database = try SQLiteDatabase.open(path: path, mode: .readWriteCreate)
      try database.execute("ALTER TABLE workflow_nested_invocations ADD COLUMN recovery_reason TEXT")
    }
    XCTAssertFalse(SQLiteWorkflowRuntimePersistenceStore.discardIncompatibleStoreIfNeeded(databasePath: path))

    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let child = WorkflowSession(
      workflowId: "child", sessionId: "new-child", status: .created,
      entryStepId: "work", createdAt: date, updatedAt: date,
      parentSessionId: original.sessionId, rootSessionId: original.sessionId
    )
    let reservation = WorkflowNestedInvocationReservation(
      parentSessionId: original.sessionId, parentStepId: "entry", resumeStepId: "resume",
      sourceStepExecutionId: "exec-legacy", branchId: "cross-workflow",
      childSnapshot: WorkflowRuntimePersistenceSnapshot(session: child)
    )
    XCTAssertEqual(try store.reserveNestedInvocation(reservation).phase, .prepared)
    XCTAssertEqual(try store.load(sessionId: original.sessionId).session, original)
    let reopened = try SQLiteDatabase.open(path: path, mode: .readOnly, options: .readOnlyDefault)
    XCTAssertEqual(try SQLiteSchemaMigrator.stampedGeneration(in: reopened), 4)
    let columns = try reopened.query("PRAGMA table_info(workflow_nested_invocations)")
    XCTAssertEqual(columns.filter { $0["name"] == "recovery_reason" }.count, 1)
    // Reopening the now-current database must not reapply either migration.
    XCTAssertEqual(try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path).reserveNestedInvocation(reservation).phase, .prepared)
  }

  private func createHistoricalStore(path: String, session: WorkflowSession, generation: Int64) throws {
    let database = try SQLiteDatabase.open(path: path, mode: .readWriteCreate)
    // Literal released generation-2 DDL, independent of today's schema builder.
    try database.execute(
      """
      CREATE TABLE workflow_runtime_snapshots (
        workflow_execution_id TEXT PRIMARY KEY,
        session_json BLOB NOT NULL CHECK (json_valid(session_json, 8)),
        root_output_json BLOB CHECK (root_output_json IS NULL OR json_valid(root_output_json, 8)),
        diagnostics_json BLOB NOT NULL CHECK (json_valid(diagnostics_json, 8)),
        loop_evidence_json BLOB CHECK (loop_evidence_json IS NULL OR json_valid(loop_evidence_json, 8)),
        loop_summary_json BLOB CHECK (loop_summary_json IS NULL OR json_valid(loop_summary_json, 8)),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        workflow_id TEXT NOT NULL GENERATED ALWAYS AS (json_extract(session_json, '$.workflowId')) STORED,
        session_status TEXT NOT NULL GENERATED ALWAYS AS (json_extract(session_json, '$.status')) STORED,
        parent_session_id TEXT GENERATED ALWAYS AS (json_extract(session_json, '$.parentSessionId')) STORED,
        root_session_id TEXT NOT NULL GENERATED ALWAYS AS (
          COALESCE(json_extract(session_json, '$.rootSessionId'), workflow_execution_id)
        ) STORED
      )
      """
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let json = try XCTUnwrap(String(data: encoder.encode(session), encoding: .utf8))
    try database.execute(
      """
      INSERT INTO workflow_runtime_snapshots (
        workflow_execution_id, session_json, diagnostics_json, created_at, updated_at
      ) VALUES (?, jsonb(?), jsonb('[]'), '2023-11-14T22:13:20Z', '2023-11-14T22:13:20Z')
      """,
      bindings: [.text(session.sessionId), .text(json)]
    )
    if generation == 3 {
      try database.execute(
        """
        CREATE TABLE workflow_nested_invocations (
          invocation_key TEXT PRIMARY KEY,
          reservation_json BLOB NOT NULL CHECK (json_valid(reservation_json, 8)),
          child_terminal_json BLOB CHECK (child_terminal_json IS NULL OR json_valid(child_terminal_json, 8)),
          parent_message_json BLOB CHECK (parent_message_json IS NULL OR json_valid(parent_message_json, 8)),
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
        """
      )
    }
    try database.execute("PRAGMA user_version = \(generation)")
  }
}
