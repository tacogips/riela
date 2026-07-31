import Foundation
@testable import RielaNote
#if RIELA_NOTE_LIBSQL_TESTS
import RielaNoteLibSQL
#endif
import RielaSQLite
import XCTest

class NoteTestCase: XCTestCase {
  override func tearDownWithError() throws {
    try super.tearDownWithError()
    try removeCurrentNoteTestRoot()
  }

  private func removeCurrentNoteTestRoot() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/RielaNoteTests", isDirectory: true)
      .appendingPathComponent(currentTestFunctionName, isDirectory: true)
    if FileManager.default.fileExists(atPath: root.path) {
      try FileManager.default.removeItem(at: root)
    }
  }

  private var currentTestFunctionName: String {
    var candidate = name
    if let last = candidate.split(separator: " ").last {
      candidate = String(last)
    }
    if let last = candidate.split(separator: "/").last {
      candidate = String(last)
    }
    return candidate
      .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      .replacingOccurrences(of: "()", with: "")
  }
}

final class NoteStoreSchemaTests: NoteTestCase {
  func testPrepareCreatesSchemaAndSeedsRowsIdempotently() throws {
    let driver = try makeNoteDriver()

    try NoteStoreSchema.prepare(on: driver)
    try NoteStoreSchema.prepare(on: driver)

    try driver.withDatabase { database in
      XCTAssertTrue(try database.tableExists("notebooks"))
      XCTAssertTrue(try database.tableExists("notes"))
      XCTAssertTrue(try database.tableExists("note_fts_map"))
      XCTAssertEqual(
        try NoteStoreSchema.seededTagClassIds(in: database),
        ["content-kind", "document-kind", "event", "folder", "person", "source", "topic", "workflow", "year"]
      )

      let kindTags = try database.query(
        """
        SELECT name
        FROM tags
        WHERE is_system = 1 AND name LIKE 'notebook-kind:%'
        ORDER BY name
        """
      ).compactMap { $0["name"] }
      XCTAssertEqual(
        kindTags,
        [
          "notebook-kind:agent-conversation",
          "notebook-kind:imported-material",
          "notebook-kind:system-memory",
          "notebook-kind:user-memo"
        ]
      )

      let autoActions = try database.query("SELECT trigger, workflow_id FROM auto_actions ORDER BY trigger")
      XCTAssertEqual(autoActions.map { $0["trigger"] }, ["note-created", "note-updated"])
      XCTAssertTrue(autoActions.allSatisfy { $0["workflow_id"] == NoteStoreSchema.autoTaggingWorkflowId })
      XCTAssertEqual(try database.query("PRAGMA foreign_keys").first?["foreign_keys"], "1")
      XCTAssertEqual(try schemaVersions(in: database), [1, 2, 3, 4, 5, NoteStoreSchema.currentVersion])

      try database.requireFTS5Available()
      try database.requireFTS5TrigramAvailable()
      let ftsSchema = try database.query(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'note_fts' LIMIT 1"
      ).first?["sql"]
      XCTAssertTrue(ftsSchema?.contains("tokenize='trigram'") == true)
    }
  }

  func testPrepareDispatchesV2MigrationFromVersionOneStore() throws {
    let driver = try makeNoteDriver()
    try driver.withDatabase { database in
      try database.execute(
        """
        CREATE TABLE note_schema_version (
          version INTEGER PRIMARY KEY,
          applied_at TEXT NOT NULL
        )
        """
      )
      try database.execute(
        "INSERT INTO note_schema_version (version, applied_at) VALUES (1, '2026-07-04T00:00:00Z')"
      )
      try database.execute("""
        CREATE VIRTUAL TABLE note_fts USING fts5(
          title, body, tags,
          content='',
          tokenize='unicode61'
        )
        """)
    }

    try NoteStoreSchema.prepare(on: driver)

    try driver.withDatabase { database in
      XCTAssertEqual(try schemaVersions(in: database), [1, 2, 3, 4, 5, NoteStoreSchema.currentVersion])
      let ftsSchema = try database.query(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'note_fts' LIMIT 1"
      ).first?["sql"]
      XCTAssertTrue(ftsSchema?.contains("tokenize='trigram'") == true)
    }
  }

  func testMigrateToV6AddsReadOnlyAndPreservesV5Notebook() throws {
    let driver = try makeNoteDriver()
    try driver.withDatabase { database in
      try database.execute(
        """
        CREATE TABLE note_schema_version (
          version INTEGER PRIMARY KEY,
          applied_at TEXT NOT NULL
        )
        """
      )
      for version in 1...5 {
        try database.execute(
          "INSERT INTO note_schema_version (version, applied_at) VALUES (?, '2026-08-01T00:00:00Z')",
          bindings: [.int(Int64(version))]
        )
      }
      try database.execute(
        """
        CREATE TABLE notebooks (
          notebook_id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'none',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          meta_json BLOB CHECK (meta_json IS NULL OR json_valid(meta_json, 8))
        )
        """
      )
      try database.execute(
        """
        INSERT INTO notebooks (notebook_id, title, status, created_at, updated_at)
        VALUES ('legacy-notebook', 'Legacy', 'none', '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z')
        """
      )
      try database.execute(
        """
        CREATE TABLE tag_classes (
          class_id TEXT PRIMARY KEY,
          label TEXT NOT NULL,
          description TEXT,
          is_system INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL
        )
        """
      )
      try database.execute(
        """
        CREATE TABLE tags (
          tag_id TEXT PRIMARY KEY,
          name TEXT NOT NULL UNIQUE,
          class_id TEXT,
          parent_tag_id TEXT,
          status_set_id TEXT,
          is_system INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL
        )
        """
      )
      try database.execute(
        """
        INSERT INTO tags (tag_id, name, class_id, is_system, created_at)
        VALUES ('legacy-system-memory-kind', ?, NULL, 0, '2026-08-01T00:00:00Z')
        """,
        bindings: [.text(NoteStoreSchema.systemMemoryNotebookKindTag)]
      )
    }

    try NoteStoreSchema.prepare(on: driver)

    try driver.withDatabase { database in
      let columns = try database.query("PRAGMA table_info(notebooks)").compactMap { $0["name"] }
      XCTAssertTrue(columns.contains("read_only"))
      XCTAssertEqual(
        try database.query("SELECT read_only FROM notebooks WHERE notebook_id = 'legacy-notebook'").first?["read_only"],
        "0"
      )
      XCTAssertEqual(
        try database.query("SELECT read_only FROM notebooks WHERE notebook_id = ?", bindings: [
          .text(NoteStoreSchema.systemMemoryNotebookId)
        ]).first?["read_only"],
        "1"
      )
      let kindTag = try database.query(
        "SELECT tag_id, class_id, is_system FROM tags WHERE name = ?",
        bindings: [.text(NoteStoreSchema.systemMemoryNotebookKindTag)]
      ).first
      XCTAssertEqual(kindTag?["tag_id"], "legacy-system-memory-kind")
      XCTAssertEqual(kindTag?["class_id"], "document-kind")
      XCTAssertEqual(kindTag?["is_system"], "1")
      XCTAssertEqual(
        try database.query(
          "SELECT tag_id FROM notebook_tags WHERE notebook_id = ?",
          bindings: [.text(NoteStoreSchema.systemMemoryNotebookId)]
        ).first?["tag_id"],
        "legacy-system-memory-kind"
      )
      XCTAssertEqual(try schemaVersions(in: database), [1, 2, 3, 4, 5, NoteStoreSchema.currentVersion])
    }
  }

  func testPrepareCachesSQLiteCapabilityProbeAcrossNoteStores() throws {
    NoteSQLiteCapabilityCache.resetForTesting()
    defer {
      NoteSQLiteCapabilityCache.resetForTesting()
    }
    let first = try makeNoteDriver()
    let second = try makeNoteDriver()

    try NoteStoreSchema.prepare(on: first)
    try NoteStoreSchema.prepare(on: first)
    try NoteStoreSchema.prepare(on: second)

    XCTAssertEqual(NoteSQLiteCapabilityCache.probeRunCountForTesting(), 1)
    try first.withDatabase { database in
      XCTAssertTrue(try database.tableExists("notes"))
    }
    try second.withDatabase { database in
      XCTAssertTrue(try database.tableExists("notes"))
    }
  }

  func testFileLocatorConstraintRejectsInvalidLocalRows() throws {
    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)

    XCTAssertThrowsError(
      try driver.withDatabase { database in
        try database.execute(
          """
          INSERT INTO files (
            file_id, storage_kind, media_type, byte_size, sha256, created_at
          ) VALUES ('file-1', 'local', 'text/plain', 1, 'abc', '2026-07-04T00:00:00Z')
          """
        )
      }
    )
  }

  func testPrepareRejectsFutureSchemaVersion() throws {
    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)
    try driver.withDatabase { database in
      try database.execute(
        "INSERT INTO note_schema_version (version, applied_at) VALUES (?, ?)",
        bindings: [.int(999), .text("2026-07-04T00:00:00Z")]
      )
    }

    XCTAssertThrowsError(try NoteStoreSchema.prepare(on: driver)) { error in
      XCTAssertEqual(
        error as? NoteStoreSchemaError,
        .unsupportedFutureVersion(found: 999, supported: NoteStoreSchema.currentVersion)
      )
    }
  }

  func testSQLiteDriverReusesConnectionBetweenOperations() throws {
    guard let driver = try makeNoteDriver() as? SQLiteNoteDatabaseDriver else {
      XCTFail("Expected SQLite note database driver")
      return
    }
    let firstDatabase = try driver.withDatabase { ObjectIdentifier($0) }
    let secondDatabase = try driver.withDatabase { ObjectIdentifier($0) }

    XCTAssertEqual(firstDatabase, secondDatabase)
  }

  func testPrepareRebuildsLegacyUnicodeFTSAsTrigram() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let note = try service.createNote(bodyMarkdown: "# 日本語ノート\nこれは日本語検索の検証です")
    try driver.withDatabase { database in
      try database.execute("DROP TABLE note_fts")
      try database.execute("""
        CREATE VIRTUAL TABLE note_fts USING fts5(
          title, body, tags,
          content='',
          tokenize='unicode61'
        )
        """)
      try database.execute("DELETE FROM note_fts_map")
      try database.execute(
        "INSERT INTO note_fts(rowid, title, body, tags) VALUES (1, ?, ?, '')",
        bindings: [.text(note.title ?? ""), .text(note.bodyMarkdown)]
      )
      try database.execute(
        "INSERT INTO note_fts_map (fts_rowid, note_id) VALUES (1, ?)",
        bindings: [.text(note.noteId)]
      )
    }

    try NoteStoreSchema.prepare(on: driver)

    try driver.withDatabase { database in
      let ftsSchema = try database.query(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'note_fts' LIMIT 1"
      ).first?["sql"]
      XCTAssertTrue(ftsSchema?.contains("tokenize='trigram'") == true)
      try database.execute("INSERT INTO note_fts(note_fts) VALUES('integrity-check')")
    }
    XCTAssertEqual(try service.searchNotes(query: "日本語検索").map(\.note.noteId), [note.noteId])
  }

  #if RIELA_NOTE_LIBSQL_TESTS
  func testLibSQLLocalDriverReusesConnectionBetweenOperations() throws {
    let driver = LibSQLNoteDatabaseDriver(noteRoot: try makeNoteRoot())
    let firstDatabase = try driver.withDatabase { ObjectIdentifier($0) }
    let secondDatabase = try driver.withDatabase { ObjectIdentifier($0) }

    XCTAssertEqual(firstDatabase, secondDatabase)
  }

  func testLibSQLLocalDriverSerializesConcurrentWritesWithSingleProbeCycle() throws {
    NoteSQLiteCapabilityCache.resetForTesting()
    defer {
      NoteSQLiteCapabilityCache.resetForTesting()
    }

    let driver = LibSQLNoteDatabaseDriver(noteRoot: try makeNoteRoot())
    let service = try NoteService(driver: driver)

    let writeCount = 24
    let failures = NSMutableArray()
    let failuresLock = NSLock()

    DispatchQueue.concurrentPerform(iterations: writeCount) { index in
      do {
        _ = try service.createNote(bodyMarkdown: "# Concurrent \(index)\nbody \(index)")
      } catch {
        failuresLock.lock()
        failures.add(String(describing: error))
        failuresLock.unlock()
      }
    }

    XCTAssertEqual(
      failures.count,
      0,
      "concurrent writes through one LibSQL driver must not raise 'database is locked': \(failures)"
    )

    // A single cached, lock-guarded connection means the capability probe runs
    // exactly once regardless of how many concurrent operations executed.
    XCTAssertEqual(NoteSQLiteCapabilityCache.probeRunCountForTesting(), 1)

    let stored = try driver.withDatabase { database in
      try database.query("SELECT COUNT(*) AS total FROM notes").first?["total"]
    }
    XCTAssertEqual(stored, String(writeCount))
  }
  #endif
}

private func schemaVersions(in database: SQLiteDatabase) throws -> [Int] {
  try database.query("SELECT version FROM note_schema_version ORDER BY version")
    .compactMap { row in
      row["version"].flatMap(Int.init)
    }
}

func makeNoteRoot(function: String = #function) throws -> String {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tmp/RielaNoteTests", isDirectory: true)
    .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.path
}

func makeNoteDriver(function: String = #function) throws -> NoteDatabaseDriving {
  let noteRoot = try makeNoteRoot(function: function)
  switch ProcessInfo.processInfo.environment["RIELA_NOTE_TEST_DRIVER"]?.lowercased() {
  case nil, "", "sqlite":
    return SQLiteNoteDatabaseDriver(noteRoot: noteRoot)
  case "libsql":
    #if RIELA_NOTE_LIBSQL_TESTS
    return LibSQLNoteDatabaseDriver(noteRoot: noteRoot)
    #else
    throw NSError(
      domain: "RielaNoteTests",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey:
          "RIELA_NOTE_TEST_DRIVER=libsql requires RIELA_NOTE_ENABLE_LIBSQL_TESTS=1 when SwiftPM evaluates Package.swift"
      ]
    )
    #endif
  case let driver?:
    throw NSError(
      domain: "RielaNoteTests",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Unsupported RIELA_NOTE_TEST_DRIVER value: \(driver)"]
    )
  }
}
