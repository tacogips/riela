import RielaNote
@testable import RielaNoteUI
import XCTest

final class RielaNoteUIClientWindowTests: XCTestCase {
  func testDefaultClientRejectsUnpositionedNonFirstPageWindow() async throws {
    let fixture = NoteUITestFixture()

    do {
      _ = try await fixture.client.notebookNotesWindow(
        containing: fixture.searchNote.noteId,
        pageSize: 1
      )
      XCTFail("Expected the default client to reject a window with an unknown absolute offset.")
    } catch {
      XCTAssertEqual(
        error as? RielaNoteUIClientCapabilityError,
        .notebookNotesWindowUnsupported
      )
      XCTAssertEqual(
        rielaNoteLoadFailureMessage(error),
        "This note source cannot open a bounded reader window."
      )
    }
  }

  func testServiceClientLoadsCenteredBoundedWindowForDirectSelection() async throws {
    let service = try makeService()
    let ingest = try service.createNotebookWithNotes(
      title: "Reader",
      pages: (1...6).map { (index: Int) -> NotePageDraft in
        NotePageDraft(bodyMarkdown: "# Page \(index)", noteNumber: index)
      }
    )
    let orderedNotes = try service.listNotes(notebookId: ingest.notebook.notebookId)
    let client = NoteServiceRielaNoteUIClient(service: service)

    let window = try await client.notebookNotesWindow(
      containing: orderedNotes[4].noteId,
      pageSize: 2
    )

    XCTAssertEqual(window.notes.map(\.noteId), [orderedNotes[3].noteId, orderedNotes[4].noteId])
    XCTAssertEqual(window.startOffset, 3)
    XCTAssertTrue(window.hasEarlierNotes)
    XCTAssertTrue(window.hasMoreNotes)
  }
}
