import Foundation
@testable import RielaNoteUI
import XCTest

@MainActor
final class RielaNoteAgentViewModelTests: XCTestCase {
  func testSubmitFailureRestoresDraftForRetry() async throws {
    let fixture = NoteUITestFixture()
    fixture.client.agentAnswerError = AgentViewModelTestError.answerFailed
    let viewModel = RielaNoteAgentViewModel(client: fixture.client)

    viewModel.draftMessage = "ontology"
    await viewModel.submitDraft()

    XCTAssertEqual(viewModel.draftMessage, "ontology")
    XCTAssertEqual(viewModel.turns, [])
    XCTAssertNotNil(viewModel.errorMessage)
    XCTAssertEqual(fixture.client.savedConversations.count, 0)
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
}
