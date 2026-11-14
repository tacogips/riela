import Foundation

extension DeterministicWorkflowRunner {
  struct LoopConvergenceError: Error, Equatable, Sendable, CustomStringConvertible {
    var violation: LoopConvergenceViolation

    var description: String {
      violation.diagnostic
    }
  }

  func enforceRequiredLoopPolicyPreflight(_ request: DeterministicWorkflowRunRequest) throws {
    guard request.workflow.loop?.required == true else {
      return
    }
    let evidence = loopPolicyEvaluator.preflight(workflow: request.workflow, nodePayloads: request.nodePayloads)
    guard let denial = evidence.denials.first else {
      return
    }
    throw AdapterExecutionError(.policyBlocked, "loop policy denied \(denial.policy): \(denial.reason ?? denial.decision)")
  }

  func stdioPolicyContext(
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    payload: AgentNodePayload,
    request: DeterministicWorkflowRunRequest
  ) -> LoopPolicyStepDecision? {
    guard workflow.loop?.policies != nil else {
      return nil
    }
    let evidence = loopPolicyEvaluator.preflight(workflow: workflow, nodePayloads: request.nodePayloads)
    return loopPolicyEvaluator.evaluateStep(step: step, node: payload, workflowPolicy: evidence.effective)
  }

  func workflowRoutingReconciler(
    workflow: WorkflowDefinition,
    step: WorkflowStepRef
  ) -> OutputContractRoutingReconciler? {
    guard workflow.loop != nil else {
      return nil
    }
    guard step.loop?.gateId != nil || step.loop?.role == "gate" else {
      return nil
    }
    return reconcileCompletionReviewRouting
  }

  struct LoopBudgetViolationDetails: Equatable, Sendable {
    var diagnostic: String
    var consumedTokens: Int?
    var maxTotalTokens: Int?
    var elapsedMs: Int?
    var maxWallClockMs: Int?
  }

  /// Checks the authored loop budget against the session's accumulated cost and
  /// wall-clock at a step boundary, before the next step is dispatched.
  /// A violation always emits one `budget_exceeded` progress record with the
  /// consumed/allowed values. `onExceeded == "fail"` then fails the session
  /// with `budgetExceeded`; `"warn"` continues (the projector records the
  /// exceedance as a residual risk from the same deterministic inputs). Token
  /// bounds are enforced only on recorded totals — absent usage never
  /// fabricates a violation. Step-boundary entry point: reloads the session
  /// (so freshly persisted backend-event usage is visible) and enforces the
  /// authored budget. The first boundary is skipped — no step has completed
  /// yet.
  func enforceLoopBudgetAtStepBoundary(
    visitedSteps: Int,
    sessionId: String,
    workflow: WorkflowDefinition,
    eventHandler: WorkflowRunEventHandler?,
    budgetEventEmitted: inout Bool
  ) async throws {
    guard visitedSteps > 1, let budget = workflow.loop?.budget else {
      return
    }
    guard let refreshed = try await store.loadSession(id: sessionId) else {
      return
    }
    guard let violation = Self.loopBudgetViolationDetails(budget: budget, session: refreshed, now: Date()) else {
      return
    }
    if !budgetEventEmitted {
      budgetEventEmitted = true
      await emitRunEvent(
        budgetExceededEvent(workflow: workflow, session: refreshed, violation: violation, action: budget.onExceeded),
        handler: eventHandler
      )
    }
    if budget.onExceeded == "fail" {
      throw DeterministicWorkflowRunnerError.loopBudgetExceeded(violation.diagnostic)
    }
  }

  /// Enforces `budget.maxSessionAttempts` from the recovery lineage computed at
  /// entry. Only rerun increments the attempt number, so run/resume entries
  /// never trip this bound; lineage without an attempt number (legacy sources)
  /// is treated as attempt one and never fails closed retroactively.
  func enforceLoopSessionAttempts(
    lineage: LoopRecoveryLineage,
    workflow: WorkflowDefinition
  ) throws {
    guard let maxAttempts = workflow.loop?.budget?.maxSessionAttempts,
          let attempt = lineage.attemptNumber,
          attempt > maxAttempts else {
      return
    }
    throw DeterministicWorkflowRunnerError.loopBudgetExceeded(
      "loop budget exceeded: session attempt \(attempt) exceeds maxSessionAttempts \(maxAttempts)"
    )
  }

  /// Pure budget evaluation shared by runner enforcement and evidence
  /// projection. Returns a deterministic diagnostic when a bound is exceeded.
  static func loopBudgetViolation(
    budget: LoopBudgetDeclaration,
    session: WorkflowSession,
    now: Date
  ) -> String? {
    loopBudgetViolationDetails(budget: budget, session: session, now: now)?.diagnostic
  }

  static func loopBudgetViolationDetails(
    budget: LoopBudgetDeclaration,
    session: WorkflowSession,
    now: Date
  ) -> LoopBudgetViolationDetails? {
    if let maxTotalTokens = budget.maxTotalTokens {
      let summary = LoopCostSummary.make(from: LoopCostAccumulator.evidence(from: session.executions))
      if let total = summary.totalTokens, total > maxTotalTokens {
        return LoopBudgetViolationDetails(
          diagnostic: "loop budget exceeded: \(total) total tokens consumed; maximum is \(maxTotalTokens)",
          consumedTokens: total,
          maxTotalTokens: maxTotalTokens
        )
      }
    }
    if let maxWallClockMs = budget.maxWallClockMs {
      let elapsedMs = Int((now.timeIntervalSince(session.createdAt) * 1_000).rounded())
      if elapsedMs > maxWallClockMs {
        return LoopBudgetViolationDetails(
          diagnostic: "loop budget exceeded: session wall-clock \(elapsedMs)ms; maximum is \(maxWallClockMs)ms",
          elapsedMs: elapsedMs,
          maxWallClockMs: maxWallClockMs
        )
      }
    }
    return nil
  }

  private func budgetExceededEvent(
    workflow: WorkflowDefinition,
    session: WorkflowSession,
    violation: LoopBudgetViolationDetails,
    action: String
  ) -> WorkflowRunEvent {
    WorkflowRunEvent(
      type: .budgetExceeded,
      workflowId: workflow.workflowId,
      sessionId: session.sessionId,
      status: session.status,
      currentStepId: session.currentStepId,
      loopBudgetDiagnostic: violation.diagnostic,
      loopBudgetAction: action,
      loopBudgetConsumedTokens: violation.consumedTokens,
      loopBudgetMaxTotalTokens: violation.maxTotalTokens,
      loopBudgetElapsedMs: violation.elapsedMs,
      loopBudgetMaxWallClockMs: violation.maxWallClockMs,
      nodeExecutions: session.executions.count
    )
  }

  func enforceLoopConvergenceIfNeeded(
    publishResult: WorkflowPublicationResult,
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    request: DeterministicWorkflowRunRequest
  ) async throws {
    guard let convergence = workflow.loop?.convergence,
          step.loop?.gateId != nil || step.loop?.role == "gate" else {
      return
    }

    var tracker = LoopConvergenceTracker(declaration: convergence)
    let parser = loopGateParser(workflow: workflow)
    guard parser.result(from: publishResult.stepExecution) != nil else {
      return
    }
    var currentCheck: LoopConvergenceCheck?
    for execution in publishResult.session.executions {
      guard let result = parser.result(from: execution) else {
        continue
      }
      let check = tracker.recordGateVisit(
        gateId: result.gateId,
        decision: result.decision,
        findings: result.blockingFindings
      )
      if execution.executionId == publishResult.stepExecution.executionId {
        currentCheck = check
      }
    }

    guard let violation = currentCheck?.violation else {
      return
    }

    await emitRunEvent(loopStallEvent(
      workflowId: workflow.workflowId,
      session: publishResult.session,
      step: step,
      execution: publishResult.stepExecution,
      violation: violation,
      action: convergence.onStall
    ), handler: request.eventHandler)

    if convergence.onStall == .fail {
      throw LoopConvergenceError(violation: violation)
    }
  }

  private func loopStallEvent(
    workflowId: String,
    session: WorkflowSession,
    step: WorkflowStepRef,
    execution: WorkflowStepExecution,
    violation: LoopConvergenceViolation,
    action: LoopConvergenceStallAction
  ) -> WorkflowRunEvent {
    WorkflowRunEvent(
      type: .loopStall,
      workflowId: workflowId,
      sessionId: session.sessionId,
      status: session.status,
      currentStepId: session.currentStepId,
      stepId: step.id,
      nodeId: step.nodeId,
      executionId: execution.executionId,
      loopStallGateId: violation.gateId,
      loopStallViolationKind: violation.kind.rawValue,
      loopStallAction: action.rawValue,
      loopStallGateVisits: violation.gateVisits,
      loopStallRepeatedRounds: violation.repeatedRounds,
      loopStallFingerprints: violation.fingerprints.map(\.key),
      nodeExecutions: session.executions.count
    )
  }
}
