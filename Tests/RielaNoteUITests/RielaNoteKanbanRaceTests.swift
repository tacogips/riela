import Foundation
import RielaNote
@testable import RielaNoteUI
import XCTest

@MainActor
final class RielaNoteKanbanRaceTests: XCTestCase {
  func testTagChangeDiscardsStaleLoadMorePage() async throws {
    let gate = KanbanNotebookRequestGate()
    let client = KanbanRaceClient(gate: gate)
    let viewModel = RielaNoteLibraryViewModel(client: client, notebookLimit: 1)
    await viewModel.load()
    viewModel.selectedSearchTagNames = ["alpha"]
    await viewModel.submitSearch()
    XCTAssertEqual(viewModel.notebooks.map(\.notebookId), ["alpha-1"])
    XCTAssertTrue(viewModel.canLoadMoreNotebooks)

    let requestKey = kanbanRequestKey(tagFilter: ["alpha"], offset: 1)
    await gate.block(requestKey)
    let staleLoadMore = Task {
      await viewModel.loadMoreNotebooks()
    }
    try await gate.waitUntilSuspended(requestKey)

    viewModel.selectedSearchTagNames = ["beta"]
    await viewModel.submitSearch()
    XCTAssertEqual(viewModel.notebooks.map(\.notebookId), ["beta-1"])

    await gate.resume(requestKey)
    await staleLoadMore.value

    XCTAssertEqual(viewModel.notebooks.map(\.notebookId), ["beta-1"])
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testTagChangeDiscardsStaleRefreshFirstPage() async throws {
    let gate = KanbanNotebookRequestGate()
    let client = KanbanRaceClient(gate: gate)
    let viewModel = RielaNoteLibraryViewModel(client: client, notebookLimit: 1)
    await viewModel.load()
    viewModel.selectedSearchTagNames = ["alpha"]
    await viewModel.submitSearch()
    XCTAssertEqual(viewModel.notebooks.map(\.notebookId), ["alpha-1"])

    let requestKey = kanbanRequestKey(tagFilter: ["alpha"], offset: 0)
    await gate.block(requestKey)
    let staleRefresh = Task {
      await viewModel.refresh()
    }
    try await gate.waitUntilSuspended(requestKey)

    viewModel.selectedSearchTagNames = ["beta"]
    await viewModel.submitSearch()
    XCTAssertEqual(viewModel.notebooks.map(\.notebookId), ["beta-1"])

    await gate.resume(requestKey)
    await staleRefresh.value

    XCTAssertEqual(viewModel.notebooks.map(\.notebookId), ["beta-1"])
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testRefreshDiscardsSameFilterLoadMorePage() async throws {
    let gate = KanbanNotebookRequestGate()
    let client = KanbanRaceClient(gate: gate)
    let viewModel = RielaNoteLibraryViewModel(client: client, notebookLimit: 1)
    await viewModel.load()
    viewModel.selectedSearchTagNames = ["alpha"]
    await viewModel.submitSearch()
    XCTAssertEqual(viewModel.notebooks.map(\.notebookId), ["alpha-1"])

    let requestKey = kanbanRequestKey(tagFilter: ["alpha"], offset: 1)
    await gate.block(requestKey)
    let staleLoadMore = Task {
      await viewModel.loadMoreNotebooks()
    }
    try await gate.waitUntilSuspended(requestKey)

    await viewModel.refresh()
    XCTAssertEqual(viewModel.notebooks.map(\.notebookId), ["alpha-1"])

    await gate.resume(requestKey)
    await staleLoadMore.value

    XCTAssertEqual(viewModel.notebooks.map(\.notebookId), ["alpha-1"])
    XCTAssertTrue(viewModel.canLoadMoreNotebooks)
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testInitialTagLoadFailureDoesNotExposeUnfilteredNotebookBoard() async {
    let gate = KanbanNotebookRequestGate()
    let client = KanbanRaceClient(
      gate: gate,
      includeUnfilteredNotebook: true
    )
    let viewModel = RielaNoteLibraryViewModel(client: client, notebookLimit: 1)
    await viewModel.load()
    XCTAssertEqual(viewModel.notebooks.map(\.notebookId), ["unfiltered-1"])

    let requestKey = kanbanRequestKey(tagFilter: ["alpha"], offset: 0)
    await gate.fail(requestKey)
    viewModel.selectedSearchTagNames = ["alpha"]
    await viewModel.submitSearch()

    XCTAssertEqual(viewModel.notebooks.map(\.notebookId), ["unfiltered-1"])
    XCTAssertFalse(viewModel.hasCurrentTagKanbanSnapshot)
    guard case .tagKanbanLoadFailed = RielaNoteSearchPopupSheet(
      viewModel: viewModel,
      onClose: {}
    ).contentMode else {
      return XCTFail("expected filtered load failure without the unfiltered board")
    }
  }

  func testTagChangeFailureDoesNotExposePreviousTagNotebookBoard() async {
    let gate = KanbanNotebookRequestGate()
    let client = KanbanRaceClient(gate: gate)
    let viewModel = await loadedAlphaViewModel(client: client)
    XCTAssertEqual(viewModel.notebooks.map(\.notebookId), ["alpha-1"])

    let requestKey = kanbanRequestKey(tagFilter: ["beta"], offset: 0)
    await gate.fail(requestKey)
    viewModel.selectedSearchTagNames = ["beta"]
    await viewModel.submitSearch()

    XCTAssertEqual(viewModel.notebooks.map(\.notebookId), ["alpha-1"])
    XCTAssertFalse(viewModel.hasCurrentTagKanbanSnapshot)
    guard case .tagKanbanLoadFailed = RielaNoteSearchPopupSheet(
      viewModel: viewModel,
      onClose: {}
    ).contentMode else {
      return XCTFail("expected beta load failure without the alpha board")
    }
  }

  func testNewerProgressMutationWinsOverOlderSuccess() async throws {
    let gate = KanbanNotebookRequestGate()
    let client = KanbanRaceClient(gate: gate)
    let viewModel = await loadedAlphaViewModel(client: client)
    let notebookId = try XCTUnwrap(viewModel.notebooks.first?.notebookId)
    let olderKey = kanbanProgressRequestKey(notebookId: notebookId, progress: .progress)
    await gate.block(olderKey)
    let olderMutation = Task {
      await viewModel.setNotebookProgress(notebookId: notebookId, progress: .progress)
    }
    try await gate.waitUntilSuspended(olderKey)

    await viewModel.setNotebookProgress(notebookId: notebookId, progress: .done)
    XCTAssertEqual(viewModel.notebooks.first?.progress, .done)

    await gate.resume(olderKey)
    await olderMutation.value

    let persistedProgress = await client.persistedProgress(notebookId: notebookId)
    XCTAssertEqual(viewModel.notebooks.first?.progress, .done)
    XCTAssertEqual(persistedProgress, .done)
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testOlderProgressFailureCannotReplaceNewerSuccess() async throws {
    let gate = KanbanNotebookRequestGate()
    let client = KanbanRaceClient(gate: gate)
    let viewModel = await loadedAlphaViewModel(client: client)
    let notebookId = try XCTUnwrap(viewModel.notebooks.first?.notebookId)
    let olderKey = kanbanProgressRequestKey(notebookId: notebookId, progress: .progress)
    await gate.block(olderKey)
    await gate.fail(olderKey)
    let olderMutation = Task {
      await viewModel.setNotebookProgress(notebookId: notebookId, progress: .progress)
    }
    try await gate.waitUntilSuspended(olderKey)

    await viewModel.setNotebookProgress(notebookId: notebookId, progress: .done)
    await gate.resume(olderKey)
    await olderMutation.value

    XCTAssertEqual(viewModel.notebooks.first?.progress, .done)
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testRefreshReconcilesInFlightProgressMutationCompletion() async throws {
    let gate = KanbanNotebookRequestGate()
    let client = KanbanRaceClient(gate: gate)
    let viewModel = await loadedAlphaViewModel(client: client)
    let notebookId = try XCTUnwrap(viewModel.notebooks.first?.notebookId)
    let mutationKey = kanbanProgressRequestKey(notebookId: notebookId, progress: .done)
    await gate.block(mutationKey)
    let staleMutation = Task {
      await viewModel.setNotebookProgress(notebookId: notebookId, progress: .done)
    }
    try await gate.waitUntilSuspended(mutationKey)

    await viewModel.refresh()
    XCTAssertEqual(viewModel.notebooks.first?.progress, NotebookProgress.none)

    await gate.resume(mutationKey)
    await staleMutation.value

    let persistedProgress = await client.persistedProgress(notebookId: notebookId)
    XCTAssertEqual(viewModel.notebooks.first?.progress, .done)
    XCTAssertEqual(persistedProgress, .done)
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testFailedMutationDoesNotInvalidateOtherNotebookSuccess() async throws {
    let gate = KanbanNotebookRequestGate()
    let client = KanbanRaceClient(gate: gate)
    let viewModel = await loadedAlphaViewModel(client: client, notebookLimit: 3)
    let failedNotebookId = "alpha-1"
    let successfulNotebookId = "alpha-2"
    let successKey = kanbanProgressRequestKey(
      notebookId: successfulNotebookId,
      progress: .done
    )
    await gate.block(successKey)
    let successfulMutation = Task {
      await viewModel.setNotebookProgress(
        notebookId: successfulNotebookId,
        progress: .done
      )
    }
    try await gate.waitUntilSuspended(successKey)

    let failureKey = kanbanProgressRequestKey(
      notebookId: failedNotebookId,
      progress: .pending
    )
    await gate.fail(failureKey)
    await viewModel.setNotebookProgress(
      notebookId: failedNotebookId,
      progress: .pending
    )
    guard case .failed = viewModel.state else {
      return XCTFail("expected the first notebook mutation to fail")
    }

    await gate.resume(successKey)
    await successfulMutation.value

    let persistedProgress = await client.persistedProgress(
      notebookId: successfulNotebookId
    )
    XCTAssertEqual(
      viewModel.notebooks.first(where: { $0.notebookId == successfulNotebookId })?.progress,
      .done
    )
    XCTAssertEqual(persistedProgress, .done)
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testNewerProgressMutationConvergesDatabaseEvenWhenBoardContextChanges() async throws {
    let gate = KanbanNotebookRequestGate()
    let client = KanbanRaceClient(gate: gate)
    let viewModel = await loadedAlphaViewModel(client: client)
    let notebookId = try XCTUnwrap(viewModel.notebooks.first?.notebookId)

    // Older mutation (progress) is suspended before its DB write lands.
    let olderKey = kanbanProgressRequestKey(notebookId: notebookId, progress: .progress)
    await gate.block(olderKey)
    let olderMutation = Task {
      await viewModel.setNotebookProgress(notebookId: notebookId, progress: .progress)
    }
    try await gate.waitUntilSuspended(olderKey)

    // Newer mutation (done) commits fully: DB and UI now show done.
    await viewModel.setNotebookProgress(notebookId: notebookId, progress: .done)
    XCTAssertEqual(viewModel.notebooks.first?.progress, .done)

    // The user switches to a different tag board before the stale write lands.
    viewModel.selectedSearchTagNames = ["beta"]
    await viewModel.submitSearch()

    // Now the stale older write commits last (DB briefly regresses to progress).
    await gate.resume(olderKey)
    await olderMutation.value

    // Convergence guarantee: the database must reflect the newest requested
    // target (done), even though the active board context changed to beta.
    let persistedProgress = await client.persistedProgress(notebookId: notebookId)
    XCTAssertEqual(persistedProgress, .done)
  }

  private func loadedAlphaViewModel(
    client: KanbanRaceClient,
    notebookLimit: Int = 1
  ) async -> RielaNoteLibraryViewModel {
    let viewModel = RielaNoteLibraryViewModel(
      client: client,
      notebookLimit: notebookLimit
    )
    await viewModel.load()
    viewModel.selectedSearchTagNames = ["alpha"]
    await viewModel.submitSearch()
    return viewModel
  }
}

private actor KanbanNotebookRequestGate {
  private var blockedKeys: Set<String> = []
  private var failingKeys: Set<String> = []
  private var continuations: [String: CheckedContinuation<Void, Never>] = [:]

  func block(_ key: String) {
    blockedKeys.insert(key)
  }

  func fail(_ key: String) {
    failingKeys.insert(key)
  }

  func shouldFail(_ key: String) -> Bool {
    failingKeys.contains(key)
  }

  func suspendIfBlocked(_ key: String) async {
    guard blockedKeys.contains(key) else {
      return
    }
    await withCheckedContinuation { continuation in
      continuations[key] = continuation
    }
  }

  func waitUntilSuspended(
    _ key: String,
    timeout: Duration = .seconds(2)
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while continuations[key] == nil {
      guard clock.now < deadline else {
        throw KanbanRaceClientError.timedOutWaitingForRequest(key)
      }
      await Task.yield()
    }
  }

  func resume(_ key: String) {
    blockedKeys.remove(key)
    continuations.removeValue(forKey: key)?.resume()
  }
}

private final class KanbanRaceClient: RielaNoteUIClient, @unchecked Sendable {
  let gate: KanbanNotebookRequestGate
  let notebooksByTag: [String: [Notebook]]
  let progressStore = KanbanNotebookProgressStore()

  init(
    gate: KanbanNotebookRequestGate,
    includeUnfilteredNotebook: Bool = false
  ) {
    self.gate = gate
    var notebooksByTag = [
      "alpha": [
        Self.notebook(id: "alpha-1"),
        Self.notebook(id: "alpha-2"),
        Self.notebook(id: "alpha-3")
      ],
      "beta": [Self.notebook(id: "beta-1")]
    ]
    if includeUnfilteredNotebook {
      notebooksByTag[""] = [Self.notebook(id: "unfiltered-1")]
    }
    self.notebooksByTag = notebooksByTag
  }

  var defaultConfigWorkflowRoot: String {
    "tmp/RielaNoteKanbanRaceTests/workflows"
  }

  func listNotebooks(limit: Int, offset: Int) async throws -> [Notebook] {
    Array([Self.notebook(id: "unfiltered-1")].dropFirst(offset).prefix(limit))
  }

  func listNotebooks(
    limit: Int,
    offset: Int,
    tagFilter: [String],
    filter: RielaNoteListFilter
  ) async throws -> [Notebook] {
    let key = kanbanRequestKey(tagFilter: tagFilter, offset: offset)
    await gate.suspendIfBlocked(key)
    if await gate.shouldFail(key) {
      throw KanbanRaceClientError.notebookLoadFailed
    }
    let tagKey = tagFilter.sorted().joined(separator: ",")
    let page = Array((notebooksByTag[tagKey] ?? []).dropFirst(offset).prefix(limit))
    return await progressStore.applyingProgress(to: page)
  }

  func listNotes(notebookId: String, limit: Int, offset: Int) async throws -> [Note] {
    []
  }

  func setNotebookProgress(
    notebookId: String,
    progress: NotebookProgress
  ) async throws -> Notebook {
    let key = kanbanProgressRequestKey(notebookId: notebookId, progress: progress)
    await gate.suspendIfBlocked(key)
    if await gate.shouldFail(key) {
      throw KanbanRaceClientError.progressMutationFailed
    }
    await progressStore.setProgress(progress, notebookId: notebookId)
    return Self.notebook(id: notebookId, progress: progress)
  }

  func persistedProgress(notebookId: String) async -> NotebookProgress {
    await progressStore.progress(notebookId: notebookId)
  }

  func listTags() async throws -> [Tag] {
    [
      Self.tag(name: "alpha"),
      Self.tag(name: "beta")
    ]
  }

  func createUserMemo(bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw KanbanRaceClientError.unsupported
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
    throw KanbanRaceClientError.unsupported
  }

  func firstNote(inNotebook notebookId: String) async throws -> RielaNoteDetail? {
    nil
  }

  func resolveFile(fileId: String) async throws -> RielaNoteResolvedFile {
    throw KanbanRaceClientError.unsupported
  }

  func updateNoteBody(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw KanbanRaceClientError.unsupported
  }

  func applyTag(noteId: String, tagName: String, classId: String?) async throws -> RielaNoteDetail {
    throw KanbanRaceClientError.unsupported
  }

  func removeTag(noteId: String, tagName: String) async throws -> RielaNoteDetail {
    throw KanbanRaceClientError.unsupported
  }

  func addComment(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw KanbanRaceClientError.unsupported
  }

  func linkNote(noteId: String, targetNoteId: String, linkKind: String) async throws -> RielaNoteDetail {
    throw KanbanRaceClientError.unsupported
  }

  func answerNoteAgentTurn(message: String, limit: Int) async throws -> RielaNoteAgentTurn {
    throw KanbanRaceClientError.unsupported
  }

  func saveNoteAgentConversation(
    title: String,
    turns: [RielaNoteAgentTurn]
  ) async throws -> RielaNoteAgentConversationSaveResult {
    throw KanbanRaceClientError.unsupported
  }

  func appendNoteAgentTurn(
    notebookId: String,
    turn: RielaNoteAgentTurn
  ) async throws -> RielaNoteAgentConversationSaveResult {
    throw KanbanRaceClientError.unsupported
  }

  func proposeNoteConfigAgentChange(message: String) async throws -> RielaNoteConfigAgentProposal {
    throw KanbanRaceClientError.unsupported
  }

  func applyNoteConfigAgentProposal(
    _ proposal: RielaNoteConfigAgentProposal,
    workflowRoot: String
  ) async throws -> RielaNoteConfigAgentApplyResult {
    throw KanbanRaceClientError.unsupported
  }

  private static func notebook(
    id: String,
    progress: NotebookProgress = .none
  ) -> Notebook {
    Notebook(
      notebookId: id,
      title: id,
      progress: progress,
      createdAt: "2026-07-24T00:00:00Z",
      updatedAt: "2026-07-24T00:00:00Z"
    )
  }

  private static func tag(name: String) -> Tag {
    Tag(
      tagId: "tag-\(name)",
      name: name,
      classId: "topic",
      isSystem: false,
      createdAt: "2026-07-24T00:00:00Z"
    )
  }
}

private actor KanbanNotebookProgressStore {
  private var progressByNotebookId: [String: NotebookProgress] = [:]

  func setProgress(_ progress: NotebookProgress, notebookId: String) {
    progressByNotebookId[notebookId] = progress
  }

  func progress(notebookId: String) -> NotebookProgress {
    progressByNotebookId[notebookId] ?? .none
  }

  func applyingProgress(to notebooks: [Notebook]) -> [Notebook] {
    notebooks.map { notebook in
      Notebook(
        notebookId: notebook.notebookId,
        title: notebook.title,
        progress: progress(notebookId: notebook.notebookId),
        createdAt: notebook.createdAt,
        updatedAt: notebook.updatedAt,
        metaJSON: notebook.metaJSON,
        tags: notebook.tags,
        firstNotePreview: notebook.firstNotePreview,
        noteCount: notebook.noteCount
      )
    }
  }
}

private enum KanbanRaceClientError: Error {
  case unsupported
  case notebookLoadFailed
  case progressMutationFailed
  case timedOutWaitingForRequest(String)
}

private func kanbanRequestKey(tagFilter: [String], offset: Int) -> String {
  "\(tagFilter.sorted().joined(separator: ","))|\(offset)"
}

private func kanbanProgressRequestKey(
  notebookId: String,
  progress: NotebookProgress
) -> String {
  "progress|\(notebookId)|\(progress.rawValue)"
}
