import Foundation
import RielaNote
@testable import RielaNoteUI
import XCTest

@MainActor
final class RielaNoteLibraryRefreshTests: XCTestCase {
  func testNoteServiceClientExposesDatabaseChangeObservationURLs() throws {
    let service = try makeRefreshTestService()
    let client = NoteServiceRielaNoteUIClient(service: service)
    let databasePath = service.driver.databasePath

    XCTAssertEqual(client.noteStoreChangeObservationURLs.map(\.path), [
      databasePath,
      "\(databasePath)-wal",
      "\(databasePath)-shm"
    ])
  }

  func testNoteStoreChangeWatcherEmitsForWalWrites() async throws {
    let root = try makeRefreshTestRoot()
    let databaseURL = root.appendingPathComponent("note-store.sqlite")
    let walURL = URL(fileURLWithPath: "\(databaseURL.path)-wal")
    _ = FileManager.default.createFile(atPath: databaseURL.path, contents: Data())
    _ = FileManager.default.createFile(atPath: walURL.path, contents: Data())
    let didObserveChange = expectation(description: "observed WAL write")
    let watcher = RielaNoteStoreChangeWatcher(
      fileURLs: [databaseURL, walURL],
      debounceInterval: 0.05
    ) {
      didObserveChange.fulfill()
    }
    XCTAssertTrue(watcher.start())
    defer {
      watcher.stop()
    }

    let handle = try FileHandle(forWritingTo: walURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("change".utf8))
    try handle.close()

    await fulfillment(of: [didObserveChange], timeout: 2)
  }

  func testNoteStoreChangeWatcherEmitsWhenWalIsCreatedAfterStart() async throws {
    let root = try makeRefreshTestRoot()
    let databaseURL = root.appendingPathComponent("note-store.sqlite")
    let walURL = URL(fileURLWithPath: "\(databaseURL.path)-wal")
    _ = FileManager.default.createFile(atPath: databaseURL.path, contents: Data())
    let didObserveChange = expectation(description: "observed WAL creation")
    let watcher = RielaNoteStoreChangeWatcher(
      fileURLs: [databaseURL, walURL],
      debounceInterval: 0.05
    ) {
      didObserveChange.fulfill()
    }
    XCTAssertTrue(watcher.start())
    defer {
      watcher.stop()
    }

    _ = FileManager.default.createFile(atPath: walURL.path, contents: Data("change".utf8))

    await fulfillment(of: [didObserveChange], timeout: 2)
  }

  func testNoteStoreChangeWatcherKeepsWatchingWalAfterDeleteAndRecreate() async throws {
    let root = try makeRefreshTestRoot()
    let databaseURL = root.appendingPathComponent("note-store.sqlite")
    let walURL = URL(fileURLWithPath: "\(databaseURL.path)-wal")
    _ = FileManager.default.createFile(atPath: databaseURL.path, contents: Data())
    _ = FileManager.default.createFile(atPath: walURL.path, contents: Data())
    let didObserveDelete = expectation(description: "observed WAL delete")
    let didObserveRecreatedWrite = expectation(description: "observed recreated WAL write")
    var observedChanges = 0
    let watcher = RielaNoteStoreChangeWatcher(
      fileURLs: [databaseURL, walURL],
      debounceInterval: 0.05
    ) {
      observedChanges += 1
      if observedChanges == 1 {
        didObserveDelete.fulfill()
      } else {
        didObserveRecreatedWrite.fulfill()
      }
    }
    XCTAssertTrue(watcher.start())
    defer {
      watcher.stop()
    }

    try FileManager.default.removeItem(at: walURL)
    await fulfillment(of: [didObserveDelete], timeout: 2)

    _ = FileManager.default.createFile(atPath: walURL.path, contents: Data())
    let handle = try FileHandle(forWritingTo: walURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("after recreate".utf8))
    try handle.close()

    await fulfillment(of: [didObserveRecreatedWrite], timeout: 2)
  }

  func testRefreshReloadsSelectedDetailAndKeepsSelection() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)

    await viewModel.load()
    await viewModel.selectNote("note-2")

    fixture.client.searchNote.title = "Ontology refreshed"
    fixture.client.searchNote.bodyMarkdown = "# Ontology refreshed\n\nUpdated from another process"
    fixture.client.searchNote.updatedAt = "2026-07-04T00:02:00Z"

    await viewModel.refresh()

    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-2")
    XCTAssertEqual(viewModel.selectedNote?.title, "Ontology refreshed")
    XCTAssertEqual(viewModel.selectedNote?.bodyMarkdown, "# Ontology refreshed\n\nUpdated from another process")
    XCTAssertEqual(viewModel.notebookNotes.map(\.title), ["Page One", "Ontology refreshed"])
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testRefreshRerunsActiveSearchWithoutChangingSelection() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)
    viewModel.searchText = "ontology"

    await viewModel.submitSearch()

    fixture.client.searchNote.title = "Ontology refreshed"
    fixture.client.searchResult = NoteSearchResult(
      note: fixture.client.searchNote,
      snippet: "refreshed snippet",
      rank: 0,
      matchedTags: fixture.client.searchNote.tags.map(\.tag)
    )

    await viewModel.refresh()

    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-2")
    XCTAssertEqual(viewModel.selectedNote?.title, "Ontology refreshed")
    XCTAssertEqual(viewModel.searchResults.map(\.snippet), ["refreshed snippet"])
    XCTAssertEqual(fixture.client.searchRequests.map(\.offset), [0, 0])
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testRefreshDoesNotRestoreSelectionChangedWhileRefreshIsInFlight() async throws {
    let fixture = NoteUITestFixture()
    let viewModel = RielaNoteLibraryViewModel(client: fixture.client)

    await viewModel.load()
    await viewModel.selectNote("note-2")
    fixture.client.noteDetailDelayNanosecondsByNoteId["note-2"] = 50_000_000
    let refreshReachedSelectedDetail = expectation(description: "refresh reached selected note detail")
    var didFulfillRefreshReachedSelectedDetail = false
    fixture.client.onNoteDetailStart = { noteId in
      guard noteId == "note-2", !didFulfillRefreshReachedSelectedDetail else {
        return
      }
      didFulfillRefreshReachedSelectedDetail = true
      refreshReachedSelectedDetail.fulfill()
    }

    let refresh = Task {
      await viewModel.refresh()
    }
    await fulfillment(of: [refreshReachedSelectedDetail], timeout: 1)
    await viewModel.selectNote("note-1")
    await refresh.value

    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-1")
    XCTAssertEqual(viewModel.state, .loaded)
  }
}

private func makeRefreshTestService(function: String = #function) throws -> NoteService {
  try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: makeRefreshTestRoot(function: function).path))
}

private func makeRefreshTestRoot(function: String = #function) throws -> URL {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tmp/RielaNoteLibraryRefreshTests", isDirectory: true)
    .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}
