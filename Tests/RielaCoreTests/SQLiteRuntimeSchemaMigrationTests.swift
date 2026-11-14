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
  private static let definitionStoreBaseGeneration: Int64 = 9

  func testGeneration2UpgradesThrough3To4WithoutLosingSnapshot() throws {
    try assertUpgrade(startingAt: 2)
  }

  func testGeneration3UpgradesTo4WithoutLosingSnapshot() throws {
    try assertUpgrade(startingAt: 3)
  }

  func testGeneration11UpgradesTo12AddsPayloadRefsTable() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let execution = WorkflowStepExecution(
      executionId: "exec", stepId: "step", nodeId: "node", attempt: 1,
      inputSnapshot: [:], status: .completed, createdAt: date, updatedAt: date
    )
    let session = WorkflowSession(
      workflowId: "workflow", sessionId: "session", status: .running,
      entryStepId: "step", createdAt: date, updatedAt: date, executions: [execution]
    )
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    try store.save(WorkflowRuntimePersistenceSnapshot(session: session))
    let path = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    let db = try SQLiteDatabase.open(path: path, mode: .readWriteCreate, options: .writableRuntimeStoreDefault)
    let before = try db.query("SELECT digest FROM workflow_runtime_payloads ORDER BY digest").compactMap { $0["digest"] }
    XCTAssertFalse(before.isEmpty)
    try db.execute("DROP TABLE workflow_runtime_payload_refs")
    try db.execute("PRAGMA user_version = 11")
    try store.prepareSchema(in: db)
    XCTAssertEqual(try SQLiteSchemaMigrator.stampedGeneration(in: db), 12)
    XCTAssertTrue(try db.tableExists("workflow_runtime_payload_refs"))
    XCTAssertEqual(try db.query("SELECT digest FROM workflow_runtime_payloads ORDER BY digest").compactMap { $0["digest"] }, before)
    XCTAssertEqual(try db.query("SELECT name FROM sqlite_master WHERE type='index' AND name='workflow_runtime_payload_refs_root_digest'").count, 1)
  }

  func testGeneration10UpgradesTo11WithoutLosingSnapshot() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let original = WorkflowSession(
      workflowId: "generation-ten", sessionId: "generation-ten-session", status: .completed,
      entryStepId: "entry", createdAt: date, updatedAt: date
    )
    let path = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    try createHistoricalStore(path: path, session: original, generation: 9)
    let fixture = try SQLiteDatabase.open(path: path, mode: .readWriteCreate)
    try SQLiteWorkflowRuntimePersistenceStore.createGeneration10DefinitionSchema(in: fixture)
    try fixture.execute(
      "UPDATE workflow_runtime_snapshots SET created_at=?, updated_at=? WHERE workflow_execution_id=?",
      bindings: [
        .text(SQLiteWorkflowRuntimePersistenceStore.dateString(date)),
        .text(SQLiteWorkflowRuntimePersistenceStore.dateString(date)),
        .text(original.sessionId)
      ]
    )
    try fixture.execute("PRAGMA user_version = 10")

    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let database = try SQLiteDatabase.open(path: path, mode: .readWriteCreate, options: .writableRuntimeStoreDefault)
    try store.prepareSchema(in: database)

    XCTAssertEqual(try SQLiteSchemaMigrator.stampedGeneration(in: database), 12)
    XCTAssertEqual(try store.load(sessionId: original.sessionId).session, original)
  }

  func testGenerationTenInlineExecutionFixtureSupportsReadOnlySummaryAndStartupBackfill() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let execution = WorkflowStepExecution(
      executionId: "step-attempt-1-exec-41", stepId: "step", nodeId: "node", attempt: 1,
      inputSnapshot: [:], status: .completed, createdAt: date, updatedAt: date
    )
    let session = WorkflowSession(
      workflowId: "generation-ten", sessionId: "generation-ten-session", status: .running,
      entryStepId: "step", createdAt: date, updatedAt: date, executions: [execution]
    )
    let path = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    try createHistoricalStore(path: path, session: session, generation: 9)
    let fixture = try SQLiteDatabase.open(path: path, mode: .readWriteCreate)
    try SQLiteWorkflowRuntimePersistenceStore.createGeneration10DefinitionSchema(in: fixture)
    try fixture.execute(
      "UPDATE workflow_runtime_snapshots SET created_at=?, updated_at=? WHERE workflow_execution_id=?",
      bindings: [
        .text(SQLiteWorkflowRuntimePersistenceStore.dateString(date)),
        .text(SQLiteWorkflowRuntimePersistenceStore.dateString(date)),
        .text(session.sessionId)
      ]
    )
    let child = WorkflowSession(
      workflowId: "nested-child", sessionId: "generation-ten-child", status: .created,
      entryStepId: "step", createdAt: date, updatedAt: date,
      parentSessionId: session.sessionId, rootSessionId: session.sessionId
    )
    let reservation = WorkflowNestedInvocationReservation(
      parentSessionId: session.sessionId, parentStepId: "step", resumeStepId: "resume",
      sourceStepExecutionId: "step-attempt-1-exec-41", branchId: "legacy-branch",
      childSnapshot: WorkflowRuntimePersistenceSnapshot(session: child)
    )
    let nestedEncoder = JSONEncoder()
    nestedEncoder.dateEncodingStrategy = .iso8601
    let nestedJSON = try XCTUnwrap(String(data: nestedEncoder.encode(reservation), encoding: .utf8))
    try fixture.execute(
      "INSERT INTO workflow_nested_invocations(invocation_key,reservation_json,created_at,updated_at) VALUES(?,jsonb(?),?,?)",
      bindings: [
        .text("generation-ten-invocation"), .text(nestedJSON),
        .text(SQLiteWorkflowRuntimePersistenceStore.dateString(date)),
        .text(SQLiteWorkflowRuntimePersistenceStore.dateString(date))
      ]
    )
    try fixture.execute("PRAGMA user_version = 10")

    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    XCTAssertEqual(try store.loadSessionSummaries(workflowId: session.workflowId, limit: 10).map(\.sessionId), [session.sessionId])
    let generator = MonotonicWorkflowRuntimeIDGenerator()
    try store.observePersistedIdentities(generator)
    XCTAssertEqual(try generator.nextStepExecutionId(stepId: "step", attempt: 1), "step-attempt-1-exec-42")
    XCTAssertEqual(try store.load(sessionId: session.sessionId).session, session)
    try store.save(WorkflowRuntimePersistenceSnapshot(session: session))
    XCTAssertEqual(try store.load(sessionId: session.sessionId).session, session)
    XCTAssertEqual(try store.legacyEmbeddedNestedInvocationKeys(limit: 10), ["generation-ten-invocation"])
    XCTAssertTrue(try store.convertLegacyNestedInvocation(invocationKey: "generation-ten-invocation"))
    let migrated = try SQLiteDatabase.open(path: path, mode: .readOnly)
    XCTAssertEqual(try SQLiteSchemaMigrator.stampedGeneration(in: migrated), 12)
    XCTAssertEqual(
      try store.nestedInvocationRecord(key: "generation-ten-invocation", in: migrated)?.reservation,
      reservation
    )
    XCTAssertGreaterThan(
      try migrated.query("SELECT COUNT(*) AS value FROM workflow_nested_invocation_refs").first?["value"].flatMap(Int.init) ?? 0,
      0
    )
  }

  func testGeneration9UpgradesThrough10To11WithoutLosingSnapshot() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let original = WorkflowSession(
      workflowId: "generation-nine", sessionId: "generation-nine-session", status: .completed,
      entryStepId: "entry", createdAt: date, updatedAt: date
    )
    let path = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    try createHistoricalStore(path: path, session: original, generation: 9)

    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let database = try SQLiteDatabase.open(path: path, mode: .readWriteCreate, options: .writableRuntimeStoreDefault)
    try store.prepareSchema(in: database)

    XCTAssertEqual(try SQLiteSchemaMigrator.stampedGeneration(in: database), 12)
    XCTAssertEqual(try store.load(sessionId: original.sessionId).session, original)
  }

  func testPreviouslyInterruptedUpgradeResumesFromGeneration3WithRecoveryColumn() throws {
    try assertUpgrade(startingAt: 3, recoveryColumnAlreadyPresent: true)
  }

  /// Generation 5 added the Work Runtime's `work_*` tables and registered no
  /// upgrade step, so nothing older than it has a path forward.
  func testNoGenerationBelowTheCurrentOneHasAMigrationPath() {
    let current = SQLiteWorkflowRuntimePersistenceStore.schemaGeneration
    XCTAssertGreaterThan(current, Self.nestedInvocationGeneration)
    // Generation 9 → 10 only adds the definition store tables, so existing
    // session stores upgrade in place; every older generation is still discarded.
    XCTAssertTrue(
      SQLiteSchemaMigrator.hasCompletePath(
        from: Self.definitionStoreBaseGeneration,
        to: current,
        migrations: SQLiteWorkflowRuntimePersistenceStore.schemaMigrations
      ),
      "generation \(Self.definitionStoreBaseGeneration) must migrate to \(current) by adding the definition store tables"
    )
    for stamped in 1..<Self.definitionStoreBaseGeneration {
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

  func testNestedReadersSeeEmptyStateWhileDatabaseSchemaIsBeingCreated() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    let database = try SQLiteDatabase.open(path: path, mode: .readWriteCreate)
    try database.execute("CREATE TABLE bootstrap (id INTEGER PRIMARY KEY)")

    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    XCTAssertNil(try store.nestedInvocationRecord(
      parentSessionId: "parent", sourceStepExecutionId: "source-exec", branchId: "fanout-1"
    ))
    XCTAssertEqual(try store.nestedInvocationRecords(parentSessionId: "parent"), [])
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
