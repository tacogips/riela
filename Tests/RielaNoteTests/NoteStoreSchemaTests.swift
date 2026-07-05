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
        ["content-kind", "document-kind", "event", "person", "source", "topic", "workflow", "year"]
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
          "notebook-kind:user-memo"
        ]
      )

      let autoActions = try database.query("SELECT trigger, workflow_id FROM auto_actions ORDER BY trigger")
      XCTAssertEqual(autoActions.map { $0["trigger"] }, ["note-created", "note-updated"])
      XCTAssertTrue(autoActions.allSatisfy { $0["workflow_id"] == NoteStoreSchema.autoTaggingWorkflowId })
      XCTAssertEqual(try database.query("PRAGMA foreign_keys").first?["foreign_keys"], "1")
      XCTAssertEqual(try schemaVersions(in: database), [1, 2, NoteStoreSchema.currentVersion])

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
      XCTAssertEqual(try schemaVersions(in: database), [1, 2, NoteStoreSchema.currentVersion])
      let ftsSchema = try database.query(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'note_fts' LIMIT 1"
      ).first?["sql"]
      XCTAssertTrue(ftsSchema?.contains("tokenize='trigram'") == true)
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
