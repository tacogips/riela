import RielaSQLite

extension SQLiteWorkflowRuntimePersistenceStore {
  static func addGeneration4NestedRecoveryReason(in database: SQLiteDatabase) throws {
    let columns = try database.query("PRAGMA table_info(workflow_nested_invocations)")
    if let column = columns.first(where: { $0["name"] == "recovery_reason" }) {
      // The former 2→3 migration used the fresh generation-4 builder. Its
      // first transaction could commit before 3→4 failed on a duplicate
      // column. Accept only that exact nullable-TEXT intermediate shape.
      guard column["type"] == "TEXT", column["notnull"] == "0",
            column["pk"] == "0", column["dflt_value"] == nil else {
        throw SQLiteError(operation: .execute, code: nil, message: "unexpected nested recovery_reason column shape")
      }
      return
    }
    try database.execute("ALTER TABLE workflow_nested_invocations ADD COLUMN recovery_reason TEXT")
  }

  /// Frozen generation-3 shape; keep this independent of fresh-store schema
  /// changes so a generation-2 database can apply every upgrade exactly once.
  static func createGeneration3NestedInvocationSchema(in database: SQLiteDatabase) throws {
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
    try database.execute(
      "CREATE INDEX idx_workflow_nested_invocations_child ON workflow_nested_invocations (json_extract(reservation_json, '$.childSnapshot.session.sessionId'))"
    )
  }
}
