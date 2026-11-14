import Foundation
import RielaNote
import SwiftUI

@MainActor
public final class RielaNoteLibraryViewModel: ObservableObject {
  public enum LoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
  }

  public enum NoteContentMode: String, Equatable, Sendable, CaseIterable {
    case text
    case sourceImage
  }

  /// A note/notebook selection deferred behind the discard confirmation because a
  /// body edit is in progress. Every navigation path routes through
  /// `requestSelection`, so switching away while editing always confirms first.
  public enum PendingSelection: Equatable, Sendable {
    case note(String)
    case notebook(String)
    case previousNote
    case nextNote

    var isPagerSelection: Bool {
      switch self {
      case .previousNote, .nextNote:
        true
      case .note, .notebook:
        false
      }
    }

    func isNoOp(currentNoteId: String?) -> Bool {
      switch self {
      case let .note(noteId):
        currentNoteId == noteId
      case .notebook:
        false
      case .previousNote, .nextNote:
        false
      }
    }
  }

  @Published public internal(set) var notebooks: [Notebook] = []
  @Published public internal(set) var notebookNotes: [Note] = []
  @Published public private(set) var availableSearchTags: [Tag] = []
  @Published public private(set) var availableSearchTagClasses: [TagClass] = []
  @Published public private(set) var searchResults: [NoteSearchResult] = []
  @Published public internal(set) var selectedDetail: RielaNoteDetail?
  @Published public internal(set) var resolvedSourceImage: RielaNoteResolvedFile?
  @Published public internal(set) var decodedSourceImage: RielaNoteDecodedSourceImage?
  @Published public internal(set) var selectedResolvedFile: RielaNoteResolvedFile?
  @Published public internal(set) var selectedNotebookId: String?
  @Published public internal(set) var selectedSearchTagNames: Set<String> = []
  @Published public internal(set) var selectedSearchClassIds: Set<String> = []
  @Published public internal(set) var hasMoreNotebooks = false
  @Published public internal(set) var hasEarlierNotebookNotes = false
  @Published public internal(set) var hasMoreNotebookNotes = false
  @Published public private(set) var hasMoreSearchResults = false
  @Published public private(set) var fileTreeInvalidationRevision = 0
  @Published public internal(set) var linkProposals: [NoteLinkProposal] = []
  @Published public internal(set) var linkProposalError: String?
  @Published public internal(set) var isLinkProposalLoading = false
  @Published public internal(set) var editRewriteError: String?
  @Published public internal(set) var editRewriteSummary: String?
  @Published public internal(set) var isEditRewriteLoading = false
  @Published public internal(set) var selectionQuestionError: String?
  @Published public internal(set) var isSelectionQuestionLoading = false
  @Published public internal(set) var didSaveSelectionQuestionComment = false
  @Published public internal(set) var commentPromotionError: String?
  @Published public internal(set) var notebookExpansionError: String?
  @Published public internal(set) var notebookExpansionSession: RielaNoteNotebookExpansionSession?
  @Published public internal(set) var expandingNotebookIds: Set<String> = []
  @Published public internal(set) var isCommentPromotionLoading = false
  @Published public internal(set) var isSourceImageLoading = false
  @Published public var filter = RielaNoteListFilter()
  @Published public var searchText = ""
  @Published public var sourceImageZoom = 1.0
  @Published public var contentMode: NoteContentMode = .text
  @Published public var isDetailExpanded = false
  @Published public internal(set) var state: LoadState = .idle

  /// A selection change that another view (list, links, agent citation, pager)
  /// requested while a body edit is in progress. Non-nil presents the
  /// keep-editing / discard confirmation; the deferred change runs only if the
  /// user chooses Discard. See `requestSelection`.
  @Published public internal(set) var pendingSelection: PendingSelection?

  /// Mirror of the detail view's body-edit flag, lifted here so list/root views
  /// can guard navigation without reaching into the detail view's local state.
  @Published public internal(set) var isEditingBody = false

  public static let sourceImageMinimumZoom = 0.5
  public static let sourceImageMaximumZoom = 3.0
  public static let sourceImageZoomStep = 0.25

  public nonisolated let client: any RielaNoteUIClient
  private let notebookLimit: Int
  let notebookNoteLimit: Int
  private let searchLimit: Int
  let sourceImageCacheLimit: Int
  var notebooksOffset = 0
  var notebookNotesStartOffset = 0
  var notebookNotesOffset = 0
  private var searchResultsOffset = 0
  var resolvedFileCache: [String: RielaNoteResolvedFile] = [:]
  var resolvedFileCacheOrder: [String] = []
  var decodedSourceImageCache: [String: RielaNoteDecodedSourceImage] = [:]
  var decodedSourceImageCacheOrder: [String] = []
  var notebookContentModes: [String: NoteContentMode] = [:]
  var isLoadingMoreNotebookNotes = false
  var isLoadingEarlierNotebookNotes = false
  private var isLoadingMoreSearchResults = false
  var searchGeneration = 0
  var notebookPageGeneration = 0
  var notebookSnapshotContext: RielaNoteNotebookBoardContext?
  var notebookProgressMutationFailure: RielaNoteNotebookMutationFailure?
  var notebookProgressMutationGenerations: [String: Int] = [:]
  var notebookProgressMutationTargets: [String: NotebookProgress] = [:]
  var selectionGeneration = 0
  var linkProposalGeneration = 0
  var editRewriteGeneration = 0
  var selectionQuestionGeneration = 0
  var commentPromotionGeneration = 0
  var notebookExpansionTasks: [String: Task<RielaNoteNotebookExpansionSession, Error>] = [:]

  /// Absolute trailing pagination cursor for the selected notebook's note
  /// window. It equals the note count for a window that begins at offset zero.
  var notebookNotesOffsetForTesting: Int {
    notebookNotesOffset
  }

  var notebookNotesStartOffsetForTesting: Int {
    notebookNotesStartOffset
  }

  var searchResultsOffsetForTesting: Int {
    searchResultsOffset
  }

  var notebookPageSize: Int {
    max(notebookLimit, 1)
  }

  var notebookNotePageSize: Int {
    max(notebookNoteLimit, 1)
  }

  private var searchPageSize: Int {
    max(searchLimit, 1)
  }

  public init(
    client: any RielaNoteUIClient,
    notebookLimit: Int = 50,
    notebookNoteLimit: Int = 50,
    searchLimit: Int = 30,
    sourceImageCacheLimit: Int = 64
  ) {
    self.client = client
    self.notebookLimit = notebookLimit
    self.notebookNoteLimit = notebookNoteLimit
    self.searchLimit = searchLimit
    self.sourceImageCacheLimit = max(sourceImageCacheLimit, 1)
  }

  public var selectedNote: Note? {
    selectedDetail?.note
  }

  public var selectedNoteIndex: Int? {
    pagerNoteSnapshot.currentIndex
  }

  public var selectedNotePositionText: String? {
    pagerNoteSnapshot.selectedPositionText
  }

  public var canSelectPreviousNote: Bool {
    pagerNoteSnapshot.canSelectPrevious
  }

  public var canSelectNextNote: Bool {
    pagerNoteSnapshot.canSelectNext
  }

  public var pagerNoteSnapshot: RielaNotePagerNoteSnapshot {
    RielaNotePagerNoteSnapshot(
      notes: notebookNotes,
      selectedNoteId: selectedNote?.noteId,
      leadingOffset: notebookNotesStartOffset,
      hasEarlierNotes: hasEarlierNotebookNotes,
      hasMoreNotes: hasMoreNotebookNotes
    )
  }

  public var canLoadMoreNotebookNotes: Bool {
    selectedNotebookId != nil && hasMoreNotebookNotes && !isSearching && !isLoadingMoreNotebookNotes
  }

  public var canLoadEarlierNotebookNotes: Bool {
    selectedNotebookId != nil
      && hasEarlierNotebookNotes
      && !isSearching
      && !isLoadingEarlierNotebookNotes
  }

  public var canLoadMoreNotebooks: Bool {
    hasMoreNotebooks && (!isSearching || isTagKanbanActive)
  }

  public var canLoadMoreSearchResults: Bool {
    isSearching && hasMoreSearchResults && !isLoadingMoreSearchResults
  }

  public var canCreateNoteInSelectedNotebook: Bool {
    selectedNotebookId != nil
  }

  public var sourcePageImageAttachment: NoteFileAttachment? {
    selectedDetail?.files.first { $0.role == .sourcePageImage }
  }

  public var selectedResolvedFileStatusText: String? {
    guard let resolvedFile = selectedResolvedFile else {
      return nil
    }
    return "\(fileDisplayName(resolvedFile.file)) · \(byteCountText(resolvedFile.file.byteSize))"
  }

  public func load() async {
    let searchGeneration = searchGeneration
    notebookProgressMutationFailure = nil
    state = .loading
    do {
      guard try await loadNotebooksFirstPage() else {
        return
      }
      availableSearchTags = try await client.listTags()
      availableSearchTagClasses = try await client.listTagClasses()
      guard isCurrentSearchGeneration(searchGeneration) else {
        return
      }
      searchResults = []
      searchResultsOffset = 0
      hasMoreSearchResults = false
      state = .loaded
      if selectedDetail == nil, let first = notebooks.first {
        await selectNotebook(first.notebookId)
      }
    } catch {
      guard isCurrentSearchGeneration(searchGeneration) else {
        return
      }
      state = .failed(rielaNoteLoadFailureMessage(error))
    }
  }

  public func refresh() async {
    fileTreeInvalidationRevision += 1
    let selectedNoteId = selectedNote?.noteId
    let currentNotebookId = selectedNotebookId
    let preferredMode = contentMode
    let selectionGeneration = selectionGeneration
    let searchGeneration = searchGeneration
    notebookProgressMutationFailure = nil
    state = .loading
    do {
      guard try await loadNotebooksFirstPage() else {
        return
      }
      if let currentNotebookId {
        guard try await loadNotebooksUntilContains(currentNotebookId) else {
          return
        }
      }
      availableSearchTags = try await client.listTags()
      availableSearchTagClasses = try await client.listTagClasses()
      if isSearching {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let tagFilter = selectedSearchTagNames.sorted()
        let classFilter = selectedSearchClassIds.sorted()
        let page = try await fetchSearchResults(query: query, tagFilter: tagFilter, classFilter: classFilter)
        guard isCurrentSearch(
          generation: searchGeneration,
          query: query,
          tagFilter: tagFilter,
          classFilter: classFilter
        ) else {
          state = .loaded
          return
        }
        applySearchResultsPage(page)
      } else if let currentNotebookId {
        try await loadNotebookNotesFirstPage(notebookId: currentNotebookId, generation: selectionGeneration)
        if let selectedNoteId,
           !notebookNotes.contains(where: { $0.noteId == selectedNoteId }) {
          do {
            try await loadNotebookNotesWindow(
              containing: selectedNoteId,
              notebookId: currentNotebookId,
              generation: selectionGeneration
            )
          } catch let error as NoteServiceError where isMissingSelection(error, noteId: selectedNoteId) {
            // Let the detail refresh below degrade the deleted selection to the
            // first still-available note in the bounded first page.
          }
        }
      } else if let first = notebooks.first {
        self.selectedNotebookId = first.notebookId
        try await loadNotebookNotesFirstPage(notebookId: first.notebookId, generation: selectionGeneration)
      }
      guard self.selectionGeneration == selectionGeneration else {
        state = .loaded
        return
      }
      let refreshedDetail: RielaNoteDetail?
      if let selectedNoteId {
        // A note deleted elsewhere degrades to a selection change, not an error
        // screen: fall back to the first available note in the list.
        refreshedDetail = try await refreshedDetailFallingBackOnMissing(selectedNoteId)
      } else if let first = notebookNotes.first {
        refreshedDetail = try await client.noteDetail(noteId: first.noteId)
      } else {
        refreshedDetail = nil
      }
      guard self.selectionGeneration == selectionGeneration else {
        state = .loaded
        return
      }
      selectedDetail = refreshedDetail
      await prepareSelectedNoteFiles(preferredMode: preferredMode)
      state = .loaded
    } catch let error as NoteServiceError where isSelectedNotebookMissing(error, notebookId: currentNotebookId) {
      // The selected notebook was deleted elsewhere: drop it and reload the
      // cross-notebook feed rather than failing every refresh into the overlay.
      await degradeToFirstAvailableNote()
    } catch {
      state = .failed(rielaNoteLoadFailureMessage(error))
    }
  }

  /// Fetches the selected note's detail, falling back to the first available note
  /// when the selected note has been deleted elsewhere (`notFound`).
  private func refreshedDetailFallingBackOnMissing(_ selectedNoteId: String) async throws -> RielaNoteDetail? {
    do {
      return try await client.noteDetail(noteId: selectedNoteId)
    } catch let error as NoteServiceError {
      guard case let .notFound(missing) = error, missing.contains(selectedNoteId) || missing == selectedNoteId else {
        throw error
      }
      notebookNotes.removeAll { $0.noteId == selectedNoteId }
      if let first = notebookNotes.first {
        return try await client.noteDetail(noteId: first.noteId)
      }
      return nil
    }
  }

  private func isSelectedNotebookMissing(_ error: NoteServiceError, notebookId: String?) -> Bool {
    guard let notebookId, case let .notFound(missing) = error else {
      return false
    }
    return missing.contains(notebookId) || missing == notebookId
  }

  /// Clears the stale selection and lands on the first available note, leaving
  /// `state == .loaded`.
  private func degradeToFirstAvailableNote() async {
    let generation = advanceSelectionGeneration()
    selectedDetail = nil
    do {
      guard try await loadNotebooksFirstPage() else {
        return
      }
      if let first = notebooks.first {
        selectedNotebookId = first.notebookId
        try await loadNotebookNotesFirstPage(notebookId: first.notebookId, generation: generation)
        guard isCurrentSelection(generation) else {
          return
        }
        if let firstNote = notebookNotes.first {
          selectedDetail = try await client.noteDetail(noteId: firstNote.noteId)
        } else {
          selectedNotebookId = nil
        }
      } else {
        selectedNotebookId = nil
      }
      guard isCurrentSelection(generation) else {
        return
      }
      await prepareSelectedNoteFiles(preferredMode: .text)
      state = .loaded
    } catch {
      guard isCurrentSelection(generation) else {
        return
      }
      state = .failed(rielaNoteLoadFailureMessage(error))
    }
  }

  func performSearch(selectFirstResult: Bool) async {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty || hasSearchFilters else {
      advanceSearchGeneration()
      await load()
      return
    }
    let generation = advanceSearchGeneration()
    let tagFilter = selectedSearchTagNames.sorted()
    let classFilter = selectedSearchClassIds.sorted()
    notebookProgressMutationFailure = nil
    state = .loading
    do {
      let page = try await fetchSearchResults(query: query, tagFilter: tagFilter, classFilter: classFilter)
      let notebookPage = tagFilter.isEmpty
        ? nil
        : try await fetchNotebooksFirstPageForSearch(tagFilter: tagFilter)
      guard isCurrentSearch(generation: generation, query: query, tagFilter: tagFilter, classFilter: classFilter) else {
        return
      }
      applySearchResultsPage(page)
      if let notebookPage {
        applyNotebooksFirstPage(
          notebookPage,
          context: RielaNoteNotebookBoardContext(
            tagFilter: tagFilter,
            filter: filter
          )
        )
      }
      state = .loaded
      if selectFirstResult, let first = searchResults.first {
        await selectNote(first.note.noteId)
      }
    } catch {
      guard isCurrentSearch(generation: generation, query: query, tagFilter: tagFilter, classFilter: classFilter) else {
        return
      }
      state = .failed(rielaNoteLoadFailureMessage(error))
    }
  }

  public func selectNotebook(_ notebookId: String) async {
    let generation = advanceSelectionGeneration()
    state = .loading
    do {
      selectedNotebookId = notebookId
      try await loadNotebookNotesFirstPage(notebookId: notebookId, generation: generation)
      guard isCurrentSelection(generation) else {
        return
      }
      let detail: RielaNoteDetail?
      if let first = notebookNotes.first {
        detail = try await client.noteDetail(noteId: first.noteId)
      } else {
        detail = try await client.firstNote(inNotebook: notebookId)
      }
      guard isCurrentSelection(generation) else {
        return
      }
      selectedDetail = detail
      await prepareSelectedNoteFiles(preferredMode: notebookContentModes[notebookId] ?? .text)
      state = .loaded
    } catch {
      guard isCurrentSelection(generation) else {
        return
      }
      state = .failed(rielaNoteLoadFailureMessage(error))
    }
  }

  public func selectNote(_ noteId: String) async {
    let generation = advanceSelectionGeneration()
    state = .loading
    do {
      let previousNotebookId = selectedNotebookId
      let detail = try await client.noteDetail(noteId: noteId)
      guard isCurrentSelection(generation) else {
        return
      }
      let detailNotebookId = detail.note.notebookId
      if selectedNotebookId != detailNotebookId || !notebookNotes.contains(where: { $0.noteId == noteId }) {
        try await loadNotebookNotesWindow(
          containing: noteId,
          notebookId: detailNotebookId,
          generation: generation
        )
      }
      guard isCurrentSelection(generation) else {
        return
      }
      selectedDetail = detail
      let notebookId = selectedDetail?.note.notebookId
      let preferredMode = notebookId.flatMap { notebookContentModes[$0] }
        ?? (previousNotebookId == notebookId ? contentMode : .text)
      await prepareSelectedNoteFiles(preferredMode: preferredMode)
      state = .loaded
    } catch let error as NoteServiceError where isMissingSelection(error, noteId: noteId) {
      // The target note was deleted elsewhere: degrade to the first available
      // note instead of showing an error screen.
      guard isCurrentSelection(generation) else {
        return
      }
      await degradeToFirstAvailableNote()
    } catch {
      guard isCurrentSelection(generation) else {
        return
      }
      state = .failed(rielaNoteLoadFailureMessage(error))
    }
  }

  private func isMissingSelection(_ error: NoteServiceError, noteId: String) -> Bool {
    guard case let .notFound(missing) = error else {
      return false
    }
    return missing.contains(noteId) || missing == noteId
  }

  /// Single entry point for every note/notebook selection change driven by the UI
  /// (list rows, notebook rows, links section, agent citations, pager). While a
  /// body edit is in progress the change is stashed and the discard confirmation
  /// is raised; otherwise it runs immediately. Returns after any immediate
  /// navigation completes.
  public func requestSelection(_ selection: PendingSelection) async {
    if selection.isNoOp(currentNoteId: selectedNote?.noteId) {
      return
    }
    if isEditingBody, selection.isPagerSelection {
      return
    }
    guard isEditingBody else {
      await performSelection(selection)
      return
    }
    pendingSelection = selection
  }

  /// Confirms a stashed selection (the Discard branch), navigating to
  /// `selection`. The editing flag is cleared here; the detail view's
  /// `.onChange(of:noteId)` still performs the draft reset once the new selection
  /// loads. The caller captures `pendingSelection` synchronously before the
  /// dialog dismisses, so a concurrent binding-driven `cancelPendingSelection`
  /// cannot drop the request.
  public func confirmPendingSelection(_ selection: PendingSelection) async {
    pendingSelection = nil
    isEditingBody = false
    await performSelection(selection)
  }

  /// Dismisses the confirmation without navigating (the Keep editing branch).
  public func cancelPendingSelection() {
    pendingSelection = nil
  }

  private func performSelection(_ selection: PendingSelection) async {
    switch selection {
    case let .note(noteId):
      await selectNote(noteId)
    case let .notebook(notebookId):
      await selectNotebook(notebookId)
    case .previousNote:
      await selectPreviousNote()
    case .nextNote:
      await selectNextNote()
    }
  }

  /// Pushes the detail view's body-edit flag into shared state so other views can
  /// guard navigation against it. Clearing the flag also drops any stale pending
  /// confirmation (e.g. the editor was reset by a note switch).
  public func setEditingBody(_ isEditing: Bool) {
    isEditingBody = isEditing
    if !isEditing {
      pendingSelection = nil
    }
  }

  public func createUserMemo(body: String = "") async throws {
    // The create call itself must not mutate load state so a failure leaves the
    // list untouched; only the post-create list reload drives `state`.
    let detail = try await client.createUserMemo(bodyMarkdown: body)
    state = .loading
    // A create makes the new note the current selection; claim the newest
    // generation so a concurrent selection cannot overwrite it.
    let generation = advanceSelectionGeneration()
    searchText = ""
    searchResults = []
    searchResultsOffset = 0
    hasMoreSearchResults = false
    selectedSearchTagNames = []
    selectedSearchClassIds = []
    filter = RielaNoteListFilter(sort: filter.sort)
    selectedDetail = detail
    selectedNotebookId = detail.note.notebookId
    guard try await loadNotebooksFirstPage(),
          try await loadNotebooksUntilContains(detail.note.notebookId) else {
      return
    }
    availableSearchTags = try await client.listTags()
    availableSearchTagClasses = try await client.listTagClasses()
    try await loadNotebookNotesFirstPage(notebookId: detail.note.notebookId, generation: generation)
    guard isCurrentSelection(generation) else {
      return
    }
    if !notebookNotes.contains(where: { $0.noteId == detail.note.noteId }) {
      notebookNotes.append(detail.note)
    }
    clearResolvedFileSelection()
    contentMode = .text
    state = .loaded
  }

  public func createNoteInSelectedNotebook(body: String = "") async throws {
    guard let notebookId = selectedNotebookId else {
      throw NoteServiceError.invalidInput("No notebook is selected.")
    }
    let detail = try await client.createNote(inNotebook: notebookId, bodyMarkdown: body)
    state = .loading
    // A create makes the new note the current selection; claim the newest
    // generation so a concurrent selection cannot overwrite it.
    let generation = advanceSelectionGeneration()
    searchText = ""
    searchResults = []
    searchResultsOffset = 0
    hasMoreSearchResults = false
    selectedSearchTagNames = []
    selectedSearchClassIds = []
    filter = RielaNoteListFilter(sort: filter.sort)
    selectedDetail = detail
    selectedNotebookId = detail.note.notebookId
    guard try await loadNotebooksFirstPage(),
          try await loadNotebooksUntilContains(detail.note.notebookId) else {
      return
    }
    availableSearchTags = try await client.listTags()
    availableSearchTagClasses = try await client.listTagClasses()
    try await loadNotebookNotesFirstPage(notebookId: detail.note.notebookId, generation: generation)
    if !notebookNotes.contains(where: { $0.noteId == detail.note.noteId }) {
      try await loadNotebookNotesWindow(
        containing: detail.note.noteId,
        notebookId: detail.note.notebookId,
        generation: generation
      )
    }
    guard isCurrentSelection(generation) else {
      return
    }
    if !notebookNotes.contains(where: { $0.noteId == detail.note.noteId }) {
      notebookNotes.append(detail.note)
    }
    clearResolvedFileSelection()
    contentMode = .text
    state = .loaded
  }

  public func saveSelectedNoteBody(_ bodyMarkdown: String, expectedNoteId: String? = nil) async throws {
    guard let noteId = selectedDetail?.note.noteId else {
      throw NoteServiceError.notFound("No note is selected.")
    }
    guard expectedNoteId == nil || expectedNoteId == noteId else {
      throw NoteServiceError.invalidInput("The note changed before the save completed.")
    }
    let generation = selectionGeneration
    let detail = try await client.updateNoteBody(noteId: noteId, bodyMarkdown: bodyMarkdown)
    guard isCurrentSelection(generation) else {
      return
    }
    selectedDetail = detail
    if let index = notebookNotes.firstIndex(where: { $0.noteId == noteId }) {
      notebookNotes[index] = detail.note
    }
    clearResolvedFileSelection()
    contentMode = .text
  }

  public func applyTagToSelectedNote(name: String, classId: String? = "topic") async throws {
    guard let noteId = selectedDetail?.note.noteId else {
      throw NoteServiceError.notFound("No note is selected.")
    }
    let tagName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !tagName.isEmpty else {
      throw NoteServiceError.invalidInput("A tag name is required.")
    }
    let generation = selectionGeneration
    let normalizedClassId = classId?.trimmingCharacters(in: .whitespacesAndNewlines)
    let detail = try await client.applyTag(
      noteId: noteId,
      tagName: tagName,
      classId: normalizedClassId?.isEmpty == true ? nil : normalizedClassId
    )
    let tags = try await client.listTags()
    guard isCurrentSelection(generation) else {
      return
    }
    replaceSelectedDetail(detail)
    availableSearchTags = tags
  }

  public func removeTagFromSelectedNote(name: String) async throws {
    guard let noteId = selectedDetail?.note.noteId else {
      throw NoteServiceError.notFound("No note is selected.")
    }
    let generation = selectionGeneration
    let detail = try await client.removeTag(noteId: noteId, tagName: name)
    guard isCurrentSelection(generation) else {
      return
    }
    replaceSelectedDetail(detail)
  }

  public func addCommentToSelectedNote(_ bodyMarkdown: String) async throws {
    guard let noteId = selectedDetail?.note.noteId else {
      throw NoteServiceError.notFound("No note is selected.")
    }
    try await addComment(bodyMarkdown, toNoteId: noteId)
  }

  public func addComment(_ bodyMarkdown: String, toNoteId noteId: String) async throws {
    let commentBody = bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !commentBody.isEmpty else {
      throw NoteServiceError.invalidInput("A comment cannot be empty.")
    }
    let generation = selectionGeneration
    let detail = try await client.addComment(noteId: noteId, bodyMarkdown: commentBody)
    guard isCurrentSelection(generation), selectedDetail?.note.noteId == noteId else {
      return
    }
    selectedDetail = detail
  }

  public func selectPreviousNote() async {
    await selectAdjacentNote(delta: -1)
  }

  public func selectNextNote() async {
    await selectAdjacentNote(delta: 1)
  }

  public func loadMoreNotebooks() async {
    guard canLoadMoreNotebooks else {
      return
    }
    state = .loading
    do {
      guard try await appendNotebooksPage() else {
        return
      }
      state = .loaded
    } catch {
      state = .failed(rielaNoteLoadFailureMessage(error))
    }
  }

  public func loadMoreSearchResults() async {
    guard canLoadMoreSearchResults else {
      return
    }
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let tagFilter = selectedSearchTagNames.sorted()
    let classFilter = selectedSearchClassIds.sorted()
    let generation = searchGeneration
    isLoadingMoreSearchResults = true
    state = .loading
    do {
      let page = try await client.searchNotes(
        query: query,
        tagFilter: tagFilter,
        classFilter: classFilter,
        filter: filter,
        limit: searchPageSize + 1,
        offset: searchResultsOffset
      )
      guard isCurrentSearch(generation: generation, query: query, tagFilter: tagFilter, classFilter: classFilter) else {
        isLoadingMoreSearchResults = false
        return
      }
      let visiblePage = Array(page.prefix(searchPageSize))
      let existingNoteIds = Set(searchResults.map(\.note.noteId))
      let appended = visiblePage.filter { !existingNoteIds.contains($0.note.noteId) }
      searchResults.append(contentsOf: appended)
      searchResultsOffset += appended.count
      hasMoreSearchResults = page.count > searchPageSize
      isLoadingMoreSearchResults = false
      state = .loaded
    } catch {
      guard isCurrentSearch(generation: generation, query: query, tagFilter: tagFilter, classFilter: classFilter) else {
        isLoadingMoreSearchResults = false
        return
      }
      isLoadingMoreSearchResults = false
      state = .failed(rielaNoteLoadFailureMessage(error))
    }
  }

  private func fetchSearchResults(
    query: String,
    tagFilter: [String],
    classFilter: [String]
  ) async throws -> [NoteSearchResult] {
    try await client.searchNotes(
      query: query,
      tagFilter: tagFilter,
      classFilter: classFilter,
      filter: filter,
      limit: searchPageSize + 1,
      offset: 0
    )
  }

  private func applySearchResultsPage(_ page: [NoteSearchResult]) {
    searchResults = page
    hasMoreSearchResults = searchResults.count > searchPageSize
    searchResults = Array(searchResults.prefix(searchPageSize))
    searchResultsOffset = searchResults.count
  }

  @discardableResult
  private func advanceSearchGeneration() -> Int {
    searchGeneration += 1
    return searchGeneration
  }

  private func isCurrentSearchGeneration(_ generation: Int) -> Bool {
    searchGeneration == generation
  }

  private func isCurrentSearch(
    generation: Int,
    query: String,
    tagFilter: [String],
    classFilter: [String]
  ) -> Bool {
    searchGeneration == generation
      && searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query
      && selectedSearchTagNames.sorted() == tagFilter
      && selectedSearchClassIds.sorted() == classFilter
  }

  func reloadForFilterChange() async {
    if isSearching {
      await performSearch(selectFirstResult: false)
    } else {
      await refresh()
    }
  }

  @discardableResult
  private func advanceSelectionGeneration() -> Int {
    selectionGeneration += 1
    linkProposalGeneration += 1
    editRewriteGeneration += 1
    selectionQuestionGeneration += 1
    commentPromotionGeneration += 1
    linkProposals = []
    linkProposalError = nil
    isLinkProposalLoading = false
    editRewriteError = nil
    editRewriteSummary = nil
    isEditRewriteLoading = false
    selectionQuestionError = nil
    isSelectionQuestionLoading = false
    didSaveSelectionQuestionComment = false
    commentPromotionError = nil
    isCommentPromotionLoading = false
    return selectionGeneration
  }

  func isCurrentSelection(_ generation: Int) -> Bool {
    selectionGeneration == generation
  }

  /// Current selection generation, captured by extension-file mutations so their
  /// post-`await` selection writes can be dropped when the selection moves on.
  var selectionGenerationSnapshot: Int {
    selectionGeneration
  }

  private func replaceSelectedDetail(_ detail: RielaNoteDetail) {
    selectedDetail = detail
    if let index = notebookNotes.firstIndex(where: { $0.noteId == detail.note.noteId }) {
      notebookNotes[index] = detail.note
    }
  }

}

extension RielaNoteLibraryViewModel {
  public func linkSelectedNote(to targetNoteId: String, kind: String = "related") async throws {
    guard let noteId = selectedDetail?.note.noteId else {
      throw NoteServiceError.notFound("No note is selected.")
    }
    let normalizedTarget = targetNoteId.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedTarget.isEmpty else {
      throw NoteServiceError.invalidInput("A target note is required.")
    }
    let generation = selectionGeneration
    let detail = try await client.linkNote(
      noteId: noteId,
      targetNoteId: normalizedTarget,
      linkKind: rielaNoteAllowedLinkKind(normalizedKind)
    )
    guard isCurrentSelection(generation) else {
      return
    }
    selectedDetail = detail
  }

}
