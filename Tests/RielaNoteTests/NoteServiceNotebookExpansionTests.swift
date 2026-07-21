import Foundation
import RielaNote
import XCTest

final class NoteServiceNotebookExpansionTests: NoteTestCase {
  func testCompactMetadataPreservesSiblingsAndSourceUpdatedAt() throws {
    let service = try makeService()
    let notebook = try service.createNotebook(
      title: "Plan",
      metaJSON: #"{"other":{"keep":true},"rielaNote":{"existing":"value"}}"#
    )
    _ = try service.createNote(notebookId: notebook.notebookId, bodyMarkdown: "# Milestone\nDraft it.")
    let before = try service.getNotebookForExpansion(notebook.notebookId)

    let updated = try service.updateNotebookCompactMetadata(
      notebookId: notebook.notebookId,
      compactMetadataJSON: #"{"version":1,"summaryMarkdown":"- Draft it","computedAt":"2026-07-21T00:00:00.000Z","sourceNoteIds":["note-1"],"source":{"updatedAt":"marker","noteCount":1}}"#
    )

    XCTAssertEqual(updated.updatedAt, before.updatedAt)
    let root = try XCTUnwrap(jsonObject(updated.metaJSON))
    XCTAssertEqual((root["other"] as? [String: Any])?["keep"] as? Bool, true)
    XCTAssertEqual((root["rielaNote"] as? [String: Any])?["existing"] as? String, "value")
    XCTAssertNotNil((root["rielaNote"] as? [String: Any])?["notebookCompact"])
  }

  func testCompactMetadataRejectsNonObjectJSONWithoutMutation() throws {
    let service = try makeService()
    let notebook = try service.createNotebook(title: "Plan", metaJSON: #"{"keep":true}"#)

    XCTAssertThrowsError(try service.updateNotebookCompactMetadata(
      notebookId: notebook.notebookId,
      compactMetadataJSON: "[]"
    ))
    XCTAssertEqual(try service.getNotebook(notebook.notebookId).metaJSON, notebook.metaJSON)
  }

  func testCompactMetadataRejectsNonObjectRielaNoteNamespaceWithoutMutation() throws {
    let service = try makeService()
    let notebook = try service.createNotebook(
      title: "Plan",
      metaJSON: #"{"keep":true,"rielaNote":"reserved-user-value"}"#
    )

    XCTAssertThrowsError(try service.updateNotebookCompactMetadata(
      notebookId: notebook.notebookId,
      compactMetadataJSON: #"{"version":1}"#
    ))

    XCTAssertEqual(try service.getNotebook(notebook.notebookId).metaJSON, notebook.metaJSON)
  }

  func testConversationSourceLinksAreAIProvenanceAndAtomic() throws {
    let service = try makeService()
    let source = try service.createNotebookWithNotes(
      title: "Source",
      pages: [
        NotePageDraft(bodyMarkdown: "# One\nFirst"),
        NotePageDraft(bodyMarkdown: "# Two\nSecond")
      ]
    )
    let sourceIds = source.notes.map(\.noteId)
    let saved = try service.saveConversation(
      title: "Expansion",
      transcript: [NoteConversationTurn(userMarkdown: "Expand", assistantMarkdown: "- Summary")],
      notebookMetaJSON: #"{"rielaNote":{"notebookExpansion":{"version":1}}}"#,
      sourceLinks: NoteConversationSourceLinks(sourceNoteIds: sourceIds),
      assignedBy: "test"
    )
    let seed = try XCTUnwrap(saved.notes.first)
    let seedLinks = try service.listLinks(noteId: seed.noteId)

    XCTAssertEqual(Set(seedLinks.map(\.toNoteId)), Set(sourceIds))
    XCTAssertTrue(seedLinks.allSatisfy { $0.linkKind == "source-citation" && $0.provenance == .ai })
    XCTAssertNotNil(saved.notebook.metaJSON)

    let later = try service.appendConversationTurn(
      notebookId: saved.notebook.notebookId,
      turn: NoteConversationTurn(userMarkdown: "Next?", assistantMarkdown: "Do it."),
      sourceLinks: NoteConversationSourceLinks(sourceNoteIds: sourceIds)
    )
    XCTAssertEqual(Set(try service.listLinks(noteId: later.noteId).map(\.toNoteId)), Set(sourceIds))

    let notebookCount = try service.listNotebooks(limit: 100).count
    XCTAssertThrowsError(try service.saveConversation(
      title: "Broken",
      transcript: [NoteConversationTurn(userMarkdown: "Q", assistantMarkdown: "A")],
      sourceLinks: NoteConversationSourceLinks(sourceNoteIds: ["missing-note"])
    ))
    XCTAssertEqual(try service.listNotebooks(limit: 100).count, notebookCount)
  }

  private func jsonObject(_ json: String?) -> [String: Any]? {
    guard let json, let data = json.data(using: .utf8) else {
      return nil
    }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }
}
