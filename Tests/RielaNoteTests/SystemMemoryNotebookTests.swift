import Foundation
import RielaNote
import RielaSQLite
import XCTest

final class SystemMemoryNotebookTests: NoteTestCase {
  func testBootstrapSeedsStableLockedSystemMemoryNotebookIdempotently() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)

    let notebook = try service.systemMemoryNotebook()
    XCTAssertEqual(notebook.notebookId, NoteStoreSchema.systemMemoryNotebookId)
    XCTAssertTrue(notebook.readOnly)
    XCTAssertEqual(notebook.tags.map(\.tag.name), [NoteStoreSchema.systemMemoryNotebookKindTag])
    XCTAssertEqual(notebook.tags.first?.deletable, false)

    let reopened = try NoteService(driver: driver)
    XCTAssertEqual(try reopened.systemMemoryNotebook().notebookId, notebook.notebookId)
    XCTAssertEqual(
      try reopened.listNotebooks().filter { $0.notebookId == NoteStoreSchema.systemMemoryNotebookId }.count,
      1
    )
  }

  func testNotebookLockBlocksContentWritesButAllowsMetadataAndPersistedUnlock() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let note = try service.saveSystemMemoryNote(
      title: "Remembered",
      bodyMarkdown: "# Remembered\nBody",
      tags: [NoteTagInput(name: "memory-namespace:test")]
    )

    assertReadOnly(
      try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "changed"),
      expectedIdentifier: note.notebookId
    )
    assertReadOnly(try service.deleteNote(noteId: note.noteId), expectedIdentifier: note.notebookId)
    assertReadOnly(
      try service.createNote(
        notebookId: NoteStoreSchema.systemMemoryNotebookId,
        bodyMarkdown: "blocked"
      ),
      expectedIdentifier: note.notebookId
    )
    assertReadOnly(
      try service.attachFile(
        noteId: note.noteId,
        data: Data("blocked".utf8),
        mediaType: "text/plain"
      ),
      expectedIdentifier: note.notebookId
    )
    assertReadOnly(
      try service.deleteNotebook(notebookId: note.notebookId),
      expectedIdentifier: note.notebookId
    )

    let comment = try service.addComment(noteId: note.noteId, bodyMarkdown: "metadata")
    assertReadOnly(
      try service.promoteCommentToNotebook(noteId: note.noteId, commentId: comment.commentId),
      expectedIdentifier: note.notebookId
    )
    XCTAssertThrowsError(
      try service.createNotebook(
        title: "Claimed System Memory",
        kindTagName: NoteStoreSchema.systemMemoryNotebookKindTag
      )
    ) { error in
      guard case NoteServiceError.invalidInput = error else {
        return XCTFail("expected invalidInput, got \(error)")
      }
    }

    let tagged = try service.applyTags(
      noteId: note.noteId,
      tags: [NoteTagInput(name: "reviewed")],
      provenance: .human
    )
    XCTAssertTrue(tagged.tags.contains { $0.tag.name == "reviewed" })
    XCTAssertEqual(comment.bodyMarkdown, "metadata")

    XCTAssertFalse(try service.setNotebookReadOnly(notebookId: note.notebookId, readOnly: false).readOnly)
    XCTAssertEqual(
      try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "unlocked").bodyMarkdown,
      "unlocked"
    )
    XCTAssertFalse(try service.getNotebook(note.notebookId).readOnly)

    let reopened = try NoteService(driver: driver)
    XCTAssertFalse(try reopened.systemMemoryNotebook().readOnly)
  }

  func testTypedSystemWriteBypassesOnlyNotebookLockAndSkipsAutoActions() throws {
    let service = try makeService()
    let note = try service.saveSystemMemoryNote(bodyMarkdown: "# System write\nBody")

    XCTAssertEqual(note.notebookId, NoteStoreSchema.systemMemoryNotebookId)
    XCTAssertTrue(try service.getNotebook(note.notebookId).readOnly)
    XCTAssertTrue(try service.listAutoActionDispatchAttempts().isEmpty)

    _ = try service.setReadOnly(noteId: note.noteId, readOnly: true)
    XCTAssertThrowsError(try service.updateSystemMemoryNote(noteId: note.noteId, bodyMarkdown: "blocked"))

    let ordinary = try service.createNote(bodyMarkdown: "# Ordinary\nBody")
    XCTAssertThrowsError(
      try service.attachSystemMemoryFile(
        noteId: ordinary.noteId,
        data: Data("blocked".utf8),
        mediaType: "text/plain"
      )
    )

    _ = try service.setReadOnly(noteId: note.noteId, readOnly: false)
    let attachment = try service.attachSystemMemoryFile(
      noteId: note.noteId,
      data: Data("memory".utf8),
      mediaType: "text/plain",
      originalFilename: "memory.txt"
    )
    XCTAssertEqual(attachment.noteId, note.noteId)
  }

  func testNoteLevelLockBlocksOrdinaryAttachmentWritesInWritableNotebook() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Locked note\nBody")
    XCTAssertFalse(try service.getNotebook(note.notebookId).readOnly)
    _ = try service.setReadOnly(noteId: note.noteId, readOnly: true)

    assertReadOnly(
      try service.attachFile(
        noteId: note.noteId,
        data: Data("blocked".utf8),
        mediaType: "text/plain"
      ),
      expectedIdentifier: note.noteId
    )
    let sourceURL = URL(fileURLWithPath: service.noteRootPath(), isDirectory: true)
      .appendingPathComponent("locked-source.txt")
    try Data("blocked file".utf8).write(to: sourceURL)
    assertReadOnly(
      try service.attachFile(
        noteId: note.noteId,
        fileURL: sourceURL,
        mediaType: "text/plain"
      ),
      expectedIdentifier: note.noteId
    )
    XCTAssertThrowsError(
      try service.attachIngestedPageFile(
        noteId: note.noteId,
        data: Data("not an imported page".utf8),
        mediaType: "text/plain"
      )
    ) { error in
      guard case NoteServiceError.invalidInput = error else {
        return XCTFail("expected invalidInput, got \(error)")
      }
    }
    XCTAssertTrue(try service.listFiles(noteId: note.noteId).isEmpty)
  }

  func testSystemMemorySearchScopesNamespaceAndTagsBeforeLimit() throws {
    let service = try makeService()
    let target = try service.saveSystemMemoryNote(
      bodyMarkdown: "shared needle target",
      tags: [
        NoteTagInput(name: "memory-namespace:chat"),
        NoteTagInput(name: "topic:target")
      ]
    )
    for index in 0..<3 {
      _ = try service.saveSystemMemoryNote(
        bodyMarkdown: "shared needle other \(index)",
        tags: [
          NoteTagInput(name: "memory-namespace:other"),
          NoteTagInput(name: "topic:target")
        ]
      )
      _ = try service.createNote(bodyMarkdown: "shared needle ordinary \(index)")
    }
    _ = try service.saveSystemMemoryNote(
      bodyMarkdown: "shared needle wrong tag",
      tags: [
        NoteTagInput(name: "memory-namespace:chat"),
        NoteTagInput(name: "topic:other")
      ]
    )

    XCTAssertEqual(
      try service.searchSystemMemoryNotes(
        query: "shared needle",
        namespace: "chat",
        tagFilter: ["topic:target"],
        limit: 1
      ).map(\.noteId),
      [target.noteId]
    )
  }

  func testSystemMemoryNewestReadHasNoLegacyTenThousandNoteWindow() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    try driver.withDatabase { database in
      try database.transaction { db in
        for index in 1...10_001 {
          try db.execute(
            """
            INSERT INTO notes (
              note_id, notebook_id, note_number, title, title_source, body_markdown,
              read_only, created_at, updated_at, meta_json
            ) VALUES (?, ?, ?, NULL, 'derived', ?, 0, '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z', NULL)
            """,
            bindings: [
              .text("bulk-memory-\(index)"),
              .text(NoteStoreSchema.systemMemoryNotebookId),
              .int(Int64(index)),
              .text("memory \(index)")
            ]
          )
        }
      }
    }

    XCTAssertEqual(
      try service.searchSystemMemoryNotes(limit: 1).first?.noteId,
      "bulk-memory-10001"
    )
  }

  func testSystemMemoryRollbackRemovesNotesRelationshipsAndFiles() throws {
    let service = try makeService()
    let related = try service.createNote(bodyMarkdown: "related")
    let note = try service.saveSystemMemoryNote(bodyMarkdown: "partial")
    _ = try service.linkNotes(from: note.noteId, to: related.noteId, provenance: .ai)
    let attachment = try service.attachSystemMemoryFile(
      noteId: note.noteId,
      data: Data("partial file".utf8),
      mediaType: "text/plain",
      originalFilename: "partial.txt"
    )
    let storedPath = URL(fileURLWithPath: service.noteRootPath(), isDirectory: true)
      .appendingPathComponent("files", isDirectory: true)
      .appendingPathComponent(try XCTUnwrap(attachment.file.localPath))
      .path
    XCTAssertTrue(FileManager.default.fileExists(atPath: storedPath))

    try service.rollbackSystemMemoryNotes(noteIds: [note.noteId])

    XCTAssertThrowsError(try service.getNote(note.noteId))
    XCTAssertThrowsError(try service.getFileRecord(fileId: attachment.file.fileId))
    XCTAssertFalse(FileManager.default.fileExists(atPath: storedPath))
    XCTAssertEqual(try service.getNote(related.noteId).noteId, related.noteId)
  }

  private func assertReadOnly<T>(
    _ expression: @autoclosure () throws -> T,
    expectedIdentifier: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(try expression(), file: file, line: line) { error in
      XCTAssertEqual(error as? NoteServiceError, .readOnly(expectedIdentifier), file: file, line: line)
    }
  }
}
