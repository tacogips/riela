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

  func testSnapshotReportsTrailingEdgeForReaderLazyLoading() {
    let notes = (1...5).map(makeNote)
    let snapshot = RielaNotePagerNoteSnapshot(
      notes: notes,
      selectedNoteId: "note-3",
      hasMoreNotes: true
    )

    XCTAssertFalse(snapshot.shouldLoadNextPage(visibleNoteId: "note-2", trailingThreshold: 1))
    XCTAssertTrue(snapshot.shouldLoadNextPage(visibleNoteId: "note-4", trailingThreshold: 1))
    XCTAssertFalse(snapshot.shouldLoadNextPage(visibleNoteId: "missing", trailingThreshold: 1))
    XCTAssertEqual(snapshot.positionText(for: "note-3"), "3/5+")
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

  func testCenteredWindowUsesAbsolutePositionAndExposesEarlierPageBoundary() {
    let snapshot = RielaNotePagerNoteSnapshot(
      notes: [makeNote(4), makeNote(5)],
      selectedNoteId: "note-4",
      leadingOffset: 3,
      hasEarlierNotes: true,
      hasMoreNotes: true
    )

    XCTAssertEqual(snapshot.selectedPositionText, "#4 of 5+")
    XCTAssertEqual(snapshot.positionText(for: "note-5"), "5/5+")
    XCTAssertTrue(snapshot.canSelectPrevious)
    XCTAssertTrue(snapshot.shouldLoadPreviousPage(visibleNoteId: "note-4", leadingThreshold: 0))
    XCTAssertFalse(snapshot.shouldLoadPreviousPage(visibleNoteId: "note-5", leadingThreshold: 0))
    XCTAssertFalse(snapshot.isCloserToTrailingEdge(noteId: "note-4"))
    XCTAssertTrue(snapshot.isCloserToTrailingEdge(noteId: "note-5"))
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
