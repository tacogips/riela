import Foundation
import RielaCore
import RielaWork
import XCTest
@testable import RielaCLI

final class TaskRuntimeExampleTests: XCTestCase {
  func testRepairExampleRunsTheRequiredGateForARealTaskAttempt() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.completion = CompletionContract(
      gates: [GateDeclaration(id: "verification", stepId: "verify", required: true)],
      acceptance: [AcceptanceCriterion(
        id: "fixture-passes", statement: "The fixture check passes", gateIds: ["verification"]
      )]
    )
    try harness.store.saveTask(task)

    let result = try await harness.dispatch("task-repair-loop")
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let attempt = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first)
    XCTAssertEqual(attempt.state, .reconciled)
    XCTAssertEqual(attempt.outcome?.latestGateResults.first?.gateId, "verification")
    XCTAssertEqual(attempt.outcome?.latestGateResults.first?.decision, .accepted)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
      .load(sessionId: attempt.sessionId)
    XCTAssertEqual(
      GateAcceptanceParser.acceptance(requiredGates: task.completion.gates, session: snapshot.session),
      GateAcceptance(met: true, note: "The fixture check passed.")
    )
    XCTAssertFalse(try harness.store.listEvidence(taskId: task.id).isEmpty)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .succeeded)
    XCTAssertEqual(try harness.store.listDecisions(taskId: task.id).last?.kind, .accept)
  }

  func testRepairExampleGuardStopsAfterPersistingViolation() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.guardPolicy = GuardPolicy(
      convergence: ConvergenceGuard(maxGateVisits: 0),
      onViolation: .fail
    )
    try harness.store.saveTask(task)

    let result = try await harness.dispatch("task-repair-loop")
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .failed)
    let violations = try harness.store.listEvidence(taskId: task.id, kind: .guardViolation)
    XCTAssertEqual(violations.count, 1)
    guard case let .stop(reference)? = try harness.store.listDecisions(taskId: task.id).last?.kind else {
      return XCTFail("terminal guard decision must stop the task")
    }
    XCTAssertEqual(reference.evidenceId, violations[0].id)
  }

  func testRepairExampleCapacityWaitDoesNotReserveAnAttempt() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop")

    let result = try await harness.dispatch("task-repair-loop", capacity: 0)
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let response = try harness.decode(result)
    XCTAssertEqual(response.status, "waiting")
    XCTAssertEqual(response.waitReason, .capacity)
    XCTAssertNil(response.attemptId)
    XCTAssertNil(response.sessionId)
    XCTAssertTrue(try harness.store.listAttempts(taskId: task.id).isEmpty)
  }

  func testRepairExampleWarningPreservesEvidenceAndAllowsSatisfiedCompletion() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.guardPolicy = GuardPolicy(
      convergence: ConvergenceGuard(maxGateVisits: 0),
      onViolation: .warn
    )
    try harness.store.saveTask(task)

    let result = try await harness.dispatch("task-repair-loop")
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .succeeded)
    XCTAssertEqual(try harness.store.listEvidence(taskId: task.id, kind: .guardViolation).count, 1)
    XCTAssertEqual(try harness.store.listDecisions(taskId: task.id).last?.kind, .accept)
  }

  func testDirectorExampleProducesOneRecommendationInARealTaskAttempt() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-agent-director")

    let result = try await harness.dispatch("task-agent-director")
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let attempts = try harness.store.listAttempts(taskId: task.id)
    XCTAssertEqual(attempts.count, 1)
    let attempt = try XCTUnwrap(attempts.first)
    XCTAssertEqual(attempt.outcome?.sessionStatus, .completed)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
      .load(sessionId: attempt.sessionId)
    XCTAssertEqual(snapshot.session.executions.first?.acceptedOutput?.payload["kind"], .string("accept"))
  }

  func testBothBundlesLoadAndMatchTheirDocumentedMockKeys() throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    for name in ["task-repair-loop", "task-agent-director"] {
      let bundle = try harness.bundle(name)
      XCTAssertEqual(bundle.workflow.workflowId, name)
      XCTAssertFalse(DefaultWorkflowValidator().validate(
        bundle.workflow, nodePayloads: bundle.nodePayloads
      ).contains { $0.severity == .error })
      let scenario = harness.examples.appendingPathComponent(name)
        .appendingPathComponent("mock-scenario.json")
      let object = try JSONSerialization.jsonObject(with: Data(contentsOf: scenario)) as? [String: Any]
      let mockKeys = Set(try XCTUnwrap(object).keys)
      let nodeIds = Set(bundle.workflow.nodeRegistry.map(\.id))
      XCTAssertEqual(mockKeys, nodeIds)
      let expected = harness.examples.appendingPathComponent(name)
        .appendingPathComponent("EXPECTED_RESULTS.md")
      XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    }
  }
}
