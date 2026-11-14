import Foundation
import RielaNote

public extension RielaNoteLibraryViewModel {
  var isSearching: Bool {
    hasSearchQuery || hasSearchFilters
  }

  var isTagKanbanActive: Bool {
    !selectedSearchTagNames.isEmpty
  }

  var hasSearchQuery: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var hasSearchFilters: Bool {
    !selectedSearchTagNames.isEmpty
      || !selectedSearchClassIds.isEmpty
      || filter.createdRange != .any
  }

  func submitSearch() async {
    await performSearch(selectFirstResult: true)
  }

  func updateSearchText(_ text: String) async {
    searchText = text
    await performSearch(selectFirstResult: false)
  }

  func toggleSearchTag(_ tagName: String) async {
    if selectedSearchTagNames.contains(tagName) {
      selectedSearchTagNames.remove(tagName)
    } else {
      selectedSearchTagNames.insert(tagName)
    }
    await performSearch(selectFirstResult: false)
  }

  func toggleSearchClass(_ classId: String) async {
    if selectedSearchClassIds.contains(classId) {
      selectedSearchClassIds.remove(classId)
    } else {
      selectedSearchClassIds.insert(classId)
    }
    await performSearch(selectFirstResult: false)
  }

  func clearSearchFilters() async {
    selectedSearchTagNames = []
    selectedSearchClassIds = []
    filter = RielaNoteListFilter(sort: filter.sort)
    await performSearch(selectFirstResult: false)
  }

  func updateSort(_ sort: NoteListSort) async {
    filter.sort = sort
    await reloadForFilterChange()
  }

  func updateCreatedRange(_ range: RielaNoteListFilter.CreatedRange) async {
    filter.createdRange = range
    await reloadForFilterChange()
  }

  func updateIncludeLinked(_ includeLinked: Bool) async {
    filter.includeLinked = includeLinked
    await performSearch(selectFirstResult: false)
  }

  func updateCustomCreatedAfter(_ value: String) async {
    filter.customCreatedAfter = value
    guard rielaNoteCreatedBoundInputIsValid(value) else {
      return
    }
    await reloadForFilterChange()
  }

  func updateCustomCreatedBefore(_ value: String) async {
    filter.customCreatedBefore = value
    guard rielaNoteCreatedBoundInputIsValid(value) else {
      return
    }
    await reloadForFilterChange()
  }
}
