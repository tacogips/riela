import Foundation
import RielaAdapters
import RielaCore
import RielaWork
import XCTest
@testable import RielaCLI

private actor SlowHandoverScenarioAdapter: NodeAdapter {
  let fallback: ScenarioNodeAdapter

  init(scenarioPath: String) throws {
    fallback = ScenarioNodeAdapter(scenario: try WorkflowMockScenarioLoader().loadScenario(at: scenarioPath))
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    try await Task.sleep(for: .milliseconds(350))
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
}
