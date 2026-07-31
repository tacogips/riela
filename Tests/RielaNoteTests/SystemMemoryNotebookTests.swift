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
