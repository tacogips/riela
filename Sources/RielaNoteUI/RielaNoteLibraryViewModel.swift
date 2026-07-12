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

  @Published public private(set) var notebooks: [Notebook] = []
  @Published public internal(set) var notebookNotes: [Note] = []
  @Published public private(set) var availableSearchTags: [Tag] = []
  @Published public private(set) var availableSearchTagClasses: [TagClass] = []
  @Published public private(set) var searchResults: [NoteSearchResult] = []
  @Published public internal(set) var selectedDetail: RielaNoteDetail?
  @Published public private(set) var resolvedSourceImage: RielaNoteResolvedFile?
  @Published public private(set) var decodedSourceImage: RielaNoteDecodedSourceImage?
  @Published public private(set) var selectedResolvedFile: RielaNoteResolvedFile?
  @Published public private(set) var selectedNotebookId: String?
  @Published public private(set) var selectedSearchTagNames: Set<String> = []
  @Published public private(set) var selectedSearchClassIds: Set<String> = []
  @Published public private(set) var hasMoreNotebooks = false
  @Published public private(set) var hasMoreNotebookNotes = false
  @Published public private(set) var hasMoreSearchResults = false
  @Published public internal(set) var linkProposals: [NoteLinkProposal] = []
  @Published public internal(set) var linkProposalError: String?
  @Published public internal(set) var isLinkProposalLoading = false
  @Published public internal(set) var editRewriteError: String?
  @Published public internal(set) var editRewriteSummary: String?
  @Published public internal(set) var isEditRewriteLoading = false
  @Published public internal(set) var selectionQuestionError: String?
  @Published public internal(set) var isSelectionQuestionLoading = false
  @Published public internal(set) var didSaveSelectionQuestionComment = false
  @Published public internal(set) var translateNoteError: String?
  @Published public internal(set) var isTranslateNoteLoading = false
  @Published public internal(set) var translateNoteSummary: String?
  @Published public internal(set) var commentPromotionError: String?
  @Published public internal(set) var isCommentPromotionLoading = false
  @Published public private(set) var isSourceImageLoading = false
  @Published public var filter = RielaNoteListFilter()
  @Published public var searchText = ""
  @Published public var sourceImageZoom = 1.0
  @Published public var contentMode: NoteContentMode = .text
  @Published public var isDetailExpanded = false
  @Published public var translationTargetLanguage: String
  @Published public internal(set) var state: LoadState = .idle

  public static let sourceImageMinimumZoom = 0.5
  public static let sourceImageMaximumZoom = 3.0
  public static let sourceImageZoomStep = 0.25

  public nonisolated let client: any RielaNoteUIClient
  private let notebookLimit: Int
  private let notebookNoteLimit: Int
  private let searchLimit: Int
  private let sourceImageCacheLimit: Int
  private var notebooksOffset = 0
  private var notebookNotesOffset = 0
  private var searchResultsOffset = 0
  private var resolvedFileCache: [String: RielaNoteResolvedFile] = [:]
  private var resolvedFileCacheOrder: [String] = []
  private var decodedSourceImageCache: [String: RielaNoteDecodedSourceImage] = [:]
  private var decodedSourceImageCacheOrder: [String] = []
  private var notebookContentModes: [String: NoteContentMode] = [:]
  private var isLoadingMoreNotebookNotes = false
  private var isLoadingMoreSearchResults = false
  private var searchGeneration = 0
  private var selectionGeneration = 0
  var linkProposalGeneration = 0
  var editRewriteGeneration = 0
  var selectionQuestionGeneration = 0
  var translateNoteGeneration = 0
  var commentPromotionGeneration = 0

  /// Pagination cursor for the selected notebook's note list, exposed for tests that
  /// assert the offset invariant (offset stays equal to the appended note count).
  var notebookNotesOffsetForTesting: Int {
    notebookNotesOffset
  }

  var searchResultsOffsetForTesting: Int {
    searchResultsOffset
  }

  private var notebookPageSize: Int {
    max(notebookLimit, 1)
  }

  private var notebookNotePageSize: Int {
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
    sourceImageCacheLimit: Int = 64,
    translationTargetLanguage: String? = nil
  ) {
    self.client = client
    self.notebookLimit = notebookLimit
    self.notebookNoteLimit = notebookNoteLimit
    self.searchLimit = searchLimit
    self.sourceImageCacheLimit = max(sourceImageCacheLimit, 1)
    self.translationTargetLanguage = rielaNoteNormalizedTranslationTargetLanguage(
      translationTargetLanguage ?? client.defaultTranslationTargetLanguage
    )
  }

  public var isSearching: Bool {
    hasSearchQuery || hasSearchFilters
  }

  public var hasSearchQuery: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  public var hasSearchFilters: Bool {
    !selectedSearchTagNames.isEmpty
      || !selectedSearchClassIds.isEmpty
      || filter.createdRange != .any
  }

  public var selectedNote: Note? {
    selectedDetail?.note
  }

  public var selectedNoteIndex: Int? {
    guard let selectedNote else {
      return nil
    }
    return notebookNotes.firstIndex { $0.noteId == selectedNote.noteId }
  }

  public var selectedNotePositionText: String? {
    guard let selectedNoteIndex, !notebookNotes.isEmpty else {
      return nil
    }
    let loadedCount = hasMoreNotebookNotes ? "\(notebookNotes.count)+" : "\(notebookNotes.count)"
    return "#\(selectedNoteIndex + 1) of \(loadedCount)"
  }

  public var canSelectPreviousNote: Bool {
    guard let selectedNoteIndex else {
      return false
    }
    return selectedNoteIndex > 0
  }

  public var canSelectNextNote: Bool {
    guard let selectedNoteIndex else {
      return false
    }
    return selectedNoteIndex + 1 < notebookNotes.count || hasMoreNotebookNotes
  }

  public var canLoadMoreNotebookNotes: Bool {
    selectedNotebookId != nil && hasMoreNotebookNotes && !isSearching && !isLoadingMoreNotebookNotes
  }

  public var canLoadMoreNotebooks: Bool {
    hasMoreNotebooks && !isSearching
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
    state = .loading
    do {
      try await loadNotebooksFirstPage()
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
    let selectedNoteId = selectedNote?.noteId
    let currentNotebookId = selectedNotebookId
    let preferredMode = contentMode
    let selectionGeneration = selectionGeneration
    let searchGeneration = searchGeneration
    state = .loading
    do {
      try await loadNotebooksFirstPage()
      if let currentNotebookId {
        try await loadNotebooksUntilContains(currentNotebookId)
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
        if let selectedNoteId {
          try await loadNotebookNotesUntilContains(selectedNoteId, generation: selectionGeneration)
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
      try await loadNotebooksFirstPage()
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

  public func submitSearch() async {
    await performSearch(selectFirstResult: true)
  }

  public func updateSearchText(_ text: String) async {
    searchText = text
    await performSearch(selectFirstResult: false)
  }

  public func toggleSearchTag(_ tagName: String) async {
    if selectedSearchTagNames.contains(tagName) {
      selectedSearchTagNames.remove(tagName)
    } else {
      selectedSearchTagNames.insert(tagName)
    }
    await performSearch(selectFirstResult: false)
  }

  public func toggleSearchClass(_ classId: String) async {
    if selectedSearchClassIds.contains(classId) {
      selectedSearchClassIds.remove(classId)
    } else {
      selectedSearchClassIds.insert(classId)
    }
    await performSearch(selectFirstResult: false)
  }

  public func clearSearchFilters() async {
    selectedSearchTagNames = []
    selectedSearchClassIds = []
    filter = RielaNoteListFilter(sort: filter.sort)
    await performSearch(selectFirstResult: false)
  }

  private func performSearch(selectFirstResult: Bool) async {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty || hasSearchFilters else {
      advanceSearchGeneration()
      await load()
      return
    }
    let generation = advanceSearchGeneration()
    let tagFilter = selectedSearchTagNames.sorted()
    let classFilter = selectedSearchClassIds.sorted()
    state = .loading
    do {
      let page = try await fetchSearchResults(query: query, tagFilter: tagFilter, classFilter: classFilter)
      guard isCurrentSearch(generation: generation, query: query, tagFilter: tagFilter, classFilter: classFilter) else {
        return
      }
      applySearchResultsPage(page)
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
      selectedDetail = detail
      let detailNotebookId = detail.note.notebookId
      if selectedNotebookId != detailNotebookId || !notebookNotes.contains(where: { $0.noteId == noteId }) {
        let notebookId = detailNotebookId
        selectedNotebookId = notebookId
        try await loadNotebookNotesFirstPage(notebookId: notebookId, generation: generation)
        try await loadNotebookNotesUntilContains(noteId, generation: generation)
      }
      guard isCurrentSelection(generation) else {
        return
      }
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
    try await loadNotebooksFirstPage()
    try await loadNotebooksUntilContains(detail.note.notebookId)
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
    try await loadNotebooksFirstPage()
    try await loadNotebooksUntilContains(detail.note.notebookId)
    availableSearchTags = try await client.listTags()
    availableSearchTagClasses = try await client.listTagClasses()
    try await loadNotebookNotesFirstPage(notebookId: detail.note.notebookId, generation: generation)
    try await loadNotebookNotesUntilContains(detail.note.noteId, generation: generation)
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

  public func setContentMode(_ mode: NoteContentMode) async {
    guard mode == .sourceImage else {
      contentMode = .text
      rememberContentMode(.text)
      return
    }
    guard let sourcePageImageAttachment else {
      contentMode = .text
      rememberContentMode(.text)
      return
    }
    contentMode = .sourceImage
    rememberContentMode(.sourceImage)
    await resolveSourceImageAttachment(sourcePageImageAttachment, generation: selectionGeneration)
  }

  public func retrySourceImage() async {
    let attachment = sourcePageImageAttachment ?? selectedResolvedFile.map {
      NoteFileAttachment(noteId: selectedNote?.noteId ?? "", file: $0.file, role: .related, position: 0)
    }
    guard let attachment else {
      return
    }
    removeResolvedFileCacheValue(forKey: attachment.file.fileId)
    removeDecodedSourceImageCacheValue(forKey: attachment.file.fileId)
    if resolvedSourceImage?.file.fileId == attachment.file.fileId {
      resolvedSourceImage = nil
      decodedSourceImage = nil
    }
    contentMode = .sourceImage
    await resolveSourceImageAttachment(attachment, generation: selectionGeneration, useCache: false)
  }

  public func zoomInSourceImage() {
    sourceImageZoom = clampedSourceImageZoom(sourceImageZoom + Self.sourceImageZoomStep)
  }

  public func zoomOutSourceImage() {
    sourceImageZoom = clampedSourceImageZoom(sourceImageZoom - Self.sourceImageZoomStep)
  }

  public func resetSourceImageZoom() {
    sourceImageZoom = 1.0
  }

  public func selectFileAttachment(_ attachment: NoteFileAttachment) async {
    if attachment.role == .sourcePageImage || attachment.file.mediaType.hasPrefix("image/") {
      contentMode = .sourceImage
      await resolveSourceImageAttachment(attachment, generation: selectionGeneration)
      return
    }
    let generation = selectionGeneration
    do {
      let resolved = try await resolveFile(attachment.file.fileId)
      guard isCurrentSelection(generation) else {
        return
      }
      selectedResolvedFile = resolved
    } catch {
      guard isCurrentSelection(generation) else {
        return
      }
      state = .failed(rielaNoteLoadFailureMessage(error))
    }
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
    let commentBody = bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !commentBody.isEmpty else {
      throw NoteServiceError.invalidInput("A comment cannot be empty.")
    }
    let generation = selectionGeneration
    let detail = try await client.addComment(noteId: noteId, bodyMarkdown: commentBody)
    guard isCurrentSelection(generation) else {
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
      try await appendNotebooksPage()
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

  public func loadMoreNotebookNotes() async {
    guard let notebookId = selectedNotebookId, canLoadMoreNotebookNotes else {
      return
    }
    let generation = selectionGeneration
    isLoadingMoreNotebookNotes = true
    state = .loading
    do {
      try await appendNotebookNotesPage(notebookId: notebookId, generation: generation)
      guard isCurrentSelection(generation) else {
        isLoadingMoreNotebookNotes = false
        return
      }
      isLoadingMoreNotebookNotes = false
      state = .loaded
    } catch {
      guard isCurrentSelection(generation) else {
        isLoadingMoreNotebookNotes = false
        return
      }
      isLoadingMoreNotebookNotes = false
      state = .failed(rielaNoteLoadFailureMessage(error))
    }
  }

  private func selectAdjacentNote(delta: Int) async {
    guard let selectedNoteIndex else {
      return
    }
    let targetIndex = selectedNoteIndex + delta
    if targetIndex >= notebookNotes.count, delta > 0, canLoadMoreNotebookNotes {
      await loadMoreNotebookNotes()
    }
    guard notebookNotes.indices.contains(targetIndex) else {
      return
    }
    await selectNote(notebookNotes[targetIndex].noteId)
  }

  private func loadNotebooksFirstPage() async throws {
    let page = try await client.listNotebooks(limit: notebookPageSize + 1, offset: 0, filter: filter)
    notebooks = Array(page.prefix(notebookPageSize))
    notebooksOffset = notebooks.count
    hasMoreNotebooks = page.count > notebookPageSize
  }

  private func appendNotebooksPage() async throws {
    let page = try await client.listNotebooks(limit: notebookPageSize + 1, offset: notebooksOffset, filter: filter)
    let visiblePage = Array(page.prefix(notebookPageSize))
    let existingNotebookIds = Set(notebooks.map(\.notebookId))
    notebooks.append(contentsOf: visiblePage.filter { !existingNotebookIds.contains($0.notebookId) })
    notebooksOffset += visiblePage.count
    hasMoreNotebooks = page.count > notebookPageSize
  }

  private func loadNotebooksUntilContains(_ notebookId: String) async throws {
    while !notebooks.contains(where: { $0.notebookId == notebookId }) && hasMoreNotebooks {
      try await appendNotebooksPage()
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

  private func reloadForFilterChange() async {
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

  private func isCurrentSelection(_ generation: Int) -> Bool {
    selectionGeneration == generation
  }

  private func loadNotebookNotesFirstPage(notebookId: String, generation: Int) async throws {
    let page = try await client.listNotes(notebookId: notebookId, limit: notebookNotePageSize + 1, offset: 0)
    // Drop a first page fetched for a superseded selection so it never replaces the
    // list the newer selection has already populated.
    guard isCurrentSelection(generation), selectedNotebookId == notebookId else {
      return
    }
    notebookNotes = Array(page.prefix(notebookNotePageSize))
    notebookNotesOffset = notebookNotes.count
    hasMoreNotebookNotes = page.count > notebookNotePageSize
  }

  private func appendNotebookNotesPage(notebookId: String, generation: Int) async throws {
    let requestOffset = notebookNotesOffset
    let page = try await client.listNotes(
      notebookId: notebookId,
      limit: notebookNotePageSize + 1,
      offset: requestOffset
    )
    // Drop a page fetched for a superseded selection so it never lands in the new
    // notebook's list or skews the shared offset.
    guard isCurrentSelection(generation), selectedNotebookId == notebookId else {
      return
    }
    let visiblePage = Array(page.prefix(notebookNotePageSize))
    let existingNoteIds = Set(notebookNotes.map(\.noteId))
    let appended = visiblePage.filter { !existingNoteIds.contains($0.noteId) }
    notebookNotes.append(contentsOf: appended)
    notebookNotesOffset += appended.count
    hasMoreNotebookNotes = page.count > notebookNotePageSize
  }

  private func loadNotebookNotesUntilContains(_ noteId: String, generation: Int) async throws {
    while !notebookNotes.contains(where: { $0.noteId == noteId }), hasMoreNotebookNotes {
      guard let notebookId = selectedNotebookId, isCurrentSelection(generation) else {
        return
      }
      try await appendNotebookNotesPage(notebookId: notebookId, generation: generation)
    }
  }

  private func replaceSelectedDetail(_ detail: RielaNoteDetail) {
    selectedDetail = detail
    if let index = notebookNotes.firstIndex(where: { $0.noteId == detail.note.noteId }) {
      notebookNotes[index] = detail.note
    }
  }

  private func prepareSelectedNoteFiles(preferredMode: NoteContentMode) async {
    clearResolvedFileSelection()
    let generation = selectionGeneration
    guard selectedDetail != nil else {
      contentMode = .text
      return
    }
    if preferredMode == .sourceImage, let sourcePageImageAttachment {
      contentMode = .sourceImage
      await resolveSourceImageAttachment(sourcePageImageAttachment, generation: generation)
    } else {
      contentMode = .text
    }
    scheduleAdjacentSourceImagePrefetch(generation: generation)
  }

  private func scheduleAdjacentSourceImagePrefetch(generation: Int) {
    Task { @MainActor [weak self] in
      guard let self, self.isCurrentSelection(generation) else {
        return
      }
      await self.prefetchAdjacentSourceImages()
    }
  }

  private func resolveSourceImageAttachment(
    _ attachment: NoteFileAttachment,
    generation: Int,
    useCache: Bool = true
  ) async {
    isSourceImageLoading = true
    do {
      let resolved = try await resolveFile(attachment.file.fileId, useCache: useCache)
      // A stale resolution is dropped whole; the current selection owns isSourceImageLoading.
      guard isCurrentSelection(generation) else {
        return
      }
      resolvedSourceImage = resolved
      selectedResolvedFile = resolved
      // Decode after publishing the resolved file so a decode failure still leaves the
      // resolved image visible (matching the non-decodable-image behavior).
      let decoded = try await decodeSourceImage(resolved, useCache: useCache)
      guard isCurrentSelection(generation) else {
        return
      }
      decodedSourceImage = decoded
      isSourceImageLoading = false
    } catch {
      // A stale failure never sets global state = .failed and never clears a newer
      // selection's loading flag.
      guard isCurrentSelection(generation) else {
        return
      }
      isSourceImageLoading = false
      state = .failed(rielaNoteLoadFailureMessage(error))
    }
  }

  private func prefetchAdjacentSourceImages() async {
    guard let selectedNoteIndex else {
      return
    }
    let adjacentIndices = [selectedNoteIndex - 1, selectedNoteIndex + 1]
    for index in adjacentIndices where notebookNotes.indices.contains(index) {
      await prefetchSourceImage(noteId: notebookNotes[index].noteId)
    }
  }

  private func prefetchSourceImage(noteId: String) async {
    do {
      let detail = try await client.noteDetail(noteId: noteId)
      guard let attachment = detail.files.first(where: { $0.role == .sourcePageImage }) else {
        return
      }
      _ = try await resolveFile(attachment.file.fileId)
    } catch {
      // Prefetch is best-effort; explicit image selection still surfaces errors.
    }
  }

  private func rememberContentMode(_ mode: NoteContentMode) {
    guard let notebookId = selectedDetail?.note.notebookId ?? selectedNotebookId else {
      return
    }
    notebookContentModes[notebookId] = mode
  }

  func clearResolvedFileSelection() {
    resolvedSourceImage = nil
    decodedSourceImage = nil
    selectedResolvedFile = nil
    isSourceImageLoading = false
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

  public func updateSort(_ sort: NoteListSort) async {
    filter.sort = sort
    await reloadForFilterChange()
  }

  public func updateCreatedRange(_ range: RielaNoteListFilter.CreatedRange) async {
    filter.createdRange = range
    await reloadForFilterChange()
  }

  public func updateIncludeLinked(_ includeLinked: Bool) async {
    filter.includeLinked = includeLinked
    await performSearch(selectFirstResult: false)
  }

  public func updateCustomCreatedAfter(_ value: String) async {
    filter.customCreatedAfter = value
    guard rielaNoteCreatedBoundInputIsValid(value) else {
      return
    }
    await reloadForFilterChange()
  }

  public func updateCustomCreatedBefore(_ value: String) async {
    filter.customCreatedBefore = value
    guard rielaNoteCreatedBoundInputIsValid(value) else {
      return
    }
    await reloadForFilterChange()
  }

}

private extension RielaNoteLibraryViewModel {
  func prefetchFile(_ fileId: String) async {
    do {
      _ = try await resolveFile(fileId)
    } catch {
      // Prefetch is best-effort; explicit file selection still surfaces errors.
    }
  }

  func resolveFile(_ fileId: String, useCache: Bool = true) async throws -> RielaNoteResolvedFile {
    if useCache, let cached = resolvedFileCache[fileId] {
      touchResolvedFileCacheKey(fileId)
      return cached
    }
    let resolved = try await client.resolveFile(fileId: fileId)
    storeResolvedFileCacheValue(resolved, forKey: fileId)
    return resolved
  }

  func decodeSourceImage(
    _ resolvedFile: RielaNoteResolvedFile,
    useCache: Bool = true
  ) async throws -> RielaNoteDecodedSourceImage {
    let fileId = resolvedFile.file.fileId
    if useCache, let cached = decodedSourceImageCache[fileId] {
      touchDecodedSourceImageCacheKey(fileId)
      return cached
    }
    let data = resolvedFile.data
    let decoded = try await Task.detached(priority: .userInitiated) {
      try RielaNoteSourceImageDecoder.decode(fileId: fileId, data: data)
    }.value
    storeDecodedSourceImageCacheValue(decoded, forKey: fileId)
    return decoded
  }

  private func storeResolvedFileCacheValue(_ value: RielaNoteResolvedFile, forKey fileId: String) {
    resolvedFileCache[fileId] = value
    touchResolvedFileCacheKey(fileId)
    evictResolvedFileCacheIfNeeded()
  }

  private func touchResolvedFileCacheKey(_ fileId: String) {
    resolvedFileCacheOrder.removeAll { $0 == fileId }
    resolvedFileCacheOrder.append(fileId)
  }

  private func evictResolvedFileCacheIfNeeded() {
    while resolvedFileCacheOrder.count > sourceImageCacheLimit {
      let evicted = resolvedFileCacheOrder.removeFirst()
      resolvedFileCache.removeValue(forKey: evicted)
    }
  }

  private func removeResolvedFileCacheValue(forKey fileId: String) {
    resolvedFileCache.removeValue(forKey: fileId)
    resolvedFileCacheOrder.removeAll { $0 == fileId }
  }

  private func storeDecodedSourceImageCacheValue(_ value: RielaNoteDecodedSourceImage, forKey fileId: String) {
    decodedSourceImageCache[fileId] = value
    touchDecodedSourceImageCacheKey(fileId)
    evictDecodedSourceImageCacheIfNeeded()
  }

  private func touchDecodedSourceImageCacheKey(_ fileId: String) {
    decodedSourceImageCacheOrder.removeAll { $0 == fileId }
    decodedSourceImageCacheOrder.append(fileId)
  }

  private func evictDecodedSourceImageCacheIfNeeded() {
    while decodedSourceImageCacheOrder.count > sourceImageCacheLimit {
      let evicted = decodedSourceImageCacheOrder.removeFirst()
      decodedSourceImageCache.removeValue(forKey: evicted)
    }
  }

  private func removeDecodedSourceImageCacheValue(forKey fileId: String) {
    decodedSourceImageCache.removeValue(forKey: fileId)
    decodedSourceImageCacheOrder.removeAll { $0 == fileId }
  }

  private func clampedSourceImageZoom(_ zoom: Double) -> Double {
    min(max(zoom, Self.sourceImageMinimumZoom), Self.sourceImageMaximumZoom)
  }

  private func fileDisplayName(_ file: FileRecord) -> String {
    file.originalFilename ?? file.fileId
  }

  private func byteCountText(_ byteSize: Int64) -> String {
    byteSize == 1 ? "1 byte" : "\(byteSize) bytes"
  }
}

/// Human-readable message for a list load/selection failure. `NoteServiceError`
/// cases map to short user-facing text; anything else falls back to a generic
/// message so raw error descriptions never reach the UI.
func rielaNoteLoadFailureMessage(_ error: Error) -> String {
  switch error {
  case let serviceError as NoteServiceError:
    switch serviceError {
    case .notFound:
      return "That note is no longer available."
    case .readOnly:
      return "This note is read-only."
    case .protectedTag:
      return "That tag can't be changed."
    case .invalidInput:
      return "The request was invalid."
    case .invalidRow:
      return "A stored note could not be read."
    }
  default:
    return "Unable to load notes right now."
  }
}
