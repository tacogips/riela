import RielaNote
@testable import RielaNoteUI
import XCTest

final class RielaNoteDraftMarkdownTests: XCTestCase {
  func testDraftMarkdownUsesFallbackTitleForEmptyDraft() {
    XCTAssertEqual(
      rielaNoteDraftMarkdown(title: "  ", fallbackTitle: "Untitled Note", body: " \n "),
      "# Untitled Note\n\n"
    )
  }

  func testDraftMarkdownIncludesTrimmedBody() {
    XCTAssertEqual(
      rielaNoteDraftMarkdown(title: " Reading Notes ", fallbackTitle: "Untitled Note", body: "\nFirst pass.\n"),
      "# Reading Notes\n\nFirst pass."
    )
  }

  func testBodyDraftStateKeepsUnsavedDraftWhenTogglingPreview() {
    var state = RielaNoteBodyDraftState()
    let note = Note(
      noteId: "note-1",
      notebookId: "notebook-1",
      noteNumber: 1,
      title: "Drafted",
      bodyMarkdown: "Persisted body",
      readOnly: false,
      createdAt: "2026-07-05T00:00:00Z",
      updatedAt: "2026-07-05T00:00:00Z"
    )

    state.toggle(noteId: note.noteId, bodyMarkdown: note.bodyMarkdown)
    state.draftBodyMarkdown = "Unsaved body"
    state.toggle(noteId: note.noteId, bodyMarkdown: note.bodyMarkdown)

    XCTAssertFalse(state.isEditingBody)
    XCTAssertEqual(state.previewBodyMarkdown(for: note), "Unsaved body")

    state.toggle(noteId: note.noteId, bodyMarkdown: note.bodyMarkdown)
    XCTAssertTrue(state.isEditingBody)
    XCTAssertEqual(state.draftBodyMarkdown, "Unsaved body")
  }
}
