import Foundation
import RielaCore
import RielaSQLite

public extension WorkStore {
  /// Creates the Work Runtime tables on an already-open connection, behind the
  /// runtime store's own generation guard.
  ///
  /// The `work_*` tables live in the runtime records database (design section
  /// 11) so attempt reservation and session creation can share one
  /// transaction in P1. One `PRAGMA user_version` therefore covers both
  /// schemas, and it is the runtime store's: `RielaWork` calls the core guard,
  /// never the reverse (design section 16).
  ///
  /// Nothing here touches a runtime table, so a failure in this schema fails
  /// the Work Runtime closed and leaves session persistence alone.
  static func prepareSchema(in db: SQLiteDatabase) throws {
    try db.requireJSONBAvailable()
    try SQLiteWorkflowRuntimePersistenceStore.requireCompatibleSchemaGeneration(in: db)
    try createTables(in: db)
  }

  /// The table and index statements, without the guard. Every filterable
  /// column is generated from the JSONB record so it can never drift from the
  /// payload; `created_at`/`updated_at` stay explicit because the record's
  /// ISO8601 dates are second-granularity while ordering needs the
  /// fractional-second timestamps the store writes itself.
  internal static func createTables(in db: SQLiteDatabase) throws {
    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS work_intents (
        intent_id TEXT PRIMARY KEY,
        record JSONB NOT NULL CHECK (json_valid(record, 8)),
        created_at TEXT NOT NULL,
        title TEXT NOT NULL GENERATED ALWAYS AS (json_extract(record, '$.title')) STORED,
        state TEXT NOT NULL GENERATED ALWAYS AS (json_extract(record, '$.state')) STORED
      )
      """
    )
    try db.execute("CREATE INDEX IF NOT EXISTS idx_work_intents_state ON work_intents (state, created_at DESC, intent_id)")

    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS work_tasks (
        task_id TEXT PRIMARY KEY,
        record JSONB NOT NULL CHECK (json_valid(record, 8)),
        updated_at TEXT NOT NULL,
        intent_id TEXT NOT NULL GENERATED ALWAYS AS (json_extract(record, '$.intentId')) STORED,
        parent_id TEXT GENERATED ALWAYS AS (json_extract(record, '$.parentId')) STORED,
        state TEXT NOT NULL GENERATED ALWAYS AS (json_extract(record, '$.state')) STORED,
        workflow_id TEXT GENERATED ALWAYS AS (json_extract(record, '$.plan.workflow.name')) STORED,
        version INTEGER NOT NULL GENERATED ALWAYS AS (json_extract(record, '$.version')) STORED
      )
      """
    )
    try db.execute("CREATE INDEX IF NOT EXISTS idx_work_tasks_intent ON work_tasks (intent_id, updated_at DESC, task_id)")
    try db.execute("CREATE INDEX IF NOT EXISTS idx_work_tasks_parent ON work_tasks (parent_id, task_id)")
    try db.execute("CREATE INDEX IF NOT EXISTS idx_work_tasks_state ON work_tasks (state, updated_at DESC, task_id)")
    try db.execute("CREATE INDEX IF NOT EXISTS idx_work_tasks_workflow ON work_tasks (workflow_id, updated_at DESC, task_id)")

    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS work_attempts (
        attempt_id TEXT PRIMARY KEY,
        record JSONB NOT NULL CHECK (json_valid(record, 8)),
        created_at TEXT NOT NULL,
        task_id TEXT NOT NULL GENERATED ALWAYS AS (json_extract(record, '$.taskId')) STORED,
        session_id TEXT NOT NULL GENERATED ALWAYS AS (json_extract(record, '$.sessionId')) STORED,
        generation INTEGER NOT NULL GENERATED ALWAYS AS (json_extract(record, '$.generation')) STORED,
        state TEXT NOT NULL GENERATED ALWAYS AS (json_extract(record, '$.state')) STORED,
        launch_phase TEXT GENERATED ALWAYS AS (json_extract(record, '$.launch.phase')) STORED
      )
      """
    )
    // One task has at most one live attempt and one attempt is exactly one
    // workflow session (design section 5), so the session mapping is unique.
    try db.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_work_attempts_session ON work_attempts (session_id)")
    try db.execute("CREATE INDEX IF NOT EXISTS idx_work_attempts_task ON work_attempts (task_id, created_at, attempt_id)")
    try db.execute("CREATE INDEX IF NOT EXISTS idx_work_attempts_state ON work_attempts (state, created_at DESC, attempt_id)")
    try db.execute(
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_work_attempts_one_live_per_task ON work_attempts (task_id) WHERE state IN ('prepared', 'running', 'terminal')"
    )

    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS work_leases (
        attempt_id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL,
        session_id TEXT NOT NULL UNIQUE,
        token_digest TEXT NOT NULL,
        acquired_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """
    )
    try db.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_work_leases_task ON work_leases (task_id)")

    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS work_pending_reservations (
        request_id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL UNIQUE,
        decision_id TEXT NOT NULL UNIQUE,
        predecessor_attempt_id TEXT,
        entry_record JSONB NOT NULL CHECK (json_valid(entry_record, 8)),
        created_at TEXT NOT NULL,
        consumed_attempt_id TEXT UNIQUE,
        consumed_at TEXT
      )
      """
    )

    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS work_cancellations (
        attempt_id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL,
        decision_id TEXT NOT NULL UNIQUE,
        requested_at TEXT NOT NULL,
        acknowledged_at TEXT,
        terminal_status TEXT
      )
      """
    )

    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS work_decisions (
        decision_id TEXT PRIMARY KEY,
        record JSONB NOT NULL CHECK (json_valid(record, 8)),
        created_at TEXT NOT NULL,
        task_id TEXT NOT NULL GENERATED ALWAYS AS (json_extract(record, '$.taskId')) STORED,
        attempt_id TEXT GENERATED ALWAYS AS (json_extract(record, '$.attemptId')) STORED,
        kind TEXT NOT NULL GENERATED ALWAYS AS (json_extract(record, '$.kind.kind')) STORED,
        producer_kind TEXT NOT NULL GENERATED ALWAYS AS (json_extract(record, '$.producer.kind')) STORED
      )
      """
    )
    try db.execute("CREATE INDEX IF NOT EXISTS idx_work_decisions_task ON work_decisions (task_id, created_at, decision_id)")
    try db.execute("CREATE INDEX IF NOT EXISTS idx_work_decisions_attempt ON work_decisions (attempt_id, created_at, decision_id)")
    try db.execute("CREATE INDEX IF NOT EXISTS idx_work_decisions_kind ON work_decisions (kind, created_at DESC, decision_id)")

    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS work_evidence (
        evidence_id TEXT PRIMARY KEY,
        record JSONB NOT NULL CHECK (json_valid(record, 8)),
        created_at TEXT NOT NULL,
        task_id TEXT NOT NULL GENERATED ALWAYS AS (json_extract(record, '$.taskId')) STORED,
        attempt_id TEXT GENERATED ALWAYS AS (json_extract(record, '$.attemptId')) STORED,
        kind TEXT NOT NULL GENERATED ALWAYS AS (json_extract(record, '$.kind')) STORED
      )
      """
    )
    try db.execute("CREATE INDEX IF NOT EXISTS idx_work_evidence_task_kind ON work_evidence (task_id, kind, created_at, evidence_id)")
    try db.execute("CREATE INDEX IF NOT EXISTS idx_work_evidence_attempt ON work_evidence (attempt_id, created_at, evidence_id)")

    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS work_findings (
        task_id TEXT NOT NULL,
        fingerprint TEXT NOT NULL,
        record JSONB NOT NULL CHECK (json_valid(record, 8)),
        severity TEXT NOT NULL GENERATED ALWAYS AS (json_extract(record, '$.severity')) STORED,
        status TEXT NOT NULL GENERATED ALWAYS AS (json_extract(record, '$.status')) STORED,
        gate_id TEXT GENERATED ALWAYS AS (json_extract(record, '$.gateId')) STORED,
        PRIMARY KEY (task_id, fingerprint)
      )
      """
    )
    try db.execute("CREATE INDEX IF NOT EXISTS idx_work_findings_task_status ON work_findings (task_id, status, severity)")
    try db.execute("CREATE INDEX IF NOT EXISTS idx_work_findings_gate ON work_findings (task_id, gate_id)")
  }

  /// Every table `prepareSchema` creates, in creation order. The store tests
  /// and P1 read it instead of repeating the list.
  static let tableNames = [
    "work_intents",
    "work_tasks",
    "work_attempts",
    "work_leases",
    "work_pending_reservations",
    "work_cancellations",
    "work_decisions",
    "work_evidence",
    "work_findings"
  ]
}
