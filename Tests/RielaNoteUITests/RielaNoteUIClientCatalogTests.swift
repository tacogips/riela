import Foundation
import RielaNote
@testable import RielaNoteUI
import XCTest

@MainActor
final class RielaNoteUIClientCatalogTests: XCTestCase {
  func testNoteServiceClientListsTagClassesForSearchFilters() async throws {
    let service = try makeCatalogTestService()
    let client = NoteServiceRielaNoteUIClient(service: service)

    let tagClasses = try await client.listTagClasses()

    XCTAssertTrue(tagClasses.contains { $0.classId == "topic" })
    XCTAssertTrue(tagClasses.contains { $0.classId == "person" })
  }

  func testNoteServiceClientUsesWorkflowLinkProposalProviderWhenConfigured() async throws {
    let service = try makeCatalogTestService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\n\nRoadmap planning")
    let target = try service.createNote(bodyMarkdown: "# Target\n\nRelated roadmap context")
    let client = NoteServiceRielaNoteUIClient(
      service: service,
      linkProposalProvider: StaticLinkProposalProvider(drafts: [
        RielaNoteLinkProposalDraft(targetNoteId: target.noteId, reason: "Workflow selected this candidate.")
      ])
    )

    let proposals = try await client.proposeNoteLinks(noteId: subject.noteId)

    XCTAssertEqual(proposals.map(\.targetNote.noteId), [target.noteId])
    XCTAssertEqual(proposals.first?.source, "workflow")
    XCTAssertEqual(proposals.first?.reason, "Workflow selected this candidate.")
  }

  func testNoteServiceClientForwardsTagFilterPaginationAndProgressMutation() async throws {
    let service = try makeCatalogTestService()
    let parent = try service.defineTag(name: "portfolio")
    let child = try service.defineTag(name: "project", parentTagId: parent.tagId)
    let first = try service.createNotebook(title: "First")
    let second = try service.createNotebook(title: "Second")
    _ = try service.applyNotebookTags(
      notebookId: first.notebookId,
      tags: [child.name],
      provenance: .human
    )
    _ = try service.applyNotebookTags(
      notebookId: second.notebookId,
      tags: [child.name],
      provenance: .human
    )
    let client = NoteServiceRielaNoteUIClient(service: service)
    let all = try await client.listNotebooks(
      limit: 10,
      offset: 0,
      tagFilter: [parent.name],
      filter: RielaNoteListFilter()
    )
    let page = try await client.listNotebooks(
      limit: 1,
      offset: 1,
      tagFilter: [parent.name],
      filter: RielaNoteListFilter()
    )

    XCTAssertEqual(Set(all.map(\.notebookId)), Set([first.notebookId, second.notebookId]))
    XCTAssertEqual(page.map(\.notebookId), Array(all.dropFirst().prefix(1)).map(\.notebookId))
    let updated = try await client.setNotebookProgress(
      notebookId: first.notebookId,
      progress: .pending
    )
    XCTAssertEqual(updated.progress, .pending)
  }

  func testLegacyClientTagFilterFallbackFailsClosed() async throws {
    let fixture = NoteUITestFixture()
    let legacyClient = FailingRielaNoteUIClient(base: fixture.client)

    let unfiltered = try await legacyClient.listNotebooks(
      limit: 10,
      offset: 0,
      tagFilter: [],
      filter: RielaNoteListFilter()
    )

    XCTAssertEqual(unfiltered.map(\.notebookId), [fixture.notebook.notebookId])
    do {
      _ = try await legacyClient.listNotebooks(
        limit: 10,
        offset: 0,
        tagFilter: ["portfolio"],
        filter: RielaNoteListFilter()
      )
      XCTFail("expected a nonempty tag filter to fail closed")
    } catch {
      XCTAssertEqual(
        error as? RielaNoteUIClientCapabilityError,
        .notebookTagFilterUnsupported
      )
    }
  }
}

private struct StaticLinkProposalProvider: RielaNoteLinkProposalProviding {
  var drafts: [RielaNoteLinkProposalDraft]

  func proposeLinkDrafts(noteId: String, noteRoot: String, query: String, limit: Int) async throws
    -> [RielaNoteLinkProposalDraft] {
    drafts
  }
}

private func makeCatalogTestService(function: String = #function) throws -> NoteService {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tmp/RielaNoteUIClientCatalogTests", isDirectory: true)
    .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
}
