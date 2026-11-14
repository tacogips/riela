@testable import RielaNoteUI
import XCTest

@MainActor
final class RielaNoteLibrarySelectionTests: XCTestCase {
  func testViewModelLoadsNotebookListAndSelectsFirstNote() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)

    await viewModel.load()

    XCTAssertEqual(viewModel.notebooks.map(\.notebookId), ["notebook-1"])
    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-1")
    XCTAssertEqual(viewModel.notebookNotes.map(\.noteId), ["note-1", "note-2"])
    XCTAssertEqual(viewModel.selectedNotePositionText, "#1 of 2")
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testViewModelPagesWithinSelectedNotebook() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)

    await viewModel.selectNotebook("notebook-1")
    XCTAssertFalse(viewModel.canSelectPreviousNote)
    XCTAssertTrue(viewModel.canSelectNextNote)

    await viewModel.selectNextNote()
    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-2")
    XCTAssertEqual(viewModel.selectedNotePositionText, "#2 of 2")
    XCTAssertTrue(viewModel.canSelectPreviousNote)
    XCTAssertFalse(viewModel.canSelectNextNote)

    await viewModel.selectPreviousNote()
    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-1")
  }

  func testViewModelLoadsNextNotebookPageWhenAdvancingPastLoadedNotes() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client, notebookNoteLimit: 1)

    await viewModel.selectNotebook("notebook-1")

    XCTAssertEqual(viewModel.notebookNotes.map(\.noteId), ["note-1"])
    XCTAssertEqual(viewModel.selectedNotePositionText, "#1 of 1+")
    XCTAssertTrue(viewModel.canLoadMoreNotebookNotes)
    XCTAssertEqual(fixture.client.listNoteRequests.map(\.offset), [0])
    XCTAssertEqual(fixture.client.listNoteRequests.map(\.limit), [2])

    await viewModel.selectNextNote()

    XCTAssertEqual(viewModel.notebookNotes.map(\.noteId), ["note-1", "note-2"])
    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-2")
    XCTAssertEqual(viewModel.selectedNotePositionText, "#2 of 2")
    XCTAssertFalse(viewModel.canLoadMoreNotebookNotes)
    XCTAssertEqual(fixture.client.listNoteRequests.map(\.offset), [0, 1])
  }
}
