import Foundation
import RielaNote
@testable import RielaNoteUI
import XCTest

/// TASK-006 (T5): failing-mutation tests. Every mutation must rethrow instead of
/// writing `state = .failed`, leave `state == .loaded`, and preserve the user's
/// draft/selection so the view can keep the editor/compose/sheet open.
@MainActor
final class RielaNoteMutationFailureTests: XCTestCase {
  func testFailedBodySaveRethrowsAndLeavesStateLoaded() async throws {
    let fixture = NoteUITestFixture()
    let client = FailingRielaNoteUIClient(base: fixture.client)
    let viewModel = RielaNoteLibraryViewModel(client: client)
    await viewModel.selectNote("note-2")
    let originalBody = viewModel.selectedNote?.bodyMarkdown

    client.failUpdateNoteBody = true
    await XCTAssertThrowsErrorAsync(
      try await viewModel.saveSelectedNoteBody("# Draft edit\n\nUnsaved", expectedNoteId: "note-2")
    )

    // The store body is unchanged (the save never landed) and the list state is
    // still loaded — no `.failed` overlay.
    XCTAssertEqual(viewModel.selectedNote?.bodyMarkdown, originalBody)
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testFailedCreateUserMemoRethrowsAndLeavesStateLoaded() async throws {
    let fixture = NoteUITestFixture()
    let client = FailingRielaNoteUIClient(base: fixture.client)
    let viewModel = RielaNoteLibraryViewModel(client: client)
    await viewModel.load()

    client.failCreateUserMemo = true
    await XCTAssertThrowsErrorAsync(try await viewModel.createUserMemo(body: "Lost memo"))

    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertTrue(fixture.client.createdMemos.isEmpty)
  }

  func testFailedCreateNoteInNotebookRethrowsAndLeavesStateLoaded() async throws {
    let fixture = NoteUITestFixture()
    let client = FailingRielaNoteUIClient(base: fixture.client)
    let viewModel = RielaNoteLibraryViewModel(client: client)
    await viewModel.selectNotebook("notebook-1")

    client.failCreateNote = true
    await XCTAssertThrowsErrorAsync(try await viewModel.createNoteInSelectedNotebook(body: "Lost draft"))

    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertTrue(fixture.client.createdNotebookNotes.isEmpty)
  }

  func testFailedCommentAddRethrowsAndLeavesStateLoaded() async throws {
    let fixture = NoteUITestFixture()
    let client = FailingRielaNoteUIClient(base: fixture.client)
    let viewModel = RielaNoteLibraryViewModel(client: client)
    await viewModel.selectNote("note-2")

    client.failAddComment = true
    await XCTAssertThrowsErrorAsync(try await viewModel.addCommentToSelectedNote("Kept draft"))

    // No comment stored; state stays loaded so the detail view keeps the draft.
    XCTAssertEqual(viewModel.selectedDetail?.comments.count, 0)
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testFailedTagAddRethrowsAndLeavesStateLoaded() async throws {
    let fixture = NoteUITestFixture()
    let client = FailingRielaNoteUIClient(base: fixture.client)
    let viewModel = RielaNoteLibraryViewModel(client: client)
    await viewModel.selectNote("note-2")

    client.failApplyTag = true
    await XCTAssertThrowsErrorAsync(try await viewModel.applyTagToSelectedNote(name: "idea"))

    XCTAssertFalse(viewModel.selectedNote?.tags.contains { $0.tag.name == "idea" } == true)
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testFailedTagRemoveRethrowsAndLeavesStateLoaded() async throws {
    // FIX-7(a): exercises the previously-unused `failRemoveTag` flag. A failed
    // tag removal rethrows, leaves the selected note's tags intact (so the view
    // keeps its draft field), and keeps `state == .loaded`.
    let fixture = NoteUITestFixture()
    let client = FailingRielaNoteUIClient(base: fixture.client)
    let viewModel = RielaNoteLibraryViewModel(client: client)
    await viewModel.selectNote("note-2")
    // Add a removable tag first through the (succeeding) base path.
    try await viewModel.applyTagToSelectedNote(name: "idea")
    let tagsBefore = viewModel.selectedNote?.tags.map(\.tag.name)

    client.failRemoveTag = true
    await XCTAssertThrowsErrorAsync(try await viewModel.removeTagFromSelectedNote(name: "idea"))

    // The tag is still present (removal never landed) and state stays loaded.
    XCTAssertEqual(viewModel.selectedNote?.tags.map(\.tag.name), tagsBefore)
    XCTAssertTrue(viewModel.selectedNote?.tags.contains { $0.tag.name == "idea" } == true)
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testFailedLinkRethrowsAndLeavesStateLoaded() async throws {
    let fixture = NoteUITestFixture()
    let client = FailingRielaNoteUIClient(base: fixture.client)
    let viewModel = RielaNoteLibraryViewModel(client: client)
    await viewModel.selectNote("note-2")

    client.failLinkNote = true
    await XCTAssertThrowsErrorAsync(try await viewModel.linkSelectedNote(to: "note-1", kind: "related"))

    XCTAssertEqual(viewModel.selectedDetail?.links.count, 0)
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testGuardFailuresThrow() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)
    // No selection: mutations that require a selected note throw.
    await XCTAssertThrowsErrorAsync(try await viewModel.saveSelectedNoteBody("body"))
    await XCTAssertThrowsErrorAsync(try await viewModel.addCommentToSelectedNote("comment"))
    await XCTAssertThrowsErrorAsync(try await viewModel.applyTagToSelectedNote(name: "tag"))
    await XCTAssertThrowsErrorAsync(try await viewModel.linkSelectedNote(to: "note-1"))
    // No selected notebook: create-in-notebook throws.
    await XCTAssertThrowsErrorAsync(try await viewModel.createNoteInSelectedNotebook())
    XCTAssertEqual(viewModel.state, .idle)
  }
}

/// Decorates a `MockRielaNoteUIClient`, forwarding every call but throwing on the
/// mutation the test flags. Read paths (list/detail/search) always succeed so the
/// view model can reach `.loaded` before the failing mutation runs.
final class FailingRielaNoteUIClient: RielaNoteUIClient, @unchecked Sendable {
  let base: MockRielaNoteUIClient
  var failUpdateNoteBody = false
  var failCreateUserMemo = false
  var failCreateNote = false
  var failAddComment = false
  var failApplyTag = false
  var failRemoveTag = false
  var failLinkNote = false
  var failSetNotebookProgress = false

  init(base: MockRielaNoteUIClient) {
    self.base = base
  }

  var defaultConfigWorkflowRoot: String {
    base.defaultConfigWorkflowRoot
  }

  func listNotebooks(limit: Int, offset: Int) async throws -> [Notebook] {
    try await base.listNotebooks(limit: limit, offset: offset)
  }

  func setNotebookProgress(
    notebookId: String,
    progress: NotebookProgress
  ) async throws -> Notebook {
    if failSetNotebookProgress {
      throw NoteServiceError.invalidInput("progress mutation failed")
    }
    return try await base.setNotebookProgress(
      notebookId: notebookId,
      progress: progress
    )
  }

  func listNotes(notebookId: String, limit: Int, offset: Int) async throws -> [Note] {
    try await base.listNotes(notebookId: notebookId, limit: limit, offset: offset)
  }

  func listTags() async throws -> [Tag] {
    try await base.listTags()
  }

  func createUserMemo(bodyMarkdown: String) async throws -> RielaNoteDetail {
    if failCreateUserMemo {
      throw NoteServiceError.invalidInput("create failed")
    }
    return try await base.createUserMemo(bodyMarkdown: bodyMarkdown)
  }

  func createNote(inNotebook notebookId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    if failCreateNote {
      throw NoteServiceError.invalidInput("create failed")
    }
    return try await base.createNote(inNotebook: notebookId, bodyMarkdown: bodyMarkdown)
  }

  func searchNotes(
    query: String,
    tagFilter: [String],
    classFilter: [String],
    limit: Int,
    offset: Int
  ) async throws -> [NoteSearchResult] {
    try await base.searchNotes(
      query: query,
      tagFilter: tagFilter,
      classFilter: classFilter,
      limit: limit,
      offset: offset
    )
  }

  func noteDetail(noteId: String) async throws -> RielaNoteDetail {
    try await base.noteDetail(noteId: noteId)
  }

  func firstNote(inNotebook notebookId: String) async throws -> RielaNoteDetail? {
    try await base.firstNote(inNotebook: notebookId)
  }

  func resolveFile(fileId: String) async throws -> RielaNoteResolvedFile {
    try await base.resolveFile(fileId: fileId)
  }

  func updateNoteBody(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    if failUpdateNoteBody {
      throw NoteServiceError.invalidInput("save failed")
    }
    return try await base.updateNoteBody(noteId: noteId, bodyMarkdown: bodyMarkdown)
  }

  func applyTag(noteId: String, tagName: String, classId: String?) async throws -> RielaNoteDetail {
    if failApplyTag {
      throw NoteServiceError.invalidInput("tag failed")
    }
    return try await base.applyTag(noteId: noteId, tagName: tagName, classId: classId)
  }

  func removeTag(noteId: String, tagName: String) async throws -> RielaNoteDetail {
    if failRemoveTag {
      throw NoteServiceError.invalidInput("remove failed")
    }
    return try await base.removeTag(noteId: noteId, tagName: tagName)
  }

  func addComment(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    if failAddComment {
      throw NoteServiceError.invalidInput("comment failed")
    }
    return try await base.addComment(noteId: noteId, bodyMarkdown: bodyMarkdown)
  }

  func linkNote(noteId: String, targetNoteId: String, linkKind: String) async throws -> RielaNoteDetail {
    if failLinkNote {
      throw NoteServiceError.invalidInput("link failed")
    }
    return try await base.linkNote(noteId: noteId, targetNoteId: targetNoteId, linkKind: linkKind)
  }

  func answerNoteAgentTurn(message: String, limit: Int) async throws -> RielaNoteAgentTurn {
    try await base.answerNoteAgentTurn(message: message, limit: limit)
  }

  func saveNoteAgentConversation(
    title: String,
    turns: [RielaNoteAgentTurn]
  ) async throws -> RielaNoteAgentConversationSaveResult {
    try await base.saveNoteAgentConversation(title: title, turns: turns)
  }

  func appendNoteAgentTurn(
    notebookId: String,
    turn: RielaNoteAgentTurn
  ) async throws -> RielaNoteAgentConversationSaveResult {
    try await base.appendNoteAgentTurn(notebookId: notebookId, turn: turn)
  }

  func proposeNoteConfigAgentChange(message: String) async throws -> RielaNoteConfigAgentProposal {
    try await base.proposeNoteConfigAgentChange(message: message)
  }

  func applyNoteConfigAgentProposal(
    _ proposal: RielaNoteConfigAgentProposal,
    workflowRoot: String
  ) async throws -> RielaNoteConfigAgentApplyResult {
    try await base.applyNoteConfigAgentProposal(proposal, workflowRoot: workflowRoot)
  }
}

@MainActor
func XCTAssertThrowsErrorAsync(
  _ expression: @autoclosure () async throws -> some Sendable,
  _ errorHandler: (Error) -> Void = { _ in },
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("expected error", file: file, line: line)
  } catch {
    errorHandler(error)
  }
}
