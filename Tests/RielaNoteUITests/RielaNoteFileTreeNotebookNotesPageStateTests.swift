import RielaNote
@testable import RielaNoteUI
import XCTest

final class FileTreePageStateTests: XCTestCase {
  func testFirstPageTracksOffsetAndLoadMoreAvailability() {
    var state = RielaNoteFileTreeNotebookNotesPageState()

    state.mergeFetchedPage((1...3).map { makeNote($0) }, pageSize: 2)

    XCTAssertTrue(state.didLoad)
    XCTAssertEqual(state.notes.map(\.noteId), ["note-1", "note-2"])
    XCTAssertEqual(state.nextOffset, 2)
    XCTAssertTrue(state.hasMore)
    XCTAssertTrue(state.canLoadMore)
  }

  func testLoadMoreAppendsInServiceOrderAndStopsAtEnd() {
    var state = RielaNoteFileTreeNotebookNotesPageState()
    state.mergeFetchedPage((1...3).map { makeNote($0) }, pageSize: 2)

    state.mergeFetchedPage([makeNote(3)], pageSize: 2)

    XCTAssertEqual(state.notes.map(\.noteId), ["note-1", "note-2", "note-3"])
    XCTAssertEqual(state.nextOffset, 3)
    XCTAssertFalse(state.hasMore)
    XCTAssertFalse(state.canLoadMore)
  }

  func testDuplicateIdsReplaceExistingNotesWithoutChangingOrder() {
    var state = RielaNoteFileTreeNotebookNotesPageState()
    state.mergeFetchedPage([makeNote(1, title: "Original"), makeNote(2)], pageSize: 2)

    state.mergeFetchedPage([makeNote(2, title: "Updated"), makeNote(3)], pageSize: 2)

    XCTAssertEqual(state.notes.map(\.noteId), ["note-1", "note-2", "note-3"])
    XCTAssertEqual(state.notes[1].title, "Updated")
    XCTAssertEqual(state.nextOffset, 4)
  }

  func testResetClearsCachedFreshnessAndLoadingState() {
    var state = RielaNoteFileTreeNotebookNotesPageState()
    state.markLoading()
    state.mergeFetchedPage((1...3).map { makeNote($0) }, pageSize: 2)

    state.reset()

    XCTAssertFalse(state.didLoad)
    XCTAssertTrue(state.notes.isEmpty)
    XCTAssertEqual(state.nextOffset, 0)
    XCTAssertFalse(state.hasMore)
    XCTAssertFalse(state.isLoading)
  }

  func testNearTrailingEdgeTriggersNextPageOnlyInsideThreshold() {
    var state = RielaNoteFileTreeNotebookNotesPageState()
    state.mergeFetchedPage((1...6).map { makeNote($0) }, pageSize: 5)

    XCTAssertFalse(state.shouldLoadNextPage(visibleNoteId: "note-2", trailingThreshold: 1))
    XCTAssertTrue(state.shouldLoadNextPage(visibleNoteId: "note-4", trailingThreshold: 1))
    XCTAssertTrue(state.shouldLoadNextPage(visibleNoteId: "note-5", trailingThreshold: 1))
  }

  func testNearTrailingEdgeRefusesLoadingExhaustedAndUnknownNotes() {
    var loadingState = RielaNoteFileTreeNotebookNotesPageState()
    loadingState.mergeFetchedPage((1...6).map { makeNote($0) }, pageSize: 5)
    loadingState.markLoading()

    XCTAssertFalse(loadingState.shouldLoadNextPage(visibleNoteId: "note-5", trailingThreshold: 2))

    var exhaustedState = RielaNoteFileTreeNotebookNotesPageState()
    exhaustedState.mergeFetchedPage((1...5).map { makeNote($0) }, pageSize: 5)

    XCTAssertFalse(exhaustedState.shouldLoadNextPage(visibleNoteId: "note-5", trailingThreshold: 2))
    XCTAssertFalse(exhaustedState.shouldLoadNextPage(visibleNoteId: "missing", trailingThreshold: 2))
  }

  private func makeNote(_ index: Int, title: String? = nil) -> Note {
    Note(
      noteId: "note-\(index)",
      notebookId: "notebook-1",
      noteNumber: index,
      title: title ?? "Note \(index)",
      bodyMarkdown: "# Note \(index)",
      readOnly: false,
      createdAt: "2026-07-19T00:00:00Z",
      updatedAt: "2026-07-19T00:00:00Z"
    )
  }
}
