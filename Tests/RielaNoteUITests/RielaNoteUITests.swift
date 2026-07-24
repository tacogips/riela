import Foundation
import RielaNote
@testable import RielaNoteUI
import SwiftUI
import XCTest

@MainActor
final class RielaNoteUITests: XCTestCase {
  func testViewModelCreatesUserMemoAndSelectsIt() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)
    viewModel.searchText = "draft"

    try await viewModel.createUserMemo()

    XCTAssertEqual(fixture.client.createdMemos.count, 1)
    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-user-memo-1")
    XCTAssertEqual(viewModel.selectedNote?.tags.map(\.tag.name), ["user-memo"])
    XCTAssertEqual(viewModel.notebookNotes.map(\.noteId), ["note-1", "note-2", "note-user-memo-1"])
    XCTAssertEqual(viewModel.selectedNotePositionText, "#3 of 3")
    XCTAssertFalse(viewModel.isSearching)
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testSearchSelectsFirstSearchResult() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)
    viewModel.searchText = "ontology"

    await viewModel.submitSearch()

    XCTAssertEqual(viewModel.searchResults.map(\.note.noteId), ["note-2"])
    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-2")
    XCTAssertTrue(viewModel.isSearching)
  }

  func testSearchTextChangeRefreshesResultsWithoutChangingSelection() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)

    await viewModel.load()
    await viewModel.updateSearchText("ontology")

    XCTAssertEqual(viewModel.searchResults.map(\.note.noteId), ["note-2"])
    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-1")
    XCTAssertEqual(fixture.client.searchRequests.last?.query, "ontology")
  }

  func testStaleSearchResponseDoesNotOverwriteNewerQueryResults() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)
    fixture.client.searchDelayNanosecondsByQuery["old"] = 50_000_000
    fixture.client.searchResultsByQuery["old"] = [
      NoteSearchResult(note: fixture.client.note, snippet: "old snippet", rank: 0, matchedTags: [])
    ]
    fixture.client.searchResultsByQuery["ontology"] = [fixture.client.searchResult]

    let staleSearch = Task {
      await viewModel.updateSearchText("old")
    }
    try await Task.sleep(nanoseconds: 5_000_000)
    let currentSearch = Task {
      await viewModel.updateSearchText("ontology")
    }

    await currentSearch.value
    await staleSearch.value

    XCTAssertEqual(viewModel.searchText, "ontology")
    XCTAssertEqual(viewModel.searchResults.map(\.note.noteId), ["note-2"])
    XCTAssertEqual(Set(fixture.client.searchRequests.map(\.query)), ["old", "ontology"])
  }

  func testSearchTagFilterIsAppliedWithoutQuery() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)

    await viewModel.load()
    await viewModel.toggleSearchTag("notebook-kind:imported-material")

    XCTAssertEqual(fixture.client.searchRequests.last?.tagFilter, ["notebook-kind:imported-material"])
    XCTAssertTrue(viewModel.hasSearchFilters)
    XCTAssertEqual(viewModel.searchResults.map(\.note.noteId), ["note-2"])
  }

  func testTogglingIncludeLinkedWithEmptyQueryLeavesNotebookListUntouched() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)

    await viewModel.load()
    let notebooksBefore = viewModel.notebooks.map(\.notebookId)
    let notebookNotesBefore = viewModel.notebookNotes.map(\.noteId)

    // includeLinked is no longer a standalone search filter, so toggling it with
    // an empty query and no other filters must not enter search mode.
    await viewModel.updateIncludeLinked(true)

    XCTAssertFalse(viewModel.hasSearchFilters)
    XCTAssertFalse(viewModel.isSearching)
    XCTAssertEqual(viewModel.notebooks.map(\.notebookId), notebooksBefore)
    XCTAssertEqual(viewModel.notebookNotes.map(\.noteId), notebookNotesBefore)
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testSourceImageModeResolvesPageImageFile() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)

    await viewModel.selectNote("note-1")
    await viewModel.setContentMode(.sourceImage)

    XCTAssertEqual(viewModel.contentMode, .sourceImage)
    XCTAssertEqual(viewModel.resolvedSourceImage?.file.fileId, "file-page")
    XCTAssertEqual(viewModel.resolvedSourceImage?.data, Data([1, 2, 3]))
  }

  func testSourceImageModeUsesResolvedFileCacheWhenToggledBack() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)

    await viewModel.selectNote("note-1")
    await viewModel.setContentMode(.sourceImage)
    await viewModel.setContentMode(.text)
    await viewModel.setContentMode(.sourceImage)

    XCTAssertEqual(fixture.client.resolveFileCallCount, 1)
    XCTAssertEqual(viewModel.resolvedSourceImage?.file.fileId, "file-page")
  }

  func testViewModelResolvesRelatedFileChipWithoutChangingContentMode() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)

    await viewModel.selectNote("note-1")
    await viewModel.selectFileAttachment(fixture.relatedAttachment)
    await viewModel.selectFileAttachment(fixture.relatedAttachment)

    XCTAssertEqual(viewModel.contentMode, .text)
    XCTAssertEqual(viewModel.selectedResolvedFile?.file.fileId, "file-related")
    XCTAssertEqual(viewModel.selectedResolvedFile?.data, Data("source metadata".utf8))
    XCTAssertEqual(viewModel.selectedResolvedFileStatusText, "metadata.txt · 15 bytes")
    XCTAssertEqual(fixture.client.resolvedFileIds.filter { $0 == "file-related" }.count, 1)
  }

  func testViewModelSavesEditableNoteBodyThroughClient() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)

    await viewModel.selectNote("note-2")
    try await viewModel.saveSelectedNoteBody("# Changed\n\nUpdated body")

    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-2")
    XCTAssertEqual(viewModel.selectedNote?.bodyMarkdown, "# Changed\n\nUpdated body")
    XCTAssertEqual(viewModel.selectedNote?.title, "Changed")
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testViewModelEditsSelectedNoteMetadata() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)

    await viewModel.selectNote("note-2")
    try await viewModel.applyTagToSelectedNote(name: "idea")
    try await viewModel.addCommentToSelectedNote("Looks useful")
    try await viewModel.linkSelectedNote(to: "note-1", kind: "related")
    try await viewModel.removeTagFromSelectedNote(name: "idea")

    XCTAssertFalse(viewModel.selectedNote?.tags.contains { $0.tag.name == "idea" } == true)
    XCTAssertEqual(viewModel.selectedDetail?.comments.map(\.bodyMarkdown), ["Looks useful"])
    XCTAssertEqual(viewModel.selectedDetail?.links.map(\.toNoteId), ["note-1"])
    XCTAssertEqual(viewModel.selectedDetail?.linkedNotesById["note-1"]?.title, "Page One")
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testViewModelAddsCommentToExplicitTargetWithoutChangingSelection() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)

    await viewModel.selectNote("note-2")
    try await viewModel.addComment("Visible page comment", toNoteId: "note-1")

    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-2")
    XCTAssertEqual(fixture.client.commentsByNoteId["note-1"]?.map(\.bodyMarkdown), ["Visible page comment"])
    XCTAssertTrue(viewModel.selectedDetail?.comments.isEmpty == true)
  }

  func testViewModelOpensLinkedNoteById() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)

    await viewModel.selectNote("note-2")
    try await viewModel.linkSelectedNote(to: "note-1", kind: "related")
    await viewModel.selectNote("note-1")

    XCTAssertEqual(viewModel.selectedNote?.title, "Page One")
    XCTAssertEqual(viewModel.selectedNotePositionText, "#1 of 2")
  }

  func testViewModelRejectsStaleBodySaveAfterSelectionChanges() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)

    await viewModel.selectNote("note-1")
    await viewModel.selectNote("note-2")
    await XCTAssertThrowsErrorAsync(
      try await viewModel.saveSelectedNoteBody("# Page One Draft\n\nWrong target", expectedNoteId: "note-1")
    )

    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-2")
    XCTAssertEqual(viewModel.selectedNote?.bodyMarkdown, "# Ontology\n\nSearch body")
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testNoteServiceClientUpdatesEditableNoteBody() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Draft\n\nBody")
    let viewModel = RielaNoteLibraryViewModel(client: NoteServiceRielaNoteUIClient(service: service))

    await viewModel.selectNote(note.noteId)
    try await viewModel.saveSelectedNoteBody("# Saved\n\nChanged body")

    XCTAssertEqual(viewModel.selectedNote?.bodyMarkdown, "# Saved\n\nChanged body")
    XCTAssertEqual(try service.getNote(note.noteId).title, "Saved")
  }

  func testNoteServiceClientListsAndPagesNotebookNotes() async throws {
    let service = try makeService()
    let first = try service.createNote(bodyMarkdown: "# First\n\nBody")
    let second = try service.createNote(notebookId: first.notebookId, bodyMarkdown: "# Second\n\nBody")
    let viewModel = RielaNoteLibraryViewModel(client: NoteServiceRielaNoteUIClient(service: service))

    await viewModel.selectNotebook(first.notebookId)
    await viewModel.selectNextNote()

    XCTAssertEqual(viewModel.notebookNotes.map(\.noteId), [first.noteId, second.noteId])
    XCTAssertEqual(viewModel.selectedNote?.noteId, second.noteId)
    XCTAssertEqual(viewModel.selectedNotePositionText, "#2 of 2")
  }

  func testNoteServiceClientCreatesUserMemoWithTag() async throws {
    let service = try makeService()
    let client = NoteServiceRielaNoteUIClient(service: service)

    let detail = try await client.createUserMemo(bodyMarkdown: "# Quick Memo\n\nBody")

    XCTAssertEqual(detail.note.title, "Quick Memo")
    XCTAssertEqual(detail.note.tags.map(\.tag.name), ["user-memo"])
    XCTAssertEqual(detail.note.tags.first?.tag.classId, "topic")
    XCTAssertEqual(detail.note.tags.first?.provenance, .human)
    XCTAssertEqual(try service.getNote(detail.note.noteId), detail.note)
  }

  func testNoteServiceClientSearchesByTagWithoutTextQuery() async throws {
    let service = try makeService()
    let first = try service.createNote(
      bodyMarkdown: "# First\n\nBody",
      tags: [NoteTagInput(name: "idea", classId: "topic")]
    )
    _ = try service.createNote(
      bodyMarkdown: "# Second\n\nBody",
      tags: [NoteTagInput(name: "other", classId: "topic")]
    )
    let client = NoteServiceRielaNoteUIClient(service: service)

    let results = try await client.searchNotes(query: "", tagFilter: ["idea"], classFilter: [], limit: 10, offset: 0)

    XCTAssertEqual(results.map(\.note.noteId), [first.noteId])
  }

  func testNoteServiceClientEditsNoteMetadata() async throws {
    let service = try makeService()
    let first = try service.createNote(bodyMarkdown: "# First\n\nBody")
    let second = try service.createNote(bodyMarkdown: "# Second\n\nBody")
    let client = NoteServiceRielaNoteUIClient(service: service)

    let tagged = try await client.applyTag(noteId: first.noteId, tagName: "idea", classId: "topic")
    let commented = try await client.addComment(noteId: first.noteId, bodyMarkdown: "Looks useful")
    let linked = try await client.linkNote(noteId: first.noteId, targetNoteId: second.noteId, linkKind: "related")
    let untagged = try await client.removeTag(noteId: first.noteId, tagName: "idea")

    XCTAssertEqual(tagged.note.tags.map(\.tag.name), ["idea"])
    XCTAssertEqual(commented.comments.map(\.bodyMarkdown), ["Looks useful"])
    XCTAssertEqual(linked.links.map(\.toNoteId), [second.noteId])
    XCTAssertEqual(linked.linkedNotesById[second.noteId]?.title, "Second")
    XCTAssertTrue(untagged.note.tags.isEmpty)
  }

  func testNoteServiceClientResolvesLocalSourcePageImage() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Local Page\n\nBody")
    let imageData = Data([1, 2, 3, 4])
    let attachment = try service.attachFile(
      noteId: note.noteId,
      data: imageData,
      role: .sourcePageImage,
      mediaType: "image/png",
      originalFilename: "page.png"
    )
    let viewModel = RielaNoteLibraryViewModel(client: NoteServiceRielaNoteUIClient(service: service))

    await viewModel.selectNote(note.noteId)
    await viewModel.setContentMode(.sourceImage)

    XCTAssertEqual(viewModel.sourcePageImageAttachment?.file.fileId, attachment.file.fileId)
    XCTAssertEqual(viewModel.resolvedSourceImage?.data, imageData)
  }

  func testNoteServiceClientResolvesRelatedFileAttachment() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Related File\n\nBody")
    let fileData = Data("hello file".utf8)
    let attachment = try service.attachFile(
      noteId: note.noteId,
      data: fileData,
      role: .related,
      mediaType: "text/plain",
      originalFilename: "hello.txt"
    )
    let viewModel = RielaNoteLibraryViewModel(client: NoteServiceRielaNoteUIClient(service: service))

    await viewModel.selectNote(note.noteId)
    await viewModel.selectFileAttachment(attachment)

    XCTAssertEqual(viewModel.contentMode, .text)
    XCTAssertEqual(viewModel.selectedResolvedFile?.file.fileId, attachment.file.fileId)
    XCTAssertEqual(viewModel.selectedResolvedFile?.data, fileData)
    XCTAssertEqual(viewModel.selectedResolvedFileStatusText, "hello.txt · 10 bytes")
  }

  func testAgentViewModelAutoSavesFirstTurnAndAppendsLaterTurns() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteAgentViewModel(client: fixture.client)

    viewModel.draftMessage = "ontology"
    await viewModel.submitDraft()
    viewModel.draftMessage = "follow up"
    await viewModel.submitDraft()

    XCTAssertEqual(viewModel.turns.count, 2)
    XCTAssertEqual(viewModel.turns.first?.citations.map(\.noteId), ["note-2"])
    XCTAssertEqual(viewModel.turns.first?.persistedNoteIds, ["conversation-note-1"])
    XCTAssertEqual(viewModel.turns.last?.persistedNoteIds, ["conversation-note-2"])
    XCTAssertEqual(viewModel.autoSaveNotebookId, "agent-notebook-1")
    XCTAssertEqual(fixture.client.savedConversations.count, 1)
    XCTAssertEqual(fixture.client.appendedTurns.count, 1)
  }

  func testAgentViewModelTemporaryChatPersistsOnlyAfterExplicitSave() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteAgentViewModel(client: fixture.client)
    viewModel.isTemporaryChat = true

    viewModel.draftMessage = "ontology"
    await viewModel.submitDraft()

    XCTAssertEqual(viewModel.turns.count, 1)
    XCTAssertEqual(viewModel.turns.first?.persistedNoteIds, [])
    XCTAssertEqual(fixture.client.savedConversations.count, 0)

    await viewModel.saveTemporaryConversation(title: "Saved Temp Chat")

    XCTAssertEqual(viewModel.autoSaveNotebookId, "agent-notebook-1")
    XCTAssertEqual(viewModel.turns.first?.persistedNoteIds, ["conversation-note-1"])
    XCTAssertEqual(fixture.client.savedConversations.first?.title, "Saved Temp Chat")
  }

  func testNoteServiceClientAnswersWithResolvableCitationsAndConversationNotebook() async throws {
    let service = try makeService()
    let source = try service.createNote(
      bodyMarkdown: "# Architecture Note\n\nSource-backed notebooks stay searchable for the note agent."
    )
    let client = NoteServiceRielaNoteUIClient(service: service)

    let turn = try await client.answerNoteAgentTurn(message: "source-backed notebooks", limit: 5)
    let saved = try await client.saveNoteAgentConversation(title: "Agent Chat", turns: [turn])
    let appended = try await client.appendNoteAgentTurn(notebookId: saved.notebookId, turn: turn)

    XCTAssertEqual(turn.citations.first?.noteId, source.noteId)
    XCTAssertTrue(turn.assistantMarkdown.contains("Source-backed notebooks stay searchable"))
    XCTAssertEqual(try service.getNote(source.noteId).noteId, source.noteId)
    XCTAssertEqual(saved.noteIds.count, 1)
    XCTAssertEqual(appended.noteIds.count, 1)
    let notebook = try service.getNotebook(saved.notebookId)
    XCTAssertEqual(notebook.tags.map(\.tag.name), ["notebook-kind:agent-conversation"])
    let links = try service.listLinks(noteId: saved.noteIds[0])
    XCTAssertTrue(links.contains {
      $0.fromNoteId == saved.noteIds[0] && $0.toNoteId == source.noteId && $0.linkKind == "source-citation"
    })
  }

  func testConfigAgentViewModelAppliesAuditableConfigurationProposal() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteConfigAgentViewModel(client: fixture.client)
    viewModel.workflowRoot = "tmp/RielaNoteUITests/config-agent-workflows"

    viewModel.draftMessage = "Business idea notes"
    await viewModel.submitDraft()
    await viewModel.applyProposal(id: try XCTUnwrap(viewModel.proposals.first?.id))

    XCTAssertEqual(viewModel.proposals.first?.tagClass.classId, "business-idea")
    XCTAssertEqual(viewModel.proposals.first?.appliedResult?.tag.classId, "business-idea")
    XCTAssertEqual(viewModel.proposals.first?.appliedResult?.autoAction.workflowId, "note-auto-tagging")
    XCTAssertEqual(
      viewModel.proposals.first?.appliedResult?.workflowScaffold.workflowId,
      "note-ingest-business-idea"
    )
    XCTAssertEqual(fixture.client.appliedConfigWorkflowRoots, ["tmp/RielaNoteUITests/config-agent-workflows"])
  }

  func testNoteServiceClientAppliesConfigAgentProposalToStoreAndWorkflowRoot() async throws {
    let service = try makeService()
    let client = NoteServiceRielaNoteUIClient(service: service)
    let proposal = try await client.proposeNoteConfigAgentChange(message: "Business idea notes")
    let workflowRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/RielaNoteUITests/config-agent-service-workflows", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .path

    let result = try await client.applyNoteConfigAgentProposal(proposal, workflowRoot: workflowRoot)

    XCTAssertEqual(result.tagClass.classId, "business-idea-notes")
    XCTAssertEqual(result.tag.classId, "business-idea-notes")
    XCTAssertEqual(result.autoAction.workflowId, "note-auto-tagging")
    XCTAssertTrue(FileManager.default.fileExists(atPath: result.workflowScaffold.workflowPath))
    XCTAssertTrue(try service.listTagClasses().contains(result.tagClass))
    XCTAssertTrue(try service.listAutoActions().contains(result.autoAction))
  }

  func testListAndDetailViewsConstructFromViewModel() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)
    let agentViewModel = RielaNoteAgentViewModel(client: fixture.client)
    let configAgentViewModel = RielaNoteConfigAgentViewModel(client: fixture.client)
    await viewModel.load()

    _ = RielaNoteRootView(
      viewModel: viewModel,
      agentViewModel: agentViewModel,
      configAgentViewModel: configAgentViewModel
    )
    _ = RielaNoteNotebookListView(viewModel: viewModel)
    _ = RielaNoteNotebookListView(viewModel: viewModel, onOpenNote: { _ in })
    _ = RielaNoteDetailView(viewModel: viewModel)
    _ = RielaNoteAgentView(viewModel: agentViewModel)
    _ = RielaNoteConfigAgentView(viewModel: configAgentViewModel)
    _ = RielaNoteAgentTurnView(
      turn: RielaNoteAgentTurn(
        userMarkdown: "Question",
        assistantMarkdown: "Answer",
        citations: [RielaNoteAgentCitation(noteId: "note-1", title: "Page One")]
      ),
      onOpenCitation: { _ in }
    )
    _ = RielaNoteNotebookRow(notebook: fixture.notebook)
    _ = RielaNoteSearchResultRow(result: fixture.searchResult)
  }
}

func makeService(function: String = #function) throws -> NoteService {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tmp/RielaNoteUITests", isDirectory: true)
    .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
}

struct NoteUITestFixture {
  let notebook: Notebook
  let note: Note
  let searchNote: Note
  let sourceAttachment: NoteFileAttachment
  let relatedAttachment: NoteFileAttachment
  let searchResult: NoteSearchResult
  let client: MockRielaNoteUIClient

  init() {
    let tag = Tag(
      tagId: "tag-1",
      name: "notebook-kind:imported-material",
      classId: "document-kind",
      isSystem: true,
      createdAt: "2026-07-04T00:00:00Z"
    )
    let systemAssignment = TagAssignment(
      tag: tag,
      provenance: .system,
      assignedBy: "riela-note",
      deletable: false,
      createdAt: "2026-07-04T00:00:00Z"
    )
    notebook = Notebook(
      notebookId: "notebook-1",
      title: "Imported Book",
      createdAt: "2026-07-04T00:00:00Z",
      updatedAt: "2026-07-04T00:00:00Z",
      tags: [systemAssignment],
      firstNotePreview: "First page preview"
    )
    note = Note(
      noteId: "note-1",
      notebookId: "notebook-1",
      noteNumber: 1,
      title: "Page One",
      bodyMarkdown: "# Page One\n\nBody",
      readOnly: true,
      createdAt: "2026-07-04T00:00:00Z",
      updatedAt: "2026-07-04T00:00:00Z",
      tags: [systemAssignment]
    )
    searchNote = Note(
      noteId: "note-2",
      notebookId: "notebook-1",
      noteNumber: 2,
      title: "Ontology",
      bodyMarkdown: "# Ontology\n\nSearch body",
      readOnly: false,
      createdAt: "2026-07-04T00:00:00Z",
      updatedAt: "2026-07-04T00:00:00Z",
      tags: [systemAssignment]
    )
    let sourceFile = FileRecord(
      fileId: "file-page",
      storageKind: .local,
      localPath: "aa/file-page",
      s3Profile: nil,
      s3Bucket: nil,
      s3Key: nil,
      mediaType: "image/png",
      byteSize: 3,
      sha256: "sha",
      originalFilename: "page.png",
      createdAt: "2026-07-04T00:00:00Z",
      migratedAt: nil
    )
    let relatedFile = FileRecord(
      fileId: "file-related",
      storageKind: .local,
      localPath: "bb/file-related",
      s3Profile: nil,
      s3Bucket: nil,
      s3Key: nil,
      mediaType: "text/plain",
      byteSize: 15,
      sha256: "sha-related",
      originalFilename: "metadata.txt",
      createdAt: "2026-07-04T00:00:00Z",
      migratedAt: nil
    )
    sourceAttachment = NoteFileAttachment(noteId: "note-1", file: sourceFile, role: .sourcePageImage, position: 0)
    relatedAttachment = NoteFileAttachment(noteId: "note-1", file: relatedFile, role: .related, position: 1)
    searchResult = NoteSearchResult(note: searchNote, snippet: "ontology snippet", rank: 0, matchedTags: [tag])
    client = MockRielaNoteUIClient(
      notebook: notebook,
      note: note,
      searchNote: searchNote,
      sourceAttachment: sourceAttachment,
      relatedAttachment: relatedAttachment,
      searchResult: searchResult
    )
  }
}

final class MockRielaNoteUIClient: RielaNoteUIClient, @unchecked Sendable {
  var notebook: Notebook
  var note: Note
  var searchNote: Note
  var sourceAttachment: NoteFileAttachment
  var relatedAttachment: NoteFileAttachment
  var searchResult: NoteSearchResult
  var createdMemos: [Note] = []
  var createdNotebookNotes: [Note] = []
  var commentsByNoteId: [String: [NoteComment]] = [:]
  var links: [NoteLink] = []
  var searchRequests: [MockSearchRequest] = []
  var listNoteRequests: [MockListNotesRequest] = []
  var noteDetailRequests: [String] = []
  var resolveFileCallCount = 0
  var resolvedFileIds: [String] = []
  var savedConversations: [(title: String, turns: [RielaNoteAgentTurn])] = []
  var appendedTurns: [(notebookId: String, turn: RielaNoteAgentTurn)] = []
  var appliedConfigWorkflowRoots: [String] = []
  var agentAnswerError: Error?
  var searchDelayNanosecondsByQuery: [String: UInt64] = [:]
  var searchResultsByQuery: [String: [NoteSearchResult]] = [:]
  var noteDetailDelayNanosecondsByNoteId: [String: UInt64] = [:]
  var onNoteDetailStart: ((String) -> Void)?
  var linkNoteDelayNanoseconds: UInt64?
  var onLinkNoteStart: (() -> Void)?

  var defaultConfigWorkflowRoot: String {
    "tmp/RielaNoteUITests/default-config-workflows"
  }

  init(
    notebook: Notebook,
    note: Note,
    searchNote: Note,
    sourceAttachment: NoteFileAttachment,
    relatedAttachment: NoteFileAttachment,
    searchResult: NoteSearchResult
  ) {
    self.notebook = notebook
    self.note = note
    self.searchNote = searchNote
    self.sourceAttachment = sourceAttachment
    self.relatedAttachment = relatedAttachment
    self.searchResult = searchResult
  }

  func listNotebooks(limit: Int, offset: Int) async throws -> [Notebook] {
    [notebook]
  }

  func listNotebooks(
    limit: Int,
    offset: Int,
    tagFilter: [String],
    filter: RielaNoteListFilter
  ) async throws -> [Notebook] {
    let matches = tagFilter.isEmpty
      || !Set(notebook.tags.map(\.tag.name)).isDisjoint(with: tagFilter)
    return matches ? [notebook] : []
  }

  func listNotes(notebookId: String, limit: Int, offset: Int) async throws -> [Note] {
    listNoteRequests.append(MockListNotesRequest(notebookId: notebookId, limit: limit, offset: offset))
    return Array(([note, searchNote] + createdMemos + createdNotebookNotes).dropFirst(offset).prefix(limit))
  }

  func listTags() async throws -> [Tag] {
    let assignments = ([notebook.tags, note.tags, searchNote.tags] + createdMemos.map(\.tags) + createdNotebookNotes.map(\.tags))
      .flatMap { $0 }
    return Array(Dictionary(grouping: assignments.map(\.tag), by: \.name).values.compactMap(\.first))
      .sorted { $0.name < $1.name }
  }

  func createUserMemo(bodyMarkdown: String) async throws -> RielaNoteDetail {
    let tag = Tag(
      tagId: "tag-user-memo",
      name: "user-memo",
      classId: "topic",
      isSystem: false,
      createdAt: "2026-07-04T00:00:00Z"
    )
    let assignment = TagAssignment(
      tag: tag,
      provenance: .human,
      assignedBy: "riela-note-ui",
      deletable: true,
      createdAt: "2026-07-04T00:00:00Z"
    )
    let memo = Note(
      noteId: "note-user-memo-\(createdMemos.count + 1)",
      notebookId: notebook.notebookId,
      noteNumber: 3 + createdMemos.count,
      title: "Untitled Memo",
      bodyMarkdown: bodyMarkdown,
      readOnly: false,
      createdAt: "2026-07-04T00:00:00Z",
      updatedAt: "2026-07-04T00:00:00Z",
      tags: [assignment]
    )
    createdMemos.append(memo)
    return RielaNoteDetail(note: memo)
  }

  func createNote(inNotebook notebookId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    let tag = Tag(
      tagId: "tag-user-memo",
      name: "user-memo",
      classId: "topic",
      isSystem: false,
      createdAt: "2026-07-04T00:00:00Z"
    )
    let assignment = TagAssignment(
      tag: tag,
      provenance: .human,
      assignedBy: "riela-note-ui",
      deletable: true,
      createdAt: "2026-07-04T00:00:00Z"
    )
    let created = Note(
      noteId: "note-current-\(createdNotebookNotes.count + 1)",
      notebookId: notebookId,
      noteNumber: 3 + createdMemos.count + createdNotebookNotes.count,
      title: "Untitled Note",
      bodyMarkdown: bodyMarkdown,
      readOnly: false,
      createdAt: "2026-07-04T00:00:00Z",
      updatedAt: "2026-07-04T00:00:00Z",
      tags: [assignment]
    )
    createdNotebookNotes.append(created)
    return RielaNoteDetail(note: created)
  }

  func searchNotes(
    query: String,
    tagFilter: [String],
    classFilter: [String],
    limit: Int,
    offset: Int
  ) async throws -> [NoteSearchResult] {
    if let delay = searchDelayNanosecondsByQuery[query] {
      try await Task.sleep(nanoseconds: delay)
    }
    searchRequests.append(MockSearchRequest(
      query: query,
      tagFilter: tagFilter,
      classFilter: classFilter,
      limit: limit,
      offset: offset
    ))
    guard tagFilter.isEmpty || !Set(searchNote.tags.map(\.tag.name)).isDisjoint(with: tagFilter) else {
      return []
    }
    if let results = searchResultsByQuery[query] {
      return Array(results.dropFirst(offset).prefix(limit))
    }
    let memoResults = (createdMemos + createdNotebookNotes).map { memo in
      NoteSearchResult(note: memo, snippet: memo.title ?? memo.noteId, rank: 1, matchedTags: memo.tags.map(\.tag))
    }
    return Array(([searchResult] + memoResults).dropFirst(offset).prefix(limit))
  }

  func noteDetail(noteId: String) async throws -> RielaNoteDetail {
    onNoteDetailStart?(noteId)
    noteDetailRequests.append(noteId)
    if let delay = noteDetailDelayNanosecondsByNoteId[noteId] {
      try await Task.sleep(nanoseconds: delay)
    }
    if let memo = createdMemos.first(where: { $0.noteId == noteId }) {
      return detail(for: memo)
    }
    if let created = createdNotebookNotes.first(where: { $0.noteId == noteId }) {
      return detail(for: created)
    }
    let selected = noteId == searchNote.noteId ? searchNote : note
    return detail(for: selected)
  }

  func firstNote(inNotebook notebookId: String) async throws -> RielaNoteDetail? {
    detail(for: note)
  }

  func resolveFile(fileId: String) async throws -> RielaNoteResolvedFile {
    resolveFileCallCount += 1
    resolvedFileIds.append(fileId)
    if fileId == relatedAttachment.file.fileId {
      return RielaNoteResolvedFile(file: relatedAttachment.file, data: Data("source metadata".utf8))
    }
    return RielaNoteResolvedFile(file: sourceAttachment.file, data: Data([1, 2, 3]))
  }

  func updateNoteBody(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    let selected = noteId == searchNote.noteId
      ? Note(
        noteId: searchNote.noteId,
        notebookId: searchNote.notebookId,
        noteNumber: searchNote.noteNumber,
        title: "Changed",
        bodyMarkdown: bodyMarkdown,
        readOnly: searchNote.readOnly,
        createdAt: searchNote.createdAt,
        updatedAt: "2026-07-04T00:01:00Z",
        tags: searchNote.tags
      )
      : note
    store(note: selected)
    return detail(for: selected)
  }

  func applyTag(noteId: String, tagName: String, classId: String?) async throws -> RielaNoteDetail {
    var selected = storedNote(noteId: noteId)
    let tag = Tag(
      tagId: "tag-\(tagName)",
      name: tagName,
      classId: classId,
      isSystem: false,
      createdAt: "2026-07-04T00:00:00Z"
    )
    let assignment = TagAssignment(
      tag: tag,
      provenance: .human,
      assignedBy: "riela-note-ui",
      deletable: true,
      createdAt: "2026-07-04T00:00:00Z"
    )
    selected.tags.removeAll { $0.tag.name == tagName }
    selected.tags.append(assignment)
    store(note: selected)
    return detail(for: selected)
  }

  func removeTag(noteId: String, tagName: String) async throws -> RielaNoteDetail {
    var selected = storedNote(noteId: noteId)
    selected.tags.removeAll { $0.tag.name == tagName }
    store(note: selected)
    return detail(for: selected)
  }

  func addComment(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    let selected = storedNote(noteId: noteId)
    var comments = commentsByNoteId[noteId] ?? []
    comments.append(NoteComment(
      commentId: "comment-\(comments.count + 1)",
      noteId: noteId,
      bodyMarkdown: bodyMarkdown,
      author: "user",
      createdAt: "2026-07-04T00:00:00Z"
    ))
    commentsByNoteId[noteId] = comments
    return detail(for: selected)
  }

  func linkNote(noteId: String, targetNoteId: String, linkKind: String) async throws -> RielaNoteDetail {
    onLinkNoteStart?()
    if let linkNoteDelayNanoseconds {
      try await Task.sleep(nanoseconds: linkNoteDelayNanoseconds)
    }
    let selected = storedNote(noteId: noteId)
    links.append(NoteLink(
      fromNoteId: noteId,
      toNoteId: targetNoteId,
      linkKind: linkKind,
      provenance: .human,
      createdAt: "2026-07-04T00:00:00Z"
    ))
    return detail(for: selected)
  }

  func answerNoteAgentTurn(message: String, limit: Int) async throws -> RielaNoteAgentTurn {
    if let agentAnswerError {
      throw agentAnswerError
    }
    return RielaNoteAgentTurn(
      userMarkdown: message,
      assistantMarkdown: "Mock answer for \(message)",
      citations: [
        RielaNoteAgentCitation(
          noteId: searchResult.note.noteId,
          title: searchResult.note.title,
          snippet: searchResult.snippet
        )
      ]
    )
  }

  func saveNoteAgentConversation(
    title: String,
    turns: [RielaNoteAgentTurn]
  ) async throws -> RielaNoteAgentConversationSaveResult {
    savedConversations.append((title: title, turns: turns))
    return RielaNoteAgentConversationSaveResult(
      notebookId: "agent-notebook-\(savedConversations.count)",
      noteIds: turns.indices.map { "conversation-note-\($0 + 1)" }
    )
  }

  func appendNoteAgentTurn(
    notebookId: String,
    turn: RielaNoteAgentTurn
  ) async throws -> RielaNoteAgentConversationSaveResult {
    appendedTurns.append((notebookId: notebookId, turn: turn))
    return RielaNoteAgentConversationSaveResult(
      notebookId: notebookId,
      noteIds: ["conversation-note-\(savedConversations.count + appendedTurns.count)"]
    )
  }

  func proposeNoteConfigAgentChange(message: String) async throws -> RielaNoteConfigAgentProposal {
    RielaNoteConfigAgentProposal(
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
    appliedConfigWorkflowRoots.append(workflowRoot)
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
      files: [
        NoteWorkflowScaffoldFile(
          relativePath: "workflow.json",
          path: "\(workflowRoot)/\(proposal.ingestionWorkflow.workflowId)/workflow.json"
        )
      ]
    )
    return RielaNoteConfigAgentApplyResult(
      tagClass: tagClass,
      tag: tag,
      autoAction: action,
      workflowScaffold: scaffold
    )
  }

  private func detail(for selected: Note) -> RielaNoteDetail {
    let selectedLinks = links.filter { $0.fromNoteId == selected.noteId || $0.toNoteId == selected.noteId }
    return RielaNoteDetail(
      note: selected,
      comments: commentsByNoteId[selected.noteId] ?? [],
      links: selectedLinks,
      linkedNotesById: linkedNotesById(for: selected.noteId, links: selectedLinks),
      files: selected.noteId == note.noteId ? [sourceAttachment, relatedAttachment] : []
    )
  }

  private func linkedNotesById(for noteId: String, links: [NoteLink]) -> [String: Note] {
    Dictionary(uniqueKeysWithValues: links.map { link in
      let linkedNoteId = link.fromNoteId == noteId ? link.toNoteId : link.fromNoteId
      return (linkedNoteId, storedNote(noteId: linkedNoteId))
    })
  }

  private func storedNote(noteId: String) -> Note {
    if note.noteId == noteId {
      return note
    }
    if searchNote.noteId == noteId {
      return searchNote
    }
    return createdMemos.first { $0.noteId == noteId }
      ?? createdNotebookNotes.first { $0.noteId == noteId }
      ?? note
  }

  private func store(note updated: Note) {
    if note.noteId == updated.noteId {
      note = updated
    } else if searchNote.noteId == updated.noteId {
      searchNote = updated
    } else if let index = createdMemos.firstIndex(where: { $0.noteId == updated.noteId }) {
      createdMemos[index] = updated
    } else if let index = createdNotebookNotes.firstIndex(where: { $0.noteId == updated.noteId }) {
      createdNotebookNotes[index] = updated
    }
  }
}

struct MockSearchRequest: Equatable {
  var query: String
  var tagFilter: [String]
  var classFilter: [String]
  var limit: Int
  var offset: Int
}

struct MockListNotesRequest: Equatable {
  var notebookId: String
  var limit: Int
  var offset: Int
}
