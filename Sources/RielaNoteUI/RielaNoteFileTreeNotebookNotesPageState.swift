import RielaNote

struct RielaNoteFileTreeNotebookNotesPageState: Equatable {
  private(set) var notes: [Note] = []
  private(set) var nextOffset = 0
  private(set) var hasMore = false
  private(set) var didLoad = false
  var isLoading = false

  var canLoadMore: Bool {
    didLoad && hasMore && !isLoading
  }

  func shouldLoadNextPage(visibleNoteId: String, trailingThreshold: Int) -> Bool {
    guard canLoadMore,
          let visibleIndex = notes.firstIndex(where: { $0.noteId == visibleNoteId }) else {
      return false
    }
    let lastIndex = notes.index(before: notes.endIndex)
    return lastIndex - visibleIndex <= max(trailingThreshold, 0)
  }

  mutating func reset() {
    notes = []
    nextOffset = 0
    hasMore = false
    didLoad = false
    isLoading = false
  }

  mutating func mergeFetchedPage(_ page: [Note], pageSize: Int) {
    let visiblePage = Array(page.prefix(max(pageSize, 1)))
    for note in visiblePage {
      if let index = notes.firstIndex(where: { $0.noteId == note.noteId }) {
        notes[index] = note
      } else {
        notes.append(note)
      }
    }
    nextOffset += visiblePage.count
    hasMore = page.count > max(pageSize, 1)
    didLoad = true
    isLoading = false
  }

  mutating func markLoading() {
    isLoading = true
  }

  mutating func markLoadFinished() {
    isLoading = false
  }
}
