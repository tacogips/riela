import RielaSQLite

/// Database guards prevent late/stale writers from recreating expired payloads,
/// even when they bypass the CLI admission registry.
func ensureSessionRetentionTriggers(_ db: SQLiteDatabase) throws {
  if try db.tableExists("session_retention_tombstones") {
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
  }
  if try db.tableExists("session_retention_tombstones"), try db.tableExists("workflow_nested_invocations") {
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
  if try db.tableExists("session_message_retention_tombstones") {
    for table in ["workflow_messages", "workflow_message_payload_index"] where try db.tableExists(table) {
      for operation in ["INSERT", "UPDATE"] {
        try db.execute("""
          CREATE TRIGGER IF NOT EXISTS retention_message_guard_\(table)_\(operation.lowercased())
          BEFORE \(operation) ON \(table)
          WHEN EXISTS(SELECT 1 FROM session_message_retention_tombstones
            WHERE session_id=NEW.workflow_execution_id)
          BEGIN SELECT RAISE(ABORT,'workflow messages expired under retention'); END
          """)
      }
    }
  }
}

func ensureMessageRetentionTombstones(_ db: SQLiteDatabase) throws {
  try db.execute("""
    CREATE TABLE IF NOT EXISTS session_message_retention_tombstones(
      session_id TEXT PRIMARY KEY, workflow_id TEXT NOT NULL, pruned_at TEXT NOT NULL, message_bytes INTEGER NOT NULL)
    """)
}
