import Foundation
import RielaSQLite
import RielaMemory

enum WorkflowDefinitionHistorySchema {
  static let pinBackfillByteLimit: Int64 = 268_435_456

  static func migrateToGeneration11(in db: SQLiteDatabase, pinBackfillByteLimit: Int64 = pinBackfillByteLimit) throws {
    let history = VersionedHistoryStore(tablePrefix: "definition", headStorage: .stored,
      sql: SQLiteDatabaseHistoryExecutor(database: db), withGuardedDelete: { body in try withGuardedDelete(db, body: body) })
    try history.ensureSchema()
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
    try db.execute("""
      INSERT OR IGNORE INTO definition_version_identities(version_id, workflow_name, history_version, created_at)
      SELECT version_id, workflow_name, history_version, created_at FROM definition_versions
      """)
    try createVersionTriggers(in: db)
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
    try db.execute("CREATE INDEX IF NOT EXISTS definition_versions_document_digest ON definition_versions(document_digest)")
    try db.execute("CREATE INDEX IF NOT EXISTS definition_version_pins_workflow_history ON definition_version_pins(workflow_name, history_version)")
    let snapshotBytes = try payloadByteCount(in: db, table: "workflow_runtime_snapshots", column: "session_json")
    let cliBytes = try payloadByteCount(in: db, table: "cli_workflow_sessions", column: "record_json")
    if snapshotBytes + cliBytes <= pinBackfillByteLimit {
      try backfillSameStorePins(in: db)
      try backfillCLIPins(in: db)
      try applyDefaultRetention(in: db, history: history, defaultHistoryRetention: 10)
      try db.execute("INSERT OR REPLACE INTO definition_store_state(key, value) VALUES ('retention', 'active')")
    } else {
      try db.execute("INSERT OR REPLACE INTO definition_store_state(key, value) VALUES ('retention', 'pendingBackfill')")
    }
  }

  static func create(in db: SQLiteDatabase) throws {
    let history = VersionedHistoryStore(tablePrefix: "definition", headStorage: .stored,
      sql: SQLiteDatabaseHistoryExecutor(database: db), withGuardedDelete: { body in try withGuardedDelete(db, body: body) })
    try history.ensureSchema()
    try createSupportingTables(in: db)
    try createVersionsTable(in: db)
    try createVersionTriggers(in: db)
    try db.execute("CREATE INDEX IF NOT EXISTS definition_versions_workflow_created ON definition_versions(workflow_name, created_at)")
    try db.execute("CREATE INDEX IF NOT EXISTS definition_versions_document_digest ON definition_versions(document_digest)")
    try db.execute("CREATE INDEX IF NOT EXISTS definition_version_pins_workflow_history ON definition_version_pins(workflow_name, history_version)")
    try db.execute("CREATE INDEX IF NOT EXISTS definition_audit_workflow_order ON definition_change_audit(workflow_name, created_order)")
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
      CREATE TABLE IF NOT EXISTS definition_version_identities(
        version_id TEXT PRIMARY KEY, workflow_name TEXT NOT NULL, history_version INTEGER NOT NULL,
        created_at TEXT NOT NULL, UNIQUE(workflow_name, history_version))
      """)
    try db.execute("CREATE INDEX IF NOT EXISTS definition_version_identities_workflow ON definition_version_identities(workflow_name, history_version)")
    try db.execute("""
      CREATE TRIGGER IF NOT EXISTS definition_version_identities_no_update BEFORE UPDATE ON definition_version_identities
      BEGIN SELECT RAISE(ABORT, 'definition version identities are immutable'); END
      """)
    try db.execute("""
      CREATE TRIGGER IF NOT EXISTS definition_version_identities_no_delete BEFORE DELETE ON definition_version_identities
      BEGIN SELECT RAISE(ABORT, 'definition version identities are immutable'); END
      """)
    try db.execute("""
      CREATE TRIGGER IF NOT EXISTS definition_retention_guard_single
      BEFORE INSERT ON definition_retention_guard WHEN EXISTS(SELECT 1 FROM definition_retention_guard)
      BEGIN SELECT RAISE(ABORT, 'definition retention guard already active'); END
      """)
    try db.execute("CREATE TRIGGER IF NOT EXISTS definition_audit_no_update BEFORE UPDATE ON definition_change_audit BEGIN SELECT RAISE(ABORT, 'definition_change_audit is append-only'); END")
    try db.execute("""
      CREATE TRIGGER IF NOT EXISTS definition_audit_no_replace BEFORE INSERT ON definition_change_audit
      WHEN EXISTS(SELECT 1 FROM definition_change_audit WHERE audit_id=NEW.audit_id OR created_order=NEW.created_order)
      BEGIN SELECT RAISE(ABORT, 'definition audit rows cannot be replaced'); END
      """)
    try db.execute("""
      CREATE TRIGGER IF NOT EXISTS definition_audit_guarded_delete
      BEFORE DELETE ON definition_change_audit WHEN NOT EXISTS(SELECT 1 FROM definition_retention_guard)
      BEGIN SELECT RAISE(ABORT, 'definition audit delete requires retention guard'); END
      """)
    try db.execute("CREATE TRIGGER IF NOT EXISTS definition_heads_no_delete BEFORE DELETE ON definition_heads BEGIN SELECT RAISE(ABORT, 'definition heads cannot be deleted'); END")
    try db.execute("CREATE TRIGGER IF NOT EXISTS definition_history_heads_no_delete BEFORE DELETE ON definition_history_heads BEGIN SELECT RAISE(ABORT, 'definition history heads cannot be deleted'); END")
    try db.execute("""
      CREATE TRIGGER IF NOT EXISTS definition_identities_no_replace BEFORE INSERT ON definition_version_identities
      WHEN EXISTS(SELECT 1 FROM definition_version_identities WHERE version_id=NEW.version_id OR
        (workflow_name=NEW.workflow_name AND history_version=NEW.history_version))
      BEGIN SELECT RAISE(ABORT, 'definition identities cannot be replaced'); END
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
      CREATE TRIGGER IF NOT EXISTS definition_versions_no_replace BEFORE INSERT ON definition_versions
      WHEN EXISTS(SELECT 1 FROM definition_versions WHERE version_id=NEW.version_id OR
        (workflow_name=NEW.workflow_name AND history_version=NEW.history_version))
      BEGIN SELECT RAISE(ABORT, 'definition versions cannot be replaced'); END
      """)
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
    try db.execute("""
      CREATE TRIGGER IF NOT EXISTS definition_history_no_replace BEFORE INSERT ON definition_history_versions
      WHEN EXISTS(SELECT 1 FROM definition_history_versions WHERE key=NEW.key AND version=NEW.version)
      BEGIN SELECT RAISE(ABORT, 'definition history versions cannot be replaced'); END
      """)
  }

  static func withGuardedDelete(_ db: SQLiteDatabase, body: () throws -> Void) throws {
    try db.execute("INSERT INTO definition_retention_guard(id) VALUES (1)")
    defer { try? db.execute("DELETE FROM definition_retention_guard WHERE id = 1") }
    try body()
  }

  static func deleteDroppedVersionsAndOrphanAudit(_ droppedVersions: [Int64], workflowName: String,
                                                  in db: SQLiteDatabase) throws {
    try withGuardedDelete(db) {
      for version in droppedVersions {
        try db.execute("DELETE FROM definition_versions WHERE workflow_name = ? AND history_version = ?",
          bindings: [.text(workflowName), .int(version)])
      }
      try db.execute("""
        DELETE FROM definition_change_audit WHERE workflow_name = ?
          AND version_id NOT IN (SELECT version_id FROM definition_versions)
          AND (previous_version_id IS NULL OR previous_version_id NOT IN (SELECT version_id FROM definition_versions))
        """, bindings: [.text(workflowName)])
    }
  }

  private static func versionNumber(_ id: String, in db: SQLiteDatabase) throws -> Int? {
    try db.query("SELECT history_version FROM definition_versions WHERE version_id = ?", bindings: [.text(id)])
      .first?["history_version"].flatMap(Int.init)
  }

  static func protectedHistoryVersions(in db: SQLiteDatabase, workflowName: String, currentVersionId: String,
                                       lastFileVersionId: String, cutoff: String) throws -> Set<Int64> {
    let ids = try db.query("SELECT history_version FROM definition_versions WHERE workflow_name = ? AND version_id IN (?, ?)",
      bindings: [.text(workflowName), .text(currentVersionId), .text(lastFileVersionId)])
    var versions = Set(ids.compactMap { $0["history_version"].flatMap(Int64.init) })
    let pins = try db.query("SELECT history_version FROM definition_version_pins WHERE workflow_name = ?", bindings: [.text(workflowName)])
    versions.formUnion(pins.compactMap { $0["history_version"].flatMap(Int64.init) })
    let recent = try db.query("""
      SELECT DISTINCT version.history_version FROM definition_change_audit audit
      JOIN definition_versions version ON version.version_id = audit.previous_version_id
      WHERE audit.workflow_name = ? AND audit.created_at > ?
      """, bindings: [.text(workflowName), .text(cutoff)])
    versions.formUnion(recent.compactMap { $0["history_version"].flatMap(Int64.init) })
    return versions
  }

  private static func document(versionId: String, in db: SQLiteDatabase) throws -> Data? {
    try db.query("""
      SELECT blob.bytes AS bytes FROM definition_versions AS version
      JOIN definition_blobs AS blob ON blob.digest = version.document_digest
      WHERE version.version_id = ?
      """, bindings: [.text(versionId)]).first?.data("bytes")
  }

  static func backfillSameStorePinsForMaintenance(in db: SQLiteDatabase) throws {
    try backfillSameStorePins(in: db)
    try backfillCLIPins(in: db)
  }

  private static func backfillSameStorePins(in db: SQLiteDatabase) throws {
    guard try db.tableExists("workflow_runtime_snapshots") else { return }
    let snapshots = try db.query("SELECT workflow_execution_id, json(session_json) AS session_json, created_at FROM workflow_runtime_snapshots")
    for snapshot in snapshots {
      guard let data = snapshot.data("session_json"),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let source = object["definitionSource"] as? [String: Any], source["kind"] as? String == "store",
            let versionId = source["versionId"] as? String,
            let workflowName = source["workflowName"] as? String,
            source["storeRoot"] == nil || source["storeRoot"] is NSNull ||
              normalizedDatabasePath(rootDirectory: source["storeRoot"] as? String ?? db.path ?? "") == normalizedPath(db.path ?? ""),
            let number = try versionNumber(versionId, in: db) else { continue }
      try db.execute("INSERT OR IGNORE INTO definition_version_pins(workflow_name, history_version, session_store_root, session_id, created_at) VALUES (?, ?, ?, ?, ?)",
        bindings: [.text(workflowName), .int(Int64(number)), .text(storeRootForDatabasePath(db.path ?? "")),
          .text(snapshot.string("workflow_execution_id")), .text(snapshot.string("created_at"))])
    }
  }

  private static func backfillCLIPins(in db: SQLiteDatabase) throws {
    guard try db.tableExists("cli_workflow_sessions") else { return }
    let records = try db.query("SELECT session_id, json(record_json) AS record_json, " +
      "coalesce(json_extract(record_json, '$.session.createdAt'), '') AS created_at FROM cli_workflow_sessions")
    for record in records {
      guard let data = record.data("record_json"),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
      let session = object["session"] as? [String: Any] ?? object
      guard let source = session["definitionSource"] as? [String: Any], source["kind"] as? String == "store",
            let workflow = source["workflowName"] as? String, let versionId = source["versionId"] as? String,
            source["storeRoot"] == nil || source["storeRoot"] is NSNull ||
              normalizedDatabasePath(rootDirectory: source["storeRoot"] as? String ?? "") == normalizedPath(db.path ?? ""),
            let number = try versionNumber(versionId, in: db) else { continue }
      try db.execute("INSERT OR IGNORE INTO definition_version_pins(workflow_name,history_version,session_store_root,session_id,created_at) VALUES(?,?,?,?,?)",
        bindings: [.text(workflow), .int(Int64(number)), .text(storeRootForDatabasePath(db.path ?? "")),
                   .text(record.string("session_id")), .text(record.string("created_at"))])
    }
  }

  private static func payloadByteCount(in db: SQLiteDatabase, table: String, column: String) throws -> Int64 {
    guard try db.tableExists(table) else { return 0 }
    return try db.query("SELECT COALESCE(SUM(length(\(column))), 0) AS bytes FROM \(table)")
      .first?["bytes"].flatMap(Int64.init) ?? 0
  }

  private static func applyDefaultRetention(in db: SQLiteDatabase, history: VersionedHistoryStore,
                                            defaultHistoryRetention: Int) throws {
    let names = try db.query("SELECT workflow_name, current_version_id, last_file_version_id FROM definition_heads")
    for row in names {
      let name = row.string("workflow_name")
      guard let number = try versionNumber(row.string("current_version_id"), in: db) else { continue }
      _ = try history.value(key: name, version: Int64(number), currentHeadValue: nil)
      let cutoff = canonicalDate(Date().addingTimeInterval(-24 * 60 * 60))
      let pins = try protectedHistoryVersions(in: db, workflowName: name,
        currentVersionId: row.string("current_version_id"), lastFileVersionId: row.string("last_file_version_id"), cutoff: cutoff)
      let saved = try db.query("SELECT retained_generations FROM definition_history_heads WHERE key = ?", bindings: [.text(name)])
        .first?["retained_generations"].flatMap(Int.init)
      let dropped = try history.applyRetention(key: name, currentHeadValue: nil,
        retainedGenerations: saved ?? defaultHistoryRetention, pins: pins)
      try deleteDroppedVersionsAndOrphanAudit(dropped.dropped, workflowName: name, in: db)
      if saved == nil {
        try db.execute("UPDATE definition_history_heads SET retained_generations = NULL WHERE key = ?", bindings: [.text(name)])
      }
    }
  }

  private static func canonicalDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private static func normalizedDatabasePath(rootDirectory: String) -> String {
    let path = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: rootDirectory)
    return normalizedPath(path)
  }

  private static func normalizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }

  private static func storeRootForDatabasePath(_ path: String) -> String {
    URL(fileURLWithPath: path).deletingLastPathComponent()
      .standardizedFileURL.resolvingSymlinksInPath().path
  }
}
