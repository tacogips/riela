import Foundation
import RielaSQLite

extension SQLiteWorkflowRuntimePersistenceStore {
  /// Frozen generation-10 definition-store schema. eh-02 preserves this shape
  /// so a 9 → 10 → 11 migration stays independent of future schema builders.
  static func createGeneration10DefinitionSchema(in database: SQLiteDatabase) throws {
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

  /// Bumped whenever the schema changes shape. When bumping, register an
  /// in-place upgrade step in `schemaMigrations` so existing stores are
  /// migrated instead of discarded.
  ///
  /// Generation 5 adds the Work Runtime's `work_*` tables to this same
  /// database file (`WorkStore` in `RielaWork` creates them behind this one
  /// guard). Generation 7 replaces generation 6's obsolete pending-request
  /// uniqueness with uniqueness over unconsumed requests only. No migration
  /// is registered for either shape: the Work Runtime design forbids backward
  /// compatibility, so `discardIncompatibleStoreIfNeeded` recreates them.
  /// Generation 11 adds shared definition history, definition pins and runtime execution rows.
  public static let schemaGeneration: Int64 = 11

  /// Ordered `from → from+1` upgrade steps for the session store database
  /// (covers the snapshot, message-log, CLI session, and Work Runtime tables —
  /// they share one file). Append a `SQLiteSchemaMigration(fromGeneration:)`
  /// here for every future `schemaGeneration` bump that is allowed to migrate.
  /// Stores stamped before generation 2 (the migration baseline), at generation
  /// 4 (the last pre-Work-Runtime shape), generation 5 (the P0-only Work
  /// Runtime shape), generation 6 (the obsolete P1 request shape), or generation
  /// 7 (the pre-decision-application-result shape) have no
  /// path and are discarded. P1 deliberately follows the Work Runtime's
  /// no-compatibility contract.
  public static let schemaMigrations: [SQLiteSchemaMigration] = [
    SQLiteSchemaMigration(fromGeneration: 2) { database in
      // Historical migrations must not call the current-schema builder:
      // generation 4 adds recovery_reason in the next migration.
      try createGeneration3NestedInvocationSchema(in: database)
    },
    SQLiteSchemaMigration(fromGeneration: 3) { database in
      try addGeneration4NestedRecoveryReason(in: database)
    },
    SQLiteSchemaMigration(fromGeneration: 9) { database in
      try createGeneration10DefinitionSchema(in: database)
    },
    SQLiteSchemaMigration(fromGeneration: 10) { database in
      try WorkflowDefinitionHistorySchema.migrateToGeneration11(in: database)
      try SQLiteRuntimeExecutionRowsSchema.migrateToGeneration11(in: database)
    }
  ]

  /// Brings the database up to the current schema generation: stamps fresh
  /// databases, migrates older stamped generations via `schemaMigrations`,
  /// and refuses databases without a migration path or written by a newer
  /// build. Throws SQLiteError so each store maps it into its own error
  /// domain.
  public static func requireCompatibleSchemaGeneration(in db: SQLiteDatabase) throws {
    do {
      try SQLiteSchemaMigrator.migrateIfNeeded(
        in: db,
        currentGeneration: schemaGeneration,
        migrations: schemaMigrations,
        preGenerationProbe: { db in
          try db.tableExists("workflow_runtime_snapshots")
            || db.tableExists("cli_workflow_sessions")
        },
        storeDescription: "session store"
      )
    } catch let error as SQLiteSchemaMigrator.MissingMigrationPathError {
      throw SQLiteError(
        operation: .execute,
        code: nil,
        message: "session store schema (generation \(error.stampedGeneration)) has no migration path to generation \(schemaGeneration); delete the session store and rerun"
      )
    } catch let error as SQLiteSchemaMigrator.NewerGenerationError {
      throw SQLiteError(
        operation: .execute,
        code: nil,
        message: "session store uses schema generation \(error.stampedGeneration); this build supports \(schemaGeneration)"
      )
    }
  }

  /// Deletes a session store database (plus its WAL/SHM sidecars) that is
  /// older than the current generation and has no registered migration path,
  /// so the writable open that follows rebuilds the current-generation schema
  /// from scratch. Session stores hold regenerable run history, so discarding
  /// beats hard-failing every writable open; routine and memory stores keep
  /// their hard error because their data is not regenerable. Migratable and
  /// newer-generation databases are left alone; unreadable databases are left
  /// for the normal open path to report.
  @discardableResult
  public static func discardIncompatibleStoreIfNeeded(databasePath: String) -> Bool {
    guard FileManager.default.fileExists(atPath: databasePath) else {
      return false
    }
    let isIncompatible: Bool
    do {
      let db = try SQLiteDatabase.open(path: databasePath, mode: .readOnly, options: .readOnlyDefault)
      isIncompatible = try WorkflowDefinitionStoreSchema.shouldDiscardIncompatibleStore(
        db, currentGeneration: schemaGeneration, migrations: schemaMigrations
      )
    } catch {
      return false
    }
    guard isIncompatible else {
      return false
    }
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: databasePath + suffix)
    }
    FileHandle.standardError.write(Data(
      "warning: discarded incompatible session store without a migration path at \(databasePath)\n".utf8
    ))
    return true
  }

  static func createNestedInvocationSchema(in db: SQLiteDatabase) throws {
    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS workflow_nested_invocations (
        invocation_key TEXT PRIMARY KEY,
        reservation_json BLOB NOT NULL CHECK (json_valid(reservation_json, 8)),
        child_terminal_json BLOB CHECK (child_terminal_json IS NULL OR json_valid(child_terminal_json, 8)),
        parent_message_json BLOB CHECK (parent_message_json IS NULL OR json_valid(parent_message_json, 8)),
        recovery_reason TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """
    )
    try db.execute(
      "CREATE INDEX IF NOT EXISTS idx_workflow_nested_invocations_child ON workflow_nested_invocations (json_extract(reservation_json, '$.childSnapshot.session.sessionId'))"
    )
  }

  func openDatabase(
    readOnly: Bool = false,
    strictReadOnly: Bool = false
  ) throws -> SQLiteDatabase {
    // Keep readers behind first-use compatibility checks too, so no process
    // can observe a database while another process replaces an incompatible
    // store or initializes its schema.
    let databasePath = Self.defaultDatabasePath(rootDirectory: rootDirectory)
    let schemaLock: DistributedStoreLock?
    if !strictReadOnly {
      let lock: DistributedStoreLock
      do {
        lock = try DistributedStoreLock(url: URL(fileURLWithPath: rootDirectory, isDirectory: true)
          .appendingPathComponent(".riela/runtime-schema.lock"))
        try lock.acquire()
      } catch {
        throw WorkflowRuntimePersistenceStoreError.sqliteFailed(
          "failed to open sqlite database at \(databasePath): \(error.localizedDescription)"
        )
      }
      schemaLock = lock
    } else {
      schemaLock = nil
    }
    defer { schemaLock?.release() }
    if !readOnly, !strictReadOnly { Self.discardIncompatibleStoreIfNeeded(databasePath: databasePath) }
    let mode: SQLiteOpenMode
    if strictReadOnly {
      mode = .strictReadOnlyWithImmutableFallback
    } else {
      mode = readOnly ? .readOnly : .readWriteCreate
    }
    return try mapRuntimeSQLiteError {
      var options = readOnly ? SQLiteOpenOptions.readOnlyDefault : SQLiteOpenOptions.writableRuntimeStoreDefault
      options.trackStatementWork = !readOnly && measuresSQLiteStatementWork
      let database = try SQLiteDatabase.open(
        path: databasePath,
        mode: mode,
        options: options
      )
      if !readOnly && !strictReadOnly {
        // Serialize the destructive compatibility probe with first creation,
        // migration and schema setup so peers cannot unlink a partial database.
        try prepareSchema(in: database)
        // The assembly table is transient, not another durable journal.
        // Avoid duplicating it on the guest's size-limited tmpfs volume.
        try database.execute("PRAGMA temp_store = MEMORY")
      }
      return database
    }
  }
}
