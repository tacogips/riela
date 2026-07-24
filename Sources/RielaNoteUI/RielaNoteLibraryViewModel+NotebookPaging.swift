import RielaNote

struct RielaNoteNotebookBoardContext: Equatable {
  let tagFilter: [String]
  let filter: RielaNoteListFilter
}

private struct RielaNoteNotebookPageRequest {
  let searchGeneration: Int
  let notebookPageGeneration: Int
  let tagFilter: [String]
  let filter: RielaNoteListFilter
  let offset: Int

  var context: RielaNoteNotebookBoardContext {
    RielaNoteNotebookBoardContext(tagFilter: tagFilter, filter: filter)
  }
}

extension RielaNoteLibraryViewModel {
  func loadNotebooksFirstPage() async throws -> Bool {
    let request = beginNotebookFirstPageRequest(
      tagFilter: selectedSearchTagNames.sorted()
    )
    do {
      let page = try await fetchNotebooksPage(request)
      guard isCurrentNotebookPageRequest(request) else {
        return false
      }
      applyNotebooksFirstPage(page, context: request.context)
      return true
    } catch {
      guard isCurrentNotebookPageRequest(request) else {
        return false
      }
      throw error
    }
  }

  func applyNotebooksFirstPage(
    _ page: [Notebook],
    context: RielaNoteNotebookBoardContext
  ) {
    notebooks = Array(page.prefix(notebookPageSize))
    notebooksOffset = notebooks.count
    hasMoreNotebooks = page.count > notebookPageSize
    notebookSnapshotContext = context
  }

  func appendNotebooksPage() async throws -> Bool {
    let request = notebookPageRequest(offset: notebooksOffset)
    do {
      let page = try await fetchNotebooksPage(request)
      guard isCurrentNotebookPageRequest(request),
            notebooksOffset == request.offset else {
        return false
      }
      let visiblePage = Array(page.prefix(notebookPageSize))
      let existingNotebookIds = Set(notebooks.map(\.notebookId))
      notebooks.append(contentsOf: visiblePage.filter { !existingNotebookIds.contains($0.notebookId) })
      notebooksOffset += visiblePage.count
      hasMoreNotebooks = page.count > notebookPageSize
      return true
    } catch {
      guard isCurrentNotebookPageRequest(request),
            notebooksOffset == request.offset else {
        return false
      }
      throw error
    }
  }

  private func notebookPageRequest(offset: Int) -> RielaNoteNotebookPageRequest {
    RielaNoteNotebookPageRequest(
      searchGeneration: searchGeneration,
      notebookPageGeneration: notebookPageGeneration,
      tagFilter: selectedSearchTagNames.sorted(),
      filter: filter,
      offset: offset
    )
  }

  private func beginNotebookFirstPageRequest(
    tagFilter: [String]
  ) -> RielaNoteNotebookPageRequest {
    notebookPageGeneration += 1
    notebookProgressMutationFailure = nil
    return RielaNoteNotebookPageRequest(
      searchGeneration: searchGeneration,
      notebookPageGeneration: notebookPageGeneration,
      tagFilter: tagFilter,
      filter: filter,
      offset: 0
    )
  }

  private func isCurrentNotebookPageRequest(
    _ request: RielaNoteNotebookPageRequest
  ) -> Bool {
    searchGeneration == request.searchGeneration
      && notebookPageGeneration == request.notebookPageGeneration
      && selectedSearchTagNames.sorted() == request.tagFilter
      && filter == request.filter
  }

  private func fetchNotebooksPage(
    _ request: RielaNoteNotebookPageRequest
  ) async throws -> [Notebook] {
    try await client.listNotebooks(
      limit: notebookPageSize + 1,
      offset: request.offset,
      tagFilter: request.tagFilter,
      filter: request.filter
    )
  }

  func fetchNotebooksFirstPageForSearch(
    tagFilter: [String]
  ) async throws -> [Notebook]? {
    let request = beginNotebookFirstPageRequest(tagFilter: tagFilter)
    do {
      let page = try await fetchNotebooksPage(request)
      return isCurrentNotebookPageRequest(request) ? page : nil
    } catch {
      guard isCurrentNotebookPageRequest(request) else {
        return nil
      }
      throw error
    }
  }

  func loadNotebooksUntilContains(_ notebookId: String) async throws -> Bool {
    while !notebooks.contains(where: { $0.notebookId == notebookId }) && hasMoreNotebooks {
      guard try await appendNotebooksPage() else {
        return false
      }
    }
    return true
  }
}
