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
