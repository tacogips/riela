import Foundation
import RielaNote
@testable import RielaNoteUI
import XCTest

@MainActor
final class RielaNoteLibrarySearchPaginationTests: XCTestCase {
  func testSearchFetchesOneExtraResultToExposePagination() async throws {
    let client = SearchPaginationClient()
    let viewModel = RielaNoteLibraryViewModel(client: client, searchLimit: 2)
    viewModel.searchText = "page"

    await viewModel.submitSearch()

    XCTAssertEqual(client.searchRequests, [
      SearchRequest(query: "page", tagFilter: [], classFilter: [], limit: 3, offset: 0)
    ])
    XCTAssertEqual(viewModel.searchResults.map(\.note.noteId), ["note-search-1", "note-search-2"])
    XCTAssertTrue(viewModel.canLoadMoreSearchResults)
    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-search-1")
  }

  func testLoadMoreSearchResultsAppendsNextPageAndStopsAtEnd() async throws {
    let client = SearchPaginationClient()
    let viewModel = RielaNoteLibraryViewModel(client: client, searchLimit: 2)
    viewModel.searchText = "page"

    await viewModel.submitSearch()
    await viewModel.loadMoreSearchResults()

    XCTAssertEqual(client.searchRequests, [
      SearchRequest(query: "page", tagFilter: [], classFilter: [], limit: 3, offset: 0),
      SearchRequest(query: "page", tagFilter: [], classFilter: [], limit: 3, offset: 2)
    ])
    XCTAssertEqual(viewModel.searchResults.map(\.note.noteId), [
      "note-search-1",
      "note-search-2",
      "note-search-3",
      "note-search-4"
    ])
    XCTAssertFalse(viewModel.canLoadMoreSearchResults)
    XCTAssertEqual(viewModel.state, .loaded)
    // Offset invariant: the pagination cursor tracks the actual result count.
    XCTAssertEqual(viewModel.searchResultsOffsetForTesting, viewModel.searchResults.count)
  }

  func testSearchLoadMoreDeduplicatesOverlapAndKeepsOffsetAtResultCount() async throws {
    let client = SearchPaginationClient()
    let viewModel = RielaNoteLibraryViewModel(client: client, searchLimit: 2)
    viewModel.searchText = "page"

    await viewModel.submitSearch()
    // Re-issuing the first-page offset yields overlapping ids; dedup must keep the
    // offset equal to the deduplicated result count, not the raw fetched count.
    await viewModel.loadMoreSearchResults()

    XCTAssertEqual(viewModel.searchResultsOffsetForTesting, viewModel.searchResults.count)
  }

  func testLoadExposesSearchTagClasses() async throws {
    let client = SearchPaginationClient()
    let viewModel = RielaNoteLibraryViewModel(client: client)

    await viewModel.load()

    XCTAssertEqual(viewModel.availableSearchTagClasses.map(\.classId), ["topic", "person"])
  }

  func testClassFilterIsAppliedToSearchAndPagination() async throws {
    let client = SearchPaginationClient()
    let viewModel = RielaNoteLibraryViewModel(client: client, searchLimit: 2)

    await viewModel.toggleSearchClass("topic")
    await viewModel.loadMoreSearchResults()

    XCTAssertEqual(client.searchRequests, [
      SearchRequest(query: "", tagFilter: [], classFilter: ["topic"], limit: 3, offset: 0),
      SearchRequest(query: "", tagFilter: [], classFilter: ["topic"], limit: 3, offset: 2)
    ])
    XCTAssertEqual(viewModel.selectedSearchClassIds, ["topic"])
    XCTAssertEqual(viewModel.searchResults.map(\.note.noteId), [
      "note-search-1",
      "note-search-2",
      "note-search-3",
      "note-search-4"
    ])
  }
}

private final class SearchPaginationClient: RielaNoteUIClient, @unchecked Sendable {
  private let notebook = Notebook(
    notebookId: "notebook-search",
    title: "Search Notebook",
    createdAt: "2026-07-04T00:00:00Z",
    updatedAt: "2026-07-04T00:00:00Z"
  )
  private let tagClasses = [
    TagClass(
      classId: "topic",
      label: "Topic",
      description: "Conceptual topics",
      isSystem: true,
      createdAt: "2026-07-04T00:00:00Z"
    ),
    TagClass(
      classId: "person",
      label: "Person",
      description: "People",
      isSystem: true,
      createdAt: "2026-07-04T00:00:00Z"
    )
  ]
  private let notes: [Note]
  var searchRequests: [SearchRequest] = []

  init() {
    notes = (1...4).map { index in
      Note(
        noteId: "note-search-\(index)",
        notebookId: "notebook-search",
        noteNumber: index,
        title: "Page \(index)",
        bodyMarkdown: "# Page \(index)\n\nSearch body",
        readOnly: false,
        createdAt: "2026-07-04T00:00:00Z",
        updatedAt: "2026-07-04T00:00:00Z"
      )
    }
  }

  var defaultConfigWorkflowRoot: String {
    "tmp/RielaNoteLibrarySearchPaginationTests/workflows"
  }

  func listNotebooks(limit: Int, offset: Int) async throws -> [Notebook] {
    [notebook]
  }

  func listNotes(notebookId: String, limit: Int, offset: Int) async throws -> [Note] {
    Array(notes.dropFirst(offset).prefix(limit))
  }

  func listTags() async throws -> [Tag] {
    []
  }

  func listTagClasses() async throws -> [TagClass] {
    tagClasses
  }

  func createUserMemo(bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw SearchPaginationClientError.unsupported
  }

  func searchNotes(
    query: String,
    tagFilter: [String],
    classFilter: [String],
    limit: Int,
    offset: Int
  ) async throws -> [NoteSearchResult] {
    searchRequests.append(SearchRequest(
      query: query,
      tagFilter: tagFilter,
      classFilter: classFilter,
      limit: limit,
      offset: offset
    ))
    return Array(notes.dropFirst(offset).prefix(limit)).map { note in
      NoteSearchResult(note: note, snippet: note.title ?? note.noteId, rank: 0, matchedTags: [])
    }
  }

  func noteDetail(noteId: String) async throws -> RielaNoteDetail {
    guard let note = notes.first(where: { $0.noteId == noteId }) else {
      throw SearchPaginationClientError.missingNote
    }
    return RielaNoteDetail(note: note)
  }

  func firstNote(inNotebook notebookId: String) async throws -> RielaNoteDetail? {
    RielaNoteDetail(note: notes[0])
  }

  func resolveFile(fileId: String) async throws -> RielaNoteResolvedFile {
    throw SearchPaginationClientError.unsupported
  }

  func updateNoteBody(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw SearchPaginationClientError.unsupported
  }

  func applyTag(noteId: String, tagName: String, classId: String?) async throws -> RielaNoteDetail {
    throw SearchPaginationClientError.unsupported
  }

  func removeTag(noteId: String, tagName: String) async throws -> RielaNoteDetail {
    throw SearchPaginationClientError.unsupported
  }

  func addComment(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw SearchPaginationClientError.unsupported
  }

  func linkNote(noteId: String, targetNoteId: String, linkKind: String) async throws -> RielaNoteDetail {
    throw SearchPaginationClientError.unsupported
  }

  func answerNoteAgentTurn(message: String, limit: Int) async throws -> RielaNoteAgentTurn {
    throw SearchPaginationClientError.unsupported
  }

  func saveNoteAgentConversation(
    title: String,
    turns: [RielaNoteAgentTurn]
  ) async throws -> RielaNoteAgentConversationSaveResult {
    throw SearchPaginationClientError.unsupported
  }

  func appendNoteAgentTurn(
    notebookId: String,
    turn: RielaNoteAgentTurn
  ) async throws -> RielaNoteAgentConversationSaveResult {
    throw SearchPaginationClientError.unsupported
  }

  func proposeNoteConfigAgentChange(message: String) async throws -> RielaNoteConfigAgentProposal {
    throw SearchPaginationClientError.unsupported
  }

  func applyNoteConfigAgentProposal(
    _ proposal: RielaNoteConfigAgentProposal,
    workflowRoot: String
  ) async throws -> RielaNoteConfigAgentApplyResult {
    throw SearchPaginationClientError.unsupported
  }
}

private struct SearchRequest: Equatable {
  var query: String
  var tagFilter: [String]
  var classFilter: [String]
  var limit: Int
  var offset: Int
}

private enum SearchPaginationClientError: Error {
  case missingNote
  case unsupported
}
