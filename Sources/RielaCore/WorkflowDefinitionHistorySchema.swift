import Foundation
import RielaSQLite
import RielaMemory

enum WorkflowDefinitionHistorySchema {
  static let pinBackfillByteLimit: Int64 = 268_435_456

  static func migrateToGeneration11(in db: SQLiteDatabase) throws {
    try createSupportingTables(in: db)
    try db.execute("DROP TRIGGER IF EXISTS definition_audit_no_delete")
    try db.execute("DROP TRIGGER IF EXISTS definition_versions_no_delete")
    try db.execute("DROP TRIGGER IF EXISTS definition_versions_no_update")
    try db.execute("ALTER TABLE definition_versions RENAME TO definition_versions_generation10")
    try createVersionsTable(in: db)
    try db.execute("""
      INSERT INTO definition_versions(version_id, workflow_name, parent_version_id, document_digest, operation,
        source_directory, source_scope, provenance, actor_kind, actor_id, created_at, history_version)
      SELECT version.version_id, version.workflow_name, version.parent_version_id, version.document_digest,
        version.operation, version.source_directory, version.source_scope, version.provenance,
        version.actor_kind, version.actor_id, version.created_at,
        (SELECT COUNT(*) FROM definition_change_audit AS ordered
         WHERE ordered.workflow_name = version.workflow_name AND ordered.created_order <= audit.created_order)
      FROM definition_versions_generation10 AS version
      JOIN definition_change_audit AS audit ON audit.version_id = version.version_id
      ORDER BY audit.created_order
      """)
    try db.execute("DROP TABLE definition_versions_generation10")
    try createVersionTriggers(in: db)
    let executor = SQLiteDatabaseHistoryExecutor(database: db)
    let history = VersionedHistoryStore(tablePrefix: "definition", headStorage: .stored, sql: executor,
      withGuardedDelete: { body in try withGuardedDelete(db, body: body) })
    try history.ensureSchema()
    let workflows = try db.query("SELECT workflow_name, current_version_id, revision FROM definition_heads")
    for row in workflows {
      let name = row.string("workflow_name")
      guard let headVersion = try versionNumber(row.string("current_version_id"), in: db),
            let head = try document(versionId: row.string("current_version_id"), in: db) else { continue }
      let priorRows = try db.query("""
        SELECT version.history_version, version.created_at, blob.bytes
        FROM definition_versions AS version JOIN definition_blobs AS blob ON blob.digest = version.document_digest
        WHERE version.workflow_name = ? AND version.history_version < ? ORDER BY version.history_version
        """, bindings: [.text(name), .int(Int64(headVersion))])
      // The engine import contract intentionally carries value, version and timestamp together.
      // swiftlint:disable:next large_tuple
      let previous = try priorRows.map { row -> (version: Int64, createdAt: String, value: Data) in
        guard let bytes = row.data("bytes"), let version = row["history_version"].flatMap(Int64.init) else {
          throw SQLiteError(operation: .query, code: nil, message: "invalid legacy definition blob")
        }
        return (version, row.string("created_at"), bytes)
      }
      try history.importChain(key: name, revision: Int64(row["revision"] ?? "0") ?? 0,
        headVersion: Int64(headVersion), headValue: head, previous: previous)
    }
    try db.execute("DROP TABLE definition_blobs")
    try db.execute("DROP TRIGGER IF EXISTS definition_blobs_no_update")
    let snapshotBytes = try db.tableExists("workflow_runtime_snapshots")
      ? (try db.query("SELECT COALESCE(SUM(length(session_json)), 0) AS bytes FROM workflow_runtime_snapshots").first? ["bytes"].flatMap(Int64.init) ?? 0)
      : 0
    if snapshotBytes <= pinBackfillByteLimit {
      try backfillSameStorePins(in: db)
      try applyDefaultRetention(in: db, history: history)
      try db.execute("INSERT OR REPLACE INTO definition_store_state(key, value) VALUES ('retention', 'active')")
    } else {
      try db.execute("INSERT OR REPLACE INTO definition_store_state(key, value) VALUES ('retention', 'pendingBackfill')")
    }
  }

  static func create(in db: SQLiteDatabase) throws {
    try createSupportingTables(in: db)
    try createVersionsTable(in: db)
    try createVersionTriggers(in: db)
    try db.execute("CREATE INDEX IF NOT EXISTS definition_versions_workflow_created ON definition_versions(workflow_name, created_at)")
    try db.execute("CREATE INDEX IF NOT EXISTS definition_audit_workflow_order ON definition_change_audit(workflow_name, created_order)")
    let history = VersionedHistoryStore(tablePrefix: "definition", headStorage: .stored,
      sql: SQLiteDatabaseHistoryExecutor(database: db), withGuardedDelete: { body in try withGuardedDelete(db, body: body) })
    try history.ensureSchema()
  }

  private static func createSupportingTables(in db: SQLiteDatabase) throws {
    try db.execute("""
      CREATE TABLE IF NOT EXISTS definition_heads (
        workflow_name TEXT PRIMARY KEY, current_version_id TEXT NOT NULL, last_file_version_id TEXT NOT NULL,
        revision INTEGER NOT NULL, source_directory TEXT NOT NULL, source_scope TEXT NOT NULL,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL)
      """)
    try db.execute("""
      CREATE TABLE IF NOT EXISTS definition_change_audit (
        created_order INTEGER PRIMARY KEY AUTOINCREMENT, audit_id TEXT NOT NULL UNIQUE,
        workflow_name TEXT NOT NULL, operation TEXT NOT NULL, version_id TEXT NOT NULL,
        previous_version_id TEXT, target_node_id TEXT, target_field TEXT, before_digest TEXT,
        after_digest TEXT NOT NULL, diff_json TEXT NOT NULL, reason TEXT NOT NULL CHECK (length(trim(reason)) > 0),
        evidence_refs_json TEXT NOT NULL, actor_kind TEXT NOT NULL, actor_id TEXT,
        approval_state TEXT NOT NULL, overwritten_changes_json TEXT, created_at TEXT NOT NULL)
      """)
    try db.execute("""
      CREATE TABLE IF NOT EXISTS definition_version_pins(
        workflow_name TEXT NOT NULL, history_version INTEGER NOT NULL, session_store_root TEXT NOT NULL,
        session_id TEXT NOT NULL, created_at TEXT NOT NULL,
        PRIMARY KEY(session_store_root, session_id, workflow_name))
      """)
    try db.execute("CREATE TABLE IF NOT EXISTS definition_retention_guard(id INTEGER PRIMARY KEY CHECK(id = 1))")
    try db.execute("CREATE TABLE IF NOT EXISTS definition_store_state(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    try db.execute("""
      CREATE TRIGGER IF NOT EXISTS definition_retention_guard_single
      BEFORE INSERT ON definition_retention_guard WHEN EXISTS(SELECT 1 FROM definition_retention_guard)
      BEGIN SELECT RAISE(ABORT, 'definition retention guard already active'); END
      """)
    try db.execute("CREATE TRIGGER IF NOT EXISTS definition_audit_no_update BEFORE UPDATE ON definition_change_audit BEGIN SELECT RAISE(ABORT, 'definition_change_audit is append-only'); END")
    try db.execute("""
      CREATE TRIGGER IF NOT EXISTS definition_audit_guarded_delete
      BEFORE DELETE ON definition_change_audit WHEN NOT EXISTS(SELECT 1 FROM definition_retention_guard)
      BEGIN SELECT RAISE(ABORT, 'definition audit delete requires retention guard'); END
      """)
  }

  private static func createVersionsTable(in db: SQLiteDatabase) throws {
    try db.execute("""
      CREATE TABLE IF NOT EXISTS definition_versions (
        version_id TEXT PRIMARY KEY, workflow_name TEXT NOT NULL, parent_version_id TEXT,
        document_digest TEXT NOT NULL, operation TEXT NOT NULL, source_directory TEXT NOT NULL,
        source_scope TEXT NOT NULL, provenance TEXT NOT NULL, actor_kind TEXT NOT NULL,
        actor_id TEXT, created_at TEXT NOT NULL, history_version INTEGER NOT NULL,
        UNIQUE(workflow_name, history_version))
      """)
  }

  private static func createVersionTriggers(in db: SQLiteDatabase) throws {
    try db.execute("""
      CREATE TRIGGER IF NOT EXISTS definition_versions_no_update BEFORE UPDATE ON definition_versions
      BEGIN SELECT RAISE(ABORT, 'definition_versions is append-only'); END
      """)
    try db.execute("""
      CREATE TRIGGER IF NOT EXISTS definition_versions_guarded_delete
      BEFORE DELETE ON definition_versions WHEN NOT EXISTS(SELECT 1 FROM definition_retention_guard)
      BEGIN SELECT RAISE(ABORT, 'definition version delete requires retention guard'); END
      """)
    try db.execute("""
      CREATE TRIGGER IF NOT EXISTS definition_history_guarded_delete
      BEFORE DELETE ON definition_history_versions WHEN NOT EXISTS(SELECT 1 FROM definition_retention_guard)
      BEGIN SELECT RAISE(ABORT, 'definition history delete requires retention guard'); END
      """)
  }

  private static func withGuardedDelete(_ db: SQLiteDatabase, body: () throws -> Void) throws {
    try db.execute("INSERT INTO definition_retention_guard(id) VALUES (1)")
    defer { try? db.execute("DELETE FROM definition_retention_guard WHERE id = 1") }
    try body()
  }

  private static func versionNumber(_ id: String, in db: SQLiteDatabase) throws -> Int? {
    try db.query("SELECT history_version FROM definition_versions WHERE version_id = ?", bindings: [.text(id)])
      .first?["history_version"].flatMap(Int.init)
  }

  private static func document(versionId: String, in db: SQLiteDatabase) throws -> Data? {
    try db.query("""
      SELECT blob.bytes AS bytes FROM definition_versions AS version
      JOIN definition_blobs AS blob ON blob.digest = version.document_digest
      WHERE version.version_id = ?
      """, bindings: [.text(versionId)]).first?.data("bytes")
  }

  private static func backfillSameStorePins(in db: SQLiteDatabase) throws {
    guard try db.tableExists("workflow_runtime_snapshots") else { return }
    let snapshots = try db.query("SELECT session_id, session_json FROM workflow_runtime_snapshots")
    for snapshot in snapshots {
      guard let data = snapshot.data("session_json"),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let source = object["definitionSource"] as? [String: Any], source["kind"] as? String == "store",
            let versionId = source["versionId"] as? String,
            let number = try versionNumber(versionId, in: db) else { continue }
      try db.execute("INSERT OR IGNORE INTO definition_version_pins(workflow_name, history_version, session_store_root, session_id, created_at) VALUES (?, ?, ?, ?, ?)",
        bindings: [.text(source["workflowName"] as? String ?? ""), .int(Int64(number)), .text(db.path ?? ""), .text(snapshot.string("session_id")), .text(source["createdAt"] as? String ?? "")])
    }
  }

  private static func applyDefaultRetention(in db: SQLiteDatabase, history: VersionedHistoryStore) throws {
    let names = try db.query("SELECT workflow_name, current_version_id FROM definition_heads")
    for row in names {
      let name = row.string("workflow_name")
      guard let number = try versionNumber(row.string("current_version_id"), in: db),
            let value = try document(versionId: row.string("current_version_id"), in: db) else { continue }
      let pins = try db.query("SELECT history_version FROM definition_version_pins WHERE workflow_name = ?", bindings: [.text(name)])
        .compactMap { $0["history_version"].flatMap(Int64.init) }
      let dropped = try history.applyRetention(key: name, currentHeadValue: value, retainedGenerations: 10, pins: Set(pins))
      try withGuardedDelete(db) {
        for version in dropped.dropped {
          try db.execute("DELETE FROM definition_versions WHERE workflow_name = ? AND history_version = ?", bindings: [.text(name), .int(version)])
        }
      }
      _ = number
    }
  }
}
