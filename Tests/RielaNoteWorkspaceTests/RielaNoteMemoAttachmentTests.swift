import Foundation
import RielaNote
@testable import RielaNoteWorkspace
import XCTest

@MainActor
final class RielaNoteMemoAttachmentTests: XCTestCase {
  func testCreateUserMemoAppliesSystemNonDeletableKindTag() async throws {
    let service = try makeMemoTestService()
    let client = NoteServiceRielaNoteUIClient(service: service)

    let detail = try await client.createUserMemo(bodyMarkdown: "# Memo\nBody")

    let notebook = try service.getNotebook(detail.note.notebookId)
    let kindTag = notebook.tags.first { $0.tag.name == "notebook-kind:user-memo" }
    XCTAssertNotNil(kindTag, "createUserMemo must seed the user-memo notebook kind tag")
    XCTAssertEqual(kindTag?.provenance, .system)
    XCTAssertFalse(kindTag?.deletable ?? true)

    let filtered = try service.listNotebooks(tagFilter: ["notebook-kind:user-memo"])
    XCTAssertEqual(filtered.map(\.notebookId), [detail.note.notebookId])
  }
}

private func makeMemoTestService(function: String = #function) throws -> NoteService {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tmp/RielaNoteMemoAttachmentTests", isDirectory: true)
    .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
}
