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

  func testPrepareMigratesV5NotebookRowsToV6WithoutDataLoss() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let notebook = try service.createNotebook(
      title: "Existing notebook",
      metaJSON: #"{"source":"v5-fixture"}"#
    )
    let sourceNote = try service.createNote(
      notebookId: notebook.notebookId,
      title: "Existing note",
      bodyMarkdown: "Existing body",
      readOnly: true,
      tags: [NoteTagInput(name: "v5-tag")],
      provenance: .human,
      assignedBy: "v5-fixture",
      metaJSON: #"{"ordinal":1}"#
    )
    let relatedNote = try service.createNote(
      notebookId: notebook.notebookId,
      bodyMarkdown: "Related body",
      metaJSON: #"{"ordinal":2}"#
    )
    let link = try service.linkNotes(
      from: sourceNote.noteId,
      to: relatedNote.noteId,
      linkKind: "supports",
      provenance: .human
    )
    let noteFile = try service.attachFile(
      noteId: relatedNote.noteId,
      data: Data("note file".utf8),
      role: .related,
      mediaType: "text/plain",
      originalFilename: "note.txt",
      position: 4
    )
    let notebookFile = try service.attachNotebookFile(
      notebookId: notebook.notebookId,
      data: Data("notebook file".utf8),
      role: .sourceDocument,
      mediaType: "text/plain",
      originalFilename: "source.txt"
    )

    try driver.withDatabase { database in
      try database.execute(
        "UPDATE notebooks SET status = 'progress' WHERE notebook_id = ?",
        bindings: [.text(notebook.notebookId)]
      )
      // Fixture setup only: remove the additive v6 column and marker so the
      // populated current-schema store represents the exact v5 input shape.
      try database.execute("ALTER TABLE notebooks DROP COLUMN read_only")
      try database.execute("DELETE FROM note_schema_version WHERE version = 6")
      XCTAssertFalse(try database.query("PRAGMA table_info(notebooks)").contains { $0["name"] == "read_only" })
      XCTAssertEqual(try schemaVersions(in: database), [1, 2, 3, 4, 5])
    }

    try NoteStoreSchema.prepare(on: driver)

    try driver.withDatabase { database in
      let notebookRow = try XCTUnwrap(
        database.query(
          """
          SELECT notebook_id, title, status, read_only, json(meta_json) AS meta_json
          FROM notebooks WHERE notebook_id = ?
          """,
          bindings: [.text(notebook.notebookId)]
        ).first
      )
      XCTAssertEqual(notebookRow["notebook_id"], notebook.notebookId)
      XCTAssertEqual(notebookRow["title"], "Existing notebook")
      XCTAssertEqual(notebookRow["status"], "progress")
      XCTAssertEqual(notebookRow["read_only"], "0")
      XCTAssertEqual(notebookRow["meta_json"], #"{"source":"v5-fixture"}"#)

      let noteRows = try database.query(
        """
        SELECT note_id, notebook_id, note_number, title, title_source, body_markdown,
          read_only, json(meta_json) AS meta_json
        FROM notes WHERE notebook_id = ? ORDER BY note_number
        """,
        bindings: [.text(notebook.notebookId)]
      )
      XCTAssertEqual(noteRows.map { $0["note_id"] }, [sourceNote.noteId, relatedNote.noteId])
      XCTAssertEqual(noteRows.map { $0["notebook_id"] }, [notebook.notebookId, notebook.notebookId])
      XCTAssertEqual(noteRows.map { $0["body_markdown"] }, ["Existing body", "Related body"])
      XCTAssertEqual(noteRows.map { $0["read_only"] }, ["1", "0"])
      XCTAssertEqual(noteRows.map { $0["meta_json"] }, [#"{"ordinal":1}"#, #"{"ordinal":2}"#])

      let tagNames = try database.query(
        """
        SELECT tags.name FROM note_tags
        INNER JOIN tags ON tags.tag_id = note_tags.tag_id
        WHERE note_tags.note_id = ? ORDER BY tags.name
        """,
        bindings: [.text(sourceNote.noteId)]
      ).compactMap { $0["name"] }
      XCTAssertEqual(tagNames, ["v5-tag"])

      let linkRow = try XCTUnwrap(database.query(
        """
        SELECT from_note_id, to_note_id, link_kind, provenance FROM note_links
        WHERE from_note_id = ? AND to_note_id = ?
        """,
        bindings: [.text(sourceNote.noteId), .text(relatedNote.noteId)]
      ).first)
      XCTAssertEqual(linkRow["from_note_id"], link.fromNoteId)
      XCTAssertEqual(linkRow["to_note_id"], link.toNoteId)
      XCTAssertEqual(linkRow["link_kind"], "supports")
      XCTAssertEqual(linkRow["provenance"], "human")

      let fileIds = try database.query(
        "SELECT file_id FROM files WHERE file_id IN (?, ?) ORDER BY file_id",
        bindings: [.text(noteFile.file.fileId), .text(notebookFile.file.fileId)]
      ).compactMap { $0["file_id"] }
      XCTAssertEqual(fileIds, [noteFile.file.fileId, notebookFile.file.fileId].sorted())
      let noteFileRow = try XCTUnwrap(database.query(
        "SELECT role, position FROM note_files WHERE note_id = ? AND file_id = ?",
        bindings: [.text(relatedNote.noteId), .text(noteFile.file.fileId)]
      ).first)
      XCTAssertEqual(noteFileRow["role"], "related")
      XCTAssertEqual(noteFileRow["position"], "4")
      let notebookFileRow = try XCTUnwrap(database.query(
        "SELECT role FROM notebook_files WHERE notebook_id = ? AND file_id = ?",
        bindings: [.text(notebook.notebookId), .text(notebookFile.file.fileId)]
      ).first)
      XCTAssertEqual(notebookFileRow["role"], "source-document")
      XCTAssertEqual(try schemaVersions(in: database), [1, 2, 3, 4, 5, 6])
    }
    let filesRoot = URL(fileURLWithPath: driver.databasePath)
      .deletingLastPathComponent()
      .appendingPathComponent("files", isDirectory: true)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: filesRoot.appendingPathComponent(try XCTUnwrap(noteFile.file.localPath)).path
      )
    )
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: filesRoot.appendingPathComponent(try XCTUnwrap(notebookFile.file.localPath)).path
      )
    )
  }

  func testPrepareRejectsV5UserTagCollisionForSystemMemoryIdentity() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let canonical = try service.systemMemoryNotebook()
    try driver.withDatabase { database in
      try database.execute(
        "UPDATE tags SET is_system = 0 WHERE name = ?",
        bindings: [.text(NoteStoreSchema.systemMemoryNotebookKindTag)]
      )
      try database.execute(
        """
        UPDATE notebook_tags
        SET provenance = 'human', assigned_by = 'v5-user', deletable = 1
        WHERE notebook_id = ?
        """,
        bindings: [.text(canonical.notebookId)]
      )
      try database.execute("ALTER TABLE notebooks DROP COLUMN read_only")
      try database.execute("DELETE FROM note_schema_version WHERE version = 6")
    }

    XCTAssertThrowsError(try NoteStoreSchema.prepare(on: driver)) { error in
      XCTAssertEqual(
        error as? NoteStoreSchemaError,
        .systemTagCollision(name: NoteStoreSchema.systemMemoryNotebookKindTag)
      )
    }
    try driver.withDatabase { database in
      XCTAssertEqual(try schemaVersions(in: database), [1, 2, 3, 4, 5])
      XCTAssertFalse(try database.query("PRAGMA table_info(notebooks)").contains { $0["name"] == "read_only" })
      let tagRow = try XCTUnwrap(database.query(
        "SELECT is_system FROM tags WHERE name = ?",
        bindings: [.text(NoteStoreSchema.systemMemoryNotebookKindTag)]
      ).first)
      XCTAssertEqual(tagRow["is_system"], "0")
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
