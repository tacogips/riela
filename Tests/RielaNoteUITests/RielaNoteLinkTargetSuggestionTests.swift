import RielaNote
@testable import RielaNoteUI
import XCTest

final class RielaNoteLinkTargetSuggestionTests: XCTestCase {
  func testSearchLinkResultsPreserveFullTextMatchesAndSearchRanking() {
    let current = Self.note(noteId: "note-current", title: "Current")
    let bodyOnlyMatch = Self.note(noteId: "note-body", title: "Unrelated title")
    let titleMatch = Self.note(noteId: "note-title", title: "Roadmap")
    let existing = Self.note(noteId: "note-existing", title: "Existing")
    let link = NoteLink(
      fromNoteId: current.noteId,
      toNoteId: existing.noteId,
      linkKind: "related",
      provenance: .human,
      createdAt: "2026-07-04T00:00:00Z"
    )

    let results = [
      NoteSearchResult(note: current, snippet: "self", rank: 0, matchedTags: []),
      NoteSearchResult(note: bodyOnlyMatch, snippet: "roadmap appears only in body", rank: 1, matchedTags: []),
      NoteSearchResult(note: existing, snippet: "already linked", rank: 2, matchedTags: []),
      NoteSearchResult(note: titleMatch, snippet: "title match", rank: 3, matchedTags: []),
      NoteSearchResult(note: bodyOnlyMatch, snippet: "duplicate", rank: 4, matchedTags: [])
    ]

    let filtered = rielaNoteSearchLinkResults(
      results,
      currentNoteId: current.noteId,
      existingLinks: [link]
    )

    XCTAssertEqual(filtered.map(\.note.noteId), [bodyOnlyMatch.noteId, titleMatch.noteId])
  }

  func testLinkIconDistinguishesSourceCitations() {
    XCTAssertEqual(rielaNoteLinkIconName("source-citation"), "quote.bubble")
    XCTAssertEqual(rielaNoteLinkIconName("related"), "link")
  }

  private static func note(noteId: String, title: String) -> Note {
    Note(
      noteId: noteId,
      notebookId: "notebook-1",
      noteNumber: 1,
      title: title,
      bodyMarkdown: "# \(title)",
      readOnly: false,
      createdAt: "2026-07-04T00:00:00Z",
      updatedAt: "2026-07-04T00:00:00Z"
    )
  }
}
