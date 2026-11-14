import RielaSQLite

/// SQLite owns maintenance for every writer, including older runtime versions.
/// These indexes contain IDs, lineage, status, times and byte counts only.
enum TerminalRetentionIndexes {
  static let runtimeBytes = """
    length(CAST(session_json AS BLOB)) + coalesce(length(CAST(root_output_json AS BLOB)),0) + length(CAST(diagnostics_json AS BLOB))
      + coalesce(length(CAST(loop_evidence_json AS BLOB)),0) + coalesce(length(CAST(loop_summary_json AS BLOB)),0)
    """
  static let messageBytes = "length(CAST(payload_json AS BLOB))+length(CAST(artifact_refs_json AS BLOB))"
  static let child = "json_extract(reservation_json,'$.childSnapshot.session.sessionId')"
  static let parent = "json_extract(reservation_json,'$.parentSessionId')"
  static let nestedBytes = """
    length(CAST(reservation_json AS BLOB))+coalesce(length(CAST(child_terminal_json AS BLOB)),0)+coalesce(length(CAST(parent_message_json AS BLOB)),0)
    """
  static let settled = "(child_terminal_json IS NOT NULL AND parent_message_json IS NOT NULL AND recovery_reason IS NULL)"

  static func settled(in db: SQLiteDatabase) throws -> String {
    let columns = try db.tableColumnNames("workflow_nested_invocations")
    if columns.contains("abandoned_at") {
      return "(\(settled) OR abandoned_at IS NOT NULL)"
    }
    return settled
  }

  static func index(_ table: String) -> String {
    "idx_retention_metadata_\(table == "workflow_nested_invocations" ? "v2" : "v1")_" + table
  }

  static let columns: [(String, String)] = [
    ("workflow_runtime_snapshots", "workflow_execution_id,workflow_id,session_status,parent_session_id,root_session_id,updated_at,\(runtimeBytes)"),
    ("cli_workflow_sessions", """
      session_id,workflow_id,status,json_extract(record_json,'$.session.parentSessionId'),
      coalesce(json_extract(record_json,'$.session.rootSessionId'),session_id),updated_at,length(CAST(record_json AS BLOB))
      """),
    ("workflow_messages", "workflow_execution_id,\(messageBytes)"),
    ("workflow_nested_invocations", "\(child),\(parent),\(nestedBytes),\(settled)")
  ]

  static func prepare(_ db: SQLiteDatabase) throws {
    try db.transaction { db in
      if try db.tableExists("workflow_nested_invocations") {
        try db.execute("DROP INDEX IF EXISTS idx_retention_metadata_v1_workflow_nested_invocations")
        try db.execute("""
          CREATE INDEX IF NOT EXISTS idx_workflow_nested_invocations_parent
          ON workflow_nested_invocations(json_extract(reservation_json,'$.parentSessionId'))
          """)
      }
      for (table, expression) in columns where try db.tableExists(table) {
        let indexedExpression = table == "workflow_nested_invocations" ? "\(child),\(parent),\(nestedBytes),\(try settled(in: db))" : expression
        try db.execute("CREATE INDEX IF NOT EXISTS \(index(table)) ON \(table)(\(indexedExpression))")
      }
    }
  }

  /// A legacy strict-read-only dry run remains read-only and uses the old query.
  static func source(_ table: String, in db: SQLiteDatabase) throws -> String {
    if !(try db.query("SELECT name FROM sqlite_master WHERE type='index' AND name=? AND tbl_name=?",
      bindings: [.text(index(table)), .text(table)])).isEmpty {
      return "\(table) INDEXED BY \(index(table))"
    }
    return table
  }
}
