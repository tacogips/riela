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
  @Published public private(set) var notebookNotes: [Note] = []
  @Published public private(set) var availableSearchTags: [Tag] = []
  @Published public private(set) var availableSearchTagClasses: [TagClass] = []
  @Published public private(set) var searchResults: [NoteSearchResult] = []
  @Published public private(set) var selectedDetail: RielaNoteDetail?
  @Published public private(set) var resolvedSourceImage: RielaNoteResolvedFile?
  @Published public private(set) var decodedSourceImage: RielaNoteDecodedSourceImage?
  @Published public private(set) var selectedResolvedFile: RielaNoteResolvedFile?
  @Published public private(set) var selectedNotebookId: String?
  @Published public private(set) var selectedSearchTagNames: Set<String> = []
  @Published public private(set) var selectedSearchClassIds: Set<String> = []
  @Published public private(set) var hasMoreNotebooks = false
  @Published public private(set) var hasMoreNotebookNotes = false
  @Published public private(set) var hasMoreSearchResults = false
  @Published public private(set) var linkTargetSearchNotes: [Note] = []
  @Published public private(set) var isLinkTargetSearchLoading = false
  @Published public private(set) var isSourceImageLoading = false
  @Published public var searchText = ""
  @Published public var sourceImageZoom = 1.0
  @Published public var contentMode: NoteContentMode = .text
  @Published public private(set) var state: LoadState = .idle

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
  private var linkTargetSearchQuery = ""
  private var searchGeneration = 0
  private var selectionGeneration = 0

  private var notebookPageSize: Int {
    max(notebookLimit, 1)
  }

  private var notebookNotePageSize: Int {
    max(notebookNoteLimit, 1)
  }

  private var searchPageSize: Int {
    max(searchLimit, 1)
  }

  private var linkTargetSearchLimit: Int {
    min(searchPageSize, 10)
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

  public var isSearching: Bool {
    hasSearchQuery || hasSearchFilters
  }

  public var hasSearchQuery: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  public var hasSearchFilters: Bool {
    !selectedSearchTagNames.isEmpty || !selectedSearchClassIds.isEmpty
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
    selectedNotebookId != nil && hasMoreNotebookNotes && !isSearching
  }

  public var canLoadMoreNotebooks: Bool {
    hasMoreNotebooks && !isSearching
  }

  public var canLoadMoreSearchResults: Bool {
    isSearching && hasMoreSearchResults
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
    state = .loading
    do {
      try await loadNotebooksFirstPage()
      availableSearchTags = try await client.listTags()
      availableSearchTagClasses = try await client.listTagClasses()
      searchResults = []
      searchResultsOffset = 0
      hasMoreSearchResults = false
      state = .loaded
      if selectedDetail == nil, let first = notebooks.first {
        await selectNotebook(first.notebookId)
      }
    } catch {
      state = .failed(String(describing: error))
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
        try await loadNotebookNotesFirstPage(notebookId: currentNotebookId)
        if let selectedNoteId {
          try await loadNotebookNotesUntilContains(selectedNoteId)
        }
      } else if let first = notebooks.first {
        self.selectedNotebookId = first.notebookId
        try await loadNotebookNotesFirstPage(notebookId: first.notebookId)
      }
      guard self.selectionGeneration == selectionGeneration else {
        state = .loaded
        return
      }
      let refreshedDetail: RielaNoteDetail?
      if let selectedNoteId {
        refreshedDetail = try await client.noteDetail(noteId: selectedNoteId)
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
    } catch {
      state = .failed(String(describing: error))
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
    await performSearch(selectFirstResult: false)
  }

  public func updateLinkTargetSearchText(_ query: String, currentNoteId: String) async {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    linkTargetSearchQuery = normalizedQuery
    guard !normalizedQuery.isEmpty else {
      clearLinkTargetSearch()
      return
    }
    isLinkTargetSearchLoading = true
    do {
      let results = try await client.searchNotes(
        query: normalizedQuery,
        tagFilter: [],
        classFilter: [],
        limit: linkTargetSearchLimit,
        offset: 0
      )
      guard linkTargetSearchQuery == normalizedQuery else {
        return
      }
      linkTargetSearchNotes = results.map(\.note).filter { $0.noteId != currentNoteId }
      isLinkTargetSearchLoading = false
    } catch {
      guard linkTargetSearchQuery == normalizedQuery else {
        return
      }
      linkTargetSearchNotes = []
      isLinkTargetSearchLoading = false
    }
  }

  public func clearLinkTargetSearch() {
    linkTargetSearchQuery = ""
    linkTargetSearchNotes = []
    isLinkTargetSearchLoading = false
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
      state = .failed(String(describing: error))
    }
  }

  public func selectNotebook(_ notebookId: String) async {
    let generation = advanceSelectionGeneration()
    state = .loading
    do {
      selectedNotebookId = notebookId
      try await loadNotebookNotesFirstPage(notebookId: notebookId)
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
      state = .failed(String(describing: error))
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
        try await loadNotebookNotesFirstPage(notebookId: notebookId)
        try await loadNotebookNotesUntilContains(noteId)
      }
      guard isCurrentSelection(generation) else {
        return
      }
      let notebookId = selectedDetail?.note.notebookId
      let preferredMode = notebookId.flatMap { notebookContentModes[$0] }
        ?? (previousNotebookId == notebookId ? contentMode : .text)
      await prepareSelectedNoteFiles(preferredMode: preferredMode)
      state = .loaded
    } catch {
      guard isCurrentSelection(generation) else {
        return
      }
      state = .failed(String(describing: error))
    }
  }

  public func createUserMemo(title: String = "Untitled Memo", body: String = "") async {
    state = .loading
    do {
      let detail = try await client.createUserMemo(
        bodyMarkdown: rielaNoteDraftMarkdown(title: title, fallbackTitle: "Untitled Memo", body: body)
      )
      searchText = ""
      searchResults = []
      searchResultsOffset = 0
      hasMoreSearchResults = false
      selectedSearchTagNames = []
      selectedSearchClassIds = []
      selectedDetail = detail
      selectedNotebookId = detail.note.notebookId
      try await loadNotebooksFirstPage()
      try await loadNotebooksUntilContains(detail.note.notebookId)
      availableSearchTags = try await client.listTags()
      availableSearchTagClasses = try await client.listTagClasses()
      try await loadNotebookNotesFirstPage(notebookId: detail.note.notebookId)
      if !notebookNotes.contains(where: { $0.noteId == detail.note.noteId }) {
        notebookNotes.append(detail.note)
      }
      clearResolvedFileSelection()
      contentMode = .text
      state = .loaded
    } catch {
      state = .failed(String(describing: error))
    }
  }

  public func createNoteInSelectedNotebook(title: String = "Untitled Note", body: String = "") async {
    guard let notebookId = selectedNotebookId else {
      return
    }
    state = .loading
    do {
      let detail = try await client.createNote(
        inNotebook: notebookId,
        bodyMarkdown: rielaNoteDraftMarkdown(title: title, fallbackTitle: "Untitled Note", body: body)
      )
      searchText = ""
      searchResults = []
      searchResultsOffset = 0
      hasMoreSearchResults = false
      selectedSearchTagNames = []
      selectedSearchClassIds = []
      selectedDetail = detail
      selectedNotebookId = detail.note.notebookId
      try await loadNotebooksFirstPage()
      try await loadNotebooksUntilContains(detail.note.notebookId)
      availableSearchTags = try await client.listTags()
      availableSearchTagClasses = try await client.listTagClasses()
      try await loadNotebookNotesFirstPage(notebookId: detail.note.notebookId)
      try await loadNotebookNotesUntilContains(detail.note.noteId)
      if !notebookNotes.contains(where: { $0.noteId == detail.note.noteId }) {
        notebookNotes.append(detail.note)
      }
      clearResolvedFileSelection()
      contentMode = .text
      state = .loaded
    } catch {
      state = .failed(String(describing: error))
    }
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
    await resolveSourceImageAttachment(sourcePageImageAttachment)
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
    await resolveSourceImageAttachment(attachment, useCache: false)
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
      await resolveSourceImageAttachment(attachment)
      return
    }
    do {
      selectedResolvedFile = try await resolveFile(attachment.file.fileId)
    } catch {
      state = .failed(String(describing: error))
    }
  }

  public func saveSelectedNoteBody(_ bodyMarkdown: String, expectedNoteId: String? = nil) async {
    guard let noteId = selectedDetail?.note.noteId else {
      return
    }
    guard expectedNoteId == nil || expectedNoteId == noteId else {
      return
    }
    state = .loading
    do {
      selectedDetail = try await client.updateNoteBody(noteId: noteId, bodyMarkdown: bodyMarkdown)
      if let index = notebookNotes.firstIndex(where: { $0.noteId == noteId }),
         let updatedNote = selectedDetail?.note {
        notebookNotes[index] = updatedNote
      }
      clearResolvedFileSelection()
      contentMode = .text
      state = .loaded
    } catch {
      state = .failed(String(describing: error))
    }
  }

  public func applyTagToSelectedNote(name: String, classId: String? = "topic") async {
    guard let noteId = selectedDetail?.note.noteId else {
      return
    }
    let tagName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !tagName.isEmpty else {
      return
    }
    state = .loading
    do {
      let normalizedClassId = classId?.trimmingCharacters(in: .whitespacesAndNewlines)
      let detail = try await client.applyTag(
        noteId: noteId,
        tagName: tagName,
        classId: normalizedClassId?.isEmpty == true ? nil : normalizedClassId
      )
      replaceSelectedDetail(detail)
      availableSearchTags = try await client.listTags()
      state = .loaded
    } catch {
      state = .failed(String(describing: error))
    }
  }

  public func removeTagFromSelectedNote(name: String) async {
    guard let noteId = selectedDetail?.note.noteId else {
      return
    }
    state = .loading
    do {
      let detail = try await client.removeTag(noteId: noteId, tagName: name)
      replaceSelectedDetail(detail)
      state = .loaded
    } catch {
      state = .failed(String(describing: error))
    }
  }

  public func addCommentToSelectedNote(_ bodyMarkdown: String) async {
    guard let noteId = selectedDetail?.note.noteId else {
      return
    }
    let commentBody = bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !commentBody.isEmpty else {
      return
    }
    state = .loading
    do {
      selectedDetail = try await client.addComment(noteId: noteId, bodyMarkdown: commentBody)
      state = .loaded
    } catch {
      state = .failed(String(describing: error))
    }
  }

  public func linkSelectedNote(to targetNoteId: String, kind: String = "related") async {
    guard let noteId = selectedDetail?.note.noteId else {
      return
    }
    let normalizedTarget = targetNoteId.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedTarget.isEmpty else {
      return
    }
    state = .loading
    do {
      selectedDetail = try await client.linkNote(
        noteId: noteId,
        targetNoteId: normalizedTarget,
        linkKind: normalizedKind.isEmpty ? "related" : normalizedKind
      )
      state = .loaded
    } catch {
      state = .failed(String(describing: error))
    }
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
      state = .failed(String(describing: error))
    }
  }

  public func loadMoreSearchResults() async {
    guard canLoadMoreSearchResults else {
      return
    }
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    state = .loading
    do {
      let page = try await client.searchNotes(
        query: query,
        tagFilter: selectedSearchTagNames.sorted(),
        classFilter: selectedSearchClassIds.sorted(),
        limit: searchPageSize + 1,
        offset: searchResultsOffset
      )
      let visiblePage = Array(page.prefix(searchPageSize))
      let existingNoteIds = Set(searchResults.map(\.note.noteId))
      searchResults.append(contentsOf: visiblePage.filter { !existingNoteIds.contains($0.note.noteId) })
      searchResultsOffset += visiblePage.count
      hasMoreSearchResults = page.count > searchPageSize
      state = .loaded
    } catch {
      state = .failed(String(describing: error))
    }
  }

  public func loadMoreNotebookNotes() async {
    guard let notebookId = selectedNotebookId, canLoadMoreNotebookNotes else {
      return
    }
    state = .loading
    do {
      try await appendNotebookNotesPage(notebookId: notebookId)
      state = .loaded
    } catch {
      state = .failed(String(describing: error))
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
    let page = try await client.listNotebooks(limit: notebookPageSize + 1, offset: 0)
    notebooks = Array(page.prefix(notebookPageSize))
    notebooksOffset = notebooks.count
    hasMoreNotebooks = page.count > notebookPageSize
  }

  private func appendNotebooksPage() async throws {
    let page = try await client.listNotebooks(limit: notebookPageSize + 1, offset: notebooksOffset)
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

  @discardableResult
  private func advanceSelectionGeneration() -> Int {
    selectionGeneration += 1
    return selectionGeneration
  }

  private func isCurrentSelection(_ generation: Int) -> Bool {
    selectionGeneration == generation
  }

  private func loadNotebookNotesFirstPage(notebookId: String) async throws {
    let page = try await client.listNotes(notebookId: notebookId, limit: notebookNotePageSize + 1, offset: 0)
    notebookNotes = Array(page.prefix(notebookNotePageSize))
    notebookNotesOffset = notebookNotes.count
    hasMoreNotebookNotes = page.count > notebookNotePageSize
  }

  private func appendNotebookNotesPage(notebookId: String) async throws {
    let page = try await client.listNotes(
      notebookId: notebookId,
      limit: notebookNotePageSize + 1,
      offset: notebookNotesOffset
    )
    let visiblePage = Array(page.prefix(notebookNotePageSize))
    let existingNoteIds = Set(notebookNotes.map(\.noteId))
    notebookNotes.append(contentsOf: visiblePage.filter { !existingNoteIds.contains($0.noteId) })
    notebookNotesOffset += visiblePage.count
    hasMoreNotebookNotes = page.count > notebookNotePageSize
  }

  private func loadNotebookNotesUntilContains(_ noteId: String) async throws {
    while !notebookNotes.contains(where: { $0.noteId == noteId }), hasMoreNotebookNotes {
      guard let notebookId = selectedNotebookId else {
        return
      }
      try await appendNotebookNotesPage(notebookId: notebookId)
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
      await resolveSourceImageAttachment(sourcePageImageAttachment)
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

  private func resolveSourceImageAttachment(_ attachment: NoteFileAttachment, useCache: Bool = true) async {
    isSourceImageLoading = true
    defer {
      isSourceImageLoading = false
    }
    do {
      let resolved = try await resolveFile(attachment.file.fileId, useCache: useCache)
      resolvedSourceImage = resolved
      selectedResolvedFile = resolved
      decodedSourceImage = try await decodeSourceImage(resolved, useCache: useCache)
    } catch {
      state = .failed(String(describing: error))
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

  private func clearResolvedFileSelection() {
    resolvedSourceImage = nil
    decodedSourceImage = nil
    selectedResolvedFile = nil
    isSourceImageLoading = false
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

func rielaNoteDraftMarkdown(title: String, fallbackTitle: String, body: String) -> String {
  let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
  let heading = trimmedTitle.isEmpty ? fallbackTitle : trimmedTitle
  let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmedBody.isEmpty else {
    return "# \(heading)\n\n"
  }
  return "# \(heading)\n\n\(trimmedBody)"
}
