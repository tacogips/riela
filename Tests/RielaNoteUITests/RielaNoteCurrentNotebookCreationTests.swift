import Foundation
import RielaNote
@testable import RielaNoteUI
import XCTest

@MainActor
final class RielaNoteCurrentNotebookCreationTests: XCTestCase {
  func testViewModelCreatesNoteInSelectedNotebookAndSelectsIt() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)
    await viewModel.selectNotebook("notebook-1")
    viewModel.searchText = "draft"

    try await viewModel.createNoteInSelectedNotebook()

    XCTAssertEqual(fixture.client.createdNotebookNotes.count, 1)
    XCTAssertEqual(viewModel.selectedNotebookId, "notebook-1")
    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-current-1")
    XCTAssertEqual(viewModel.selectedNote?.bodyMarkdown, "")
    XCTAssertEqual(viewModel.selectedNote?.tags.map(\.tag.name), ["user-memo"])
    XCTAssertEqual(viewModel.notebookNotes.map(\.noteId), ["note-1", "note-2", "note-current-1"])
    XCTAssertFalse(viewModel.isSearching)
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testViewModelCreatesNoteInSelectedNotebookWithDraftContent() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)
    await viewModel.selectNotebook("notebook-1")

    try await viewModel.createNoteInSelectedNotebook(body: "Capture the first draft.")

    XCTAssertEqual(fixture.client.createdNotebookNotes.count, 1)
    XCTAssertEqual(viewModel.selectedNote?.bodyMarkdown, "Capture the first draft.")
    XCTAssertEqual(viewModel.selectedNote?.tags.map(\.tag.name), ["user-memo"])
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testNoteServiceClientCreatesEditableNoteInExistingNotebook() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/RielaNoteCurrentNotebookCreationTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let first = try service.createNote(bodyMarkdown: "# Existing\n\nBody")
    let client = NoteServiceRielaNoteUIClient(service: service)

    let created = try await client.createNote(inNotebook: first.notebookId, bodyMarkdown: "# Follow-up\n\nBody")

    XCTAssertEqual(created.note.notebookId, first.notebookId)
    XCTAssertEqual(created.note.noteNumber, 2)
    XCTAssertEqual(created.note.readOnly, false)
    XCTAssertEqual(created.note.tags.map(\.tag.name), ["user-memo"])
    XCTAssertEqual(try service.listNotes(notebookId: first.notebookId).map(\.noteId), [first.noteId, created.note.noteId])
  }
}
