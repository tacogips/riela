import Foundation
import RielaSQLite

public enum NoteStoreSchemaError: Error, Equatable, Sendable {
  case unsupportedFutureVersion(found: Int, supported: Int)
}

public enum NoteStoreSchema {
  public static let currentVersion = 4
  public static let autoTaggingWorkflowId = "note-auto-tagging"

  public static func prepare(on driver: NoteDatabaseDriving) throws {
    try driver.withDatabase { database in
      try prepare(in: database)
    }
  }

  public static func prepare(in database: SQLiteDatabase) throws {
    try NoteSQLiteCapabilityCache.requireAvailable(in: database)
    try database.execute(noteSchemaVersionTableStatement)
    try rejectUnsupportedFutureVersion(in: database)
    let appliedVersions = try appliedSchemaVersions(in: database)
    let isFirstSchemaCreation = appliedVersions.isEmpty
    try database.transaction { db in
      for statement in schemaStatements {
        try db.execute(statement)
      }
      try applySchemaMigrations(appliedVersions: appliedVersions, in: db)
      try ensureNoteFTSUsesTrigram(in: db)
      try seedTagClasses(in: db)
      try seedNotebookKindTags(in: db)
      if isFirstSchemaCreation {
        try seedAutoActions(in: db)
      }
    }
  }

  public static func seededTagClassIds(in database: SQLiteDatabase) throws -> [String] {
    try database.query("SELECT class_id FROM tag_classes ORDER BY class_id").compactMap { $0["class_id"] }
  }

  private static func seedTagClasses(in database: SQLiteDatabase) throws {
    for seed in systemTagClasses {
      try database.execute(
        """
        INSERT INTO tag_classes (class_id, label, description, is_system, created_at)
        VALUES (?, ?, ?, 1, ?)
        ON CONFLICT(class_id) DO NOTHING
        """,
        bindings: [
          .text(seed.classId),
          .text(seed.label),
          .optionalText(seed.description),
          .text(NoteStoreClock.system.now())
        ]
      )
    }
  }

  private static func seedNotebookKindTags(in database: SQLiteDatabase) throws {
    for tagName in systemNotebookKindTags {
      try database.execute(
        """
        INSERT INTO tags (tag_id, name, class_id, is_system, created_at)
        VALUES (?, ?, 'document-kind', 1, ?)
        ON CONFLICT(name) DO NOTHING
        """,
        bindings: [
          .text(stableTagId(for: tagName)),
          .text(tagName),
          .text(NoteStoreClock.system.now())
        ]
      )
    }
  }

  private static func seedAutoActions(in database: SQLiteDatabase) throws {
    for trigger in [NoteAutoActionTrigger.noteCreated, .noteUpdated] {
      try database.execute(
        """
        INSERT INTO auto_actions (
          action_id, trigger, workflow_id, filter_json, enabled, position, created_at
        ) VALUES (?, ?, ?, NULL, 1, 0, ?)
        ON CONFLICT(action_id) DO NOTHING
        """,
        bindings: [
          .text("default-ai-tagging-\(trigger.rawValue)"),
          .text(trigger.rawValue),
          .text(autoTaggingWorkflowId),
          .text(NoteStoreClock.system.now())
        ]
      )
    }
  }

  private static func stableTagId(for name: String) -> String {
    name
      .replacingOccurrences(of: ":", with: "-")
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: " ", with: "-")
  }

  private static func rejectUnsupportedFutureVersion(in database: SQLiteDatabase) throws {
    let rows = try database.query("SELECT MAX(version) AS version FROM note_schema_version")
    guard let rawVersion = rows.first?["version"], let version = Int(rawVersion), version > currentVersion else {
      return
    }
    throw NoteStoreSchemaError.unsupportedFutureVersion(found: version, supported: currentVersion)
  }

  private static func appliedSchemaVersions(in database: SQLiteDatabase) throws -> Set<Int> {
    let rows = try database.query("SELECT version FROM note_schema_version")
    return Set(rows.compactMap { row in
      row["version"].flatMap(Int.init)
    })
  }

  private static func applySchemaMigrations(appliedVersions: Set<Int>, in database: SQLiteDatabase) throws {
    let migrationsToApply: [NoteSchemaMigration]
    if appliedVersions.isEmpty {
      migrationsToApply = schemaMigrations
    } else {
      migrationsToApply = schemaMigrations.filter { !appliedVersions.contains($0.version) }
    }
    for migration in migrationsToApply {
      try migration.apply(database)
      try recordSchemaVersion(migration.version, in: database)
    }
    if appliedVersions.isEmpty {
      try recordSchemaVersion(1, in: database)
    }
  }

  private static func recordSchemaVersion(_ version: Int, in database: SQLiteDatabase) throws {
    try database.execute(
      """
      INSERT INTO note_schema_version (version, applied_at)
      VALUES (?, ?)
      ON CONFLICT(version) DO NOTHING
      """,
      bindings: [
        .int(Int64(version)),
        .text(NoteStoreClock.system.now())
      ]
    )
  }

  private static func ensureNoteFTSUsesTrigram(in database: SQLiteDatabase) throws {
    let rows = try database.query(
      "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'note_fts' LIMIT 1"
    )
    let createSQL = rows.first?["sql"] ?? ""
    guard !createSQL.lowercased().contains("tokenize='trigram'") else {
      return
    }
    try database.execute("DROP TABLE IF EXISTS note_fts")
    try database.execute("""
      CREATE VIRTUAL TABLE note_fts USING fts5(
        title, body, tags,
        content='',
        tokenize='trigram'
      )
      """)
    try database.execute("DELETE FROM note_fts_map")
    let noteIds = try database.query("SELECT note_id FROM notes ORDER BY created_at, note_id").compactMap { $0["note_id"] }
    for noteId in noteIds {
      try refreshFTS(noteId: noteId, previous: nil, in: database)
    }
  }

  fileprivate static func migrateToV2(in database: SQLiteDatabase) throws {
    try ensureNoteFTSUsesTrigram(in: database)
  }

  fileprivate static func migrateToV3(in database: SQLiteDatabase) throws {
    let rows = try database.query(
      """
      SELECT sql
      FROM sqlite_master
      WHERE type = 'table' AND name = 'auto_action_dispatches'
      LIMIT 1
      """
    )
    guard let createSQL = rows.first?["sql"],
          !createSQL.contains("'in_flight'") else {
      return
    }
    try database.execute("ALTER TABLE auto_action_dispatches RENAME TO auto_action_dispatches_v2")
    try database.execute(autoActionDispatchesTableStatement)
    try database.execute(
      """
      INSERT INTO auto_action_dispatches (
        dispatch_id, action_id, action_trigger, workflow_id, filter_json,
        action_enabled, action_position, action_created_at, event_json,
        status, attempt_count, last_error, created_at, updated_at
      )
      SELECT dispatch_id, action_id, action_trigger, workflow_id, filter_json,
        action_enabled, action_position, action_created_at, event_json,
        CASE WHEN status = 'in_flight' THEN 'pending' ELSE status END,
        attempt_count, last_error, created_at, updated_at
      FROM auto_action_dispatches_v2
      """
    )
    try database.execute("DROP TABLE auto_action_dispatches_v2")
    try database.execute(autoActionDispatchesStatusIndexStatement)
  }

  fileprivate static func migrateToV4(in database: SQLiteDatabase) throws {
    if try !columnExists("parent_tag_id", in: "tags", database: database) {
      try database.execute(
        "ALTER TABLE tags ADD COLUMN parent_tag_id TEXT REFERENCES tags(tag_id)"
      )
    }
    if try !columnExists("progress", in: "notebooks", database: database) {
      try database.execute(
        """
        ALTER TABLE notebooks
        ADD COLUMN progress TEXT NOT NULL DEFAULT 'none'
          CHECK (progress IN ('none','progress','done','pending'))
        """
      )
    }
  }

  private static func columnExists(
    _ columnName: String,
    in tableName: String,
    database: SQLiteDatabase
  ) throws -> Bool {
    try database.query("PRAGMA table_info(\(tableName))")
      .contains { $0["name"] == columnName }
  }
}

private struct NoteSchemaMigration: Sendable {
  var version: Int
  var apply: @Sendable (SQLiteDatabase) throws -> Void
}

private let schemaMigrations: [NoteSchemaMigration] = [
  NoteSchemaMigration(version: 2, apply: NoteStoreSchema.migrateToV2),
  NoteSchemaMigration(version: 3, apply: NoteStoreSchema.migrateToV3),
  NoteSchemaMigration(version: 4, apply: NoteStoreSchema.migrateToV4)
]

final class NoteSQLiteCapabilityCache: @unchecked Sendable {
  private static let shared = NoteSQLiteCapabilityCache()

  private let lock = NSLock()
  private var didVerify = false
  private var probeRunCount = 0

  private init() {}

  static func requireAvailable(in database: SQLiteDatabase) throws {
    try shared.requireAvailable(in: database)
  }

  private func requireAvailable(in database: SQLiteDatabase) throws {
    lock.lock()
    defer {
      lock.unlock()
    }
    guard !didVerify else {
      return
    }

    try database.requireJSONBAvailable()
    try database.requireFTS5Available()
    try database.requireFTS5TrigramAvailable()

    didVerify = true
    probeRunCount += 1
  }

  static func resetForTesting() {
    shared.resetForTesting()
  }

  private func resetForTesting() {
    lock.lock()
    defer {
      lock.unlock()
    }
    didVerify = false
    probeRunCount = 0
  }

  static func probeRunCountForTesting() -> Int {
    shared.probeRunCountForTesting()
  }

  private func probeRunCountForTesting() -> Int {
    lock.lock()
    defer {
      lock.unlock()
    }
    return probeRunCount
  }
}

private struct SystemTagClass {
  var classId: String
  var label: String
  var description: String?
}

private let systemTagClasses: [SystemTagClass] = [
  SystemTagClass(classId: "content-kind", label: "Content Kind", description: "Content-level note kinds"),
  SystemTagClass(classId: "person", label: "Person", description: "People and named actors"),
  SystemTagClass(classId: "year", label: "Year", description: "Years and historical periods"),
  SystemTagClass(classId: "event", label: "Event", description: "Events and milestones"),
  SystemTagClass(classId: "document-kind", label: "Document Kind", description: "Notebook or document kinds"),
  SystemTagClass(classId: "topic", label: "Topic", description: "Conceptual topics"),
  SystemTagClass(classId: "folder", label: "Folder", description: "Notebook organization folders"),
  SystemTagClass(classId: "source", label: "Source", description: "Original source types and references"),
  SystemTagClass(classId: "workflow", label: "Workflow", description: "Workflow-originated processing tags")
]

private let systemNotebookKindTags = [
  "notebook-kind:imported-material",
  "notebook-kind:agent-conversation",
  "notebook-kind:user-memo"
]

private let noteSchemaVersionTableStatement = """
  CREATE TABLE IF NOT EXISTS note_schema_version (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL
  )
  """

private let schemaStatements = [
  """
  CREATE TABLE IF NOT EXISTS notebooks (
    notebook_id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    progress TEXT NOT NULL DEFAULT 'none'
      CHECK (progress IN ('none','progress','done','pending')),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    meta_json BLOB CHECK (meta_json IS NULL OR json_valid(meta_json, 8))
  )
  """,
  """
  CREATE TABLE IF NOT EXISTS notes (
    note_id TEXT PRIMARY KEY,
    notebook_id TEXT NOT NULL REFERENCES notebooks(notebook_id),
    note_number INTEGER NOT NULL,
    title TEXT,
    title_source TEXT NOT NULL DEFAULT 'derived' CHECK (title_source IN ('derived','explicit')),
    body_markdown TEXT NOT NULL,
    read_only INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    meta_json BLOB CHECK (meta_json IS NULL OR json_valid(meta_json, 8)),
    UNIQUE (notebook_id, note_number)
  )
  """,
  "CREATE INDEX IF NOT EXISTS idx_notes_notebook ON notes(notebook_id, note_number)",
  "CREATE INDEX IF NOT EXISTS idx_notes_created ON notes(created_at DESC)",
  """
  CREATE TABLE IF NOT EXISTS tag_classes (
    class_id TEXT PRIMARY KEY,
    label TEXT NOT NULL,
    description TEXT,
    is_system INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
  )
  """,
  """
  CREATE TABLE IF NOT EXISTS tags (
    tag_id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    class_id TEXT REFERENCES tag_classes(class_id),
    parent_tag_id TEXT REFERENCES tags(tag_id),
    is_system INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
  )
  """,
  """
  CREATE TABLE IF NOT EXISTS note_tags (
    note_id TEXT NOT NULL REFERENCES notes(note_id),
    tag_id TEXT NOT NULL REFERENCES tags(tag_id),
    provenance TEXT NOT NULL CHECK (provenance IN ('human','ai','system')),
    assigned_by TEXT,
    deletable INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    PRIMARY KEY (note_id, tag_id)
  )
  """,
  """
  CREATE TABLE IF NOT EXISTS notebook_tags (
    notebook_id TEXT NOT NULL REFERENCES notebooks(notebook_id),
    tag_id TEXT NOT NULL REFERENCES tags(tag_id),
    provenance TEXT NOT NULL CHECK (provenance IN ('human','ai','system')),
    assigned_by TEXT,
    deletable INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    PRIMARY KEY (notebook_id, tag_id)
  )
  """,
  """
  CREATE TABLE IF NOT EXISTS files (
    file_id TEXT PRIMARY KEY,
    storage_kind TEXT NOT NULL CHECK (storage_kind IN ('local','s3')),
    local_path TEXT,
    s3_profile TEXT,
    s3_bucket TEXT,
    s3_key TEXT,
    media_type TEXT NOT NULL,
    byte_size INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    original_filename TEXT,
    created_at TEXT NOT NULL,
    migrated_at TEXT,
    CHECK (
      (storage_kind = 'local' AND local_path IS NOT NULL)
      OR (
        storage_kind = 's3'
        AND s3_profile IS NOT NULL
        AND s3_bucket IS NOT NULL
        AND s3_key IS NOT NULL
      )
    )
  )
  """,
  "CREATE INDEX IF NOT EXISTS idx_files_sha ON files(sha256)",
  """
  CREATE TABLE IF NOT EXISTS note_files (
    note_id TEXT NOT NULL REFERENCES notes(note_id),
    file_id TEXT NOT NULL REFERENCES files(file_id),
    role TEXT NOT NULL CHECK (role IN ('embedded','related','source-page-image')),
    position INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (note_id, file_id, role)
  )
  """,
  """
  CREATE TABLE IF NOT EXISTS notebook_files (
    notebook_id TEXT NOT NULL REFERENCES notebooks(notebook_id),
    file_id TEXT NOT NULL REFERENCES files(file_id),
    role TEXT NOT NULL CHECK (role IN ('source-document','related')),
    PRIMARY KEY (notebook_id, file_id, role)
  )
  """,
  """
  CREATE TABLE IF NOT EXISTS note_links (
    from_note_id TEXT NOT NULL REFERENCES notes(note_id),
    to_note_id TEXT NOT NULL REFERENCES notes(note_id),
    link_kind TEXT NOT NULL DEFAULT 'related',
    provenance TEXT NOT NULL CHECK (provenance IN ('human','ai','system')),
    created_at TEXT NOT NULL,
    PRIMARY KEY (from_note_id, to_note_id, link_kind)
  )
  """,
  """
  CREATE TABLE IF NOT EXISTS note_comments (
    comment_id TEXT PRIMARY KEY,
    note_id TEXT NOT NULL REFERENCES notes(note_id),
    body_markdown TEXT NOT NULL,
    author TEXT NOT NULL,
    created_at TEXT NOT NULL
  )
  """,
  """
  CREATE TABLE IF NOT EXISTS auto_actions (
    action_id TEXT PRIMARY KEY,
    trigger TEXT NOT NULL CHECK (trigger IN ('note-created','note-updated','notebook-created')),
    workflow_id TEXT NOT NULL,
    filter_json BLOB CHECK (filter_json IS NULL OR json_valid(filter_json, 8)),
    enabled INTEGER NOT NULL DEFAULT 1,
    position INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
  )
  """,
  autoActionDispatchesTableStatement,
  autoActionDispatchesStatusIndexStatement,
  """
  CREATE TABLE IF NOT EXISTS api_clients (
    client_id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    token_hash TEXT NOT NULL,
    created_at TEXT NOT NULL,
    last_seen_at TEXT,
    revoked_at TEXT
  )
  """,
  """
  CREATE VIRTUAL TABLE IF NOT EXISTS note_fts USING fts5(
    title, body, tags,
    content='',
    tokenize='trigram'
  )
  """,
  """
  CREATE TABLE IF NOT EXISTS note_fts_map (
    fts_rowid INTEGER PRIMARY KEY,
    note_id TEXT NOT NULL UNIQUE
  )
  """
]

private let autoActionDispatchesTableStatement = """
  CREATE TABLE IF NOT EXISTS auto_action_dispatches (
    dispatch_id TEXT PRIMARY KEY,
    action_id TEXT NOT NULL,
    action_trigger TEXT NOT NULL CHECK (action_trigger IN ('note-created','note-updated','notebook-created')),
    workflow_id TEXT NOT NULL,
    filter_json BLOB CHECK (filter_json IS NULL OR json_valid(filter_json, 8)),
    action_enabled INTEGER NOT NULL,
    action_position INTEGER NOT NULL,
    action_created_at TEXT NOT NULL,
    event_json BLOB NOT NULL CHECK (json_valid(event_json, 8)),
    status TEXT NOT NULL CHECK (status IN ('pending','in_flight','dispatched')),
    attempt_count INTEGER NOT NULL DEFAULT 0,
    lease_token TEXT,
    leased_at TEXT,
    last_error TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )
  """

private let autoActionDispatchesStatusIndexStatement =
  "CREATE INDEX IF NOT EXISTS idx_auto_action_dispatches_status ON auto_action_dispatches(status, created_at)"

struct NoteStoreClock: Sendable {
  var now: @Sendable () -> String

  static let system = NoteStoreClock {
    noteStoreTimestampFormatter.string(from: Date())
  }
}

private let noteStoreTimestampFormatter = NoteStoreTimestampFormatter()

private final class NoteStoreTimestampFormatter: @unchecked Sendable {
  private let formatter: ISO8601DateFormatter
  private let lock = NSLock()

  init() {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    self.formatter = formatter
  }

  func string(from date: Date) -> String {
    lock.lock()
    defer {
      lock.unlock()
    }
    return formatter.string(from: date)
  }
}
