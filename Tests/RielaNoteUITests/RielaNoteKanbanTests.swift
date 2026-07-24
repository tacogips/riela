import Foundation
import RielaNote
@testable import RielaNoteUI
import XCTest

@MainActor
final class RielaNoteKanbanTests: XCTestCase {
  func testActiveParentTagLoadsDescendantNotebooksAndGroupsByProgress() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/RielaNoteKanbanTests", isDirectory: true)
      .appendingPathComponent(#function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let parent = try service.defineTag(name: "portfolio")
    let child = try service.defineTag(name: "project", parentTagId: parent.tagId)
    let active = try service.createNotebook(title: "Active")
    let pending = try service.createNotebook(title: "Pending")
    _ = try service.applyNotebookTags(
      notebookId: active.notebookId,
      tags: [child.name],
      provenance: .human
    )
    _ = try service.applyNotebookTags(
      notebookId: pending.notebookId,
      tags: [child.name],
      provenance: .human
    )
    _ = try service.setNotebookProgress(notebookId: active.notebookId, progress: .progress)
    _ = try service.setNotebookProgress(notebookId: pending.notebookId, progress: .pending)
    let viewModel = RielaNoteLibraryViewModel(
      client: NoteServiceRielaNoteUIClient(service: service),
      notebookLimit: 10
    )

    await viewModel.load()
    await viewModel.toggleSearchTag(parent.name)

    XCTAssertTrue(viewModel.isTagKanbanActive)
    XCTAssertEqual(viewModel.notebooks(for: .progress).map(\.notebookId), [active.notebookId])
    XCTAssertEqual(viewModel.notebooks(for: .pending).map(\.notebookId), [pending.notebookId])
    XCTAssertEqual(
      RielaNoteSearchPopupSheet(viewModel: viewModel, onClose: {}).contentMode,
      .tagKanban
    )

    await viewModel.setNotebookProgress(notebookId: active.notebookId, progress: .done)

    XCTAssertTrue(viewModel.notebooks(for: .progress).isEmpty)
    XCTAssertEqual(viewModel.notebooks(for: .done).map(\.notebookId), [active.notebookId])
    XCTAssertEqual(try service.getNotebook(active.notebookId).progress, .done)
  }

  func testFailedProgressMutationPreservesPriorGrouping() async {
    let fixture = NoteUITestFixture()
    let client = FailingRielaNoteUIClient(base: fixture.client)
    let viewModel = RielaNoteLibraryViewModel(client: client)
    await viewModel.load()
    viewModel.selectedSearchTagNames = ["portfolio"]
    client.failSetNotebookProgress = true

    await viewModel.setNotebookProgress(
      notebookId: fixture.notebook.notebookId,
      progress: .done
    )

    XCTAssertEqual(
      viewModel.notebooks(for: .none).map(\.notebookId),
      [fixture.notebook.notebookId]
    )
    XCTAssertTrue(viewModel.notebooks(for: .done).isEmpty)
    guard case let .failed(message) = viewModel.state else {
      return XCTFail("expected the failed mutation to surface through view-model state")
    }
    XCTAssertEqual(
      RielaNoteSearchPopupSheet(viewModel: viewModel, onClose: {}).contentMode,
      .tagKanbanFailed(message)
    )
  }
}
