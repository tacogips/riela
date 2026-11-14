import RielaSQLite

/// Database guards prevent late/stale writers from recreating expired payloads,
/// even when they bypass the CLI admission registry.
func ensureSessionRetentionTriggers(_ db: SQLiteDatabase) throws {
  guard try db.tableExists("session_retention_tombstones") else { return }
  let tables = [
    ("workflow_runtime_snapshots", "NEW.workflow_execution_id"),
    ("cli_workflow_sessions", "NEW.session_id"),
    ("workflow_messages", "NEW.workflow_execution_id"),
    ("workflow_message_payload_index", "NEW.workflow_execution_id")
  ]
  for (table, identity) in tables where try db.tableExists(table) {
    for operation in ["INSERT", "UPDATE"] {
      try db.execute("""
        CREATE TRIGGER IF NOT EXISTS retention_guard_\(table)_\(operation.lowercased())
        BEFORE \(operation) ON \(table)
        WHEN EXISTS(SELECT 1 FROM session_retention_tombstones WHERE session_id=\(identity))
        BEGIN SELECT RAISE(ABORT,'session payloads expired under terminal retention'); END
        """)
    }
  }
  if try db.tableExists("workflow_nested_invocations") {
    for operation in ["INSERT", "UPDATE"] {
      try db.execute("""
        CREATE TRIGGER IF NOT EXISTS retention_guard_nested_\(operation.lowercased())
        BEFORE \(operation) ON workflow_nested_invocations
        WHEN EXISTS(SELECT 1 FROM session_retention_tombstones
          WHERE session_id=json_extract(NEW.reservation_json,'$.parentSessionId')
             OR session_id=json_extract(NEW.reservation_json,'$.childSnapshot.session.sessionId'))
        BEGIN SELECT RAISE(ABORT,'session payloads expired under terminal retention'); END
        """)
    }
  }
}
