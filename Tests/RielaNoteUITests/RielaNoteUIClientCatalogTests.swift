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
}

private func makeCatalogTestService(function: String = #function) throws -> NoteService {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tmp/RielaNoteUIClientCatalogTests", isDirectory: true)
    .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
}
