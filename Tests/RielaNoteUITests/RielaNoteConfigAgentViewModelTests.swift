import Foundation
import RielaNote
@testable import RielaNoteUI
import XCTest

@MainActor
final class RielaNoteConfigAgentViewModelTests: XCTestCase {
  func testJapaneseConfigRequestUsesDefaultSlug() async throws {
    let service = try makeService()
    let client = NoteServiceRielaNoteUIClient(service: service)

    let proposal = try await client.proposeNoteConfigAgentChange(message: "ビジネスのアイデアのノート")

    XCTAssertEqual(proposal.tagClass.classId, "config-agent-topic")
    XCTAssertEqual(proposal.tag.name, "config-agent-topic")
    XCTAssertEqual(proposal.ingestionWorkflow.workflowId, "note-ingest-config-agent-topic")
  }

  func testInjectedScaffoldFailureLeavesNoTagOrAutoActionRows() async throws {
    let service = try makeService()
    let client = NoteServiceRielaNoteUIClient(service: service)
    let workflowRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/RielaNoteUITests/config-agent-invalid-workflows", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .path

    // A proposal whose workflow id the scaffolder would reject must fail before
    // any tag / tag-class / auto-action row is committed.
    let proposal = RielaNoteConfigAgentProposal(
      requestMarkdown: "ビジネス",
      assistantMarkdown: "Proposed configuration change",
      tagClass: RielaNoteConfigTagClassDraft(classId: "business", label: "Business"),
      tag: RielaNoteConfigTagDraft(name: "business", classId: "business"),
      autoAction: RielaNoteConfigAutoActionDraft(
        actionId: "config-agent-auto-tagging-business",
        trigger: "note-created",
        workflowId: "note-auto-tagging",
        filterJSON: #"{"noteTags":["business"]}"#,
        enabled: true,
        position: 10
      ),
      ingestionWorkflow: RielaNoteConfigIngestionWorkflowDraft(workflowId: "note-ingest-ビジネス")
    )

    do {
      _ = try await client.applyNoteConfigAgentProposal(proposal, workflowRoot: workflowRoot)
      XCTFail("Expected the invalid workflow id to be rejected before any DB write")
    } catch {
      // Expected: validation fails before mutating the store.
    }

    XCTAssertTrue(try service.listTagClasses().filter { $0.classId == "business" }.isEmpty)
    XCTAssertTrue(try service.listTags().filter { $0.name == "business" }.isEmpty)
    XCTAssertTrue(try service.listAutoActions().filter { $0.actionId.contains("business") }.isEmpty)
  }

  func testFailedSubmitRestoresDraftAndSurfacesError() async throws {
    let client = ConfigAgentStubClient()
    client.proposeError = ConfigAgentStubError.proposeFailed
    let viewModel = RielaNoteConfigAgentViewModel(client: client)

    viewModel.draftMessage = "Business idea notes"
    await viewModel.submitDraft()

    XCTAssertEqual(viewModel.draftMessage, "Business idea notes")
    XCTAssertTrue(viewModel.proposals.isEmpty)
    XCTAssertNotNil(viewModel.errorMessage)
  }

  func testFailedApplySurfacesErrorWithoutMarkingApplied() async throws {
    let client = ConfigAgentStubClient()
    let viewModel = RielaNoteConfigAgentViewModel(client: client)

    viewModel.draftMessage = "Business idea notes"
    await viewModel.submitDraft()
    let id = try XCTUnwrap(viewModel.proposals.first?.id)

    client.applyError = ConfigAgentStubError.applyFailed
    await viewModel.applyProposal(id: id)

    XCTAssertNil(viewModel.proposals.first?.appliedResult)
    XCTAssertNotNil(viewModel.errorMessage)
  }

  func testDoubleApplyIsBlockedWhileApplyInFlight() async throws {
    let client = ConfigAgentStubClient()
    client.applyDelayNanoseconds = 50_000_000
    let viewModel = RielaNoteConfigAgentViewModel(client: client)

    viewModel.draftMessage = "Business idea notes"
    await viewModel.submitDraft()
    let id = try XCTUnwrap(viewModel.proposals.first?.id)

    let first = Task { await viewModel.applyProposal(id: id) }
    try await Task.sleep(nanoseconds: 5_000_000)
    let second = Task { await viewModel.applyProposal(id: id) }

    await first.value
    await second.value

    XCTAssertEqual(client.applyCallCount, 1)
    XCTAssertNotNil(viewModel.proposals.first?.appliedResult)
  }
}

private enum ConfigAgentStubError: Error {
  case proposeFailed
  case applyFailed
}

final class ConfigAgentStubClient: RielaNoteUIClient, @unchecked Sendable {
  var proposeError: Error?
  var applyError: Error?
  var applyDelayNanoseconds: UInt64 = 0
  var applyCallCount = 0

  var defaultConfigWorkflowRoot: String {
    "tmp/RielaNoteUITests/config-agent-stub-workflows"
  }

  func listNotebooks(limit: Int, offset: Int) async throws -> [Notebook] { [] }

  func listNotes(notebookId: String, limit: Int, offset: Int) async throws -> [Note] { [] }

  func listTags() async throws -> [Tag] { [] }

  func createUserMemo(bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw ConfigAgentStubError.applyFailed
  }

  func searchNotes(
    query: String,
    tagFilter: [String],
    classFilter: [String],
    limit: Int,
    offset: Int
  ) async throws -> [NoteSearchResult] { [] }

  func noteDetail(noteId: String) async throws -> RielaNoteDetail {
    throw ConfigAgentStubError.applyFailed
  }

  func firstNote(inNotebook notebookId: String) async throws -> RielaNoteDetail? { nil }

  func resolveFile(fileId: String) async throws -> RielaNoteResolvedFile {
    throw ConfigAgentStubError.applyFailed
  }

  func updateNoteBody(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw ConfigAgentStubError.applyFailed
  }

  func applyTag(noteId: String, tagName: String, classId: String?) async throws -> RielaNoteDetail {
    throw ConfigAgentStubError.applyFailed
  }

  func removeTag(noteId: String, tagName: String) async throws -> RielaNoteDetail {
    throw ConfigAgentStubError.applyFailed
  }

  func addComment(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw ConfigAgentStubError.applyFailed
  }

  func linkNote(noteId: String, targetNoteId: String, linkKind: String) async throws -> RielaNoteDetail {
    throw ConfigAgentStubError.applyFailed
  }

  func answerNoteAgentTurn(message: String, limit: Int) async throws -> RielaNoteAgentTurn {
    throw ConfigAgentStubError.applyFailed
  }

  func saveNoteAgentConversation(
    title: String,
    turns: [RielaNoteAgentTurn]
  ) async throws -> RielaNoteAgentConversationSaveResult {
    throw ConfigAgentStubError.applyFailed
  }

  func appendNoteAgentTurn(
    notebookId: String,
    turn: RielaNoteAgentTurn
  ) async throws -> RielaNoteAgentConversationSaveResult {
    throw ConfigAgentStubError.applyFailed
  }

  func proposeNoteConfigAgentChange(message: String) async throws -> RielaNoteConfigAgentProposal {
    if let proposeError {
      throw proposeError
    }
    return RielaNoteConfigAgentProposal(
      requestMarkdown: message,
      assistantMarkdown: "Mock config proposal",
      tagClass: RielaNoteConfigTagClassDraft(
        classId: "business-idea",
        label: "Business Idea",
        description: "Business idea notes"
      ),
      tag: RielaNoteConfigTagDraft(name: "business-idea", classId: "business-idea"),
      autoAction: RielaNoteConfigAutoActionDraft(
        actionId: "config-agent-auto-tagging-business-idea",
        trigger: "note-created",
        workflowId: "note-auto-tagging",
        filterJSON: #"{"noteTags":["business-idea"]}"#,
        enabled: true,
        position: 10
      ),
      ingestionWorkflow: RielaNoteConfigIngestionWorkflowDraft(workflowId: "note-ingest-business-idea")
    )
  }

  func applyNoteConfigAgentProposal(
    _ proposal: RielaNoteConfigAgentProposal,
    workflowRoot: String
  ) async throws -> RielaNoteConfigAgentApplyResult {
    applyCallCount += 1
    if applyDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: applyDelayNanoseconds)
    }
    if let applyError {
      throw applyError
    }
    let tagClass = TagClass(
      classId: proposal.tagClass.classId,
      label: proposal.tagClass.label,
      description: proposal.tagClass.description,
      isSystem: false,
      createdAt: "2026-07-04T00:00:00Z"
    )
    let tag = Tag(
      tagId: "tag-\(proposal.tag.name)",
      name: proposal.tag.name,
      classId: proposal.tag.classId,
      isSystem: false,
      createdAt: "2026-07-04T00:00:00Z"
    )
    let action = AutoAction(
      actionId: proposal.autoAction.actionId,
      trigger: .noteCreated,
      workflowId: proposal.autoAction.workflowId,
      filterJSON: proposal.autoAction.filterJSON,
      enabled: proposal.autoAction.enabled,
      position: proposal.autoAction.position,
      createdAt: "2026-07-04T00:00:00Z"
    )
    let scaffold = NoteIngestionWorkflowScaffoldResult(
      workflowId: proposal.ingestionWorkflow.workflowId,
      workflowRoot: workflowRoot,
      workflowPath: "\(workflowRoot)/\(proposal.ingestionWorkflow.workflowId)/workflow.json",
      files: []
    )
    return RielaNoteConfigAgentApplyResult(
      tagClass: tagClass,
      tag: tag,
      autoAction: action,
      workflowScaffold: scaffold
    )
  }
}
