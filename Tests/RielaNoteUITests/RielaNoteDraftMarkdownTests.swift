import RielaNote
@testable import RielaNoteUI
import XCTest

final class RielaNoteDraftMarkdownTests: XCTestCase {
  func testTitleDerivationUsesHeadingOrFirstLineWithoutRewritingBody() {
    XCTAssertEqual(NoteTitleDerivation.title(from: "### Reading Notes\n\nFirst pass."), "Reading Notes")
    XCTAssertEqual(NoteTitleDerivation.title(from: "- First pass without heading"), "First pass without heading")
    XCTAssertNil(NoteTitleDerivation.title(from: " \n "))
  }

  func testBodyDraftStateKeepsUnsavedDraftWhenTogglingPreview() {
    var state = RielaNoteBodyDraftState()
    let note = Note(
      noteId: "note-1",
      notebookId: "notebook-1",
      noteNumber: 1,
      title: "Drafted",
      bodyMarkdown: "Persisted body",
      readOnly: false,
      createdAt: "2026-07-05T00:00:00Z",
      updatedAt: "2026-07-05T00:00:00Z"
    )

    state.toggle(noteId: note.noteId, bodyMarkdown: note.bodyMarkdown)
    state.draftBodyMarkdown = "Unsaved body"
    state.toggle(noteId: note.noteId, bodyMarkdown: note.bodyMarkdown)

    XCTAssertFalse(state.isEditingBody)
    XCTAssertEqual(state.previewBodyMarkdown(for: note), "Unsaved body")

    state.toggle(noteId: note.noteId, bodyMarkdown: note.bodyMarkdown)
    XCTAssertTrue(state.isEditingBody)
    XCTAssertEqual(state.draftBodyMarkdown, "Unsaved body")
  }

  func testBodyDraftStateStartsViewFirst() {
    let state = RielaNoteBodyDraftState()
    let note = Note(
      noteId: "note-1",
      notebookId: "notebook-1",
      noteNumber: 1,
      title: "Readable",
      bodyMarkdown: "Persisted body",
      readOnly: false,
      createdAt: "2026-07-05T00:00:00Z",
      updatedAt: "2026-07-05T00:00:00Z"
    )

    XCTAssertFalse(state.isEditingBody)
    XCTAssertNil(state.editingNoteId)
    XCTAssertEqual(state.previewBodyMarkdown(for: note), "Persisted body")
  }

  func testMarkdownBlockParserPreservesBlocksAndStripsDisplayMarkers() {
    let blocks = RielaNoteMarkdownBlock.parse(
      """
      # Heading ##

      first line
      second line

      - item one
      - item two

      > quoted
      > text

      ```swift
      let value = "# not heading"
      ``` info
      still code
      ```
      """
    )

    XCTAssertEqual(blocks[0], RielaNoteMarkdownBlock(kind: .heading(level: 1), text: "Heading"))
    XCTAssertEqual(blocks[1], RielaNoteMarkdownBlock(kind: .paragraph, text: "first line\nsecond line"))
    XCTAssertEqual(blocks[2], RielaNoteMarkdownBlock(kind: .list, text: "item one\nitem two"))
    XCTAssertEqual(blocks[3], RielaNoteMarkdownBlock(kind: .quote, text: "quoted\ntext"))
    XCTAssertEqual(
      blocks[4],
      RielaNoteMarkdownBlock(kind: .code, text: "let value = \"# not heading\"\n``` info\nstill code")
    )
  }

  func testMarkdownBlockParserKeepsUnclosedFenceAsCode() {
    let blocks = RielaNoteMarkdownBlock.parse(
      """
      intro

      ~~~
      code
      """
    )

    XCTAssertEqual(blocks.map(\.kind), [.paragraph, .code])
    XCTAssertEqual(blocks.last?.text, "code")
  }
}
