import RielaNote

@MainActor
public extension RielaNoteLibraryViewModel {
  static let readerTrailingLoadThreshold = 2

  @discardableResult
  func loadNotebookNotesPageIfNeeded(
    visibleNoteId: String,
    edgeThreshold: Int = RielaNoteLibraryViewModel.readerTrailingLoadThreshold
  ) async -> Bool {
    let snapshot = pagerNoteSnapshot
    let shouldLoadEarlier = canLoadEarlierNotebookNotes
      && snapshot.shouldLoadPreviousPage(
        visibleNoteId: visibleNoteId,
        leadingThreshold: edgeThreshold
      )
    let shouldLoadLater = canLoadMoreNotebookNotes
      && snapshot.shouldLoadNextPage(
        visibleNoteId: visibleNoteId,
        trailingThreshold: edgeThreshold
      )
    if shouldLoadLater,
       !shouldLoadEarlier || snapshot.isCloserToTrailingEdge(noteId: visibleNoteId) {
      await loadMoreNotebookNotes()
      return true
    }
    if shouldLoadEarlier {
      await loadEarlierNotebookNotes()
      return true
    }
    return false
  }

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

  func loadMoreNotebookNotes() async {
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

  func loadEarlierNotebookNotes() async {
    guard let notebookId = selectedNotebookId, canLoadEarlierNotebookNotes else {
      return
    }
    let generation = selectionGeneration
    isLoadingEarlierNotebookNotes = true
    state = .loading
    do {
      try await prependNotebookNotesPage(notebookId: notebookId, generation: generation)
      guard isCurrentSelection(generation) else {
        isLoadingEarlierNotebookNotes = false
        return
      }
      isLoadingEarlierNotebookNotes = false
      state = .loaded
    } catch {
      guard isCurrentSelection(generation) else {
        isLoadingEarlierNotebookNotes = false
        return
      }
      isLoadingEarlierNotebookNotes = false
      state = .failed(rielaNoteLoadFailureMessage(error))
    }
  }
}

@MainActor
extension RielaNoteLibraryViewModel {
  func selectAdjacentNote(delta: Int) async {
    var snapshot = pagerNoteSnapshot
    guard var selectedNoteIndex = snapshot.currentIndex else {
      return
    }
    if selectedNoteIndex == 0, delta < 0, canLoadEarlierNotebookNotes {
      await loadEarlierNotebookNotes()
      snapshot = pagerNoteSnapshot
      guard let refreshedIndex = snapshot.currentIndex else {
        return
      }
      selectedNoteIndex = refreshedIndex
    } else if selectedNoteIndex + delta >= snapshot.notes.count,
              delta > 0,
              canLoadMoreNotebookNotes {
      await loadMoreNotebookNotes()
      snapshot = pagerNoteSnapshot
    }
    let targetIndex = selectedNoteIndex + delta
    guard snapshot.notes.indices.contains(targetIndex) else {
      return
    }
    await selectNote(snapshot.notes[targetIndex].noteId)
  }

  func loadNotebookNotesFirstPage(notebookId: String, generation: Int) async throws {
    let page = try await client.listNotes(notebookId: notebookId, limit: notebookNotePageSize + 1, offset: 0)
    guard isCurrentSelection(generation), selectedNotebookId == notebookId else {
      return
    }
    notebookNotes = Array(page.prefix(notebookNotePageSize))
    notebookNotesStartOffset = 0
    notebookNotesOffset = notebookNotes.count
    hasEarlierNotebookNotes = false
    hasMoreNotebookNotes = page.count > notebookNotePageSize
  }

  func loadNotebookNotesWindow(containing noteId: String, generation: Int) async throws {
    let window = try await client.notebookNotesWindow(
      containing: noteId,
      pageSize: notebookNotePageSize
    )
    guard isCurrentSelection(generation) else {
      return
    }
    guard window.startOffset >= 0,
          window.notes.contains(where: { $0.noteId == noteId }),
          window.notes.allSatisfy({ $0.notebookId == selectedNotebookId }) else {
      throw NoteServiceError.invalidInput("The note client returned an invalid notebook window.")
    }
    notebookNotes = window.notes
    notebookNotesStartOffset = window.startOffset
    notebookNotesOffset = window.startOffset + window.notes.count
    hasEarlierNotebookNotes = window.hasEarlierNotes
    hasMoreNotebookNotes = window.hasMoreNotes
  }

  private func appendNotebookNotesPage(notebookId: String, generation: Int) async throws {
    let requestOffset = notebookNotesOffset
    let page = try await client.listNotes(
      notebookId: notebookId,
      limit: notebookNotePageSize + 1,
      offset: requestOffset
    )
    guard isCurrentSelection(generation), selectedNotebookId == notebookId else {
      return
    }
    let visiblePage = Array(page.prefix(notebookNotePageSize))
    let existingNoteIds = Set(notebookNotes.map(\.noteId))
    let appended = visiblePage.filter { !existingNoteIds.contains($0.noteId) }
    notebookNotes.append(contentsOf: appended)
    notebookNotesOffset += visiblePage.count
    hasMoreNotebookNotes = page.count > notebookNotePageSize
  }

  private func prependNotebookNotesPage(notebookId: String, generation: Int) async throws {
    let requestLimit = min(notebookNotePageSize, notebookNotesStartOffset)
    guard requestLimit > 0 else {
      hasEarlierNotebookNotes = false
      return
    }
    let requestOffset = notebookNotesStartOffset - requestLimit
    let page = try await client.listNotes(
      notebookId: notebookId,
      limit: requestLimit,
      offset: requestOffset
    )
    guard isCurrentSelection(generation), selectedNotebookId == notebookId else {
      return
    }
    let existingNoteIds = Set(notebookNotes.map(\.noteId))
    notebookNotes.insert(contentsOf: page.filter { !existingNoteIds.contains($0.noteId) }, at: 0)
    notebookNotesStartOffset = requestOffset
    hasEarlierNotebookNotes = requestOffset > 0
  }
}
