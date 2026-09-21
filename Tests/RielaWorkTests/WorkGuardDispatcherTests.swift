import Foundation
import RielaCore
import XCTest
@testable import RielaWork

final class WorkGuardDispatcherTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-work-guard-dispatch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testAdapterAggregatesCostsAndUsesOnlyLiveBackendHeartbeat() {
    let attempt = Attempt(
      id: AttemptID("attempt-1"),
      taskId: TaskID("task-1"),
      sessionId: "session-1",
      state: .terminal,
      outcome: AttemptOutcome(
        sessionStatus: .failed,
        costs: [LoopCostEvidence(stepExecutionId: "execution-1", totalTokens: 42)]
      )
    )
    let now = Date(timeIntervalSince1970: 2_000)
    let session = WorkflowSession(
      workflowId: "workflow",
      sessionId: "session-1",
      status: .running,
      entryStepId: "agent",
      currentStepId: "agent",
      createdAt: now.addingTimeInterval(-20),
      updatedAt: now,
      executions: [WorkflowStepExecution(
        executionId: "execution-1",
        stepId: "agent",
        nodeId: "agent-node",
        attempt: 1,
        backend: .codexAgent,
        status: .running,
        lastBackendEventAt: now.addingTimeInterval(-5),
        createdAt: now.addingTimeInterval(-20),
        updatedAt: now
      )]
    )

    let snapshot = TaskGuardSnapshotAdapter.make(
      attempts: [attempt],
      session: session,
      wallClockMs: 20_000,
      signals: RunnerGuardSignals(gateVisits: ["review": 3], repeatedFindingRounds: ["review": 2]),
      now: now
    )
    XCTAssertEqual(snapshot.totalTokens, 42)
    XCTAssertEqual(snapshot.idleMs, 5_000)
    XCTAssertEqual(snapshot.heartbeatBackend, NodeExecutionBackend.codexAgent.rawValue)
    XCTAssertEqual(snapshot.gateVisits, ["review": 3])
  }

  func testHeartbeatIneligibleOfficialSDKDoesNotEmitInactivity() {
    let snapshot = GuardSnapshot(
      activeStepId: "agent",
      heartbeatBackend: NodeExecutionBackend.officialOpenAISDK.rawValue,
      idleMs: 60_000
    )
    let policy = GuardPolicy(inactivity: InactivityGuard(
      stallTimeoutMs: 1_000,
      monitorIntervalMs: 100,
      heartbeatBackends: [NodeExecutionBackend.codexAgent.rawValue]
    ))
    XCTAssertEqual(WorkGuard.evaluate(policy: policy, snapshot: snapshot), [])
  }

  func testViolationEvidenceIsPersistedAndCausesTheAppliedDecision() throws {
    let store = WorkStore(rootDirectory: root.path)
    var task = sampleTask()
    task.guardPolicy = GuardPolicy(budget: BudgetGuard(maxAttempts: 1), onViolation: .askDirector)
    task.state = .verifying
    try store.saveTask(task)
    let attempt = Attempt(
      id: AttemptID("attempt-1"),
      taskId: task.id,
      sessionId: "session-1",
      state: .terminal,
      outcome: AttemptOutcome(sessionStatus: .failed, failureKind: .adapterFailure)
    )
    try store.saveAttempt(attempt)

    let result = try TaskGuardCoordinator(store: store).evaluateAndApply(
      task: task,
      latestAttempt: attempt,
      snapshot: GuardSnapshot(attemptCount: 1),
      completion: .unmet([]),
      failedStepId: "agent",
      violationEvidenceIds: [EvidenceID("evidence-guard")],
      decisionId: DecisionID("decision-stop"),
      decisionEvidenceId: EvidenceID("evidence-decision")
    )

    XCTAssertEqual(result.resolution.rule, "budget-exhausted")
    XCTAssertEqual(result.application.task.state, .failed)
    XCTAssertEqual(result.application.attempt?.state, .reconciled)
    let evidence = try store.listEvidence(taskId: task.id)
    XCTAssertEqual(Set(evidence.map(\.id)), [EvidenceID("evidence-guard"), EvidenceID("evidence-decision")])
    let decisionEvidence = try XCTUnwrap(evidence.first { $0.kind == .decision })
    XCTAssertEqual(decisionEvidence.causedBy, [EvidenceID("evidence-guard")])
  }

  private func sampleTask() -> WorkTask {
    WorkTask(
      id: TaskID("task-1"),
      intentId: IntentID("intent-1"),
      title: "Task",
      instruction: "Run",
      plan: .workflow(WorkflowReference(name: "workflow")),
      state: .ready
    )
  }
}
