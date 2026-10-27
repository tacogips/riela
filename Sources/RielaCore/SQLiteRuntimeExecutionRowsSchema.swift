import RielaSQLite

/// Generation-11 execution-row schema seam owned by eh-05.
enum SQLiteRuntimeExecutionRowsSchema {
  static func migrateToGeneration11(in db: SQLiteDatabase) throws {
    try createTables(in: db)
    let columns = try db.query("PRAGMA table_info(workflow_nested_invocations)")
    if !columns.contains(where: { $0["name"] == "abandoned_at" }) {
      try db.execute("ALTER TABLE workflow_nested_invocations ADD COLUMN abandoned_at TEXT")
    }
  }

  static func create(in db: SQLiteDatabase) throws {
    try createTables(in: db)
    let columns = try db.query("PRAGMA table_info(workflow_nested_invocations)")
    if !columns.isEmpty, !columns.contains(where: { $0["name"] == "abandoned_at" }) {
      try db.execute("ALTER TABLE workflow_nested_invocations ADD COLUMN abandoned_at TEXT")
    }
  }

  private static func createTables(in db: SQLiteDatabase) throws {
    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS workflow_runtime_payloads (
        id INTEGER PRIMARY KEY,
        root_session_id TEXT NOT NULL,
        digest TEXT NOT NULL,
        bytes BLOB NOT NULL CHECK (json_valid(bytes, 8)),
        byte_count INTEGER NOT NULL,
        UNIQUE(root_session_id, digest)
      )
      """
    )
    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS workflow_runtime_executions (
        workflow_execution_id TEXT NOT NULL REFERENCES workflow_runtime_snapshots(workflow_execution_id) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL,
        execution_id TEXT NOT NULL,
        root_session_id TEXT NOT NULL,
        payload_digest TEXT NOT NULL,
        PRIMARY KEY(workflow_execution_id, ordinal)
      ) WITHOUT ROWID
      """
    )
    try db.execute(
      "CREATE INDEX IF NOT EXISTS workflow_runtime_executions_root_digest ON workflow_runtime_executions(root_session_id, payload_digest)"
    )
    try db.execute(
      "CREATE INDEX IF NOT EXISTS workflow_runtime_executions_execution ON workflow_runtime_executions(workflow_execution_id, execution_id)"
    )
    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS workflow_nested_invocation_refs (
        invocation_key TEXT NOT NULL,
        role TEXT NOT NULL,
        ordinal INTEGER NOT NULL,
        root_session_id TEXT NOT NULL,
        digest TEXT NOT NULL,
        PRIMARY KEY(invocation_key, role, ordinal)
      ) WITHOUT ROWID
      """
    )
    try db.execute(
      "CREATE INDEX IF NOT EXISTS workflow_nested_invocation_refs_root_digest ON workflow_nested_invocation_refs(root_session_id, digest)"
    )
  }
}
