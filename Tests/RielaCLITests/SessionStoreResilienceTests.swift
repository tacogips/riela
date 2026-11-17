import Foundation
import RielaAppSupport
import RielaCore
import RielaObservability
import RielaServer
import XCTest
@testable import RielaCLI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Regression coverage for issue #193: storage failures (ENOSPC, stalled or
/// permission-gated volumes) must neither crash a host nor block its caller,
/// and stale `running` records must be reconcilable.
final class SessionStoreResilienceTests: XCTestCase {
  func testStandardStreamWriteFailureIsDroppedNotRaised() throws {
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(pipe(&fds), 0)
    close(fds[0])
    let previousHandler = signal(SIGPIPE, SIG_IGN)
    defer {
      close(fds[1])
      signal(SIGPIPE, previousHandler)
    }
    let before = RielaStandardStreams.droppedWriteCount
    // A legacy FileHandle.write(_:) raises an uncaught NSException here (EPIPE),
    // the same way it does for ENOSPC on a full log volume.
    XCTAssertFalse(RielaStandardStreams.write(Data("diagnostic\n".utf8), to: fds[1]))
    XCTAssertEqual(RielaStandardStreams.droppedWriteCount, before + 1)
    XCTAssertFalse(RielaStandardStreams.write(Data("x".utf8), to: -1))
    XCTAssertTrue(RielaStandardStreams.write(Data(), to: -1))
  }

  func testBoundedIOTimesOutThenFailsFastUntilStuckWorkReturns() async throws {
    let key = "test-store-\(UUID().uuidString)"
    let release = DispatchSemaphore(value: 0)
    let started = Date()
    let first = await BoundedSessionStoreIO.run(key: key, timeout: 0.2) { () -> Int in
      release.wait()
      return 1
    }
    guard case .timedOut = first else { return XCTFail("expected timeout, got \(first)") }
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    XCTAssertTrue(BoundedSessionStoreIO.isBlocked(key: key))
    let second = await BoundedSessionStoreIO.run(key: key, timeout: 5) { 2 }
    guard case .storeBusy = second else { return XCTFail("expected storeBusy, got \(second)") }
    XCTAssertThrowsError(try BoundedSessionStoreIO.runBlocking(key: key, timeout: 5) { 3 })
    release.signal()
    for _ in 0..<200 where BoundedSessionStoreIO.isBlocked(key: key) {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(BoundedSessionStoreIO.isBlocked(key: key))
    let third = await BoundedSessionStoreIO.run(key: key, timeout: 5) { 4 }
    guard case .completed(.success(4)) = third else { return XCTFail("expected success, got \(third)") }
    XCTAssertEqual(try BoundedSessionStoreIO.runBlocking(key: key, timeout: 5) { 5 }, 5)
  }

  func testBlockingVariantTimesOutWithoutWaitingForStuckWork() throws {
    let key = "test-store-\(UUID().uuidString)"
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let started = Date()
    XCTAssertThrowsError(try BoundedSessionStoreIO.runBlocking(key: key, timeout: 0.2) { () -> Int in
      release.wait()
      return 1
    }) { error in
      XCTAssertEqual(error as? BoundedSessionStoreIO.Unavailable, .init(timedOut: true))
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    XCTAssertTrue(BoundedSessionStoreIO.isBlocked(key: key))
  }

  @MainActor
  func testConfiguredLaunchReturnsBoundedErrorWhenStoreIsStalled() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("configured-launch-stalled-store")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = root.appendingPathComponent("sessions")
    let candidate = RielaAppDaemonWorkflowCandidate(id: "stalled", workflowId: "stalled", displayName: "test",
      sourceDescription: "test", workflowDirectory: root.appendingPathComponent("workflow").path,
      workingDirectory: root.path, eventRoot: nil, eventSources: [])
    let context = RielaWebWorkflowContext(profile: .default, assistant: .init(), sources: [candidate], workingDirectory: root,
      appRoot: root, sessionStoreRoot: store.path, principalId: "test", environment: ["HOME": root.path])
    // Simulate an open(2) that is stuck in the kernel for this store.
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    _ = await BoundedSessionStoreIO.run(key: BoundedSessionStoreIO.key(sessionStoreRoot: store.path), timeout: 0.05) {
      release.wait()
    }
    let runtime = RielaWebWorkflowRuntime()
    let started = Date()
    let response = await runtime.handler(context: context).launchConfiguredWorkflow(identity: "stalled", source: candidate,
      configuration: WorkflowInstanceConfiguration(workingDirectory: root.path), variables: [:], storeTimeout: 0.2)
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    XCTAssertEqual(response.status, 503)
    let body = try JSONDecoder().decode(JSONObject.self, from: response.body)
    guard case let .object(error)? = body["error"] else { return XCTFail("missing error") }
    XCTAssertEqual(error["code"], .string("session_store_unavailable"))
    XCTAssertTrue(runtime.launches.isEmpty)
    XCTAssertTrue(runtime.configuredLaunchPreflights.isEmpty)
  }

  func testHostOrphanReconciliationRespectsLocksAndIdleGuard() throws {
    let root = try makeRielaCLITestTemporaryDirectory("orphan-reconcile-host")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    let old = Date(timeIntervalSince1970: 1_800_000_000)
    try save(id: "orphan", updatedAt: old, store: store)
    try save(id: "live", updatedAt: old, store: store)
    try save(id: "fresh", updatedAt: old.addingTimeInterval(3_590), store: store)
    let owner = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
    try owner.acquire(sessionId: "live")
    defer { owner.release(sessionId: "live") }

    let summary = try SessionOrphanReconciliation.reconcileOrphanedRoots(
      sessionStoreRoot: root.path, minimumIdle: 60, now: old.addingTimeInterval(3_600))

    XCTAssertEqual(summary.reconciledSessionIds, ["orphan"])
    XCTAssertEqual(try store.load(sessionId: "orphan").session.status, .cancelled)
    XCTAssertEqual(try store.load(sessionId: "live").session.status, .running)
    XCTAssertEqual(try store.load(sessionId: "fresh").session.status, .running)
    let empty = try SessionOrphanReconciliation.reconcileOrphanedRoots(
      sessionStoreRoot: root.appendingPathComponent("missing").path, minimumIdle: 0)
    XCTAssertEqual(empty.reconciledSessionIds, [])
  }

  private func save(id: String, updatedAt: Date, store: CLIWorkflowSessionStore) throws {
    let execution = WorkflowStepExecution(executionId: "execution-\(id)", stepId: "step", nodeId: "node", attempt: 1,
      status: .running, createdAt: updatedAt, updatedAt: updatedAt)
    let session = WorkflowSession(workflowId: "workflow-\(id)", sessionId: id, status: .running, entryStepId: "step",
      currentStepId: "step", createdAt: updatedAt, updatedAt: updatedAt, executions: [execution], rootSessionId: id)
    try store.save(PersistedCLIWorkflowSession(workflowName: session.workflowId, session: session,
      resolution: WorkflowResolutionOptions(workflowName: session.workflowId)),
      runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: session))
  }
}
