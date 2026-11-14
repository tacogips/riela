import RielaNote
@testable import RielaNoteUI
import XCTest

final class RielaNoteLinkTargetSuggestionTests: XCTestCase {
  func testLinkTargetSuggestionsFilterCurrentExistingAndQuery() {
    let current = Self.note(noteId: "note-current", title: "Current")
    let target = Self.note(noteId: "note-target", title: "Ada Notes")
    let existing = Self.note(noteId: "note-existing", title: "Existing")
    let link = NoteLink(
      fromNoteId: current.noteId,
      toNoteId: existing.noteId,
      linkKind: "related",
      provenance: .human,
      createdAt: "2026-07-04T00:00:00Z"
    )

    let suggestions = rielaNoteLinkTargetSuggestions(
      candidateNotes: [current, existing, target, target],
      currentNoteId: current.noteId,
      existingLinks: [link],
      query: "ada"
    )

    XCTAssertEqual(suggestions.map(\.noteId), [target.noteId])
  }

  func testLinkIconDistinguishesSourceCitations() {
    XCTAssertEqual(rielaNoteLinkIconName("source-citation"), "quote.bubble")
    XCTAssertEqual(rielaNoteLinkIconName("related"), "link")
  }

  @MainActor
  func testViewModelSearchesCrossNotebookLinkTargetsWithoutChangingMainSearch() async {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)
    await viewModel.selectNote("note-1")

    await viewModel.updateLinkTargetSearchText("ontology", currentNoteId: "note-1")

    XCTAssertEqual(fixture.client.searchRequests.last?.query, "ontology")
    XCTAssertEqual(fixture.client.searchRequests.last?.tagFilter, [])
    XCTAssertEqual(fixture.client.searchRequests.last?.classFilter, [])
    XCTAssertEqual(fixture.client.searchRequests.last?.limit, 10)
    XCTAssertEqual(fixture.client.searchRequests.last?.offset, 0)
    XCTAssertEqual(viewModel.linkTargetSearchNotes.map(\.noteId), ["note-2"])
    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-1")
    XCTAssertFalse(viewModel.isSearching)
    XCTAssertFalse(viewModel.isLinkTargetSearchLoading)
  }

  private static func note(noteId: String, title: String) -> Note {
    Note(
      noteId: noteId,
      notebookId: "notebook-1",
      noteNumber: 1,
      title: title,
      bodyMarkdown: "# \(title)",
      readOnly: false,
      createdAt: "2026-07-04T00:00:00Z",
      updatedAt: "2026-07-04T00:00:00Z"
    )
  }
}
