import Foundation
import RielaNote
import XCTest

final class NoteServiceTests: NoteTestCase {
  func testCreateNoteDerivesTitleAndListShowsFirstNotePreview() throws {
    let service = try makeService()

    let note = try service.createNote(
      bodyMarkdown: """
      # Design Notes

      First paragraph of the note body.
      """,
      tags: [NoteTagInput(name: "ノート", classId: "document-kind")]
    )

    XCTAssertEqual(note.title, "Design Notes")
    XCTAssertEqual(note.noteNumber, 1)
    XCTAssertEqual(note.tags.map(\.tag.name), ["ノート"])

    let notebooks = try service.listNotebooks()
    XCTAssertEqual(notebooks.count, 1)
    XCTAssertEqual(notebooks.first?.title, "Design Notes")
    XCTAssertEqual(notebooks.first?.firstNotePreview?.contains("First paragraph"), true)
  }

  func testCreateNoteCanUseExplicitTitleWithoutRewritingBody() throws {
    let service = try makeService()

    let note = try service.createNote(title: "Explicit Title", bodyMarkdown: "Body without a heading")

    XCTAssertEqual(note.title, "Explicit Title")
    XCTAssertEqual(note.bodyMarkdown, "Body without a heading")
    XCTAssertEqual(try service.listNotebooks().first?.title, "Explicit Title")
  }

  func testUpdateNoteBodyDerivesTitleFromFirstLineWhenUpdatedBodyHasNoHeading() throws {
    let service = try makeService()
    let note = try service.createNote(title: "Explicit Title", bodyMarkdown: "Body without a heading")

    let updated = try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "Changed body without a heading")

    XCTAssertEqual(updated.title, "Changed body without a heading")
    XCTAssertEqual(updated.bodyMarkdown, "Changed body without a heading")
  }

  func testTitleDerivationSupportsHeadingLevelsFirstLineMarkersAndCap() throws {
    let service = try makeService()
    let h3 = try service.createNote(bodyMarkdown: "### Deep Heading\nBody")
    let list = try service.createNote(bodyMarkdown: "- List marker title\nBody")
    let longLine = String(repeating: "a", count: NoteTitleDerivation.fallbackTitleLimit + 10)
    let capped = try service.createNote(bodyMarkdown: "\(longLine)\nBody")
    let empty = try service.createNote(notebookTitle: "Fallback Notebook", bodyMarkdown: " \n ")

    XCTAssertEqual(h3.title, "Deep Heading")
    XCTAssertEqual(list.title, "List marker title")
    XCTAssertEqual(capped.title, String(longLine.prefix(NoteTitleDerivation.fallbackTitleLimit)))
    XCTAssertNil(empty.title)
    XCTAssertEqual(try service.getNotebook(empty.notebookId).title, "Fallback Notebook")
  }

  func testNoteTimestampsUseFractionalISO8601() throws {
    let service = try makeService()

    let note = try service.createNote(bodyMarkdown: "# Timestamped\nBody")
    let updated = try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "# Timestamped\nChanged")

    XCTAssertFractionalISO8601(note.createdAt)
    XCTAssertFractionalISO8601(note.updatedAt)
    XCTAssertFractionalISO8601(updated.updatedAt)
  }

  func testReadOnlyBlocksBodyEditAndDeleteButAllowsCommentsAndTags() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Locked\nBody", readOnly: true)

    XCTAssertThrowsError(try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "# Changed"))
    XCTAssertThrowsError(try service.deleteNote(noteId: note.noteId))

    let comment = try service.addComment(noteId: note.noteId, bodyMarkdown: "Still commentable")
    XCTAssertEqual(comment.bodyMarkdown, "Still commentable")

    let tagged = try service.applyTags(
      noteId: note.noteId,
      tags: [NoteTagInput(name: "reviewed", classId: "topic")],
      provenance: .human
    )
    XCTAssertEqual(tagged.tags.map(\.tag.name), ["reviewed"])
  }

  func testAITagsCannotOverwriteOrRemoveHumanTags() throws {
    let service = try makeService()
    let note = try service.createNote(
      bodyMarkdown: "# Tagged\nBody",
      tags: [NoteTagInput(name: "strategy", classId: "topic")],
      provenance: .human,
      assignedBy: "user"
    )

    let afterAIApply = try service.applyTags(
      noteId: note.noteId,
      tags: [NoteTagInput(name: "strategy", classId: "event")],
      provenance: .ai,
      assignedBy: "workflow-session"
    )
    let assignment = try XCTUnwrap(afterAIApply.tags.first)
    XCTAssertEqual(assignment.provenance, .human)
    XCTAssertEqual(assignment.assignedBy, "user")
    XCTAssertEqual(assignment.tag.classId, "topic")

    XCTAssertThrowsError(try service.removeTag(noteId: note.noteId, tagName: "strategy", removedBy: .ai))
    XCTAssertNoThrow(try service.removeTag(noteId: note.noteId, tagName: "strategy", removedBy: .human))
    XCTAssertTrue(try service.getNote(note.noteId).tags.isEmpty)
  }

  func testSearchReflectsCreateUpdateTagsAndDelete() throws {
    let service = try makeService()
    let note = try service.createNote(
      bodyMarkdown: "# Searchable\nAlpha beta knowledge",
      tags: [NoteTagInput(name: "research", classId: "topic")]
    )

    var results = try service.searchNotes(query: "Alpha", tagFilter: ["research"])
    XCTAssertEqual(results.map(\.note.noteId), [note.noteId])

    _ = try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "# Searchable\nGamma delta knowledge")
    XCTAssertTrue(try service.searchNotes(query: "Alpha").isEmpty)
    results = try service.searchNotes(query: "Gamma", classFilter: ["topic"])
    XCTAssertEqual(results.map(\.note.noteId), [note.noteId])

    try service.deleteNote(noteId: note.noteId)
    XCTAssertTrue(try service.searchNotes(query: "Gamma").isEmpty)
  }

  func testSearchSupportsOffsetPagination() throws {
    let service = try makeService()
    _ = try service.createNote(bodyMarkdown: "# First\n\nPaged search body")
    _ = try service.createNote(bodyMarkdown: "# Second\n\nPaged search body")
    _ = try service.createNote(bodyMarkdown: "# Third\n\nPaged search body")
    let allResults = try service.searchNotes(query: "Paged", limit: 3).map(\.note.noteId)

    XCTAssertEqual(
      try service.searchNotes(query: "Paged", limit: 2).map(\.note.noteId),
      Array(allResults.prefix(2))
    )
    XCTAssertEqual(
      try service.searchNotes(query: "Paged", limit: 2, offset: 2).map(\.note.noteId),
      Array(allResults.dropFirst(2))
    )
  }

  func testSearchSupportsSortDateAndLinkedExpansion() throws {
    let service = try makeService()
    let direct = try service.createNote(bodyMarkdown: "# Alpha\n\nShared planning term")
    let neighbor = try service.createNote(bodyMarkdown: "# Neighbor\n\nNo matching text")
    let unrelated = try service.createNote(bodyMarkdown: "# Unrelated\n\nShared planning term")
    _ = try service.linkNotes(from: direct.noteId, to: neighbor.noteId)

    let withoutLinked = try service.searchNotes(query: "planning", includeLinked: false, limit: 10)
    XCTAssertTrue(withoutLinked.map(\.note.noteId).contains(direct.noteId))
    XCTAssertFalse(withoutLinked.map(\.note.noteId).contains(neighbor.noteId))

    let withLinked = try service.searchNotes(query: "planning", includeLinked: true, limit: 10)
    XCTAssertTrue(withLinked.map(\.note.noteId).contains(neighbor.noteId))
    XCTAssertEqual(withLinked.first { $0.note.noteId == neighbor.noteId }?.isLinkedNeighbor, true)
    XCTAssertEqual(
      try service.searchNotes(query: "planning", sort: .title, limit: 10).map(\.note.noteId).prefix(2),
      [direct.noteId, unrelated.noteId]
    )
    XCTAssertTrue(try service.searchNotes(query: "", createdAfter: "2999-01-01T00:00:00.000Z").isEmpty)
  }

  func testProposeLinksExcludesExistingLinksAndSelf() throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\n\nProject roadmap planning")
    let candidate = try service.createNote(bodyMarkdown: "# Candidate\n\nRoadmap planning notes")
    let existing = try service.createNote(bodyMarkdown: "# Existing\n\nProject roadmap planning")
    _ = try service.linkNotes(from: subject.noteId, to: existing.noteId)

    let proposals = try service.proposeLinks(noteId: subject.noteId)

    XCTAssertEqual(proposals.map(\.targetNote.noteId), [candidate.noteId])
    XCTAssertEqual(proposals.first?.linkKind, "related")
    XCTAssertEqual(proposals.first?.source, "deterministic")
  }

  func testSearchDoesNotBackfillPartialFTSPageWithTextLikeScan() throws {
    let service = try makeService()
    let indexed = try service.createNote(bodyMarkdown: "# Indexed\n\nPartialOnly search body")
    let unindexed = try service.createNote(bodyMarkdown: "# Unindexed\n\nPartialOnly search body")
    try service.driver.withDatabase { database in
      try database.execute("DELETE FROM note_fts_map WHERE note_id = ?", bindings: [.text(unindexed.noteId)])
    }

    let results = try service.searchNotes(query: "PartialOnly", limit: 10).map(\.note.noteId)

    XCTAssertEqual(results, [indexed.noteId])
  }

  func testSearchFindsJapaneseSubstrings() throws {
    let service = try makeService()
    let note = try service.createNote(
      bodyMarkdown: "# 日本語ノート\nこれは日本語検索の検証です",
      tags: [NoteTagInput(name: "知識管理", classId: "topic")]
    )

    XCTAssertEqual(try service.searchNotes(query: "日本語検索").map(\.note.noteId), [note.noteId])
    XCTAssertEqual(try service.searchNotes(query: "検索").map(\.note.noteId), [note.noteId])
    XCTAssertEqual(try service.searchNotes(query: "知識").map(\.note.noteId), [note.noteId])
  }

  func testFTSRefreshUsesStableTagPayloadOrderForUpdateAndDelete() throws {
    let service = try makeService()
    let note = try service.createNote(
      bodyMarkdown: "# Indexed\nObsolete body",
      tags: [
        NoteTagInput(name: "zeta", classId: "topic"),
        NoteTagInput(name: "alpha", classId: "topic")
      ]
    )

    _ = try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "# Indexed\nBeta body")
    try assertFTSIntegrity(service)
    XCTAssertTrue(try service.searchNotes(query: "Obsolete").isEmpty)
    XCTAssertEqual(try service.searchNotes(query: "Beta", tagFilter: ["alpha"]).map(\.note.noteId), [note.noteId])

    try service.deleteNote(noteId: note.noteId)
    try assertFTSIntegrity(service)
    XCTAssertTrue(try service.searchNotes(query: "Beta").isEmpty)
  }

  func testSystemAndNonDeletableTagAssignmentsCannotBeDemotedByLaterApply() throws {
    let service = try makeService()
    let note = try service.createNote(
      bodyMarkdown: "# Tagged\nBody",
      tags: [NoteTagInput(name: "system-topic", classId: "topic")],
      provenance: .system,
      assignedBy: "riela-note"
    )

    try service.driver.withDatabase { database in
      try database.execute(
        """
        UPDATE note_tags
        SET deletable = 0
        WHERE note_id = ?
          AND tag_id = (SELECT tag_id FROM tags WHERE name = 'system-topic')
        """,
        bindings: [.text(note.noteId)]
      )
    }

    _ = try service.applyTags(noteId: note.noteId, tags: [NoteTagInput(name: "system-topic")], provenance: .human)
    let assignment = try XCTUnwrap(try service.getNote(note.noteId).tags.first { $0.tag.name == "system-topic" })
    XCTAssertEqual(assignment.provenance, .system)
    XCTAssertEqual(assignment.assignedBy, "riela-note")
    XCTAssertFalse(assignment.deletable)
  }

  func testApplyTagRejectsUnknownClassId() throws {
    let service = try makeService()

    XCTAssertThrowsError(try service.createNote(
      bodyMarkdown: "# Dangling\nBody",
      tags: [NoteTagInput(name: "dangling", classId: "missing-class")]
    )) { error in
      XCTAssertEqual(error as? NoteServiceError, .notFound("tag class not found: missing-class"))
    }
  }

  func testDefineTagClassAndTagForConfigAgent() throws {
    let service = try makeService()

    let tagClass = try service.defineTagClass(
      classId: "business-idea",
      label: "Business Idea",
      description: "Opportunity notes"
    )
    let tag = try service.defineTag(name: "business-idea", classId: tagClass.classId)

    XCTAssertEqual(tagClass.classId, "business-idea")
    XCTAssertEqual(tag.classId, "business-idea")
    XCTAssertTrue(try service.listTagClasses().contains(tagClass))
    XCTAssertTrue(try service.listTags().contains(tag))
  }

  func testScaffoldIngestionWorkflowWritesPortableBundle() throws {
    let root = URL(fileURLWithPath: try makeNoteRoot(function: #function), isDirectory: true)
      .appendingPathComponent("workflows", isDirectory: true)
    let scaffold = try NoteIngestionWorkflowScaffolder().scaffold(
      workflowRoot: root.path,
      workflowId: "note-ingest-business-idea"
    )

    XCTAssertEqual(scaffold.workflowId, "note-ingest-business-idea")
    XCTAssertEqual(scaffold.files.map(\.relativePath).sorted(), [
      "nodes/node-workflow-output.json",
      "workflow.json"
    ])
    XCTAssertTrue(FileManager.default.fileExists(atPath: scaffold.workflowPath))
    let workflowData = try Data(contentsOf: URL(fileURLWithPath: scaffold.workflowPath))
    let workflow = try XCTUnwrap(JSONSerialization.jsonObject(with: workflowData) as? [String: Any])
    let nodes = try XCTUnwrap(workflow["nodes"] as? [[String: Any]])
    let addon = try XCTUnwrap(nodes.first?["addon"] as? [String: Any])
    XCTAssertEqual(addon["name"] as? String, "riela/notebook-ingest-pages")
  }

  func testNotebookKindTagsAreNonDeletableSystemTags() throws {
    let service = try makeService()
    let notebook = try service.createNotebook(
      title: "Imported PDF",
      kindTagName: "notebook-kind:imported-material"
    )

    XCTAssertEqual(notebook.tags.first?.tag.name, "notebook-kind:imported-material")
    XCTAssertEqual(notebook.tags.first?.provenance, .system)
    XCTAssertEqual(notebook.tags.first?.deletable, false)
  }

  func testAttachNotebookFileFromURLStoresSourceDocument() throws {
    let service = try makeService()
    let notebook = try service.createNotebook(title: "Imported PDF")
    let source = URL(fileURLWithPath: service.noteRootPath(), isDirectory: true)
      .appendingPathComponent("source.pdf")
    let sourceData = Data("%PDF-1.4 source".utf8)
    try sourceData.write(to: source)

    let attachment = try service.attachNotebookFile(
      notebookId: notebook.notebookId,
      fileURL: source,
      role: .sourceDocument,
      mediaType: "application/pdf",
      originalFilename: "source.pdf"
    )

    XCTAssertEqual(attachment.role, .sourceDocument)
    XCTAssertEqual(attachment.file.mediaType, "application/pdf")
    XCTAssertEqual(attachment.file.originalFilename, "source.pdf")
    XCTAssertEqual(try service.listFiles(notebookId: notebook.notebookId), [attachment])
    XCTAssertEqual(try service.resolveFileContent(fileId: attachment.file.fileId), sourceData)
  }

  func testNotebookKindTagIdsDoNotCollideForPrefixedAndUnprefixedNames() throws {
    let service = try makeService()

    let plain = try service.createNotebook(title: "Plain Kind", kindTagName: "foo")
    let prefixed = try service.createNotebook(title: "Prefixed Kind", kindTagName: "notebook-kind:foo")

    let plainTag = try XCTUnwrap(plain.tags.first?.tag)
    let prefixedTag = try XCTUnwrap(prefixed.tags.first?.tag)
    XCTAssertEqual(plainTag.name, "foo")
    XCTAssertEqual(prefixedTag.name, "notebook-kind:foo")
    XCTAssertNotEqual(plainTag.tagId, prefixedTag.tagId)
    XCTAssertEqual(try service.listTags().filter { ["foo", "notebook-kind:foo"].contains($0.name) }.count, 2)
  }

  func testListNotebooksFiltersByNotebookTags() throws {
    let service = try makeService()
    let imported = try service.createNotebook(
      title: "Imported PDF",
      kindTagName: "notebook-kind:imported-material"
    )
    let memo = try service.createNotebook(
      title: "Daily Memo",
      kindTagName: "notebook-kind:user-memo"
    )

    XCTAssertEqual(try service.listNotebooks(tagFilter: ["notebook-kind:imported-material"]).map(\.notebookId), [
      imported.notebookId
    ])
    XCTAssertEqual(try service.listNotebooks(tagFilter: ["notebook-kind:user-memo"]).map(\.notebookId), [
      memo.notebookId
    ])
    XCTAssertTrue(try service.listNotebooks(tagFilter: ["notebook-kind:missing"]).isEmpty)
  }

  func testNotebookTagsCanBeAppliedAndRemovedAfterCreation() throws {
    let service = try makeService()
    let notebook = try service.createNotebook(title: "Working Set")

    let tagged = try service.applyNotebookTags(
      notebookId: notebook.notebookId,
      tags: ["active-project"],
      provenance: .human,
      assignedBy: "tester"
    )
    XCTAssertEqual(tagged.tags.map(\.tag.name), ["active-project"])
    XCTAssertEqual(try service.listNotebooks(tagFilter: ["active-project"]).map(\.notebookId), [notebook.notebookId])

    XCTAssertThrowsError(try service.removeNotebookTag(
      notebookId: notebook.notebookId,
      tagName: "active-project",
      removedBy: .ai
    )) { error in
      XCTAssertEqual(error as? NoteServiceError, .protectedTag("active-project"))
    }

    let untagged = try service.removeNotebookTag(
      notebookId: notebook.notebookId,
      tagName: "active-project",
      removedBy: .human
    )
    XCTAssertTrue(untagged.tags.isEmpty)
    XCTAssertTrue(try service.listNotebooks(tagFilter: ["active-project"]).isEmpty)
  }

  func testSystemNotebookKindTagsRemainProtectedAfterCreation() throws {
    let service = try makeService()
    let notebook = try service.createNotebook(
      title: "Imported PDF",
      kindTagName: "notebook-kind:imported-material"
    )

    XCTAssertThrowsError(try service.removeNotebookTag(
      notebookId: notebook.notebookId,
      tagName: "notebook-kind:imported-material",
      removedBy: .human
    )) { error in
      XCTAssertEqual(error as? NoteServiceError, .protectedTag("notebook-kind:imported-material"))
    }
  }

  func testCreateNotebookWithNotesStoresPagesAtomically() throws {
    let service = try makeService()

    let result = try service.createNotebookWithNotes(
      title: "Imported Packet",
      kindTagName: "notebook-kind:imported-material",
      metaJSON: #"{"sourceDocumentRef":"file:///packet.pdf"}"#,
      pages: [
        NotePageDraft(
          bodyMarkdown: "# Page One\n\nAlpha OCR",
          tags: [NoteTagInput(name: "ocr", classId: "topic")],
          noteNumber: 10
        ),
        NotePageDraft(
          bodyMarkdown: "# Page Two\n\nBeta OCR",
          tags: [NoteTagInput(name: "ocr", classId: "topic")],
          noteNumber: 20
        )
      ],
      assignedBy: "ingest-workflow"
    )

    XCTAssertEqual(result.notebook.title, "Imported Packet")
    XCTAssertEqual(result.notebook.tags.first?.tag.name, "notebook-kind:imported-material")
    XCTAssertEqual(result.notes.map(\.noteNumber), [10, 20])
    XCTAssertEqual(result.notes.map(\.readOnly), [true, true])
    XCTAssertEqual(result.notes.flatMap(\.tags).map(\.assignedBy), ["ingest-workflow", "ingest-workflow"])
    XCTAssertEqual(try service.searchNotes(query: "Alpha OCR").map(\.note.noteId), [result.notes[0].noteId])
    XCTAssertEqual(try service.searchNotes(query: "Beta OCR").map(\.note.noteId), [result.notes[1].noteId])
  }

  func testCreateNotebookWithNotesRejectsDuplicateExplicitPageNumbers() throws {
    let service = try makeService()

    XCTAssertThrowsError(try service.createNotebookWithNotes(
      title: "Broken Packet",
      pages: [
        NotePageDraft(bodyMarkdown: "# Page One\n\nAlpha", noteNumber: 3),
        NotePageDraft(bodyMarkdown: "# Page Two\n\nBeta", noteNumber: 3)
      ]
    )) { error in
      XCTAssertEqual(error as? NoteServiceError, .invalidInput("notebook ingest page numbers must be unique"))
    }

    XCTAssertTrue(try service.listNotebooks().isEmpty)
  }

  func testCreateNotebookWithNotesRollsBackWhenAnyPageFails() throws {
    let service = try makeService()

    XCTAssertThrowsError(try service.createNotebookWithNotes(
      title: "Broken Packet",
      kindTagName: "notebook-kind:imported-material",
      pages: [
        NotePageDraft(bodyMarkdown: "# Page One\n\nShould not remain"),
        NotePageDraft(bodyMarkdown: "# Page Two\n\nInvalid metadata", metaJSON: "{")
      ]
    ))

    XCTAssertTrue(try service.listNotebooks().isEmpty)
    XCTAssertTrue(try service.searchNotes(query: "Should not remain").isEmpty)
  }

  func testLinksAndCommentsAreAllowedForReadOnlyNotes() throws {
    let service = try makeService()
    let source = try service.createNote(bodyMarkdown: "# Source\nFacts", readOnly: true)
    let target = try service.createNote(bodyMarkdown: "# Target\nContext")

    let link = try service.linkNotes(from: source.noteId, to: target.noteId, provenance: .human)
    let comment = try service.addComment(noteId: source.noteId, bodyMarkdown: "Metadata is still allowed")

    XCTAssertEqual(link.fromNoteId, source.noteId)
    XCTAssertEqual(link.toNoteId, target.noteId)
    XCTAssertEqual(try service.listLinks(noteId: source.noteId), [link])
    XCTAssertEqual(try service.listComments(noteId: source.noteId).map(\.commentId), [comment.commentId])
  }

  func testAILinkCannotOverwriteHumanLinkProvenance() throws {
    let service = try makeService()
    let source = try service.createNote(bodyMarkdown: "# Source\nFacts")
    let target = try service.createNote(bodyMarkdown: "# Target\nContext")

    let human = try service.linkNotes(from: source.noteId, to: target.noteId, provenance: .human)
    let afterAI = try service.linkNotes(from: source.noteId, to: target.noteId, provenance: .ai)

    XCTAssertEqual(afterAI.provenance, .human)
    XCTAssertEqual(afterAI.createdAt, human.createdAt)
    XCTAssertEqual(try service.listLinks(noteId: source.noteId), [human])
  }

  func testHumanLinkCanPromoteAILinkProvenance() throws {
    let service = try makeService()
    let source = try service.createNote(bodyMarkdown: "# Source\nFacts")
    let target = try service.createNote(bodyMarkdown: "# Target\nContext")

    _ = try service.linkNotes(from: source.noteId, to: target.noteId, provenance: .ai)
    let afterHuman = try service.linkNotes(from: source.noteId, to: target.noteId, provenance: .human)

    XCTAssertEqual(afterHuman.provenance, .human)
    XCTAssertEqual(try service.listLinks(noteId: source.noteId).map(\.provenance), [.human])
  }

  func testSaveConversationCreatesConversationNotebookAndCitationLinks() throws {
    let service = try makeService()
    let cited = try service.createNote(bodyMarkdown: "# Cited\nImportant source")

    let saved = try service.saveConversation(
      title: "Agent Chat",
      transcript: [
        NoteConversationTurn(
          userMarkdown: "What matters here?",
          assistantMarkdown: "The cited note matters.",
          sourceNoteIds: [cited.noteId]
        ),
        NoteConversationTurn(userMarkdown: "Anything else?", assistantMarkdown: "No.")
      ],
      assignedBy: "agent-session-1"
    )

    XCTAssertEqual(saved.notebook.title, "Agent Chat")
    XCTAssertEqual(saved.notebook.tags.first?.tag.name, "notebook-kind:agent-conversation")
    XCTAssertEqual(saved.notebook.tags.first?.deletable, false)
    XCTAssertEqual(saved.notes.map(\.noteNumber), [1, 2])
    XCTAssertEqual(saved.notes.first?.title, "Conversation Turn 1")
    XCTAssertEqual(saved.notes.first?.bodyMarkdown.contains("## Agent"), true)

    let links = try service.listLinks(noteId: saved.notes[0].noteId)
    XCTAssertEqual(links.count, 1)
    XCTAssertEqual(links.first?.toNoteId, cited.noteId)
    XCTAssertEqual(links.first?.linkKind, "source-citation")
    XCTAssertEqual(links.first?.provenance, .system)
  }
}

func makeService(function: String = #function) throws -> NoteService {
  try NoteService(driver: try makeNoteDriver(function: function))
}

private func assertFTSIntegrity(_ service: NoteService, file: StaticString = #filePath, line: UInt = #line) throws {
  do {
    try service.driver.withDatabase { database in
      try database.execute("INSERT INTO note_fts(note_fts) VALUES('integrity-check')")
    }
  } catch {
    XCTFail("FTS integrity check failed: \(error)", file: file, line: line)
    throw error
  }
}

private func XCTAssertFractionalISO8601(
  _ value: String,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  XCTAssertNotNil(value.range(of: #"\.\d+Z$"#, options: .regularExpression), file: file, line: line)
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  XCTAssertNotNil(formatter.date(from: value), file: file, line: line)
}
