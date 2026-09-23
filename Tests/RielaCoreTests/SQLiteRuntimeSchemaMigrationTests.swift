import Foundation
import RielaSQLite
import XCTest
@testable import RielaCore

/// Two contracts live here.
///
/// 1. The registered `2 → 3 → 4` upgrade steps still do what they claim: they
///    build the nested-invocation table and its recovery column in place
///    without losing a snapshot. They are exercised against the generation
///    they were written for, because the store's current generation has moved
///    past them.
/// 2. At the store's *current* generation there is deliberately no upgrade
///    step from 4. The Work Runtime design forbids migrations, so every
///    pre-generation-5 session store is discarded and recreated instead.
final class SQLiteRuntimeSchemaMigrationTests: XCTestCase {
  private static let nestedInvocationGeneration: Int64 = 4

  func testGeneration2UpgradesThrough3To4WithoutLosingSnapshot() throws {
    try assertUpgrade(startingAt: 2)
  }

  func testGeneration3UpgradesTo4WithoutLosingSnapshot() throws {
    try assertUpgrade(startingAt: 3)
  }

  func testPreviouslyInterruptedUpgradeResumesFromGeneration3WithRecoveryColumn() throws {
    try assertUpgrade(startingAt: 3, recoveryColumnAlreadyPresent: true)
  }

  /// Generation 5 added the Work Runtime's `work_*` tables and registered no
  /// upgrade step, so nothing older than it has a path forward.
  func testNoGenerationBelowTheCurrentOneHasAMigrationPath() {
    let current = SQLiteWorkflowRuntimePersistenceStore.schemaGeneration
    XCTAssertGreaterThan(current, Self.nestedInvocationGeneration)
    for stamped in 1..<current {
      XCTAssertFalse(
        SQLiteSchemaMigrator.hasCompletePath(
          from: stamped,
          to: current,
          migrations: SQLiteWorkflowRuntimePersistenceStore.schemaMigrations
        ),
        "generation \(stamped) must have no path to \(current): the Work Runtime design forbids migrations"
      )
    }
  }

  /// The regenerable-data policy: an older session store is deleted and
  /// rebuilt at the current generation rather than hard-failing every open.
  func testAnOlderSessionStoreIsDiscardedAndRecreatedAtTheCurrentGeneration() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let legacy = WorkflowSession(
      workflowId: "legacy", sessionId: "legacy-session", status: .completed,
      entryStepId: "entry", createdAt: date, updatedAt: date
    )
    let path = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    try createHistoricalStore(path: path, session: legacy, generation: Self.nestedInvocationGeneration)

    XCTAssertTrue(SQLiteWorkflowRuntimePersistenceStore.discardIncompatibleStoreIfNeeded(databasePath: path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the discarded store is deleted, not upgraded")

    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let fresh = WorkflowSession(
      workflowId: "fresh", sessionId: "fresh-session", status: .completed,
      entryStepId: "entry", createdAt: date, updatedAt: date
    )
    try store.save(WorkflowRuntimePersistenceSnapshot(session: fresh))
    XCTAssertEqual(try store.load(sessionId: fresh.sessionId).session, fresh)
    XCTAssertThrowsError(try store.load(sessionId: legacy.sessionId), "the discarded history is gone")

    let reopened = try SQLiteDatabase.open(path: path, mode: .readOnly, options: .readOnlyDefault)
    XCTAssertEqual(
      try SQLiteSchemaMigrator.stampedGeneration(in: reopened),
      SQLiteWorkflowRuntimePersistenceStore.schemaGeneration
    )
  }

  /// Exercises the registered steps themselves, at the generation they bring a
  /// store to. `SQLiteWorkflowRuntimePersistenceStore` no longer reaches this
  /// path, but the steps stay correct and covered.
  private func assertUpgrade(startingAt generation: Int64, recoveryColumnAlreadyPresent: Bool = false) throws {
    let root = try makeRoot()
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

    let database = try SQLiteDatabase.open(path: path, mode: .readWriteCreate, options: .writableDefault)
    try SQLiteSchemaMigrator.migrateIfNeeded(
      in: database,
      currentGeneration: Self.nestedInvocationGeneration,
      migrations: SQLiteWorkflowRuntimePersistenceStore.schemaMigrations,
      preGenerationProbe: { try $0.tableExists("workflow_runtime_snapshots") },
      storeDescription: "session store"
    )

    let reopened = try SQLiteDatabase.open(path: path, mode: .readOnly, options: .readOnlyDefault)
    XCTAssertEqual(try SQLiteSchemaMigrator.stampedGeneration(in: reopened), Self.nestedInvocationGeneration)
    XCTAssertTrue(try reopened.tableExists("workflow_nested_invocations"))
    let columns = try reopened.query("PRAGMA table_info(workflow_nested_invocations)")
    XCTAssertEqual(columns.filter { $0["name"] == "recovery_reason" }.count, 1)
    let snapshots = try reopened.query("SELECT workflow_execution_id FROM workflow_runtime_snapshots")
    XCTAssertEqual(snapshots.compactMap { $0["workflow_execution_id"] }, [original.sessionId])

    // Re-running the chain on the now-current database must not reapply a step.
    try SQLiteSchemaMigrator.migrateIfNeeded(
      in: database,
      currentGeneration: Self.nestedInvocationGeneration,
      migrations: SQLiteWorkflowRuntimePersistenceStore.schemaMigrations,
      preGenerationProbe: { try $0.tableExists("workflow_runtime_snapshots") },
      storeDescription: "session store"
    )
    XCTAssertEqual(try SQLiteSchemaMigrator.stampedGeneration(in: reopened), Self.nestedInvocationGeneration)
  }

  private func makeRoot() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/schema-migration/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
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
    if generation >= 3 {
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
    if generation >= 4 {
      try database.execute("ALTER TABLE workflow_nested_invocations ADD COLUMN recovery_reason TEXT")
    }
    try database.execute("PRAGMA user_version = \(generation)")
  }
}
