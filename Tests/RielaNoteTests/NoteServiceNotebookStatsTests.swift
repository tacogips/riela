import RielaNote
import XCTest

final class NoteServiceNotebookStatsTests: NoteTestCase {
  func testListAndGetNotebookIncludeNoteCount() throws {
    let service = try makeService()
    let result = try service.createNotebookWithNotes(
      title: "Multi-page Notebook",
      pages: [
        NotePageDraft(bodyMarkdown: "# Page One\n\nFirst body"),
        NotePageDraft(bodyMarkdown: "# Page Two\n\nSecond body")
      ]
    )

    let listed = try service.listNotebooks()
    XCTAssertEqual(listed.first?.notebookId, result.notebook.notebookId)
    XCTAssertEqual(listed.first?.noteCount, 2)
    XCTAssertEqual(listed.first?.firstNotePreview?.contains("First body"), true)

    let fetched = try service.getNotebook(result.notebook.notebookId)
    XCTAssertEqual(fetched.noteCount, 2)
    XCTAssertEqual(fetched.firstNotePreview?.contains("First body"), true)
  }

  func testEmptyNotebookReportsZeroNotes() throws {
    let service = try makeService()
    let notebook = try service.createNotebook(title: "Empty Notebook")

    XCTAssertEqual(notebook.noteCount, 0)
    XCTAssertEqual(try service.listNotebooks().first?.noteCount, 0)
  }
}
