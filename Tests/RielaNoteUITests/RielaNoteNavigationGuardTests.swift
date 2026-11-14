import Foundation
import RielaNote
@testable import RielaNoteUI
import XCTest

/// FIX-1 (T5): while a body edit is in progress, every note/notebook selection
/// path routes through `requestSelection` and defers behind the discard
/// confirmation. Only Discard (`confirmPendingSelection`) navigates; Keep editing
/// (`cancelPendingSelection`) leaves the selection untouched.
@MainActor
final class RielaNoteNavigationGuardTests: XCTestCase {
  func testRequestSelectionNavigatesImmediatelyWhenNotEditing() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)
    await viewModel.selectNote("note-1")

    await viewModel.requestSelection(.note("note-2"))

    XCTAssertNil(viewModel.pendingSelection)
    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-2")
  }

  func testRequestSelectionNoOpsForAlreadySelectedNote() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)
    await viewModel.selectNote("note-1")
    fixture.client.noteDetailRequests.removeAll()

    await viewModel.requestSelection(.note("note-1"))

    XCTAssertNil(viewModel.pendingSelection)
    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-1")
    XCTAssertTrue(fixture.client.noteDetailRequests.isEmpty)
  }

  func testRequestSelectionDefersWhileEditing() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)
    await viewModel.selectNote("note-1")
    viewModel.setEditingBody(true)

    await viewModel.requestSelection(.note("note-2"))

    // The switch is stashed, not performed: the selection is still note-1.
    XCTAssertEqual(viewModel.pendingSelection, .note("note-2"))
    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-1")
  }

  func testConfirmPendingSelectionNavigatesAndClearsEditing() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)
    await viewModel.selectNote("note-1")
    viewModel.setEditingBody(true)
    await viewModel.requestSelection(.note("note-2"))

    let pending = try XCTUnwrap(viewModel.pendingSelection)
    await viewModel.confirmPendingSelection(pending)

    XCTAssertNil(viewModel.pendingSelection)
    XCTAssertFalse(viewModel.isEditingBody)
    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-2")
  }

  func testCancelPendingSelectionKeepsSelectionAndEditing() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)
    await viewModel.selectNote("note-1")
    viewModel.setEditingBody(true)
    await viewModel.requestSelection(.note("note-2"))

    viewModel.cancelPendingSelection()

    XCTAssertNil(viewModel.pendingSelection)
    XCTAssertTrue(viewModel.isEditingBody)
    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-1")
  }

  func testRequestSelectNotebookDefersWhileEditing() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)
    await viewModel.selectNote("note-2")
    viewModel.setEditingBody(true)

    await viewModel.requestSelection(.notebook("notebook-1"))

    XCTAssertEqual(viewModel.pendingSelection, .notebook("notebook-1"))
  }

  func testNotesTabRowSelectionUsesGuardedNoteSelection() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)
    await viewModel.load()
    viewModel.setEditingBody(true)

    await viewModel.requestSelection(.note("note-2"))

    XCTAssertEqual(viewModel.pendingSelection, .note("note-2"))
    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-1")
  }

  func testPagerSelectionRequestsAreInertWhileEditing() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)
    await viewModel.load()
    viewModel.setEditingBody(true)

    await viewModel.requestSelection(.nextNote)

    XCTAssertNil(viewModel.pendingSelection)
    XCTAssertTrue(viewModel.isEditingBody)
    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-1")
  }

  func testClearingEditingDropsPendingSelection() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)
    await viewModel.selectNote("note-1")
    viewModel.setEditingBody(true)
    await viewModel.requestSelection(.note("note-2"))
    XCTAssertNotNil(viewModel.pendingSelection)

    // Resetting the editor (e.g. the draft was discarded elsewhere) clears the
    // stale confirmation request.
    viewModel.setEditingBody(false)

    XCTAssertNil(viewModel.pendingSelection)
    XCTAssertFalse(viewModel.isEditingBody)
  }
}
