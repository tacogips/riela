import Foundation
import RielaCore
import XCTest
@testable import RielaWork

final class WorkGuardDispatcherTests: XCTestCase {
  private var root: URL!

  func testRunnerSignalsCountConsecutiveRepeatedFindingsAcrossAttempts() {
    let finding = LoopBlockingFinding(id: "finding-1", severity: "high", message: "same defect")
    let rejected = LoopGateResult(
      gateId: "review", stepId: "review", stepExecutionId: "first",
      decision: .needsWork, blockingFindings: [finding]
    )
    var repeated = rejected
    repeated.stepExecutionId = "second"
    let signals = RunnerGuardSignals(gateResults: [rejected, repeated])
    XCTAssertEqual(signals.gateVisits["review"], 2)
    XCTAssertEqual(signals.repeatedFindingRounds["review"], 2)

    var accepted = rejected
    accepted.stepExecutionId = "third"
    accepted.decision = .accepted
    let reset = RunnerGuardSignals(gateResults: [rejected, repeated, accepted])
    XCTAssertEqual(reset.gateVisits["review"], 3)
    XCTAssertEqual(reset.repeatedFindingRounds["review"], 0)
  }

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
        costs: [
          LoopCostEvidence(stepExecutionId: "execution-1", totalTokens: 13),
          LoopCostEvidence(stepExecutionId: "execution-1", totalTokens: 42)
        ]
      )
    )
    let laterAttempt = Attempt(
      id: AttemptID("attempt-2"),
      taskId: TaskID("task-1"),
      sessionId: "session-2",
      state: .terminal,
      outcome: AttemptOutcome(
        sessionStatus: .failed,
        costs: [LoopCostEvidence(stepExecutionId: "execution-1", totalTokens: 60)]
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
      attempts: [attempt, laterAttempt],
      session: session,
      wallClockMs: 20_000,
      signals: RunnerGuardSignals(gateVisits: ["review": 3], repeatedFindingRounds: ["review": 2]),
      now: now
    )
    XCTAssertEqual(snapshot.totalTokens, 102)
    XCTAssertEqual(snapshot.idleMs, 5_000)
    XCTAssertEqual(snapshot.heartbeatBackend, NodeExecutionBackend.codexAgent.rawValue)
    XCTAssertEqual(snapshot.gateVisits, ["review": 3])
  }

  func testGuardPersistenceConflictPreventsDependentDecisionAndTaskMutation() throws {
    let store = WorkStore(rootDirectory: root.path)
    var task = sampleTask()
    task.guardPolicy = GuardPolicy(
      inactivity: InactivityGuard(
        stallTimeoutMs: 1,
        monitorIntervalMs: 1,
        heartbeatBackends: [NodeExecutionBackend.codexAgent.rawValue]
      )
    )
    try store.saveTask(task)
    try store.saveImmutableGuardEvidence([Self.guardEvidence(
      id: "conflicting-guard", taskId: task.id, idleMs: 2,
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )])

    XCTAssertThrowsError(try TaskGuardCoordinator(store: store).evaluateAndApply(
      task: task,
      latestAttempt: nil,
      snapshot: GuardSnapshot(
        activeStepId: "agent",
        heartbeatBackend: NodeExecutionBackend.codexAgent.rawValue,
        idleMs: 1
      ),
      completion: .unmet([]),
      failedStepId: "agent",
      violationEvidenceIds: [EvidenceID("conflicting-guard")],
      decisionId: DecisionID("must-not-apply"),
      decisionEvidenceId: EvidenceID("must-not-apply-evidence")
    ))
    XCTAssertEqual(try store.loadTask(id: task.id), task)
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [])
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
    task.guardPolicy = GuardPolicy(budget: BudgetGuard(maxTotalTokens: 1), onViolation: .askDirector)
    task.state = .verifying
    try store.saveTask(task)
    let attempt = Attempt(
      id: AttemptID("attempt-1"),
      taskId: task.id,
      sessionId: "session-1",
      state: .terminal,
      outcome: AttemptOutcome(
        sessionStatus: .failed,
        failureKind: .adapterFailure,
        costs: [LoopCostEvidence(stepExecutionId: "execution-1", totalTokens: 1)]
      )
    )
    try store.saveAttempt(attempt)

    let result = try TaskGuardCoordinator(store: store).evaluateAndApply(
      task: task,
      latestAttempt: attempt,
      snapshot: GuardSnapshot(attemptCount: 1, totalTokens: 1),
      completion: .unmet([]),
      failedStepId: "agent",
      violationEvidenceIds: [EvidenceID("evidence-guard")],
      decisionId: DecisionID("decision-stop"),
      decisionEvidenceId: EvidenceID("evidence-decision")
    )

    XCTAssertEqual(result.resolution?.rule, "budget-exhausted")
    XCTAssertEqual(result.application?.task.state, .failed)
    XCTAssertEqual(result.application?.attempt?.state, .reconciled)
    let evidence = try store.listEvidence(taskId: task.id)
    XCTAssertEqual(Set(evidence.map(\.id)), [EvidenceID("evidence-guard"), EvidenceID("evidence-decision")])
    let decisionEvidence = try XCTUnwrap(evidence.first { $0.kind == .decision })
    XCTAssertEqual(decisionEvidence.causedBy, [EvidenceID("evidence-guard")])
  }

  func testCompleteGuardBatchPersistsBeforeTheSelectedPolicyAction() throws {
    let store = WorkStore(rootDirectory: root.path)
    var task = sampleTask()
    task.state = .verifying
    task.guardPolicy = GuardPolicy(
      inactivity: InactivityGuard(
        stallTimeoutMs: 1,
        monitorIntervalMs: 1,
        heartbeatBackends: [NodeExecutionBackend.codexAgent.rawValue]
      ),
      budget: BudgetGuard(maxTotalTokens: 1, maxWallClockMs: 1),
      onViolation: .askDirector
    )
    try store.saveTask(task)

    let result = try TaskGuardCoordinator(store: store).evaluateAndApply(
      task: task,
      latestAttempt: nil,
      snapshot: GuardSnapshot(
        totalTokens: 1,
        wallClockMs: 1,
        activeStepId: "agent",
        heartbeatBackend: NodeExecutionBackend.codexAgent.rawValue,
        idleMs: 1
      ),
      completion: .unmet([]),
      failedStepId: "agent",
      violationEvidenceIds: [
        EvidenceID("batch-tokens"), EvidenceID("batch-wall"), EvidenceID("batch-inactive")
      ],
      decisionId: DecisionID("batch-stop"),
      decisionEvidenceId: EvidenceID("batch-decision")
    )

    XCTAssertEqual(result.violations.count, 3)
    XCTAssertEqual(result.resolution?.rule, "budget-exhausted")
    XCTAssertEqual(
      Set(try store.listEvidence(taskId: task.id).map(\.id)),
      [EvidenceID("batch-tokens"), EvidenceID("batch-wall"), EvidenceID("batch-inactive"), EvidenceID("batch-decision")]
    )
  }

  func testConcurrentConflictingGuardBatchesCannotOverwriteOrPartiallyInsert() async throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = sampleTask()
    try store.saveTask(task)
    let canonical = Self.guardEvidence(
      id: "shared-guard",
      taskId: task.id,
      idleMs: 1,
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    XCTAssertEqual(try store.saveImmutableGuardEvidence([canonical]), [canonical])

    let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
      for index in 1...2 {
        group.addTask {
          do {
            _ = try store.saveImmutableGuardEvidence([
              Self.guardEvidence(
                id: "race-only-\(index)", taskId: task.id, idleMs: index,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
              ),
              Self.guardEvidence(
                id: "shared-guard", taskId: task.id, idleMs: 100 + index,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
              )
            ])
            return true
          } catch {
            return false
          }
        }
      }
      var values: [Bool] = []
      for await value in group { values.append(value) }
      return values
    }

    XCTAssertEqual(results, [false, false])
    XCTAssertEqual(try store.listEvidence(taskId: task.id), [canonical])
    let replay = try store.saveImmutableGuardEvidence([
      Self.guardEvidence(
        id: "shared-guard", taskId: task.id, idleMs: 1,
        createdAt: Date(timeIntervalSince1970: 1_800_000_999)
      )
    ])
    XCTAssertEqual(replay, [canonical], "equivalent replay must retain the first persisted record")
  }

  func testRecoverableFailureDecisionCarriesPersistedAttemptEvidence() throws {
    let store = WorkStore(rootDirectory: root.path)
    var task = sampleTask()
    task.state = .verifying
    try store.saveTask(task)
    let attempt = Attempt(
      id: AttemptID("attempt-1"), taskId: task.id, sessionId: "session-1", state: .terminal,
      outcome: AttemptOutcome(sessionStatus: .failed, failureKind: .adapterFailure)
    )
    try store.saveAttempt(attempt)
    let cause = Evidence(
      id: EvidenceID("attempt-failure"), taskId: task.id, attemptId: attempt.id,
      kind: .command, producedBy: .runtime,
      payloadRef: .inline(["failureKind": .string("adapter-failure")]), createdAt: Date()
    )
    try store.saveEvidence(cause)

    let result = try TaskGuardCoordinator(store: store).evaluateAndApply(
      task: task,
      latestAttempt: attempt,
      snapshot: GuardSnapshot(attemptCount: 1),
      completion: .unmet([]),
      failedStepId: "agent",
      attemptFailureEvidenceId: cause.id,
      violationEvidenceIds: [],
      decisionId: DecisionID("failure-rerun"),
      decisionEvidenceId: EvidenceID("failure-rerun-decision")
    )

    XCTAssertEqual(result.resolution?.kind, .rerun(fromStepId: "agent"))
    XCTAssertEqual(result.resolution?.causedBy, [cause.id])
    XCTAssertEqual(try store.listDecisions(taskId: task.id).first?.causedBy, [cause.id])
  }

  func testGateRecoveryDecisionCarriesPersistedGateEvidence() throws {
    let store = WorkStore(rootDirectory: root.path)
    var task = sampleTask()
    task.state = .verifying
    try store.saveTask(task)
    let gate = LoopGateResult(
      gateId: "review", stepId: "review", stepExecutionId: "review-1", decision: .needsWork
    )
    let attempt = Attempt(
      id: AttemptID("attempt-1"), taskId: task.id, sessionId: "session-1", state: .terminal,
      outcome: AttemptOutcome(sessionStatus: .completed, gateResults: [gate])
    )
    try store.saveAttempt(attempt)
    let cause = Evidence(
      id: EvidenceID("gate-review"), taskId: task.id, attemptId: attempt.id,
      kind: .gate, producedBy: .stepExecution("review-1"),
      payloadRef: .inline(["gateId": .string("review")]), createdAt: Date()
    )
    try store.saveEvidence(cause)

    let result = try TaskGuardCoordinator(store: store).evaluateAndApply(
      task: task,
      latestAttempt: attempt,
      snapshot: GuardSnapshot(attemptCount: 1),
      completion: .unmet([]),
      failedStepId: nil,
      gateEvidenceIds: ["review": cause.id],
      violationEvidenceIds: [],
      decisionId: DecisionID("gate-recovery"),
      decisionEvidenceId: EvidenceID("gate-recovery-decision")
    )

    XCTAssertEqual(result.resolution?.kind, .recover(fromGateId: "review"))
    XCTAssertEqual(result.resolution?.causedBy, [cause.id])
    XCTAssertEqual(try store.listDecisions(taskId: task.id).first?.causedBy, [cause.id])
  }

  func testWarnPersistsAnImmutableGuardBatchWithoutApplyingADecision() throws {
    let store = WorkStore(rootDirectory: root.path)
    var task = sampleTask()
    task.guardPolicy = GuardPolicy(
      inactivity: InactivityGuard(
        stallTimeoutMs: 1,
        monitorIntervalMs: 1,
        heartbeatBackends: [NodeExecutionBackend.codexAgent.rawValue]
      ),
      onViolation: .warn
    )
    try store.saveTask(task)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let result = try TaskGuardCoordinator(store: store).evaluateAndApply(
      task: task,
      latestAttempt: nil,
      snapshot: GuardSnapshot(
        activeStepId: "agent", heartbeatBackend: NodeExecutionBackend.codexAgent.rawValue, idleMs: 1
      ),
      completion: .unmet([]),
      failedStepId: nil,
      violationEvidenceIds: [EvidenceID("warning-guard")],
      decisionId: DecisionID("warning-decision"),
      decisionEvidenceId: EvidenceID("warning-decision-evidence"),
      now: now
    )

    XCTAssertNil(result.resolution)
    XCTAssertNil(result.application)
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [])
    XCTAssertEqual(try store.listEvidence(taskId: task.id).map(\.id), [EvidenceID("warning-guard")])

    let replay = try TaskGuardCoordinator(store: store).evaluateAndApply(
      task: task,
      latestAttempt: nil,
      snapshot: GuardSnapshot(
        activeStepId: "agent", heartbeatBackend: NodeExecutionBackend.codexAgent.rawValue, idleMs: 1
      ),
      completion: .unmet([]),
      failedStepId: nil,
      violationEvidenceIds: [EvidenceID("warning-guard")],
      decisionId: DecisionID("warning-decision"),
      decisionEvidenceId: EvidenceID("warning-decision-evidence"),
      now: now.addingTimeInterval(60)
    )
    XCTAssertEqual(replay.evidence, result.evidence)
  }

  func testWarnDoesNotBypassBudgetAtTheEqualityBoundary() throws {
    let store = WorkStore(rootDirectory: root.path)
    var task = sampleTask()
    task.guardPolicy = GuardPolicy(budget: BudgetGuard(maxTotalTokens: 1), onViolation: .warn)
    task.state = .verifying
    try store.saveTask(task)

    let result = try TaskGuardCoordinator(store: store).evaluateAndApply(
      task: task,
      latestAttempt: nil,
      snapshot: GuardSnapshot(totalTokens: 1),
      completion: .unmet([]),
      failedStepId: nil,
      violationEvidenceIds: [EvidenceID("warning-budget-guard")],
      decisionId: DecisionID("warning-budget-stop"),
      decisionEvidenceId: EvidenceID("warning-budget-decision")
    )

    XCTAssertEqual(result.resolution?.rule, "budget-exhausted")
    XCTAssertEqual(result.application?.task.state, .failed)
    XCTAssertEqual(try store.listDecisions(taskId: task.id).first?.kind, .stop(
      GuardViolationRef(evidenceId: EvidenceID("warning-budget-guard"), summary: "tokens budget exhausted (1/1)")
    ))
  }

  func testFailPolicyStopsInactivityInsteadOfRerunning() throws {
    let store = WorkStore(rootDirectory: root.path)
    var task = sampleTask()
    task.state = .running
    task.guardPolicy = GuardPolicy(
      inactivity: InactivityGuard(
        stallTimeoutMs: 1,
        monitorIntervalMs: 1,
        heartbeatBackends: [NodeExecutionBackend.codexAgent.rawValue]
      ),
      onViolation: .fail
    )
    try store.saveTask(task)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let fixture = try saveRunningInactivityFixture(store: store, task: task, now: now)
    let attempt = fixture.attempt
    let session = fixture.session
    let observation = fixture.observation

    let result = try TaskGuardCoordinator(store: store).evaluateAndApply(
      task: task,
      latestAttempt: attempt,
      snapshot: TaskGuardSnapshotAdapter.make(attempts: [attempt], session: session, wallClockMs: 0, now: now),
      completion: .unmet([]),
      failedStepId: "agent",
      violationEvidenceIds: [EvidenceID("inactivity-guard")],
      decisionId: DecisionID("inactivity-stop"),
      decisionEvidenceId: EvidenceID("inactivity-decision"),
      liveInactivityObservation: observation,
      now: now
    )

    XCTAssertEqual(result.resolution?.kind, .stop(GuardViolationRef(
      evidenceId: EvidenceID("inactivity-guard"), summary: "step agent was inactive for 1000ms"
    )))
    XCTAssertEqual(result.application?.task.state, .running)
    XCTAssertEqual(try store.listDecisions(taskId: task.id).map(\.kind), [result.resolution?.kind])
    XCTAssertNil(try TaskDispatcher(store: store).pendingReservation(taskId: task.id))

    let cancelledSession = WorkflowSession(
      workflowId: session.workflowId, sessionId: session.sessionId, status: .failed,
      entryStepId: "agent", currentStepId: "agent", createdAt: session.createdAt,
      updatedAt: now, failureKind: .cancelled
    )
    let cancelledSnapshot = WorkflowRuntimePersistenceSnapshot(session: cancelledSession)
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path).save(cancelledSnapshot)
    _ = try store.acknowledgeAttemptCancellation(
      attemptId: attempt.id, outcome: WorkEvidenceProjector.outcome(from: cancelledSnapshot)
    )
    XCTAssertEqual(try store.loadTask(id: task.id)?.state, .failed)
    XCTAssertEqual(try store.loadAttempt(id: attempt.id)?.state, .reconciled)
    XCTAssertNil(try TaskDispatcher(store: store).pendingReservation(taskId: task.id))
  }

  func testStaleInactivityObservationLeavesTaskAndAttemptDecisionUnchanged() throws {
    let store = WorkStore(rootDirectory: root.path)
    var task = sampleTask()
    task.state = .running
    task.guardPolicy = GuardPolicy(
      inactivity: InactivityGuard(
        stallTimeoutMs: 1, monitorIntervalMs: 1,
        heartbeatBackends: [NodeExecutionBackend.codexAgent.rawValue]
      ), onViolation: .fail
    )
    try store.saveTask(task)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let fixture = try saveRunningInactivityFixture(store: store, task: task, now: now)
    let attempt = fixture.attempt
    let session = fixture.session
    let observation = fixture.observation
    let stale = LiveInactivityObservation(
      taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId,
      executionId: observation.executionId, createdAt: observation.createdAt,
      lastBackendEventAt: now.addingTimeInterval(-2)
    )

    XCTAssertThrowsError(try TaskGuardCoordinator(store: store).evaluateAndApply(
      task: task, latestAttempt: attempt,
      snapshot: TaskGuardSnapshotAdapter.make(attempts: [attempt], session: session, wallClockMs: 0, now: now),
      completion: .unmet([]), failedStepId: "agent",
      violationEvidenceIds: [EvidenceID("stale-inactivity-guard")],
      decisionId: DecisionID("stale-inactivity-stop"),
      decisionEvidenceId: EvidenceID("stale-inactivity-decision"),
      liveInactivityObservation: stale, now: now
    )) { error in
      XCTAssertTrue(error is StaleInactivityObservation)
    }
    XCTAssertEqual(try store.loadTask(id: task.id), task)
    XCTAssertEqual(try store.loadAttempt(id: attempt.id), attempt)
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [])
    XCTAssertNil(try TaskDispatcher(store: store).pendingReservation(taskId: task.id))
    XCTAssertEqual(try store.listEvidence(taskId: task.id).map(\.id), [EvidenceID("stale-inactivity-guard")])
  }

  func testSatisfiedCompletionCarriesPersistedEvidenceThroughCoordinator() throws {
    let store = WorkStore(rootDirectory: root.path)
    var task = sampleTask()
    task.state = .verifying
    try store.saveTask(task)
    let attempt = Attempt(
      id: AttemptID("completion-attempt"), taskId: task.id, sessionId: "completion-session",
      state: .terminal, outcome: AttemptOutcome(sessionStatus: .completed)
    )
    try store.saveAttempt(attempt)
    let completionEvidence = Evidence(
      id: EvidenceID("completion-evidence"), taskId: task.id, attemptId: attempt.id,
      kind: .verification, producedBy: .runtime,
      payloadRef: .inline(["id": .string("tests"), "outcome": .string("passed")]), createdAt: Date()
    )
    try store.saveEvidence(completionEvidence)

    let result = try TaskGuardCoordinator(store: store).evaluateAndApply(
      task: task, latestAttempt: attempt, snapshot: GuardSnapshot(attemptCount: 1),
      completion: .satisfied, failedStepId: nil, completionEvidenceIds: [completionEvidence.id],
      violationEvidenceIds: [], decisionId: DecisionID("completion-decision"),
      decisionEvidenceId: EvidenceID("completion-decision-evidence")
    )

    XCTAssertEqual(result.resolution?.kind, .accept)
    XCTAssertEqual(result.resolution?.causedBy, [completionEvidence.id])
    XCTAssertEqual(result.application?.task.state, .succeeded)
    XCTAssertEqual(result.application?.attempt?.state, .reconciled)
    XCTAssertEqual(try store.listDecisions(taskId: task.id).first?.causedBy, [completionEvidence.id])
  }

  func testCompletionAcceptanceFailsClosedForMissingForeignAndStaleEvidence() throws {
    for causeScope in ["missing", "foreign", "stale"] {
      let caseRoot = root.appendingPathComponent(causeScope, isDirectory: true)
      try FileManager.default.createDirectory(at: caseRoot, withIntermediateDirectories: true)
      let store = WorkStore(rootDirectory: caseRoot.path)
      var task = sampleTask()
      task.id = TaskID("task-\(causeScope)")
      task.state = .verifying
      try store.saveTask(task)
      let attempt = Attempt(
        id: AttemptID("attempt-\(causeScope)"), taskId: task.id, sessionId: "session-\(causeScope)",
        state: .terminal, outcome: AttemptOutcome(sessionStatus: .completed)
      )
      try store.saveAttempt(attempt)
      let completionEvidenceId = EvidenceID("completion-\(causeScope)")
      if causeScope != "missing" {
        let evidence = Evidence(
          id: completionEvidenceId,
          taskId: causeScope == "foreign" ? TaskID("other-task") : task.id,
          attemptId: causeScope == "stale" ? AttemptID("older-attempt") : attempt.id,
          kind: .verification, producedBy: .runtime,
          payloadRef: .inline(["id": .string("tests"), "outcome": .string("passed")]), createdAt: Date()
        )
        try store.saveEvidence(evidence)
      }

      XCTAssertThrowsError(try TaskGuardCoordinator(store: store).evaluateAndApply(
        task: task, latestAttempt: attempt, snapshot: GuardSnapshot(attemptCount: 1),
        completion: .satisfied, failedStepId: nil, completionEvidenceIds: [completionEvidenceId],
        violationEvidenceIds: [], decisionId: DecisionID("decision-\(causeScope)"),
        decisionEvidenceId: EvidenceID("decision-evidence-\(causeScope)")
      )) { error in
        XCTAssertTrue(String(describing: error).contains(causeScope == "missing" ? "is missing" : "outside the task attempt scope"))
      }
      XCTAssertEqual(try XCTUnwrap(store.loadTask(id: task.id)).state, .verifying)
      XCTAssertEqual(try store.listDecisions(taskId: task.id), [])
    }
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

  private struct RunningInactivityFixture {
    let attempt: Attempt
    let session: WorkflowSession
    let observation: LiveInactivityObservation
  }

  private func saveRunningInactivityFixture(
    store: WorkStore, task: WorkTask, now: Date
  ) throws -> RunningInactivityFixture {
    let attempt = Attempt(
      id: AttemptID("inactivity-attempt"), taskId: task.id,
      sessionId: "inactivity-session", state: .running
    )
    try store.saveAttempt(attempt)
    let createdAt = now.addingTimeInterval(-10)
    let lastBackendEventAt = now.addingTimeInterval(-1)
    let execution = WorkflowStepExecution(
      executionId: "inactivity-execution", stepId: "agent", nodeId: "agent-node",
      attempt: 1, backend: .codexAgent, status: .running,
      lastBackendEventAt: lastBackendEventAt, createdAt: createdAt, updatedAt: now
    )
    let session = WorkflowSession(
      workflowId: "workflow", sessionId: attempt.sessionId, status: .running,
      entryStepId: "agent", currentStepId: "agent", createdAt: createdAt,
      updatedAt: now, executions: [execution]
    )
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path).save(
      WorkflowRuntimePersistenceSnapshot(session: session)
    )
    let observation = LiveInactivityObservation(
      taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId,
      executionId: execution.executionId, createdAt: execution.createdAt,
      lastBackendEventAt: execution.lastBackendEventAt
    )
    return RunningInactivityFixture(attempt: attempt, session: session, observation: observation)
  }

  private static func guardEvidence(
    id: String,
    taskId: TaskID,
    idleMs: Int,
    createdAt: Date
  ) -> Evidence {
    Evidence(
      id: EvidenceID(id), taskId: taskId, kind: .guardViolation, producedBy: .runtime,
      payloadRef: .inline([
        "kind": .string("inactivity"),
        "stepId": .string("agent"),
        "idleMs": .integer(Int64(idleMs)),
        "summary": .string("step agent was inactive for \(idleMs)ms")
      ]),
      createdAt: createdAt
    )
  }
}
