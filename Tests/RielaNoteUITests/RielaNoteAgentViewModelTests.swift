import Foundation
import RielaNote
@testable import RielaNoteUI
import XCTest

@MainActor
final class RielaNoteAgentViewModelTests: XCTestCase {
  func testComposedMessageInlinesAttachmentsWithSafeFences() throws {
    XCTAssertEqual(rielaNoteAgentComposedMessage(draft: "  hello  ", attachments: []), "hello")

    let simple = rielaNoteAgentComposedMessage(
      draft: "Summarize this",
      attachments: [RielaNoteAgentDraftAttachment(filename: "notes.md", text: "# Title\nBody")]
    )
    XCTAssertEqual(simple, "Summarize this\n\nAttached file `notes.md`:\n```\n# Title\nBody\n```")

    // A file containing a triple-backtick fence gets a longer outer fence.
    let fenced = rielaNoteAgentComposedMessage(
      draft: "",
      attachments: [RielaNoteAgentDraftAttachment(filename: "code.md", text: "```swift\nlet a = 1\n```")]
    )
    XCTAssertEqual(fenced, "Attached file `code.md`:\n````\n```swift\nlet a = 1\n```\n````")
  }

  func testAttachmentValidationRejectsBinaryAndOversizedFiles() throws {
    let client = AgentStubClient()
    let viewModel = RielaNoteAgentViewModel(client: client)

    viewModel.addAttachment(filename: "image.png", data: Data([0xFF, 0xFE, 0x00, 0xC3]))
    XCTAssertEqual(viewModel.draftAttachments, [])
    XCTAssertNotNil(viewModel.attachmentError)

    let oversized = Data(repeating: UInt8(ascii: "a"), count: RielaNoteAgentViewModel.maximumAttachmentBytes + 1)
    viewModel.addAttachment(filename: "big.txt", data: oversized)
    XCTAssertEqual(viewModel.draftAttachments, [])
    XCTAssertNotNil(viewModel.attachmentError)

    viewModel.addAttachment(filename: "ok.txt", data: Data("fine".utf8))
    XCTAssertEqual(viewModel.draftAttachments.map(\.filename), ["ok.txt"])
    XCTAssertNil(viewModel.attachmentError)

    let attachmentId = try XCTUnwrap(viewModel.draftAttachments.first?.id)
    viewModel.removeAttachment(id: attachmentId)
    XCTAssertEqual(viewModel.draftAttachments, [])
  }

  func testSubmitSendsAttachmentsInlineAndClearsThem() async throws {
    let client = AgentStubClient()
    let viewModel = RielaNoteAgentViewModel(client: client)

    viewModel.draftMessage = "What does this say?"
    viewModel.addAttachment(filename: "memo.txt", data: Data("remember the milk".utf8))
    XCTAssertTrue(viewModel.canSubmit)
    await viewModel.submitDraft()

    XCTAssertEqual(viewModel.turns.count, 1)
    XCTAssertEqual(
      viewModel.turns.first?.userMarkdown,
      "What does this say?\n\nAttached file `memo.txt`:\n```\nremember the milk\n```"
    )
    XCTAssertEqual(viewModel.draftAttachments, [])
    XCTAssertEqual(viewModel.draftMessage, "")
  }

  func testAttachmentsAloneAreSubmittable() async throws {
    let client = AgentStubClient()
    let viewModel = RielaNoteAgentViewModel(client: client)

    XCTAssertFalse(viewModel.canSubmit)
    viewModel.addAttachment(filename: "memo.txt", data: Data("content".utf8))
    XCTAssertTrue(viewModel.canSubmit)
    await viewModel.submitDraft()

    XCTAssertEqual(viewModel.turns.first?.userMarkdown, "Attached file `memo.txt`:\n```\ncontent\n```")
  }

  func testAnswerFailureClearsDraftAndSurfacesErrorWithoutTurn() async throws {
    let fixture = NoteUITestFixture()
    fixture.client.agentAnswerError = AgentViewModelTestError.answerFailed
    let viewModel = RielaNoteAgentViewModel(client: fixture.client)

    viewModel.draftMessage = "ontology"
    await viewModel.submitDraft()

    XCTAssertEqual(viewModel.draftMessage, "")
    XCTAssertEqual(viewModel.turns, [])
    XCTAssertNotNil(viewModel.errorMessage)
    XCTAssertEqual(fixture.client.savedConversations.count, 0)
  }

  func testAnsweredTurnStaysVisibleAndSaveableWhenPersistenceFails() async throws {
    let client = AgentStubClient()
    client.saveError = AgentViewModelTestError.saveFailed
    let viewModel = RielaNoteAgentViewModel(client: client)

    viewModel.draftMessage = "ontology"
    await viewModel.submitDraft()

    // Show first, persist second: the answer is visible, marked unsaved, and the
    // error banner is set — the paid-for answer is never discarded.
    XCTAssertEqual(viewModel.turns.count, 1)
    XCTAssertEqual(viewModel.turns.first?.userMarkdown, "ontology")
    XCTAssertEqual(viewModel.turns.first?.persistedNoteIds, [])
    XCTAssertNotNil(viewModel.errorMessage)

    // The unsaved turn is saveable later once persistence recovers.
    client.saveError = nil
    await viewModel.saveTemporaryConversation(title: "Recovered")

    XCTAssertEqual(viewModel.turns.first?.persistedNoteIds, ["conversation-note-1"])
    XCTAssertEqual(client.savedConversations.count, 1)
    XCTAssertNil(viewModel.errorMessage)
  }

  func testInterleavedSubmitsProduceOneNotebookWithOrderedTurns() async throws {
    let client = AgentStubClient()
    client.answerDelayNanoseconds = 40_000_000
    let viewModel = RielaNoteAgentViewModel(client: client)

    viewModel.draftMessage = "first"
    let first = Task { await viewModel.submitDraft() }
    // The second submit fires while the first is still in flight; the
    // reentrancy guard must reject it rather than opening a second notebook.
    try await Task.sleep(nanoseconds: 5_000_000)
    viewModel.draftMessage = "second"
    await viewModel.submitDraft()
    await first.value

    // Only the first submit was accepted; drive the second turn afterwards.
    viewModel.draftMessage = "second"
    await viewModel.submitDraft()

    XCTAssertEqual(viewModel.turns.map(\.userMarkdown), ["first", "second"])
    XCTAssertEqual(viewModel.autoSaveNotebookId, "agent-notebook-1")
    XCTAssertEqual(client.savedConversations.count, 1)
    XCTAssertEqual(client.appendedNotebookIds, ["agent-notebook-1"])
  }

  func testLeavingTemporaryModePersistsAllPriorTurnsInOrder() async throws {
    let client = AgentStubClient()
    let viewModel = RielaNoteAgentViewModel(client: client)
    viewModel.isTemporaryChat = true

    for message in ["turn-1", "turn-2", "turn-3"] {
      viewModel.draftMessage = message
      await viewModel.submitDraft()
    }
    XCTAssertEqual(viewModel.turns.allSatisfy { $0.persistedNoteIds.isEmpty }, true)
    XCTAssertEqual(client.savedConversations.count, 0)

    // Toggle temp off and submit a fourth turn: the first non-temp save must
    // persist all four turns in order, not just the newest.
    viewModel.isTemporaryChat = false
    viewModel.draftMessage = "turn-4"
    await viewModel.submitDraft()

    XCTAssertEqual(viewModel.turns.map(\.userMarkdown), ["turn-1", "turn-2", "turn-3", "turn-4"])
    XCTAssertEqual(client.savedConversations.count, 1)
    XCTAssertEqual(
      client.savedConversations.first?.turns.map(\.userMarkdown),
      ["turn-1", "turn-2", "turn-3", "turn-4"]
    )
    XCTAssertEqual(
      viewModel.turns.map(\.persistedNoteIds),
      [["conversation-note-1"], ["conversation-note-2"], ["conversation-note-3"], ["conversation-note-4"]]
    )
    XCTAssertFalse(viewModel.turns.contains { $0.persistedNoteIds.isEmpty })
  }

  func testTemporarySavePersistsUnsavedTurnsOnceAndDisablesSave() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteAgentViewModel(client: fixture.client)
    viewModel.isTemporaryChat = true

    viewModel.draftMessage = "ontology"
    await viewModel.submitDraft()
    await viewModel.saveTemporaryConversation(title: "Saved Temp Chat")
    await viewModel.saveTemporaryConversation(title: "Saved Temp Chat")

    XCTAssertFalse(viewModel.isTemporaryChat)
    XCTAssertFalse(viewModel.canSaveTemporaryConversation)
    XCTAssertEqual(viewModel.autoSaveNotebookId, "agent-notebook-1")
    XCTAssertEqual(viewModel.turns.first?.persistedNoteIds, ["conversation-note-1"])
    XCTAssertEqual(fixture.client.savedConversations.count, 1)
    XCTAssertEqual(fixture.client.savedConversations.first?.turns.count, 1)
  }

  func testTemporarySaveThenNormalSubmitAppendsToSavedConversation() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteAgentViewModel(client: fixture.client)
    viewModel.isTemporaryChat = true

    viewModel.draftMessage = "ontology"
    await viewModel.submitDraft()
    await viewModel.saveTemporaryConversation(title: "Saved Temp Chat")
    viewModel.draftMessage = "follow up"
    await viewModel.submitDraft()

    XCTAssertEqual(viewModel.turns.count, 2)
    XCTAssertEqual(viewModel.turns.last?.persistedNoteIds, ["conversation-note-2"])
    XCTAssertEqual(fixture.client.savedConversations.count, 1)
    XCTAssertEqual(fixture.client.appendedTurns.count, 1)
  }

  func testStartNewConversationClearsAgentState() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteAgentViewModel(client: fixture.client)

    viewModel.draftMessage = "ontology"
    await viewModel.submitDraft()
    viewModel.draftMessage = "next draft"

    XCTAssertTrue(viewModel.canStartNewConversation)

    viewModel.startNewConversation()

    XCTAssertEqual(viewModel.turns, [])
    XCTAssertNil(viewModel.autoSaveNotebookId)
    XCTAssertEqual(viewModel.draftMessage, "")
    XCTAssertFalse(viewModel.isTemporaryChat)
    XCTAssertEqual(viewModel.state, .idle)
  }
}

private enum AgentViewModelTestError: Error {
  case answerFailed
  case saveFailed
}

/// Focused agent client stub with save/answer failure injection and ordered
/// notebook bookkeeping, used for the persistence-integrity tests.
final class AgentStubClient: RielaNoteUIClient, @unchecked Sendable {
  var answerError: Error?
  var saveError: Error?
  var answerDelayNanoseconds: UInt64 = 0
  var savedConversations: [(title: String, turns: [RielaNoteAgentTurn])] = []
  var appendedNotebookIds: [String] = []
  private var persistedNoteCount = 0

  var defaultConfigWorkflowRoot: String {
    "tmp/RielaNoteUITests/agent-stub-workflows"
  }

  func listNotebooks(limit: Int, offset: Int) async throws -> [Notebook] { [] }

  func listNotes(notebookId: String, limit: Int, offset: Int) async throws -> [Note] { [] }

  func listTags() async throws -> [Tag] { [] }

  func createUserMemo(bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw AgentViewModelTestError.answerFailed
  }

  func searchNotes(
    query: String,
    tagFilter: [String],
    classFilter: [String],
    limit: Int,
    offset: Int
  ) async throws -> [NoteSearchResult] { [] }

  func noteDetail(noteId: String) async throws -> RielaNoteDetail {
    throw AgentViewModelTestError.answerFailed
  }

  func firstNote(inNotebook notebookId: String) async throws -> RielaNoteDetail? { nil }

  func resolveFile(fileId: String) async throws -> RielaNoteResolvedFile {
    throw AgentViewModelTestError.answerFailed
  }

  func updateNoteBody(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw AgentViewModelTestError.answerFailed
  }

  func applyTag(noteId: String, tagName: String, classId: String?) async throws -> RielaNoteDetail {
    throw AgentViewModelTestError.answerFailed
  }

  func removeTag(noteId: String, tagName: String) async throws -> RielaNoteDetail {
    throw AgentViewModelTestError.answerFailed
  }

  func addComment(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw AgentViewModelTestError.answerFailed
  }

  func linkNote(noteId: String, targetNoteId: String, linkKind: String) async throws -> RielaNoteDetail {
    throw AgentViewModelTestError.answerFailed
  }

  func answerNoteAgentTurn(message: String, limit: Int) async throws -> RielaNoteAgentTurn {
    if answerDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: answerDelayNanoseconds)
    }
    if let answerError {
      throw answerError
    }
    return RielaNoteAgentTurn(
      userMarkdown: message,
      assistantMarkdown: "Mock answer for \(message)"
    )
  }

  func saveNoteAgentConversation(
    title: String,
    turns: [RielaNoteAgentTurn]
  ) async throws -> RielaNoteAgentConversationSaveResult {
    if let saveError {
      throw saveError
    }
    savedConversations.append((title: title, turns: turns))
    let noteIds = turns.map { _ -> String in
      persistedNoteCount += 1
      return "conversation-note-\(persistedNoteCount)"
    }
    return RielaNoteAgentConversationSaveResult(
      notebookId: "agent-notebook-\(savedConversations.count)",
      noteIds: noteIds
    )
  }

  func appendNoteAgentTurn(
    notebookId: String,
    turn: RielaNoteAgentTurn
  ) async throws -> RielaNoteAgentConversationSaveResult {
    if let saveError {
      throw saveError
    }
    appendedNotebookIds.append(notebookId)
    persistedNoteCount += 1
    return RielaNoteAgentConversationSaveResult(
      notebookId: notebookId,
      noteIds: ["conversation-note-\(persistedNoteCount)"]
    )
  }

  func proposeNoteConfigAgentChange(message: String) async throws -> RielaNoteConfigAgentProposal {
    throw AgentViewModelTestError.answerFailed
  }

  func applyNoteConfigAgentProposal(
    _ proposal: RielaNoteConfigAgentProposal,
    workflowRoot: String
  ) async throws -> RielaNoteConfigAgentApplyResult {
    throw AgentViewModelTestError.answerFailed
  }
}
