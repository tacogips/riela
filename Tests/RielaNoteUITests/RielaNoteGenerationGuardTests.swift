import Foundation
import RielaNote
@testable import RielaNoteUI
import XCTest

/// Race tests for the T4 generation-guard invariant: every post-`await` write to
/// selection- or search-scoped state is dropped when a newer generation exists.
/// The mock client exposes per-method latency gates so a slow in-flight request can be
/// overtaken by a fresh one deterministically.
@MainActor
final class RielaNoteGenerationGuardTests: XCTestCase {
  // MARK: - (a) stale source-image resolution is dropped

  func testStaleSourceImageResolutionDoesNotOverwriteNewSelection() async throws {
    let client = GenerationGuardClient()
    let viewModel = RielaNoteLibraryViewModel(client: client)

    await viewModel.selectNotebook("notebook-1")

    // Selecting note-1 in image mode starts a slow resolve; switch to note-2 before it lands.
    client.resolveFileDelayNanoseconds = 60_000_000
    let selectA = Task { await viewModel.selectNote("note-1") }
    try await Task.sleep(nanoseconds: 5_000_000)
    client.resolveFileDelayNanoseconds = 0
    await viewModel.setContentMode(.sourceImage)
    // Note-1's resolve is still in flight; move to note-2.
    await viewModel.selectNote("note-2")
    await selectA.value

    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-2")
    // The stale note-1 image must never replace note-2's (nil, since note-2 is text mode).
    XCTAssertNotEqual(viewModel.resolvedSourceImage?.file.fileId, "file-page-1")
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testStaleSourceImageFailureLeavesStateLoaded() async throws {
    let client = GenerationGuardClient()
    let viewModel = RielaNoteLibraryViewModel(client: client)

    await viewModel.selectNotebook("notebook-1")
    await viewModel.selectNote("note-1")

    // Start a failing, slow image resolve for note-1, then switch to note-2.
    client.resolveFileDelayNanoseconds = 60_000_000
    client.resolveFileError = GenerationGuardClientError.resolveFailed
    let resolve = Task { await viewModel.setContentMode(.sourceImage) }
    try await Task.sleep(nanoseconds: 5_000_000)
    client.resolveFileDelayNanoseconds = 0
    client.resolveFileError = nil
    await viewModel.selectNote("note-2")
    await resolve.value

    // The stale failure must not flip global state to .failed.
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-2")
  }

  // MARK: - (b) notebook load-more racing selectNotebook

  func testNotebookLoadMoreRacingSelectNotebookKeepsTargetList() async throws {
    let client = GenerationGuardClient()
    let viewModel = RielaNoteLibraryViewModel(client: client, notebookNoteLimit: 2)

    await viewModel.selectNotebook("notebook-1")
    XCTAssertTrue(viewModel.canLoadMoreNotebookNotes)

    // Load-more in notebook-1 is slow; switch to notebook-2 before its page lands.
    client.listNotesDelayNanoseconds = 60_000_000
    let loadMore = Task { await viewModel.loadMoreNotebookNotes() }
    try await Task.sleep(nanoseconds: 5_000_000)
    client.listNotesDelayNanoseconds = 0
    await viewModel.selectNotebook("notebook-2")
    await loadMore.value

    XCTAssertEqual(viewModel.selectedNotebookId, "notebook-2")
    // notebook-2 has exactly 2 notes; the stale page from notebook-1 must not appear.
    XCTAssertTrue(viewModel.notebookNotes.allSatisfy { $0.notebookId == "notebook-2" })
    XCTAssertEqual(viewModel.notebookNotesOffsetForTesting, viewModel.notebookNotes.count)
  }

  func testStaleWindowFailureDoesNotRestoreOlderNotebookSelection() async throws {
    let client = GenerationGuardClient()
    let viewModel = RielaNoteLibraryViewModel(client: client, notebookNoteLimit: 2)

    await viewModel.selectNotebook("notebook-1")
    client.notebookWindowDelayNanosecondsByNoteId["note-7"] = 60_000_000
    client.notebookWindowErrorByNoteId["note-7"] = GenerationGuardClientError.windowFailed

    let staleSelection = Task { await viewModel.selectNote("note-7") }
    try await Task.sleep(nanoseconds: 5_000_000)
    await viewModel.selectNote("note-8")
    await staleSelection.value

    XCTAssertEqual(viewModel.selectedNotebookId, "notebook-2")
    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-8")
    XCTAssertTrue(viewModel.notebookNotes.allSatisfy { $0.notebookId == "notebook-2" })
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testStaleBackwardNavigationDoesNotOverrideNewerSelection() async throws {
    let client = GenerationGuardClient()
    let viewModel = RielaNoteLibraryViewModel(client: client, notebookNoteLimit: 2)

    await viewModel.selectNotebook("notebook-1")
    await viewModel.selectNote("note-5")
    await viewModel.selectNote("note-4")
    client.listNotesDelayNanoseconds = 60_000_000

    let stalePrevious = Task { await viewModel.selectPreviousNote() }
    try await Task.sleep(nanoseconds: 5_000_000)
    client.listNotesDelayNanoseconds = 0
    await viewModel.selectNote("note-5")
    await stalePrevious.value

    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-5")
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testStaleForwardNavigationDoesNotUseChangedWindowIndices() async throws {
    let client = GenerationGuardClient()
    let viewModel = RielaNoteLibraryViewModel(client: client, notebookNoteLimit: 2)

    await viewModel.selectNotebook("notebook-1")
    await viewModel.selectNote("note-5")
    client.listNotesDelayNanoseconds = 60_000_000

    let staleNext = Task { await viewModel.selectNextNote() }
    try await Task.sleep(nanoseconds: 5_000_000)
    client.listNotesDelayNanoseconds = 0
    await viewModel.selectNote("note-4")
    await viewModel.selectNote("note-5")
    await viewModel.loadEarlierNotebookNotes()
    await staleNext.value

    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-5")
    XCTAssertEqual(viewModel.state, .loaded)
  }

  // MARK: - (c) search load-more racing a new query

  func testSearchLoadMoreRacingNewQueryKeepsNewResults() async throws {
    let client = GenerationGuardClient()
    let viewModel = RielaNoteLibraryViewModel(client: client, searchLimit: 2)
    viewModel.searchText = "alpha"
    await viewModel.submitSearch()
    XCTAssertTrue(viewModel.canLoadMoreSearchResults)

    // Slow load-more for "alpha"; a new query "beta" arrives before it lands.
    client.searchNotesDelayNanoseconds = 60_000_000
    let loadMore = Task { await viewModel.loadMoreSearchResults() }
    try await Task.sleep(nanoseconds: 5_000_000)
    client.searchNotesDelayNanoseconds = 0
    viewModel.searchText = "beta"
    await viewModel.submitSearch()
    await loadMore.value

    XCTAssertTrue(viewModel.searchResults.allSatisfy { $0.note.title?.hasPrefix("beta") == true })
  }

  // MARK: - (d) empty-query load() racing a new performSearch

  func testEmptyQueryLoadRacingNewSearchKeepsNewResults() async throws {
    let client = GenerationGuardClient()
    let viewModel = RielaNoteLibraryViewModel(client: client)

    await viewModel.selectNotebook("notebook-1")
    viewModel.searchText = "alpha"
    await viewModel.submitSearch()
    XCTAssertFalse(viewModel.searchResults.isEmpty)

    // Clearing the query triggers load() (slow listTags); a new search overtakes it.
    client.listTagsDelayNanoseconds = 60_000_000
    viewModel.searchText = ""
    let clear = Task { await viewModel.updateSearchText("") }
    try await Task.sleep(nanoseconds: 5_000_000)
    client.listTagsDelayNanoseconds = 0
    viewModel.searchText = "beta"
    await viewModel.submitSearch()
    await clear.value

    // The stale load() must not wipe the newer "beta" search results.
    XCTAssertFalse(viewModel.searchResults.isEmpty)
    XCTAssertTrue(viewModel.searchResults.allSatisfy { $0.note.title?.hasPrefix("beta") == true })
  }

  // MARK: - (e) double-invoked load-more fetches one page

  func testDoubleInvokedNotebookLoadMoreFetchesOnePage() async throws {
    let client = GenerationGuardClient()
    let viewModel = RielaNoteLibraryViewModel(client: client, notebookNoteLimit: 2)

    await viewModel.selectNotebook("notebook-1")
    client.listNotesDelayNanoseconds = 40_000_000
    client.resetListNotesCount()

    async let first: Void = viewModel.loadMoreNotebookNotes()
    async let second: Void = viewModel.loadMoreNotebookNotes()
    _ = await (first, second)

    // The reentrancy flag makes the second invocation a no-op: one extra page fetch.
    XCTAssertEqual(client.listNotesCallCount, 1)
    XCTAssertEqual(viewModel.notebookNotesOffsetForTesting, viewModel.notebookNotes.count)
  }

  func testDoubleInvokedSearchLoadMoreFetchesOnePage() async throws {
    let client = GenerationGuardClient()
    let viewModel = RielaNoteLibraryViewModel(client: client, searchLimit: 2)
    viewModel.searchText = "alpha"
    await viewModel.submitSearch()

    client.searchNotesDelayNanoseconds = 40_000_000
    client.resetSearchNotesCount()

    async let first: Void = viewModel.loadMoreSearchResults()
    async let second: Void = viewModel.loadMoreSearchResults()
    _ = await (first, second)

    XCTAssertEqual(client.searchNotesCallCount, 1)
  }

  // MARK: - (f) stale SelectionQA / EditRewrite leaves is*Loading == false

  func testStaleSelectionQuestionLeavesLoadingFalse() async throws {
    let client = GenerationGuardClient()
    client.answerDelayNanoseconds = 60_000_000
    let viewModel = RielaNoteLibraryViewModel(client: client)

    await viewModel.selectNotebook("notebook-1")
    await viewModel.selectNote("note-1")
    let ask = Task {
      await viewModel.askSelectionQuestion(
        question: "Q",
        draftBodyMarkdown: "body",
        selectedText: "body",
        selectionStart: 0,
        selectionEnd: 4
      )
    }
    try await Task.sleep(nanoseconds: 5_000_000)
    XCTAssertTrue(viewModel.isSelectionQuestionLoading)
    await viewModel.selectNote("note-2")
    let saved = await ask.value

    XCTAssertFalse(saved)
    XCTAssertFalse(viewModel.isSelectionQuestionLoading)
  }

  func testStaleEditRewriteLeavesLoadingFalse() async throws {
    let client = GenerationGuardClient()
    client.rewriteDelayNanoseconds = 60_000_000
    let viewModel = RielaNoteLibraryViewModel(client: client)

    await viewModel.selectNotebook("notebook-1")
    await viewModel.selectNote("note-1")
    let rewrite = Task {
      await viewModel.proposeBodyRewrite(
        instruction: "tighten",
        draftBodyMarkdown: "body",
        selectedText: nil,
        selectionStart: nil,
        selectionEnd: nil
      )
    }
    try await Task.sleep(nanoseconds: 5_000_000)
    XCTAssertTrue(viewModel.isEditRewriteLoading)
    await viewModel.selectNote("note-2")
    let draft = await rewrite.value

    XCTAssertNil(draft)
    XCTAssertFalse(viewModel.isEditRewriteLoading)
  }

  // MARK: - Guarded mutation writes

  func testMutationDuringSelectionSwitchDoesNotSnapBackToOldNote() async throws {
    let client = GenerationGuardClient()
    let viewModel = RielaNoteLibraryViewModel(client: client)

    await viewModel.selectNotebook("notebook-1")
    await viewModel.selectNote("note-1")

    // A slow save on note-1 races a switch to note-2; note-1's result must be dropped.
    client.updateNoteBodyDelayNanoseconds = 60_000_000
    let save = Task { try? await viewModel.saveSelectedNoteBody("edited", expectedNoteId: "note-1") }
    try await Task.sleep(nanoseconds: 5_000_000)
    client.updateNoteBodyDelayNanoseconds = 0
    await viewModel.selectNote("note-2")
    await save.value

    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-2")
    XCTAssertEqual(viewModel.state, .loaded)
  }
}

private enum GenerationGuardClientError: Error {
  case unsupported
  case resolveFailed
  case windowFailed
}

private final class GenerationGuardClient: RielaNoteUIClient, @unchecked Sendable {
  private let notebooks: [Notebook]
  private var notesByNotebookId: [String: [Note]]

  var resolveFileDelayNanoseconds: UInt64 = 0
  var resolveFileError: Error?
  var listNotesDelayNanoseconds: UInt64 = 0
  var searchNotesDelayNanoseconds: UInt64 = 0
  var listTagsDelayNanoseconds: UInt64 = 0
  var updateNoteBodyDelayNanoseconds: UInt64 = 0
  var answerDelayNanoseconds: UInt64 = 0
  var rewriteDelayNanoseconds: UInt64 = 0
  var notebookWindowDelayNanosecondsByNoteId: [String: UInt64] = [:]
  var notebookWindowErrorByNoteId: [String: Error] = [:]

  private(set) var listNotesCallCount = 0
  private(set) var searchNotesCallCount = 0

  init() {
    notebooks = (1...2).map { index in
      Notebook(
        notebookId: "notebook-\(index)",
        title: "Notebook \(index)",
        createdAt: "2026-07-04T00:00:00Z",
        updatedAt: "2026-07-04T00:00:00Z"
      )
    }
    // notebook-1: 6 notes (to exercise load-more with page size 2).
    // notebook-2: 2 notes (a single page).
    notesByNotebookId = [
      "notebook-1": (1...6).map { GenerationGuardClient.note(notebookId: "notebook-1", index: $0) },
      "notebook-2": (7...8).map { GenerationGuardClient.note(notebookId: "notebook-2", index: $0) }
    ]
  }

  func resetListNotesCount() {
    listNotesCallCount = 0
  }

  func resetSearchNotesCount() {
    searchNotesCallCount = 0
  }

  var defaultConfigWorkflowRoot: String {
    "tmp/RielaNoteGenerationGuardTests/workflows"
  }

  func listNotebooks(limit: Int, offset: Int) async throws -> [Notebook] {
    Array(notebooks.dropFirst(offset).prefix(limit))
  }

  func listNotes(notebookId: String, limit: Int, offset: Int) async throws -> [Note] {
    if listNotesDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: listNotesDelayNanoseconds)
    }
    listNotesCallCount += 1
    return Array((notesByNotebookId[notebookId] ?? []).dropFirst(offset).prefix(limit))
  }

  func notebookNotesWindow(
    containing noteId: String,
    pageSize: Int
  ) async throws -> RielaNoteNotebookNotesWindow {
    let delay = notebookWindowDelayNanosecondsByNoteId[noteId] ?? 0
    let requestError = notebookWindowErrorByNoteId[noteId]
    if delay > 0 {
      try await Task.sleep(nanoseconds: delay)
    }
    if let requestError {
      throw requestError
    }
    guard let notes = notesByNotebookId.values.first(where: { notes in
      notes.contains(where: { $0.noteId == noteId })
    }),
    let targetOffset = notes.firstIndex(where: { $0.noteId == noteId }) else {
      throw GenerationGuardClientError.unsupported
    }
    let boundedPageSize = max(pageSize, 1)
    let startOffset = max(targetOffset - (boundedPageSize / 2), 0)
    let page = Array(notes.dropFirst(startOffset).prefix(boundedPageSize + 1))
    return RielaNoteNotebookNotesWindow(
      notes: Array(page.prefix(boundedPageSize)),
      startOffset: startOffset,
      hasEarlierNotes: startOffset > 0,
      hasMoreNotes: page.count > boundedPageSize
    )
  }

  func listTags() async throws -> [Tag] {
    if listTagsDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: listTagsDelayNanoseconds)
    }
    return []
  }

  func listTagClasses() async throws -> [TagClass] {
    []
  }

  func createUserMemo(bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw GenerationGuardClientError.unsupported
  }

  func searchNotes(
    query: String,
    tagFilter: [String],
    classFilter: [String],
    limit: Int,
    offset: Int
  ) async throws -> [NoteSearchResult] {
    if searchNotesDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: searchNotesDelayNanoseconds)
    }
    searchNotesCallCount += 1
    // Deterministic, query-scoped result set so callers can tell "alpha" from "beta".
    let results = (1...6).map { index -> NoteSearchResult in
      let note = Note(
        noteId: "\(query)-note-\(index)",
        notebookId: "notebook-1",
        noteNumber: index,
        title: "\(query) \(index)",
        bodyMarkdown: "# \(query) \(index)",
        readOnly: false,
        createdAt: "2026-07-04T00:00:00Z",
        updatedAt: "2026-07-04T00:00:00Z"
      )
      return NoteSearchResult(note: note, snippet: query, rank: 0, matchedTags: [])
    }
    return Array(results.dropFirst(offset).prefix(limit))
  }

  func noteDetail(noteId: String) async throws -> RielaNoteDetail {
    guard let note = notesByNotebookId.values.flatMap({ $0 }).first(where: { $0.noteId == noteId }) else {
      throw GenerationGuardClientError.unsupported
    }
    let attachment = NoteFileAttachment(
      noteId: noteId,
      file: FileRecord(
        fileId: "file-page-\(note.noteNumber)",
        storageKind: .local,
        localPath: "pages/file-page-\(note.noteNumber).png",
        s3Profile: nil,
        s3Bucket: nil,
        s3Key: nil,
        mediaType: "image/png",
        byteSize: 3,
        sha256: "sha-\(note.noteNumber)",
        originalFilename: "file-page-\(note.noteNumber).png",
        createdAt: "2026-07-04T00:00:00Z",
        migratedAt: nil
      ),
      role: .sourcePageImage,
      position: note.noteNumber
    )
    return RielaNoteDetail(note: note, files: [attachment])
  }

  func firstNote(inNotebook notebookId: String) async throws -> RielaNoteDetail? {
    guard let note = notesByNotebookId[notebookId]?.first else {
      return nil
    }
    return try await noteDetail(noteId: note.noteId)
  }

  func resolveFile(fileId: String) async throws -> RielaNoteResolvedFile {
    if resolveFileDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: resolveFileDelayNanoseconds)
    }
    if let resolveFileError {
      throw resolveFileError
    }
    let record = FileRecord(
      fileId: fileId,
      storageKind: .local,
      localPath: "pages/\(fileId).png",
      s3Profile: nil,
      s3Bucket: nil,
      s3Key: nil,
      mediaType: "image/png",
      byteSize: 3,
      sha256: "sha-\(fileId)",
      originalFilename: "\(fileId).png",
      createdAt: "2026-07-04T00:00:00Z",
      migratedAt: nil
    )
    return RielaNoteResolvedFile(file: record, data: Self.onePixelPNGData)
  }

  func updateNoteBody(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    if updateNoteBodyDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: updateNoteBodyDelayNanoseconds)
    }
    guard let note = notesByNotebookId.values.flatMap({ $0 }).first(where: { $0.noteId == noteId }) else {
      throw GenerationGuardClientError.unsupported
    }
    var updated = note
    updated.bodyMarkdown = bodyMarkdown
    return RielaNoteDetail(note: updated)
  }

  func applyTag(noteId: String, tagName: String, classId: String?) async throws -> RielaNoteDetail {
    throw GenerationGuardClientError.unsupported
  }

  func removeTag(noteId: String, tagName: String) async throws -> RielaNoteDetail {
    throw GenerationGuardClientError.unsupported
  }

  func addComment(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw GenerationGuardClientError.unsupported
  }

  func answerNoteSelectionQuestion(
    noteId: String,
    question: String,
    bodyMarkdown: String,
    selectedText: String,
    selectionStart: Int,
    selectionEnd: Int
  ) async throws -> RielaNoteSelectionAnswerDraft {
    if answerDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: answerDelayNanoseconds)
    }
    return RielaNoteSelectionAnswerDraft(answerMarkdown: "answer", summary: nil)
  }

  func proposeNoteBodyRewrite(
    noteId: String,
    instruction: String,
    bodyMarkdown: String,
    selectedText: String?,
    selectionStart: Int?,
    selectionEnd: Int?
  ) async throws -> RielaNoteEditRewriteDraft {
    if rewriteDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: rewriteDelayNanoseconds)
    }
    return RielaNoteEditRewriteDraft(rewrittenMarkdown: "rewritten", summary: "sum")
  }

  func linkNote(noteId: String, targetNoteId: String, linkKind: String) async throws -> RielaNoteDetail {
    throw GenerationGuardClientError.unsupported
  }

  func answerNoteAgentTurn(message: String, limit: Int) async throws -> RielaNoteAgentTurn {
    throw GenerationGuardClientError.unsupported
  }

  func saveNoteAgentConversation(
    title: String,
    turns: [RielaNoteAgentTurn]
  ) async throws -> RielaNoteAgentConversationSaveResult {
    throw GenerationGuardClientError.unsupported
  }

  func appendNoteAgentTurn(
    notebookId: String,
    turn: RielaNoteAgentTurn
  ) async throws -> RielaNoteAgentConversationSaveResult {
    throw GenerationGuardClientError.unsupported
  }

  func proposeNoteConfigAgentChange(message: String) async throws -> RielaNoteConfigAgentProposal {
    throw GenerationGuardClientError.unsupported
  }

  func applyNoteConfigAgentProposal(
    _ proposal: RielaNoteConfigAgentProposal,
    workflowRoot: String
  ) async throws -> RielaNoteConfigAgentApplyResult {
    throw GenerationGuardClientError.unsupported
  }

  private static func note(notebookId: String, index: Int) -> Note {
    Note(
      noteId: "note-\(index)",
      notebookId: notebookId,
      noteNumber: index,
      title: "Note \(index)",
      bodyMarkdown: "# Note \(index)\n\nbody",
      readOnly: false,
      createdAt: "2026-07-04T00:00:00Z",
      updatedAt: "2026-07-04T00:00:00Z"
    )
  }

  private static var onePixelPNGData: Data {
    guard let data = Data(base64Encoded: onePixelPNGBase64) else {
      fatalError("Invalid one-pixel PNG fixture")
    }
    return data
  }

  private static let onePixelPNGBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
}
