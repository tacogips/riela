import Foundation
import RielaNote
@testable import RielaNoteUI
import XCTest

@MainActor
final class RielaNoteLibraryNotebookPaginationTests: XCTestCase {
  func testLoadFetchesOneExtraNotebookToExposePagination() async throws {
    let client = NotebookPaginationClient()
    let viewModel = RielaNoteLibraryViewModel(client: client, notebookLimit: 2)

    await viewModel.load()

    XCTAssertEqual(client.listNotebookRequests, [
      NotebookListRequest(limit: 3, offset: 0)
    ])
    XCTAssertEqual(viewModel.notebooks.map(\.notebookId), ["notebook-1", "notebook-2"])
    XCTAssertTrue(viewModel.canLoadMoreNotebooks)
    XCTAssertEqual(viewModel.selectedNotebookId, "notebook-1")
    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-1")
  }

  func testLoadMoreNotebooksAppendsNextPageAndStopsAtEnd() async throws {
    let client = NotebookPaginationClient()
    let viewModel = RielaNoteLibraryViewModel(client: client, notebookLimit: 2)

    await viewModel.load()
    await viewModel.loadMoreNotebooks()

    XCTAssertEqual(client.listNotebookRequests, [
      NotebookListRequest(limit: 3, offset: 0),
      NotebookListRequest(limit: 3, offset: 2)
    ])
    XCTAssertEqual(viewModel.notebooks.map(\.notebookId), ["notebook-1", "notebook-2", "notebook-3"])
    XCTAssertFalse(viewModel.canLoadMoreNotebooks)
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testCreateNoteInLaterPageNotebookKeepsNotebookVisible() async throws {
    let client = NotebookPaginationClient()
    let viewModel = RielaNoteLibraryViewModel(client: client, notebookLimit: 2)

    await viewModel.load()
    await viewModel.loadMoreNotebooks()
    await viewModel.selectNotebook("notebook-3")
    try await viewModel.createNoteInSelectedNotebook(body: "Draft")

    XCTAssertEqual(viewModel.selectedNotebookId, "notebook-3")
    XCTAssertTrue(viewModel.notebooks.contains(where: { $0.notebookId == "notebook-3" }))
    XCTAssertEqual(viewModel.selectedNote?.notebookId, "notebook-3")
    XCTAssertEqual(viewModel.selectedNote?.bodyMarkdown, "Draft")
    XCTAssertEqual(Array(client.listNotebookRequests.suffix(2)), [
      NotebookListRequest(limit: 3, offset: 0),
      NotebookListRequest(limit: 3, offset: 2)
    ])
  }

  func testLoadMoreNotebookNotesKeepsOffsetEqualToNoteCount() async throws {
    let client = NotebookNotesPaginationClient()
    let viewModel = RielaNoteLibraryViewModel(client: client, notebookNoteLimit: 2)

    await viewModel.selectNotebook("notebook-notes")
    XCTAssertEqual(viewModel.notebookNotesOffsetForTesting, viewModel.notebookNotes.count)
    XCTAssertTrue(viewModel.canLoadMoreNotebookNotes)

    await viewModel.loadMoreNotebookNotes()

    // Offset invariant: the shared cursor advances only by the notes actually appended.
    XCTAssertEqual(viewModel.notebookNotesOffsetForTesting, viewModel.notebookNotes.count)
    XCTAssertEqual(viewModel.notebookNotes.map(\.noteId), ["n-1", "n-2", "n-3", "n-4"])
  }

  func testReaderEdgeLoadsOneAdditionalNotebookNotesPage() async throws {
    let client = NotebookNotesPaginationClient()
    let viewModel = RielaNoteLibraryViewModel(client: client, notebookNoteLimit: 2)

    await viewModel.selectNotebook("notebook-notes")

    XCTAssertEqual(viewModel.notebookNotes.map(\.noteId), ["n-1", "n-2"])
    let beforeEdgeLoad = await viewModel.loadNextNotebookNotesPageIfNeeded(visibleNoteId: "n-1", trailingThreshold: 0)
    XCTAssertFalse(beforeEdgeLoad)
    XCTAssertEqual(viewModel.notebookNotes.map(\.noteId), ["n-1", "n-2"])

    let edgeLoad = await viewModel.loadNextNotebookNotesPageIfNeeded(visibleNoteId: "n-2", trailingThreshold: 0)
    XCTAssertTrue(edgeLoad)
    XCTAssertEqual(viewModel.notebookNotes.map(\.noteId), ["n-1", "n-2", "n-3", "n-4"])
  }
}

private final class NotebookPaginationClient: RielaNoteUIClient, @unchecked Sendable {
  private let notebooks: [Notebook]
  private var notesByNotebookId: [String: [Note]]
  var listNotebookRequests: [NotebookListRequest] = []

  init() {
    notebooks = (1...3).map { index in
      Notebook(
        notebookId: "notebook-\(index)",
        title: "Notebook \(index)",
        createdAt: "2026-07-04T00:00:00Z",
        updatedAt: "2026-07-04T00:00:00Z"
      )
    }
    notesByNotebookId = Dictionary(uniqueKeysWithValues: notebooks.enumerated().map { offset, notebook in
      let number = offset + 1
      return (
        notebook.notebookId,
        [Note(
          noteId: "note-\(number)",
          notebookId: notebook.notebookId,
          noteNumber: 1,
          title: "Note \(number)",
          bodyMarkdown: "# Note \(number)\n\nBody",
          readOnly: false,
          createdAt: "2026-07-04T00:00:00Z",
          updatedAt: "2026-07-04T00:00:00Z"
        )]
      )
    })
  }

  var defaultConfigWorkflowRoot: String {
    "tmp/RielaNoteLibraryNotebookPaginationTests/workflows"
  }

  func listNotebooks(limit: Int, offset: Int) async throws -> [Notebook] {
    listNotebookRequests.append(NotebookListRequest(limit: limit, offset: offset))
    return Array(notebooks.dropFirst(offset).prefix(limit))
  }

  func listNotes(notebookId: String, limit: Int, offset: Int) async throws -> [Note] {
    Array((notesByNotebookId[notebookId] ?? []).dropFirst(offset).prefix(limit))
  }

  func listTags() async throws -> [Tag] {
    []
  }

  func createUserMemo(bodyMarkdown: String) async throws -> RielaNoteDetail {
    try await createNote(inNotebook: notebooks[0].notebookId, bodyMarkdown: bodyMarkdown)
  }

  func createNote(inNotebook notebookId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    let noteNumber = (notesByNotebookId[notebookId]?.count ?? 0) + 1
    let note = Note(
      noteId: "note-created-\(noteNumber)",
      notebookId: notebookId,
      noteNumber: noteNumber,
      title: "Created \(noteNumber)",
      bodyMarkdown: bodyMarkdown,
      readOnly: false,
      createdAt: "2026-07-04T00:00:00Z",
      updatedAt: "2026-07-04T00:00:00Z"
    )
    notesByNotebookId[notebookId, default: []].append(note)
    return RielaNoteDetail(note: note)
  }

  func searchNotes(
    query: String,
    tagFilter: [String],
    classFilter: [String],
    limit: Int,
    offset: Int
  ) async throws -> [NoteSearchResult] {
    []
  }

  func noteDetail(noteId: String) async throws -> RielaNoteDetail {
    guard let note = notesByNotebookId.values.flatMap({ $0 }).first(where: { $0.noteId == noteId }) else {
      throw NotebookPaginationClientError.missingNote
    }
    return RielaNoteDetail(note: note)
  }

  func firstNote(inNotebook notebookId: String) async throws -> RielaNoteDetail? {
    guard let note = notesByNotebookId[notebookId]?.first else {
      return nil
    }
    return RielaNoteDetail(note: note)
  }

  func resolveFile(fileId: String) async throws -> RielaNoteResolvedFile {
    throw NotebookPaginationClientError.unsupported
  }

  func updateNoteBody(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw NotebookPaginationClientError.unsupported
  }

  func applyTag(noteId: String, tagName: String, classId: String?) async throws -> RielaNoteDetail {
    throw NotebookPaginationClientError.unsupported
  }

  func removeTag(noteId: String, tagName: String) async throws -> RielaNoteDetail {
    throw NotebookPaginationClientError.unsupported
  }

  func addComment(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw NotebookPaginationClientError.unsupported
  }

  func linkNote(noteId: String, targetNoteId: String, linkKind: String) async throws -> RielaNoteDetail {
    throw NotebookPaginationClientError.unsupported
  }

  func answerNoteAgentTurn(message: String, limit: Int) async throws -> RielaNoteAgentTurn {
    throw NotebookPaginationClientError.unsupported
  }

  func saveNoteAgentConversation(
    title: String,
    turns: [RielaNoteAgentTurn]
  ) async throws -> RielaNoteAgentConversationSaveResult {
    throw NotebookPaginationClientError.unsupported
  }

  func appendNoteAgentTurn(
    notebookId: String,
    turn: RielaNoteAgentTurn
  ) async throws -> RielaNoteAgentConversationSaveResult {
    throw NotebookPaginationClientError.unsupported
  }

  func proposeNoteConfigAgentChange(message: String) async throws -> RielaNoteConfigAgentProposal {
    throw NotebookPaginationClientError.unsupported
  }

  func applyNoteConfigAgentProposal(
    _ proposal: RielaNoteConfigAgentProposal,
    workflowRoot: String
  ) async throws -> RielaNoteConfigAgentApplyResult {
    throw NotebookPaginationClientError.unsupported
  }
}

private final class NotebookNotesPaginationClient: RielaNoteUIClient, @unchecked Sendable {
  private let notebook = Notebook(
    notebookId: "notebook-notes",
    title: "Notes",
    createdAt: "2026-07-04T00:00:00Z",
    updatedAt: "2026-07-04T00:00:00Z"
  )
  private let notes: [Note]

  init() {
    notes = (1...4).map { index in
      Note(
        noteId: "n-\(index)",
        notebookId: "notebook-notes",
        noteNumber: index,
        title: "Note \(index)",
        bodyMarkdown: "# Note \(index)",
        readOnly: false,
        createdAt: "2026-07-04T00:00:00Z",
        updatedAt: "2026-07-04T00:00:00Z"
      )
    }
  }

  var defaultConfigWorkflowRoot: String {
    "tmp/RielaNoteLibraryNotebookPaginationTests/notes-workflows"
  }

  func listNotebooks(limit: Int, offset: Int) async throws -> [Notebook] {
    Array([notebook].dropFirst(offset).prefix(limit))
  }

  func listNotes(notebookId: String, limit: Int, offset: Int) async throws -> [Note] {
    Array(notes.dropFirst(offset).prefix(limit))
  }

  func listTags() async throws -> [Tag] {
    []
  }

  func createUserMemo(bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw NotebookPaginationClientError.unsupported
  }

  func searchNotes(
    query: String,
    tagFilter: [String],
    classFilter: [String],
    limit: Int,
    offset: Int
  ) async throws -> [NoteSearchResult] {
    []
  }

  func noteDetail(noteId: String) async throws -> RielaNoteDetail {
    guard let note = notes.first(where: { $0.noteId == noteId }) else {
      throw NotebookPaginationClientError.missingNote
    }
    return RielaNoteDetail(note: note)
  }

  func firstNote(inNotebook notebookId: String) async throws -> RielaNoteDetail? {
    notes.first.map { RielaNoteDetail(note: $0) }
  }

  func resolveFile(fileId: String) async throws -> RielaNoteResolvedFile {
    throw NotebookPaginationClientError.unsupported
  }

  func updateNoteBody(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw NotebookPaginationClientError.unsupported
  }

  func applyTag(noteId: String, tagName: String, classId: String?) async throws -> RielaNoteDetail {
    throw NotebookPaginationClientError.unsupported
  }

  func removeTag(noteId: String, tagName: String) async throws -> RielaNoteDetail {
    throw NotebookPaginationClientError.unsupported
  }

  func addComment(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw NotebookPaginationClientError.unsupported
  }

  func linkNote(noteId: String, targetNoteId: String, linkKind: String) async throws -> RielaNoteDetail {
    throw NotebookPaginationClientError.unsupported
  }

  func answerNoteAgentTurn(message: String, limit: Int) async throws -> RielaNoteAgentTurn {
    throw NotebookPaginationClientError.unsupported
  }

  func saveNoteAgentConversation(
    title: String,
    turns: [RielaNoteAgentTurn]
  ) async throws -> RielaNoteAgentConversationSaveResult {
    throw NotebookPaginationClientError.unsupported
  }

  func appendNoteAgentTurn(
    notebookId: String,
    turn: RielaNoteAgentTurn
  ) async throws -> RielaNoteAgentConversationSaveResult {
    throw NotebookPaginationClientError.unsupported
  }

  func proposeNoteConfigAgentChange(message: String) async throws -> RielaNoteConfigAgentProposal {
    throw NotebookPaginationClientError.unsupported
  }

  func applyNoteConfigAgentProposal(
    _ proposal: RielaNoteConfigAgentProposal,
    workflowRoot: String
  ) async throws -> RielaNoteConfigAgentApplyResult {
    throw NotebookPaginationClientError.unsupported
  }
}

private struct NotebookListRequest: Equatable {
  var limit: Int
  var offset: Int
}

private enum NotebookPaginationClientError: Error {
  case missingNote
  case unsupported
}
