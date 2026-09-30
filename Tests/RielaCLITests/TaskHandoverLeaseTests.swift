import Foundation
import RielaAdapters
import RielaCore
import RielaWork
import XCTest
@testable import RielaCLI

private actor SlowHandoverScenarioAdapter: NodeAdapter {
  let fallback: ScenarioNodeAdapter
  let delayMs: Int

  init(scenarioPath: String, delayMs: Int = 350) throws {
    fallback = ScenarioNodeAdapter(scenario: try WorkflowMockScenarioLoader().loadScenario(at: scenarioPath))
    self.delayMs = delayMs
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    try await Task.sleep(for: .milliseconds(delayMs))
    return try await fallback.execute(input, context: context)
  }
}

private final class HandoverLeaseCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: AttemptLease?

  func save(_ lease: AttemptLease?) {
    lock.lock()
    stored = lease
    lock.unlock()
  }

  var value: AttemptLease? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}

final class TaskHandoverLeaseTests: XCTestCase {
  func testHeartbeatExtendsLeaseDuringLongRunningAttempt() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.guardPolicy.lease = LeasePolicy(ttlMs: 600, heartbeatMs: 50)
    try harness.store.saveTask(task)

    let scenarioPath = harness.examples.appendingPathComponent("task-repair-loop/mock-scenario.json").path
    let adapter = try SlowHandoverScenarioAdapter(scenarioPath: scenarioPath)
    let initial = HandoverLeaseCapture()
    let dispatch = Task {
      try await harness.dispatch(
        "task-repair-loop", nodeAdapter: adapter,
        beforeExecution: { reservation in
          initial.save(try? harness.store.loadLease(attemptId: reservation.attempt.id))
        }
      )
    }
    let deadline = Date().addingTimeInterval(5)
    while initial.value == nil, Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let before = try XCTUnwrap(initial.value)
    try await Task.sleep(for: .milliseconds(180))
    let after = try XCTUnwrap(harness.store.loadLease(attemptId: before.attemptId))
    XCTAssertGreaterThan(after.expiresAt, before.expiresAt)
    _ = try await dispatch.value
  }

  func testRevivedOwnerFailsLeaseLostWithoutSealingSecondPacket() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.guardPolicy.lease = LeasePolicy(ttlMs: 10_000, heartbeatMs: 50)
    try harness.store.saveTask(task)

    let scenarioPath = harness.examples.appendingPathComponent("task-repair-loop/mock-scenario.json").path
    let adapter = try SlowHandoverScenarioAdapter(scenarioPath: scenarioPath)
    let leaseCapture = HandoverLeaseCapture()
    let dispatch = Task {
      try await harness.dispatch(
        "task-repair-loop", nodeAdapter: adapter,
        beforeExecution: { reservation in
          leaseCapture.save(try harness.store.loadLease(attemptId: reservation.attempt.id))
        }
      )
    }
    let deadline = Date().addingTimeInterval(5)
    while leaseCapture.value == nil, Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let lease = try XCTUnwrap(leaseCapture.value)
    let attempt = try XCTUnwrap(harness.store.loadAttempt(id: lease.attemptId))
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
    while try persistence.load(sessionId: attempt.sessionId).session.status != .running, Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let runtime = TaskHandoverRuntime(
      located: TaskCommandRunner.LocatedTask(
        task: task, store: harness.store, root: harness.store.rootDirectory
      ),
      options: TaskStoreOptions(
        scope: .project, workingDirectory: harness.repository.path, sessionStore: harness.sessionStore.path
      ),
      now: { lease.expiresAt.addingTimeInterval(0.001) }
    )
    let earlyRuntime = TaskHandoverRuntime(
      located: runtime.located, options: runtime.options, now: { Date() }
    )
    do {
      _ = try await earlyRuntime.forceOrphan(
        taskId: task.id, producer: .policy(rule: "revived-owner-test"), cliSinks: []
      )
      XCTFail("forceOrphan must refuse before lease expiry")
    } catch {
      XCTAssertTrue(String(describing: error).contains("has not expired"))
    }
    let packet = try await runtime.forceOrphan(
      taskId: task.id, producer: .policy(rule: "revived-owner-test"), cliSinks: []
    )

    let result = try await dispatch.value
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertEqual(try harness.store.listHandovers(taskId: task.id).map(\.id), [packet.id])
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
      .load(sessionId: attempt.sessionId)
    XCTAssertEqual(snapshot.session.status, .failed)
    XCTAssertEqual(snapshot.session.failureKind, .leaseLost)
    let takeover = try await harness.dispatch("task-repair-loop")
    XCTAssertEqual(takeover.exitCode, .success, "stderr: \(takeover.stderr)")
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .succeeded)
  }

  func testReconcileExpiredDryRunDoesNotMutateAndSealsOwnerLost() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.guardPolicy.lease = LeasePolicy(ttlMs: 10_000, heartbeatMs: 10_000)
    try harness.store.saveTask(task)

    let scenarioPath = harness.examples.appendingPathComponent("task-repair-loop/mock-scenario.json").path
    let adapter = try SlowHandoverScenarioAdapter(scenarioPath: scenarioPath, delayMs: 3_000)
    let leaseCapture = HandoverLeaseCapture()
    let dispatch = Task {
      try await harness.dispatch(
        "task-repair-loop", nodeAdapter: adapter,
        beforeExecution: { reservation in
          leaseCapture.save(try harness.store.loadLease(attemptId: reservation.attempt.id))
        }
      )
    }
    let deadline = Date().addingTimeInterval(5)
    while leaseCapture.value == nil, Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let lease = try XCTUnwrap(leaseCapture.value)
    let attempt = try XCTUnwrap(harness.store.loadAttempt(id: lease.attemptId))
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
    while try persistence.load(sessionId: attempt.sessionId).session.status != .running, Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(try persistence.load(sessionId: attempt.sessionId).session.status, .running)

    let runtime = TaskHandoverRuntime(
      located: TaskCommandRunner.LocatedTask(
        task: task, store: harness.store, root: harness.store.rootDirectory
      ),
      options: TaskStoreOptions(
        scope: .project, workingDirectory: harness.repository.path, sessionStore: harness.sessionStore.path
      ),
      now: { lease.expiresAt.addingTimeInterval(0.001) }
    )
    let dryRun = try await runtime.reconcileExpired(dryRun: true, cliSinks: [])
    XCTAssertEqual(dryRun.count, 1)
    XCTAssertEqual(dryRun[0].taskId, task.id)
    XCTAssertEqual(dryRun[0].attemptId, attempt.id)
    XCTAssertNil(dryRun[0].handoverId)
    XCTAssertEqual(dryRun[0].action, "would-seal-owner-lost")
    let unchangedLease = try XCTUnwrap(harness.store.loadLease(attemptId: attempt.id))
    XCTAssertEqual(unchangedLease.expiresAt, lease.expiresAt)
    XCTAssertEqual(unchangedLease.fence, lease.fence)
    XCTAssertTrue(try harness.store.listHandovers(taskId: task.id).isEmpty)

    let reconciled = try await runtime.reconcileExpired(dryRun: false, cliSinks: [])
    XCTAssertEqual(reconciled.count, 1)
    XCTAssertEqual(reconciled[0].attemptId, attempt.id)
    XCTAssertEqual(reconciled[0].action, "sealed-owner-lost")
    let handoverId = HandoverID(rawValue: try XCTUnwrap(reconciled[0].handoverId))
    let packet = try XCTUnwrap(harness.store.loadHandover(id: handoverId))
    guard case .ownerLost = packet.reason else { return XCTFail("expected ownerLost packet") }
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .waiting)
    XCTAssertNil(try TaskDispatcher(store: harness.store).pendingReservation(taskId: task.id))
    XCTAssertNil(try harness.store.loadLease(attemptId: attempt.id))
    _ = try await dispatch.value
  }
}
