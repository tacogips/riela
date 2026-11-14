import Foundation
import RielaNote
@testable import RielaNoteUI
import XCTest

@MainActor
final class RielaNoteSelectionQATests: XCTestCase {
  // MARK: - Comment markdown helper

  func testSelectionQACommentMarkdownQuotesMultiLineSelection() {
    let markdown = rielaNoteSelectionQACommentMarkdown(
      selectedText: "First line\nSecond line",
      question: "What does this mean?",
      answerMarkdown: "It means two things."
    )

    XCTAssertEqual(markdown, """
    > First line
    > Second line

    **Q:** What does this mean?

    **A:** It means two things.
    """)
  }

  func testSelectionQACommentMarkdownTruncatesLongSelection() {
    let longSelection = String(repeating: "a", count: 500)
    let markdown = rielaNoteSelectionQACommentMarkdown(
      selectedText: longSelection,
      question: "Q",
      answerMarkdown: "A"
    )

    let quotedLine = markdown.split(separator: "\n").first.map(String.init) ?? ""
    XCTAssertTrue(quotedLine.hasPrefix("> "))
    XCTAssertTrue(quotedLine.hasSuffix("…"))
    // "> " prefix (2) + 400 quoted chars + "…" (1) == 403.
    XCTAssertEqual(quotedLine.count, 403)
  }

  func testSelectionQACommentMarkdownPreservesEmoji() {
    let markdown = rielaNoteSelectionQACommentMarkdown(
      selectedText: "Idea 🧠 here",
      question: "Meaning?",
      answerMarkdown: "Brainstorm."
    )

    XCTAssertTrue(markdown.contains("> Idea 🧠 here"))
  }

  // MARK: - View-model lifecycle

  func testAskSelectionQuestionPersistsExactlyOneComment() async throws {
    let client = SelectionQATestClient()
    client.answerDraft = RielaNoteSelectionAnswerDraft(answerMarkdown: "Answer body", summary: "Sum")
    let viewModel = RielaNoteLibraryViewModel(client: client)

    await viewModel.selectNote("note-2")
    let saved = await viewModel.askSelectionQuestion(
      question: "What is this?",
      draftBodyMarkdown: "# Ontology\n\nSearch body",
      selectedText: "Search",
      selectionStart: 12,
      selectionEnd: 18
    )

    XCTAssertTrue(saved)
    XCTAssertTrue(viewModel.didSaveSelectionQuestionComment)
    XCTAssertNil(viewModel.selectionQuestionError)
    XCTAssertFalse(viewModel.isSelectionQuestionLoading)
    XCTAssertEqual(client.answerRequests.count, 1)
    XCTAssertEqual(client.answerRequests.first?.selectedText, "Search")
    XCTAssertEqual(client.addCommentCalls.count, 1)
    XCTAssertEqual(client.addCommentCalls.first?.author, "note-agent")
    XCTAssertEqual(
      client.addCommentCalls.first?.bodyMarkdown,
      rielaNoteSelectionQACommentMarkdown(
        selectedText: "Search",
        question: "What is this?",
        answerMarkdown: "Answer body"
      )
    )
    XCTAssertEqual(viewModel.selectedDetail?.comments.count, 1)
  }

  func testAskSelectionQuestionFailurePersistsNothing() async throws {
    let client = SelectionQATestClient()
    client.answerError = RielaNoteSelectionQuestionError.workflowFailed("boom")
    let viewModel = RielaNoteLibraryViewModel(client: client)

    await viewModel.selectNote("note-2")
    let saved = await viewModel.askSelectionQuestion(
      question: "What is this?",
      draftBodyMarkdown: "# Ontology",
      selectedText: "Search",
      selectionStart: 0,
      selectionEnd: 6
    )

    XCTAssertFalse(saved)
    XCTAssertNotNil(viewModel.selectionQuestionError)
    XCTAssertFalse(viewModel.didSaveSelectionQuestionComment)
    XCTAssertFalse(viewModel.isSelectionQuestionLoading)
    XCTAssertTrue(client.addCommentCalls.isEmpty)
  }

  func testAskSelectionQuestionNotConfiguredSurfacesMessage() async throws {
    let client = SelectionQATestClient()
    client.answerError = RielaNoteSelectionQuestionError.notConfigured
    let viewModel = RielaNoteLibraryViewModel(client: client)

    await viewModel.selectNote("note-2")
    let saved = await viewModel.askSelectionQuestion(
      question: "Q",
      draftBodyMarkdown: "# Ontology",
      selectedText: "Search",
      selectionStart: 0,
      selectionEnd: 6
    )

    XCTAssertFalse(saved)
    XCTAssertEqual(viewModel.selectionQuestionError, "Selection question agent is not configured.")
  }

  func testAskSelectionQuestionDropsStaleResultAfterNoteSwitch() async throws {
    let client = SelectionQATestClient()
    client.answerDelayNanoseconds = 50_000_000
    client.answerDraft = RielaNoteSelectionAnswerDraft(answerMarkdown: "late", summary: nil)
    let viewModel = RielaNoteLibraryViewModel(client: client)

    await viewModel.selectNote("note-2")
    let ask = Task {
      await viewModel.askSelectionQuestion(
        question: "Q",
        draftBodyMarkdown: "# Ontology",
        selectedText: "Search",
        selectionStart: 0,
        selectionEnd: 6
      )
    }
    try await Task.sleep(nanoseconds: 5_000_000)
    await viewModel.selectNote("note-1")
    let saved = await ask.value

    XCTAssertFalse(saved)
    XCTAssertNil(viewModel.selectionQuestionError)
    XCTAssertFalse(viewModel.didSaveSelectionQuestionComment)
    XCTAssertFalse(viewModel.isSelectionQuestionLoading)
  }

  func testPromoteCommentToNotebookRefreshesDetail() async throws {
    let client = SelectionQATestClient()
    let viewModel = RielaNoteLibraryViewModel(client: client)

    await viewModel.selectNote("note-2")
    await viewModel.promoteCommentToNotebook(commentId: "comment-1")

    XCTAssertEqual(client.promoteCalls, [SelectionQATestClient.PromoteCall(noteId: "note-2", commentId: "comment-1")])
    XCTAssertNil(viewModel.commentPromotionError)
    XCTAssertFalse(viewModel.isCommentPromotionLoading)
    XCTAssertEqual(viewModel.selectedDetail?.links.count, 1)
  }

  func testPromoteCommentToNotebookSurfacesError() async throws {
    let client = SelectionQATestClient()
    client.promoteError = RielaNoteUIClientCapabilityError.commentPromotionUnsupported
    let viewModel = RielaNoteLibraryViewModel(client: client)

    await viewModel.selectNote("note-2")
    await viewModel.promoteCommentToNotebook(commentId: "comment-1")

    XCTAssertNotNil(viewModel.commentPromotionError)
    XCTAssertFalse(viewModel.isCommentPromotionLoading)
  }

  // MARK: - Client round-trips against a real service

  func testNoteServiceClientSelectionQuestionProviderRoundTrip() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Draft\n\nBody")
    let provider = CapturingSelectionQuestionProvider(
      draft: RielaNoteSelectionAnswerDraft(answerMarkdown: "Answer", summary: "Sum")
    )
    let client = NoteServiceRielaNoteUIClient(service: service, selectionQuestionProvider: provider)

    let answer = try await client.answerNoteSelectionQuestion(
      noteId: note.noteId,
      question: "What?",
      bodyMarkdown: "# Draft\n\nBody",
      selectedText: "Body",
      selectionStart: 9,
      selectionEnd: 13
    )

    XCTAssertEqual(answer.answerMarkdown, "Answer")
    XCTAssertEqual(provider.requests.first?.noteId, note.noteId)
    XCTAssertEqual(provider.requests.first?.noteRoot, service.noteRootPath())
    XCTAssertEqual(provider.requests.first?.selectedText, "Body")
    XCTAssertEqual(provider.requests.first?.selectionStart, 9)
  }

  func testNoteServiceClientSelectionQuestionWithoutProviderThrowsNotConfigured() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Draft\n\nBody")
    let client = NoteServiceRielaNoteUIClient(service: service)

    do {
      _ = try await client.answerNoteSelectionQuestion(
        noteId: note.noteId,
        question: "What?",
        bodyMarkdown: note.bodyMarkdown,
        selectedText: "Body",
        selectionStart: 9,
        selectionEnd: 13
      )
      XCTFail("Expected notConfigured")
    } catch RielaNoteSelectionQuestionError.notConfigured {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testNoteServiceClientAddCommentPassesAuthorThrough() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Draft\n\nBody")
    let client = NoteServiceRielaNoteUIClient(service: service)

    let detail = try await client.addComment(noteId: note.noteId, bodyMarkdown: "Agent note", author: "note-agent")

    XCTAssertEqual(detail.comments.count, 1)
    XCTAssertEqual(detail.comments.first?.author, "note-agent")
    XCTAssertEqual(detail.comments.first?.bodyMarkdown, "Agent note")
  }

  func testNoteServiceClientPromoteCommentReturnsDetailWithLink() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Draft\n\nBody")
    let comment = try service.addComment(noteId: note.noteId, bodyMarkdown: "# Promote\n\nBody", author: "note-agent")
    let client = NoteServiceRielaNoteUIClient(service: service)

    let detail = try await client.promoteCommentToNotebook(noteId: note.noteId, commentId: comment.commentId)

    XCTAssertEqual(detail.links.count, 1)
    XCTAssertEqual(detail.links.first?.fromNoteId, note.noteId)
    XCTAssertEqual(detail.links.first?.linkKind, "related")
    let linkedNoteId = try XCTUnwrap(detail.links.first?.toNoteId)
    XCTAssertEqual(detail.linkedNotesById[linkedNoteId]?.bodyMarkdown, "# Promote\n\nBody")
  }

  // MARK: - Workflow provider

  #if os(macOS)
  func testWorkflowSelectionQuestionVariablesIncludeSelectionFields() throws {
    let variables = noteSelectionQuestionVariables(
      noteId: "note-1",
      noteRoot: "/tmp/notes",
      question: "What is this?",
      bodyMarkdown: "# Draft",
      selectedText: "Draft",
      selectionStart: 2,
      selectionEnd: 7
    )

    let workflowInput = try XCTUnwrap(variables["workflowInput"] as? [String: Any])
    XCTAssertEqual(variables["noteRoot"] as? String, "/tmp/notes")
    XCTAssertEqual(workflowInput["noteId"] as? String, "note-1")
    XCTAssertEqual(workflowInput["question"] as? String, "What is this?")
    XCTAssertEqual(workflowInput["selectedText"] as? String, "Draft")
    XCTAssertEqual(workflowInput["selectionStart"] as? Int, 2)
    XCTAssertEqual(workflowInput["selectionEnd"] as? Int, 7)
  }

  func testWorkflowSelectionQuestionRunArgumentsUseVariablesFile() {
    let arguments = rielaWorkflowRunArguments(
      workflowName: "note-selection-question",
      workflowDefinitionDirectory: "/tmp/examples",
      variablesFilePath: "/tmp/riela-note-workflow/variables.json"
    )

    XCTAssertEqual(arguments, [
      "workflow",
      "run",
      "note-selection-question",
      "--workflow-definition-dir",
      "/tmp/examples",
      "--variables-file",
      "/tmp/riela-note-workflow/variables.json",
      "--output",
      "jsonl"
    ])
    XCTAssertFalse(arguments.contains("--variables"))
  }

  func testWorkflowSelectionAnswerParserReadsLastDecodableRootOutputLine() {
    let output = """
    {"event":"progress"}
    {"result":{"rootOutput":{"answerMarkdown":"first","summary":"ignored"}}}
    {"result":{"rootOutput":{"answerMarkdown":"second","summary":"used"}}}
    """

    let draft = parseNoteSelectionAnswerDraft(from: output)

    XCTAssertEqual(draft, RielaNoteSelectionAnswerDraft(answerMarkdown: "second", summary: "used"))
  }
  #endif
}

// MARK: - Test doubles

private enum SelectionQATestError: Error {
  case unsupported
}

private final class CapturingSelectionQuestionProvider: RielaNoteSelectionQuestionProviding, @unchecked Sendable {
  struct Request: Equatable {
    var noteId: String
    var noteRoot: String
    var question: String
    var bodyMarkdown: String
    var selectedText: String
    var selectionStart: Int
    var selectionEnd: Int
  }

  private let draft: RielaNoteSelectionAnswerDraft
  private(set) var requests: [Request] = []

  init(draft: RielaNoteSelectionAnswerDraft) {
    self.draft = draft
  }

  func answerQuestion(
    noteId: String,
    noteRoot: String,
    question: String,
    bodyMarkdown: String,
    selectedText: String,
    selectionStart: Int,
    selectionEnd: Int
  ) async throws -> RielaNoteSelectionAnswerDraft {
    requests.append(Request(
      noteId: noteId,
      noteRoot: noteRoot,
      question: question,
      bodyMarkdown: bodyMarkdown,
      selectedText: selectedText,
      selectionStart: selectionStart,
      selectionEnd: selectionEnd
    ))
    return draft
  }
}

private final class SelectionQATestClient: RielaNoteUIClient, @unchecked Sendable {
  struct AnswerRequest: Equatable {
    var noteId: String
    var question: String
    var bodyMarkdown: String
    var selectedText: String
    var selectionStart: Int
    var selectionEnd: Int
  }

  struct AddCommentCall: Equatable {
    var noteId: String
    var bodyMarkdown: String
    var author: String
  }

  struct PromoteCall: Equatable {
    var noteId: String
    var commentId: String
  }

  var answerDraft = RielaNoteSelectionAnswerDraft(answerMarkdown: "Answer", summary: "Summary")
  var answerError: Error?
  var answerDelayNanoseconds: UInt64?
  private(set) var answerRequests: [AnswerRequest] = []
  private(set) var addCommentCalls: [AddCommentCall] = []
  private(set) var promoteCalls: [PromoteCall] = []
  var promoteError: Error?

  var defaultConfigWorkflowRoot: String {
    "tmp/RielaNoteSelectionQATests/default-config-workflows"
  }

  func answerNoteSelectionQuestion(
    noteId: String,
    question: String,
    bodyMarkdown: String,
    selectedText: String,
    selectionStart: Int,
    selectionEnd: Int
  ) async throws -> RielaNoteSelectionAnswerDraft {
    if let answerDelayNanoseconds {
      try await Task.sleep(nanoseconds: answerDelayNanoseconds)
    }
    answerRequests.append(AnswerRequest(
      noteId: noteId,
      question: question,
      bodyMarkdown: bodyMarkdown,
      selectedText: selectedText,
      selectionStart: selectionStart,
      selectionEnd: selectionEnd
    ))
    if let answerError {
      throw answerError
    }
    return answerDraft
  }

  func addComment(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    try await addComment(noteId: noteId, bodyMarkdown: bodyMarkdown, author: "user")
  }

  func addComment(noteId: String, bodyMarkdown: String, author: String) async throws -> RielaNoteDetail {
    addCommentCalls.append(AddCommentCall(noteId: noteId, bodyMarkdown: bodyMarkdown, author: author))
    let comment = NoteComment(
      commentId: "comment-\(addCommentCalls.count)",
      noteId: noteId,
      bodyMarkdown: bodyMarkdown,
      author: author,
      createdAt: "2026-07-07T00:00:00Z"
    )
    return RielaNoteDetail(note: note(noteId: noteId), comments: [comment])
  }

  func promoteCommentToNotebook(noteId: String, commentId: String) async throws -> RielaNoteDetail {
    promoteCalls.append(PromoteCall(noteId: noteId, commentId: commentId))
    if let promoteError {
      throw promoteError
    }
    let link = NoteLink(
      fromNoteId: noteId,
      toNoteId: "note-promoted",
      linkKind: "related",
      provenance: .human,
      createdAt: "2026-07-07T00:00:00Z"
    )
    return RielaNoteDetail(note: note(noteId: noteId), links: [link])
  }

  func listNotebooks(limit: Int, offset: Int) async throws -> [Notebook] {
    []
  }

  func listNotes(notebookId: String, limit: Int, offset: Int) async throws -> [Note] {
    Array([note(noteId: "note-1"), note(noteId: "note-2")].dropFirst(offset).prefix(limit))
  }

  func listTags() async throws -> [Tag] {
    []
  }

  func createUserMemo(bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw SelectionQATestError.unsupported
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
    RielaNoteDetail(note: note(noteId: noteId))
  }

  func firstNote(inNotebook notebookId: String) async throws -> RielaNoteDetail? {
    RielaNoteDetail(note: note(noteId: "note-1"))
  }

  func resolveFile(fileId: String) async throws -> RielaNoteResolvedFile {
    throw SelectionQATestError.unsupported
  }

  func updateNoteBody(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    RielaNoteDetail(note: note(noteId: noteId, bodyMarkdown: bodyMarkdown))
  }

  func applyTag(noteId: String, tagName: String, classId: String?) async throws -> RielaNoteDetail {
    throw SelectionQATestError.unsupported
  }

  func removeTag(noteId: String, tagName: String) async throws -> RielaNoteDetail {
    throw SelectionQATestError.unsupported
  }

  func linkNote(noteId: String, targetNoteId: String, linkKind: String) async throws -> RielaNoteDetail {
    throw SelectionQATestError.unsupported
  }

  func answerNoteAgentTurn(message: String, limit: Int) async throws -> RielaNoteAgentTurn {
    throw SelectionQATestError.unsupported
  }

  func saveNoteAgentConversation(
    title: String,
    turns: [RielaNoteAgentTurn]
  ) async throws -> RielaNoteAgentConversationSaveResult {
    throw SelectionQATestError.unsupported
  }

  func appendNoteAgentTurn(
    notebookId: String,
    turn: RielaNoteAgentTurn
  ) async throws -> RielaNoteAgentConversationSaveResult {
    throw SelectionQATestError.unsupported
  }

  func proposeNoteConfigAgentChange(message: String) async throws -> RielaNoteConfigAgentProposal {
    throw SelectionQATestError.unsupported
  }

  func applyNoteConfigAgentProposal(
    _ proposal: RielaNoteConfigAgentProposal,
    workflowRoot: String
  ) async throws -> RielaNoteConfigAgentApplyResult {
    throw SelectionQATestError.unsupported
  }

  private func note(noteId: String, bodyMarkdown: String? = nil) -> Note {
    Note(
      noteId: noteId,
      notebookId: "notebook-1",
      noteNumber: noteId == "note-1" ? 1 : 2,
      title: noteId == "note-1" ? "Page One" : "Ontology",
      bodyMarkdown: bodyMarkdown ?? (noteId == "note-1" ? "# Page One\n\nBody" : "# Ontology\n\nSearch body"),
      readOnly: false,
      createdAt: "2026-07-04T00:00:00Z",
      updatedAt: "2026-07-04T00:00:00Z"
    )
  }
}
