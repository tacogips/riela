import Foundation
import RielaNote
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
    let service = try makeService()
    let note = try service.saveSystemMemoryNote(
      title: "Remembered",
      bodyMarkdown: "# Remembered\nBody",
      tags: [NoteTagInput(name: "memory-namespace:test")]
    )

    XCTAssertThrowsError(try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "changed"))
    XCTAssertThrowsError(try service.deleteNote(noteId: note.noteId))
    XCTAssertThrowsError(
      try service.createNote(
        notebookId: NoteStoreSchema.systemMemoryNotebookId,
        bodyMarkdown: "blocked"
      )
    )

    let tagged = try service.applyTags(
      noteId: note.noteId,
      tags: [NoteTagInput(name: "reviewed")],
      provenance: .human
    )
    XCTAssertTrue(tagged.tags.contains { $0.tag.name == "reviewed" })
    XCTAssertEqual(try service.addComment(noteId: note.noteId, bodyMarkdown: "metadata").bodyMarkdown, "metadata")

    XCTAssertFalse(try service.setNotebookReadOnly(notebookId: note.notebookId, readOnly: false).readOnly)
    XCTAssertEqual(
      try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "unlocked").bodyMarkdown,
      "unlocked"
    )
    XCTAssertFalse(try service.getNotebook(note.notebookId).readOnly)
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
}
