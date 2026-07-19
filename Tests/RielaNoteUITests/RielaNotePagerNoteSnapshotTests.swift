import RielaNote
@testable import RielaNoteUI
import XCTest

@MainActor
final class RielaNotePagerNoteSnapshotTests: XCTestCase {
  func testSnapshotExposesPagerOrderPositionAndAdjacentNotes() {
    let notes = (1...3).map(makeNote)
    let snapshot = RielaNotePagerNoteSnapshot(
      notes: notes,
      selectedNoteId: "note-2",
      hasMoreNotes: false
    )

    XCTAssertEqual(snapshot.notes.map(\.noteId), ["note-1", "note-2", "note-3"])
    XCTAssertEqual(snapshot.currentIndex, 1)
    XCTAssertEqual(snapshot.totalLoadedCount, 3)
    XCTAssertEqual(snapshot.selectedPositionText, "#2 of 3")
    XCTAssertEqual(snapshot.positionText(for: "note-2"), "2/3")
    XCTAssertEqual(snapshot.previousNote?.noteId, "note-1")
    XCTAssertEqual(snapshot.nextNote?.noteId, "note-3")
    XCTAssertTrue(snapshot.canSelectPrevious)
    XCTAssertTrue(snapshot.canSelectNext)
  }

  func testSnapshotShowsOpenEndedCountWhenMoreNotesExist() {
    let notes = (1...2).map(makeNote)
    let snapshot = RielaNotePagerNoteSnapshot(
      notes: notes,
      selectedNoteId: "note-2",
      hasMoreNotes: true
    )

    XCTAssertEqual(snapshot.selectedPositionText, "#2 of 2+")
    XCTAssertEqual(snapshot.positionText(for: "note-2"), "2/2+")
    XCTAssertTrue(snapshot.canSelectNext)
    XCTAssertNil(snapshot.nextNote)
  }

  func testViewModelPagerPropertiesUseSnapshotForAdjacentSelection() async {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)

    await viewModel.load()

    XCTAssertEqual(viewModel.pagerNoteSnapshot.notes.map(\.noteId), ["note-1", "note-2"])
    XCTAssertEqual(viewModel.selectedNotePositionText, viewModel.pagerNoteSnapshot.selectedPositionText)
    XCTAssertEqual(viewModel.pagerNoteSnapshot.positionText(for: "note-1"), "1/2")

    await viewModel.selectNextNote()

    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-2")
    XCTAssertEqual(viewModel.selectedNoteIndex, 1)
    XCTAssertEqual(viewModel.pagerNoteSnapshot.previousNote?.noteId, "note-1")
  }

  private func makeNote(_ index: Int) -> Note {
    Note(
      noteId: "note-\(index)",
      notebookId: "notebook-1",
      noteNumber: index,
      title: "Note \(index)",
      bodyMarkdown: "# Note \(index)",
      readOnly: false,
      createdAt: "2026-07-19T00:00:00Z",
      updatedAt: "2026-07-19T00:00:00Z"
    )
  }
}
