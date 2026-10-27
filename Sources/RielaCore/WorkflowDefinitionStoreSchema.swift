import Foundation
import RielaSQLite

enum WorkflowDefinitionStoreSchema {
  static func shouldDiscardIncompatibleStore(
    _ database: SQLiteDatabase,
    currentGeneration: Int64,
    migrations: [SQLiteSchemaMigration]
  ) throws -> Bool {
    let version = try SQLiteSchemaMigrator.stampedGeneration(in: database)
    guard version < currentGeneration,
          !SQLiteSchemaMigrator.hasCompletePath(from: version, to: currentGeneration, migrations: migrations) else {
      return false
    }
    let hasHeadTable = try database.tableExists("definition_heads")
    let hasDefinitionHeads: Bool
    if hasHeadTable {
      hasDefinitionHeads = try !database.query("SELECT 1 FROM definition_heads LIMIT 1").isEmpty
    } else {
      hasDefinitionHeads = false
    }
    guard !hasDefinitionHeads else { return false }
    let hasSnapshots = try database.tableExists("workflow_runtime_snapshots")
    let hasCLISessions = try database.tableExists("cli_workflow_sessions")
    let hasMessages = try database.tableExists("workflow_messages")
    return hasSnapshots || hasCLISessions || hasMessages
  }

  static func create(in database: SQLiteDatabase) throws {
    try database.execute("""
    CREATE TABLE IF NOT EXISTS definition_blobs (
      digest TEXT PRIMARY KEY,
      bytes BLOB NOT NULL,
      size INTEGER NOT NULL,
      created_at TEXT NOT NULL
    )
    """)
    try database.execute("""
    CREATE TABLE IF NOT EXISTS definition_versions (
      version_id TEXT PRIMARY KEY,
      workflow_name TEXT NOT NULL,
      parent_version_id TEXT,
      document_digest TEXT NOT NULL REFERENCES definition_blobs(digest),
      operation TEXT NOT NULL,
      source_directory TEXT NOT NULL,
      source_scope TEXT NOT NULL,
      provenance TEXT NOT NULL,
      actor_kind TEXT NOT NULL,
      actor_id TEXT,
      created_at TEXT NOT NULL
    )
    """)
    try database.execute("""
    CREATE TABLE IF NOT EXISTS definition_heads (
      workflow_name TEXT PRIMARY KEY,
      current_version_id TEXT NOT NULL,
      last_file_version_id TEXT NOT NULL,
      revision INTEGER NOT NULL,
      source_directory TEXT NOT NULL,
      source_scope TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)
    try database.execute("""
    CREATE TABLE IF NOT EXISTS definition_change_audit (
      created_order INTEGER PRIMARY KEY AUTOINCREMENT,
      audit_id TEXT NOT NULL UNIQUE,
      workflow_name TEXT NOT NULL,
      operation TEXT NOT NULL,
      version_id TEXT NOT NULL,
      previous_version_id TEXT,
      target_node_id TEXT,
      target_field TEXT,
      before_digest TEXT,
      after_digest TEXT NOT NULL,
      diff_json TEXT NOT NULL,
      reason TEXT NOT NULL CHECK (length(trim(reason)) > 0),
      evidence_refs_json TEXT NOT NULL,
      actor_kind TEXT NOT NULL,
      actor_id TEXT,
      approval_state TEXT NOT NULL,
      overwritten_changes_json TEXT,
      created_at TEXT NOT NULL
    )
    """)
    try database.execute("CREATE INDEX IF NOT EXISTS definition_versions_workflow_created ON definition_versions(workflow_name, created_at)")
    try database.execute("CREATE INDEX IF NOT EXISTS definition_audit_workflow_order ON definition_change_audit(workflow_name, created_order)")
    try database.execute("CREATE TRIGGER IF NOT EXISTS definition_blobs_no_update BEFORE UPDATE ON definition_blobs BEGIN SELECT RAISE(ABORT, 'definition_blobs are immutable'); END")
    try database.execute("CREATE TRIGGER IF NOT EXISTS definition_versions_no_update BEFORE UPDATE ON definition_versions BEGIN SELECT RAISE(ABORT, 'definition_versions is append-only'); END")
    try database.execute("CREATE TRIGGER IF NOT EXISTS definition_versions_no_delete BEFORE DELETE ON definition_versions BEGIN SELECT RAISE(ABORT, 'definition_versions is append-only'); END")
    try database.execute("CREATE TRIGGER IF NOT EXISTS definition_audit_no_update BEFORE UPDATE ON definition_change_audit BEGIN SELECT RAISE(ABORT, 'definition_change_audit is append-only'); END")
    try database.execute("CREATE TRIGGER IF NOT EXISTS definition_audit_no_delete BEFORE DELETE ON definition_change_audit BEGIN SELECT RAISE(ABORT, 'definition_change_audit is append-only'); END")
  }
}
