@MainActor
public extension RielaNoteLibraryViewModel {
  static let readerTrailingLoadThreshold = 2

  @discardableResult
  func loadNextNotebookNotesPageIfNeeded(
    visibleNoteId: String,
    trailingThreshold: Int = RielaNoteLibraryViewModel.readerTrailingLoadThreshold
  ) async -> Bool {
    guard canLoadMoreNotebookNotes,
          pagerNoteSnapshot.shouldLoadNextPage(
            visibleNoteId: visibleNoteId,
            trailingThreshold: trailingThreshold
          ) else {
      return false
    }
    await loadMoreNotebookNotes()
    return true
  }
}
