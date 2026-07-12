import Foundation
import XCTest
@testable import RielaCore

final class LoopConcurrencyLeaseTests: XCTestCase {
  func testAcquireInsertsAndFreshLeaseIsBusy() throws {
    let (store, cleanup) = try makeStore()
    defer { cleanup() }
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    let first = try store.acquireLoopConcurrencyLease(workflowId: "wf", holder: "pending:a", now: now)
    XCTAssertEqual(first, .acquired(takenOverFrom: nil))

    let second = try store.acquireLoopConcurrencyLease(workflowId: "wf", holder: "pending:b", now: now.addingTimeInterval(30))
    XCTAssertEqual(second, .busy(holderSessionId: "pending:a", heartbeatAt: now))
  }

  func testStaleLeaseIsTakenOverWithPreviousHolderRecorded() throws {
    let (store, cleanup) = try makeStore()
    defer { cleanup() }
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    _ = try store.acquireLoopConcurrencyLease(workflowId: "wf", holder: "pending:a", now: now)
    // Crash simulation: no release; the row expires via staleness (600 s).
    let takeover = try store.acquireLoopConcurrencyLease(
      workflowId: "wf",
      holder: "pending:b",
      now: now.addingTimeInterval(601)
    )
    XCTAssertEqual(takeover, .acquired(takenOverFrom: "pending:a"))
    XCTAssertEqual(try store.loadLoopConcurrencyLease(workflowId: "wf")?.sessionId, "pending:b")
  }

  func testSnapshotSaveBindsPendingLeaseAndRefreshesHeartbeat() throws {
    let (store, cleanup) = try makeStore()
    defer { cleanup() }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try store.acquireLoopConcurrencyLease(workflowId: "wf", holder: "pending:a", now: now)

    try store.save(Self.snapshot(sessionId: "session-1", status: .running, at: now.addingTimeInterval(60)))
    let bound = try XCTUnwrap(try store.loadLoopConcurrencyLease(workflowId: "wf"))
    XCTAssertEqual(bound.sessionId, "session-1", "first save binds the pending lease to the real session")
    XCTAssertEqual(bound.heartbeatAt, now.addingTimeInterval(60))

    try store.save(Self.snapshot(sessionId: "session-1", status: .running, at: now.addingTimeInterval(120)))
    XCTAssertEqual(
      try store.loadLoopConcurrencyLease(workflowId: "wf")?.heartbeatAt,
      now.addingTimeInterval(120),
      "live saves ride the single save-path helper and refresh the heartbeat"
    )
  }

  func testTerminalSaveReleasesLeaseOnCompletionAndFailure() throws {
    for status in [WorkflowSessionStatus.completed, .failed] {
      let (store, cleanup) = try makeStore()
      defer { cleanup() }
      let now = Date(timeIntervalSince1970: 1_700_000_000)
      _ = try store.acquireLoopConcurrencyLease(workflowId: "wf", holder: "pending:a", now: now)
      try store.save(Self.snapshot(sessionId: "session-1", status: .running, at: now))
      try store.save(Self.snapshot(sessionId: "session-1", status: status, at: now.addingTimeInterval(10)))
      XCTAssertNil(
        try store.loadLoopConcurrencyLease(workflowId: "wf"),
        "terminal (\(status.rawValue)) persistence releases the lease"
      )
    }
  }

  func testSaveForOtherSessionDoesNotStealBoundLease() throws {
    let (store, cleanup) = try makeStore()
    defer { cleanup() }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try store.acquireLoopConcurrencyLease(workflowId: "wf", holder: "pending:a", now: now)
    try store.save(Self.snapshot(sessionId: "session-1", status: .running, at: now))

    try store.save(Self.snapshot(sessionId: "session-2", status: .running, at: now.addingTimeInterval(5)))
    XCTAssertEqual(
      try store.loadLoopConcurrencyLease(workflowId: "wf")?.sessionId,
      "session-1",
      "a bound lease only heartbeats from its own session's saves"
    )
  }

  func testReleaseOnlyRemovesMatchingHolder() throws {
    let (store, cleanup) = try makeStore()
    defer { cleanup() }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try store.acquireLoopConcurrencyLease(workflowId: "wf", holder: "pending:a", now: now)

    try store.releaseLoopConcurrencyLease(workflowId: "wf", holder: "pending:other")
    XCTAssertNotNil(try store.loadLoopConcurrencyLease(workflowId: "wf"))

    try store.releaseLoopConcurrencyLease(workflowId: "wf", holder: "pending:a")
    XCTAssertNil(try store.loadLoopConcurrencyLease(workflowId: "wf"))
  }

  func testLeaseReadTreatsMissingTableAsNoLease() throws {
    let (store, cleanup) = try makeStore()
    defer { cleanup() }
    XCTAssertNil(try store.loadLoopConcurrencyLease(workflowId: "wf"))
    try store.save(Self.snapshot(sessionId: "session-1", status: .completed, at: Date(timeIntervalSince1970: 1_700_000_000)))
    XCTAssertNil(try store.loadLoopConcurrencyLease(workflowId: "wf"))
  }

  // MARK: - Fixtures

  private func makeStore() throws -> (SQLiteWorkflowRuntimePersistenceStore, () -> Void) {
    let root = NSTemporaryDirectory() + "loop-lease-tests-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return (
      SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root),
      { try? FileManager.default.removeItem(atPath: root) }
    )
  }

  private static func snapshot(
    sessionId: String,
    status: WorkflowSessionStatus,
    at date: Date
  ) -> WorkflowRuntimePersistenceSnapshot {
    WorkflowRuntimePersistenceSnapshot(
      session: WorkflowSession(
        workflowId: "wf",
        sessionId: sessionId,
        status: status,
        entryStepId: "s",
        createdAt: date,
        updatedAt: date
      ),
      workflowMessages: [],
      diagnostics: []
    )
  }
}
