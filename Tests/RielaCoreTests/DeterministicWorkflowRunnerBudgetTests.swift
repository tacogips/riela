import Foundation
import XCTest
@testable import RielaCore

final class DeterministicWorkflowRunnerBudgetTests: XCTestCase {
  // MARK: - Pure evaluation

  func testBudgetViolationTripsOnTokenBound() {
    let session = Self.session(executions: [Self.execution(totalTokens: 1_500)])
    let diagnostic = DeterministicWorkflowRunner.loopBudgetViolation(
      budget: LoopBudgetDeclaration(maxTotalTokens: 1_000),
      session: session,
      now: session.createdAt
    )
    XCTAssertEqual(diagnostic, "loop budget exceeded: 1500 total tokens consumed; maximum is 1000")
  }

  func testBudgetViolationDoesNotFabricateFromAbsentUsage() {
    // Agent step without usage: totals stay nil, no violation is invented.
    let session = Self.session(executions: [Self.execution(totalTokens: nil)])
    let diagnostic = DeterministicWorkflowRunner.loopBudgetViolation(
      budget: LoopBudgetDeclaration(maxTotalTokens: 1),
      session: session,
      now: session.createdAt
    )
    XCTAssertNil(diagnostic)
  }

  func testBudgetViolationTripsOnWallClock() {
    let session = Self.session(executions: [])
    let diagnostic = DeterministicWorkflowRunner.loopBudgetViolation(
      budget: LoopBudgetDeclaration(maxWallClockMs: 5_000),
      session: session,
      now: session.createdAt.addingTimeInterval(6)
    )
    XCTAssertEqual(diagnostic, "loop budget exceeded: session wall-clock 6000ms; maximum is 5000ms")
  }

  func testBudgetViolationNilWhenWithinBounds() {
    let session = Self.session(executions: [Self.execution(totalTokens: 500)])
    let diagnostic = DeterministicWorkflowRunner.loopBudgetViolation(
      budget: LoopBudgetDeclaration(maxTotalTokens: 1_000, maxWallClockMs: 60_000),
      session: session,
      now: session.createdAt.addingTimeInterval(1)
    )
    XCTAssertNil(diagnostic)
  }

  // MARK: - Runner enforcement

  func testTokenBudgetFailsSessionBetweenSteps() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: UsageEmittingAdapter(outputs: [
        (Self.gateOutput(decision: "needs_work"), 1_500),
        (Self.gateOutput(decision: "accepted"), 10)
      ])
    )

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: Self.budgetWorkflow(budget: LoopBudgetDeclaration(maxTotalTokens: 1_000)),
        nodePayloads: ["review-node": AgentNodePayload(id: "review-node", executionBackend: .codexAgent, model: "gpt-5.5")],
        maxSteps: 4
      ))
      XCTFail("expected loop budget failure")
    } catch let error as DeterministicWorkflowRunnerError {
      guard case let .loopBudgetExceeded(diagnostic) = error else {
        return XCTFail("unexpected runner error: \(error)")
      }
      XCTAssertTrue(diagnostic.contains("1500 total tokens"))
    }

    let latestSession = await store.latestSession(workflowId: "runner-loop-budget")
    let session = try XCTUnwrap(latestSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.failureKind, .budgetExceeded)
  }

  func testWarnBudgetDoesNotFailSession() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: UsageEmittingAdapter(outputs: [
        (Self.gateOutput(decision: "needs_work"), 1_500),
        (Self.gateOutput(decision: "accepted"), 10)
      ])
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: Self.budgetWorkflow(budget: LoopBudgetDeclaration(maxTotalTokens: 1_000, onExceeded: "warn")),
      nodePayloads: ["review-node": AgentNodePayload(id: "review-node", executionBackend: .codexAgent, model: "gpt-5.5")],
      maxSteps: 4
    ))

    XCTAssertEqual(result.session.status, .completed)
  }

  func testBudgetlessWorkflowIsUnaffected() async throws {
    let runner = DeterministicWorkflowRunner(
      store: InMemoryWorkflowRuntimeStore(),
      adapter: UsageEmittingAdapter(outputs: [
        (Self.gateOutput(decision: "needs_work"), 100_000),
        (Self.gateOutput(decision: "accepted"), 100_000)
      ])
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: Self.budgetWorkflow(budget: nil),
      nodePayloads: ["review-node": AgentNodePayload(id: "review-node", executionBackend: .codexAgent, model: "gpt-5.5")],
      maxSteps: 4
    ))

    XCTAssertEqual(result.session.status, .completed)
  }

  func testWallClockBudgetFailsSessionBetweenSteps() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: UsageEmittingAdapter(
        outputs: [
          (Self.gateOutput(decision: "needs_work"), 1),
          (Self.gateOutput(decision: "accepted"), 1)
        ],
        delayMs: 20
      )
    )

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: Self.budgetWorkflow(budget: LoopBudgetDeclaration(maxWallClockMs: 1)),
        nodePayloads: ["review-node": AgentNodePayload(id: "review-node", executionBackend: .codexAgent, model: "gpt-5.5")],
        maxSteps: 4
      ))
      XCTFail("expected wall-clock budget failure")
    } catch let error as DeterministicWorkflowRunnerError {
      guard case let .loopBudgetExceeded(diagnostic) = error else {
        return XCTFail("unexpected runner error: \(error)")
      }
      XCTAssertTrue(diagnostic.contains("wall-clock"))
    }

    let latestSession = await store.latestSession(workflowId: "runner-loop-budget")
    let session = try XCTUnwrap(latestSession)
    XCTAssertEqual(session.failureKind, .budgetExceeded)
  }

  func testBudgetViolationEmitsSingleBudgetExceededEvent() async throws {
    let recorder = RunEventRecorder()
    let runner = DeterministicWorkflowRunner(
      store: InMemoryWorkflowRuntimeStore(),
      adapter: UsageEmittingAdapter(outputs: [
        (Self.gateOutput(decision: "needs_work"), 1_500),
        (Self.gateOutput(decision: "needs_work"), 10),
        (Self.gateOutput(decision: "accepted"), 10)
      ])
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: Self.budgetWorkflow(budget: LoopBudgetDeclaration(maxTotalTokens: 1_000, onExceeded: "warn")),
      nodePayloads: ["review-node": AgentNodePayload(id: "review-node", executionBackend: .codexAgent, model: "gpt-5.5")],
      maxSteps: 6,
      eventHandler: { await recorder.record($0) }
    ))

    XCTAssertEqual(result.session.status, .completed)
    let budgetEvents = await recorder.events.filter { $0.type == .budgetExceeded }
    XCTAssertEqual(budgetEvents.count, 1, "warn-mode exceedance emits exactly one budget_exceeded record")
    let payload = try XCTUnwrap(budgetEvents.first?.loopBudgetPayload)
    XCTAssertEqual(payload.action, "warn")
    XCTAssertEqual(payload.consumedTokens, 1_500)
    XCTAssertEqual(payload.maxTotalTokens, 1_000)
    XCTAssertTrue(payload.diagnostic.contains("1500 total tokens"))
  }

  func testBudgetExceededEventRoundTripsThroughCodable() throws {
    let event = WorkflowRunEvent(
      type: .budgetExceeded,
      workflowId: "wf",
      sessionId: "session-1",
      status: .running,
      loopBudgetDiagnostic: "loop budget exceeded: 1500 total tokens consumed; maximum is 1000",
      loopBudgetAction: "fail",
      loopBudgetConsumedTokens: 1_500,
      loopBudgetMaxTotalTokens: 1_000
    )
    let data = try JSONEncoder().encode(event)
    let decoded = try JSONDecoder().decode(WorkflowRunEvent.self, from: data)
    XCTAssertEqual(decoded, event)
    XCTAssertEqual(decoded.type, .budgetExceeded)
    XCTAssertEqual(decoded.loopBudgetPayload?.consumedTokens, 1_500)
  }

  // MARK: - maxSessionAttempts lineage enforcement

  func testRerunIncrementsAttemptNumberAndRecordsRoot() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = Self.budgetWorkflow(budget: LoopBudgetDeclaration(maxSessionAttempts: 3))
    let payloads = ["review-node": AgentNodePayload(id: "review-node", executionBackend: .codexAgent, model: "gpt-5.5")]

    let first = try await DeterministicWorkflowRunner(
      store: store,
      adapter: UsageEmittingAdapter(outputs: [(Self.gateOutput(decision: "accepted"), 10)])
    ).run(DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: payloads, maxSteps: 4))
    XCTAssertEqual(first.recovery?.attemptNumber, 1)

    let rerun = try await DeterministicWorkflowRunner(
      store: store,
      adapter: UsageEmittingAdapter(outputs: [(Self.gateOutput(decision: "accepted"), 10)])
    ).run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: payloads,
      maxSteps: 4,
      rerunFromSessionId: first.session.sessionId,
      rerunFromStepId: "review",
      sourceRecoveryLineage: first.recovery
    ))
    XCTAssertEqual(rerun.recovery?.attemptNumber, 2)
    XCTAssertEqual(rerun.recovery?.rootSessionId, first.session.sessionId)
  }

  func testMaxSessionAttemptsFailsRerunEntry() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = Self.budgetWorkflow(budget: LoopBudgetDeclaration(maxSessionAttempts: 2))
    let payloads = ["review-node": AgentNodePayload(id: "review-node", executionBackend: .codexAgent, model: "gpt-5.5")]

    let first = try await DeterministicWorkflowRunner(
      store: store,
      adapter: UsageEmittingAdapter(outputs: [(Self.gateOutput(decision: "accepted"), 10)])
    ).run(DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: payloads, maxSteps: 4))

    do {
      _ = try await DeterministicWorkflowRunner(
        store: store,
        adapter: UsageEmittingAdapter(outputs: [(Self.gateOutput(decision: "accepted"), 10)])
      ).run(DeterministicWorkflowRunRequest(
        workflow: workflow,
        nodePayloads: payloads,
        maxSteps: 4,
        rerunFromSessionId: first.session.sessionId,
        rerunFromStepId: "review",
        sourceRecoveryLineage: LoopRecoveryLineage(
          entryMode: .rerun,
          inputReusePolicy: "source-session",
          rootSessionId: first.session.sessionId,
          attemptNumber: 2
        )
      ))
      XCTFail("expected maxSessionAttempts failure")
    } catch let error as DeterministicWorkflowRunnerError {
      guard case let .loopBudgetExceeded(diagnostic) = error else {
        return XCTFail("unexpected runner error: \(error)")
      }
      XCTAssertEqual(diagnostic, "loop budget exceeded: session attempt 3 exceeds maxSessionAttempts 2")
    }
  }

  func testLegacyLineageWithoutAttemptNumberDoesNotFailRerun() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = Self.budgetWorkflow(budget: LoopBudgetDeclaration(maxSessionAttempts: 2))
    let payloads = ["review-node": AgentNodePayload(id: "review-node", executionBackend: .codexAgent, model: "gpt-5.5")]

    let first = try await DeterministicWorkflowRunner(
      store: store,
      adapter: UsageEmittingAdapter(outputs: [(Self.gateOutput(decision: "accepted"), 10)])
    ).run(DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: payloads, maxSteps: 4))

    let rerun = try await DeterministicWorkflowRunner(
      store: store,
      adapter: UsageEmittingAdapter(outputs: [(Self.gateOutput(decision: "accepted"), 10)])
    ).run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: payloads,
      maxSteps: 4,
      rerunFromSessionId: first.session.sessionId,
      rerunFromStepId: "review"
    ))
    XCTAssertEqual(rerun.session.status, .completed)
    XCTAssertEqual(rerun.recovery?.attemptNumber, 2)
  }

  // MARK: - Evidence projection

  func testProjectorRecordsBudgetDecisionAndWarnResidualRisk() throws {
    let workflow = Self.budgetWorkflow(budget: LoopBudgetDeclaration(maxTotalTokens: 1_000, onExceeded: "warn"))
    let session = Self.session(executions: [Self.execution(totalTokens: 1_500)])
    let manifest = try XCTUnwrap(DefaultLoopEvidenceProjector().project(LoopEvidenceProjectionInput(
      workflow: workflow,
      session: session,
      workflowSource: Self.workflowSource
    )))

    let decision = try XCTUnwrap(manifest.policy.decisions.first { $0.policy == "budget" })
    XCTAssertEqual(decision.decision, "exceeded-warn")
    XCTAssertTrue(try XCTUnwrap(decision.reason).contains("1500 total tokens"))
    let risk = try XCTUnwrap(manifest.residualRisks.first { $0.owner == "loop-budget" })
    XCTAssertTrue(risk.accepted)
    XCTAssertEqual(risk.severity, "medium")
    XCTAssertEqual(manifest.costSummary?.totalTokens, 1_500)
  }

  func testProjectorRecordsWithinBudgetDecisionWithoutResidualRisk() throws {
    let workflow = Self.budgetWorkflow(budget: LoopBudgetDeclaration(maxTotalTokens: 10_000))
    let session = Self.session(executions: [Self.execution(totalTokens: 1_500)])
    let manifest = try XCTUnwrap(DefaultLoopEvidenceProjector().project(LoopEvidenceProjectionInput(
      workflow: workflow,
      session: session,
      workflowSource: Self.workflowSource
    )))

    let decision = try XCTUnwrap(manifest.policy.decisions.first { $0.policy == "budget" })
    XCTAssertEqual(decision.decision, "within-budget")
    XCTAssertTrue(manifest.residualRisks.filter { $0.owner == "loop-budget" }.isEmpty)
  }

  func testProjectorRecordsFailDecisionForBudgetExceededSession() throws {
    let workflow = Self.budgetWorkflow(budget: LoopBudgetDeclaration(maxTotalTokens: 1_000))
    var session = Self.session(executions: [Self.execution(totalTokens: 1_500)])
    session.status = .failed
    session.failureKind = .budgetExceeded
    let manifest = try XCTUnwrap(DefaultLoopEvidenceProjector().project(LoopEvidenceProjectionInput(
      workflow: workflow,
      session: session,
      workflowSource: Self.workflowSource
    )))

    let decision = try XCTUnwrap(manifest.policy.decisions.first { $0.policy == "budget" })
    XCTAssertEqual(decision.decision, "exceeded-fail")
    XCTAssertTrue(manifest.residualRisks.filter { $0.owner == "loop-budget" }.isEmpty)
  }

  func testProjectorRecordsNoBudgetDecisionForBudgetlessWorkflow() throws {
    let workflow = Self.budgetWorkflow(budget: nil)
    let session = Self.session(executions: [Self.execution(totalTokens: 1_500)])
    let manifest = try XCTUnwrap(DefaultLoopEvidenceProjector().project(LoopEvidenceProjectionInput(
      workflow: workflow,
      session: session,
      workflowSource: Self.workflowSource
    )))
    XCTAssertTrue(manifest.policy.decisions.filter { $0.policy == "budget" }.isEmpty)
  }

  // MARK: - Fixtures

  private static let workflowSource = LoopWorkflowSource(
    scope: "project",
    kind: "workflow-directory",
    workflowDirectory: "/tmp/runner-loop-budget",
    mutable: true
  )

  private static func budgetWorkflow(budget: LoopBudgetDeclaration?) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "runner-loop-budget",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "review",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "review-node", nodeFile: "nodes/review.json")],
      steps: [
        WorkflowStepRef(
          id: "review",
          nodeId: "review-node",
          role: .worker,
          transitions: [WorkflowStepTransition(toStepId: "review", label: "needs_work")],
          loop: WorkflowStepLoopMetadata(role: "gate", gateId: "implementation-review")
        )
      ],
      nodes: [WorkflowNodeRef(id: "review-node", nodeFile: "nodes/review.json")],
      loop: WorkflowLoopMetadata(
        required: false,
        budget: budget,
        gates: [LoopGateDeclaration(
          id: "implementation-review",
          stepId: "review",
          required: false,
          acceptWhen: LoopGateAcceptancePolicy(decision: .accepted)
        )]
      )
    )
  }

  private static func gateOutput(decision: String) -> AdapterExecutionOutput {
    AdapterExecutionOutput(
      provider: "test",
      model: "gpt-5.5",
      promptText: "prompt",
      completionPassed: true,
      when: ["always": true],
      payload: [
        "decision": .string(decision),
        "loopGate": .object([
          "gateId": .string("implementation-review"),
          "decision": .string(decision),
          "blockingFindings": .array([])
        ])
      ]
    )
  }

  private static func session(executions: [WorkflowStepExecution]) -> WorkflowSession {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return WorkflowSession(
      workflowId: "wf",
      sessionId: "session-budget",
      status: .running,
      entryStepId: "review",
      createdAt: date,
      updatedAt: date,
      executions: executions
    )
  }

  private static func execution(totalTokens: Int?) -> WorkflowStepExecution {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return WorkflowStepExecution(
      executionId: "review-exec",
      stepId: "review",
      nodeId: "review-node",
      attempt: 1,
      backend: .codexAgent,
      status: .completed,
      recentBackendEvents: totalTokens.map { total in
        [WorkflowBackendEventRecord(
          sequence: 1,
          at: date,
          eventType: "usage",
          channel: .usage,
          usage: ["total_tokens": .integer(Int64(total))]
        )]
      },
      createdAt: date,
      updatedAt: date
    )
  }
}

/// Emits a usage backend event before each output, mirroring how real agent
/// adapters surface token usage. An optional per-step delay makes wall-clock
/// budget bounds observable in tests.
private actor UsageEmittingAdapter: NodeAdapter {
  private var outputs: [(AdapterExecutionOutput, Int)]
  private let delayMs: Int

  init(outputs: [(AdapterExecutionOutput, Int)], delayMs: Int = 0) {
    self.outputs = outputs
    self.delayMs = delayMs
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    guard !outputs.isEmpty else {
      throw AdapterExecutionError(.invalidOutput, "usage-emitting adapter exhausted")
    }
    if delayMs > 0 {
      try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
    }
    let (output, totalTokens) = outputs.removeFirst()
    await context.backendEventHandler?(AdapterBackendEvent(
      provider: "test",
      eventType: "usage",
      channel: .usage,
      usage: ["total_tokens": .integer(Int64(totalTokens))]
    ))
    return output
  }
}

private actor RunEventRecorder {
  private(set) var events: [WorkflowRunEvent] = []

  func record(_ event: WorkflowRunEvent) {
    events.append(event)
  }
}
