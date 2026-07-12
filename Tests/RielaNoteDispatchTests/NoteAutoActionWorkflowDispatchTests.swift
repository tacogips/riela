import Foundation
import RielaCore
import RielaNote
import RielaNoteDispatch
import XCTest

final class NoteAutoActionWorkflowDispatchTests: XCTestCase {
  func testDispatcherDelegatesToLauncher() async throws {
    let launcher = StubNoteAutoActionWorkflowLauncher(result: .succeeded)
    let dispatcher = NoteAutoActionWorkflowDispatcher(launcher: launcher)

    let outcome = try await dispatcher.dispatch(record())

    XCTAssertEqual(outcome, .succeeded)
    let launched = await launcher.launchedRecords()
    XCTAssertEqual(launched.map(\.action.workflowId), ["ai-tag-workflow"])
  }

  func testDispatcherPropagatesLauncherFailure() async throws {
    let launcher = StubNoteAutoActionWorkflowLauncher(result: .failed("run failed"))
    let dispatcher = NoteAutoActionWorkflowDispatcher(launcher: launcher)

    let outcome = try await dispatcher.dispatch(record())

    XCTAssertEqual(outcome, .failed("run failed"))
  }

  func testDispatcherRethrowsLauncherError() async throws {
    let launcher = StubNoteAutoActionWorkflowLauncher(error: StubLauncherError.unresolved)
    let dispatcher = NoteAutoActionWorkflowDispatcher(launcher: launcher)

    do {
      _ = try await dispatcher.dispatch(record())
      XCTFail("expected dispatch to rethrow launcher error")
    } catch {
      XCTAssertEqual(error as? StubLauncherError, .unresolved)
    }
  }

  /// The app-configuration path: a `NoteService` built the way a window
  /// controller builds it (with the workflow dispatcher wired via a stub
  /// launcher) enqueues a pending row on note creation from the seeded
  /// `note-created` auto-action and, after the fired dispatch drains, launches
  /// exactly one workflow run and marks the row dispatched.
  func testAppConfiguredServiceEnqueuesAndLaunchesOnNoteCreation() async throws {
    let noteRoot = try makeNoteRoot()
    let launcher = StubNoteAutoActionWorkflowLauncher(result: .succeeded)
    let service = try NoteService(
      driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot),
      autoActionDispatcher: NoteAutoActionWorkflowDispatcher(launcher: launcher)
    )

    _ = try service.createNote(bodyMarkdown: "# Fire\nBody")
    await service.drainAutoActionDispatches()

    let launched = await launcher.launchedRecords()
    XCTAssertEqual(launched.count, 1)
    XCTAssertEqual(launched.first?.event.trigger, .noteCreated)

    let attempts = try service.listAutoActionDispatchAttempts()
    XCTAssertEqual(attempts.count, 1)
    XCTAssertEqual(attempts.first?.status, .dispatched)
  }

  /// Without a dispatcher wired, note creation still records a pending row so a
  /// later maintenance tick can run it — the always-enqueue guarantee.
  func testServiceWithoutDispatcherStillEnqueuesPendingRow() throws {
    let noteRoot = try makeNoteRoot()
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot))

    _ = try service.createNote(bodyMarkdown: "# Fire\nBody")

    let attempts = try service.listAutoActionDispatchAttempts()
    XCTAssertEqual(attempts.count, 1)
    XCTAssertEqual(attempts.first?.status, .pending)
  }

  /// The maintenance tick reclaims a pending row and drives it to completion
  /// through the wired launcher.
  func testMaintenanceTickerRunOnceRetriesPendingDispatch() async throws {
    let noteRoot = try makeNoteRoot()

    // First service (no dispatcher) records a pending row without launching it.
    let recordingService = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot))
    _ = try recordingService.createNote(bodyMarkdown: "# Fire\nBody")
    XCTAssertEqual(try recordingService.listAutoActionDispatchAttempts().first?.status, .pending)

    // A second service configured like the app (dispatcher wired) runs the
    // maintenance tick once, launching the pending dispatch.
    let launcher = StubNoteAutoActionWorkflowLauncher(result: .succeeded)
    let appService = try NoteService(
      driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot),
      autoActionDispatcher: NoteAutoActionWorkflowDispatcher(launcher: launcher)
    )
    let ticker = NoteAutoActionMaintenanceTicker(service: appService, interval: 0)
    let retried = await ticker.runOnce()

    XCTAssertEqual(retried, 1)
    let launched = await launcher.launchedRecords()
    XCTAssertEqual(launched.count, 1)
    let attempts = try appService.listAutoActionDispatchAttempts()
    XCTAssertEqual(attempts.first?.status, .dispatched)
  }

  private func makeNoteRoot() throws -> String {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/RielaNoteDispatchTests/NoteAutoActionDispatch", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.path
  }

  private func record(workflowId: String = "ai-tag-workflow") -> AutoActionDispatchRecord {
    AutoActionDispatchRecord(
      action: AutoAction(
        actionId: "auto-action-1",
        trigger: .noteCreated,
        workflowId: workflowId,
        filterJSON: nil,
        enabled: true,
        position: 0,
        createdAt: "2026-07-04T00:00:00Z"
      ),
      event: NoteAutoActionEvent(
        trigger: .noteCreated,
        notebookId: "notebook-1",
        noteId: "note-1",
        noteBodyMarkdown: "# Note\nBody"
      )
    )
  }
}

enum StubLauncherError: Error, Equatable {
  case unresolved
}

actor StubNoteAutoActionWorkflowLauncher: NoteAutoActionWorkflowLaunching {
  private let result: AutoActionDispatchOutcome?
  private let error: Error?
  private var launched: [AutoActionDispatchRecord] = []

  init(result: AutoActionDispatchOutcome) {
    self.result = result
    self.error = nil
  }

  init(error: Error) {
    self.result = nil
    self.error = error
  }

  func launch(_ record: AutoActionDispatchRecord) async throws -> AutoActionDispatchOutcome {
    launched.append(record)
    if let error {
      throw error
    }
    return result ?? .succeeded
  }

  func launchedRecords() -> [AutoActionDispatchRecord] {
    launched
  }
}
