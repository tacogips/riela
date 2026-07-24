import Foundation

private let maximumReportedLoopFindingFingerprints = 8

public enum LoopConvergencePolicySource: String, Codable, Equatable, Sendable {
  case declared
  case defaultPolicy = "default"
  case stepBudget = "step-budget"
}

enum EffectiveLoopConvergencePolicy: Equatable, Sendable {
  case declared(LoopConvergenceDeclaration)
  case authoredInactive
  case disabled
  case defaultPolicy(LoopConvergenceDeclaration)

  static let synthesizedDefault = LoopConvergenceDeclaration(
    maxGateVisits: 4,
    maxRepeatedFindingRounds: 2
  )

  var declaration: LoopConvergenceDeclaration? {
    switch self {
    case let .declared(declaration), let .defaultPolicy(declaration):
      declaration
    case .authoredInactive, .disabled:
      nil
    }
  }

  var source: LoopConvergencePolicySource? {
    switch self {
    case .declared:
      .declared
    case .defaultPolicy:
      .defaultPolicy
    case .authoredInactive, .disabled:
      nil
    }
  }

  var isDefault: Bool {
    if case .defaultPolicy = self {
      return true
    }
    return false
  }
}

struct WorkflowTerminalReservationRedirect: Sendable {
  var result: WorkflowPendingStepRedirectResult
  var loopGuardOutcome: JSONValue
}

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
    step: WorkflowStepRef,
    disableDefaultLoopGuard: Bool = false
  ) -> OutputContractRoutingReconciler? {
    let effectivePolicy = effectiveLoopConvergencePolicy(
      workflow: workflow,
      disableDefaultLoopGuard: disableDefaultLoopGuard
    )
    guard workflow.loop != nil || effectivePolicy.isDefault else {
      return nil
    }
    guard step.loop?.gateId != nil || step.loop?.role == "gate" else {
      return nil
    }
    return reconcileCompletionReviewRouting
  }

  func workflowPrePersistenceRoutingDecider(
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    request: DeterministicWorkflowRunRequest
  ) -> WorkflowPrePersistenceRoutingDecider? {
    guard effectiveLoopConvergencePolicy(
      workflow: workflow,
      disableDefaultLoopGuard: request.disableDefaultLoopGuard
    ).isDefault,
      step.loop?.gateId != nil || step.loop?.role == "gate" else {
      return nil
    }
    return { context in
      Self.defaultLoopRoutingDecision(
        context: context,
        workflow: workflow,
        step: step
      )
    }
  }

  private static func defaultLoopRoutingDecision(
    context: WorkflowPrePersistenceRoutingContext,
    workflow: WorkflowDefinition,
    step: WorkflowStepRef
  ) -> WorkflowPrePersistenceRoutingDecision {
    var tracker = LoopConvergenceTracker(
      declaration: EffectiveLoopConvergencePolicy.synthesizedDefault
    )
    let parser = loopGateParser(workflow: workflow)
    var currentViolation: LoopConvergenceViolation?
    for execution in context.session.executions {
      let intendedStatus = execution.executionId == context.stepExecution.executionId
        ? context.intendedSuccessfulStatus
        : nil
      guard let result = parser.result(from: execution, intendedStatus: intendedStatus) else {
        continue
      }
      let check = tracker.recordGateVisit(
        gateId: result.gateId,
        decision: result.decision,
        findings: result.blockingFindings
      )
      if execution.executionId == context.stepExecution.executionId {
        currentViolation = check.violation
      }
    }
    guard let violation = currentViolation else {
      return .unchanged(context)
    }

    let guardPublication: WorkflowLoopGuardPublication
    let corridor = defaultViolationTerminalCorridor(
      workflow: workflow,
      originStepId: step.id,
      selectedTransitions: context.selectedTransitions
    )
    guard let corridor else {
      guardPublication = WorkflowLoopGuardPublication(
        violation: violation,
        action: .fail,
        policySource: .defaultPolicy
      )
      return WorkflowPrePersistenceRoutingDecision(
        selectedTransitions: [],
        routedPayload: context.payload,
        publishesRootOutput: false,
        completesRootWithoutOutput: false,
        loopGuard: guardPublication
      )
    }

    guardPublication = WorkflowLoopGuardPublication(
      violation: violation,
      action: .acceptWithResidualRisks,
      policySource: .defaultPolicy
    )
    return WorkflowPrePersistenceRoutingDecision(
      selectedTransitions: [WorkflowStepTransition(
        toStepId: corridor.entryStepId,
        label: "loop_guard_terminal"
      )],
      routedPayload: payload(
        context.payload,
        adding: convergenceGuardOutcome(violation: violation)
      ),
      publishesRootOutput: false,
      completesRootWithoutOutput: false,
      loopGuard: guardPublication
    )
  }

  private static func defaultViolationTerminalCorridor(
    workflow: WorkflowDefinition,
    originStepId: String,
    selectedTransitions: [WorkflowStepTransition]
  ) -> LoopTerminalCorridor? {
    let selector = LoopTerminalCorridorSelector()
    if selector.hasReachableDispatchBoundary(
      workflow: workflow,
      originStepId: originStepId,
      selectedOriginTransitions: selectedTransitions
    ) {
      return nil
    }
    if let selectedCorridor = selector.select(
      workflow: workflow,
      originStepId: originStepId,
      selectedOriginTransitions: selectedTransitions
    ) {
      return selectedCorridor
    }
    return selector.select(workflow: workflow, originStepId: originStepId)
  }

  static func payload(_ payload: JSONObject, adding outcome: JSONObject) -> JSONObject {
    var routed = payload
    routed["loopGuardOutcome"] = .object(outcome)
    return routed
  }

  func carriedLoopGuardPayload(from request: DeterministicWorkflowRunRequest) -> JSONObject {
    guard let outcome = request.variables["loopGuardOutcome"] else {
      return [:]
    }
    return ["loopGuardOutcome": outcome]
  }

  func recoveredLoopGuardPayload(sessionId: String, stepId: String) async throws -> JSONObject {
    // Recovery must read the persisted current-step input directly from the
    // store: session-entry resolution runs before interruptedSessionId is
    // armed, so a custom input resolver failing or cancelling here would skip
    // failure-metadata finalization and leave the session replayable.
    let resolvedInput = try await DefaultWorkflowMessageInputResolver().resolveInput(
      for: sessionId,
      stepId: stepId,
      store: store
    )
    guard let outcome = resolvedInput.payload["loopGuardOutcome"] else {
      return [:]
    }
    return ["loopGuardOutcome": outcome]
  }

  func redirectForTerminalReservationIfNeeded(
    session: WorkflowSession,
    currentStepId: String,
    workflow: WorkflowDefinition,
    request: DeterministicWorkflowRunRequest,
    visitedSteps: Int,
    maxSteps: Int
  ) async throws -> WorkflowTerminalReservationRedirect? {
    guard effectiveLoopConvergencePolicy(
      workflow: workflow,
      disableDefaultLoopGuard: request.disableDefaultLoopGuard
    ).isDefault,
      let corridor = LoopTerminalCorridorSelector().select(
        workflow: workflow,
        originStepId: currentStepId
      ),
      !corridor.contains(currentStepId) else {
      return nil
    }
    let reservedSteps = max(3, corridor.stepIds.count)
    let remainingSteps = maxSteps - visitedSteps
    guard
      maxSteps >= reservedSteps,
      remainingSteps >= corridor.stepIds.count,
      remainingSteps <= reservedSteps
    else {
      return nil
    }

    let resolved = try await inputResolver.resolveInput(
      for: session.sessionId,
      stepId: currentStepId,
      store: store
    )
    let delivered = resolved.messages.filter { $0.lifecycleStatus == .delivered }
    let latest = delivered.sorted {
      if $0.createdOrder == $1.createdOrder {
        return $0.communicationId < $1.communicationId
      }
      return $0.createdOrder < $1.createdOrder
    }.last
    var payload = resolved.payload
    payload.removeValue(forKey: "_rielaInput")
    let outcome: JSONObject = [
      "decision": .string(WorkflowLoopGuardAction.acceptWithResidualRisks.rawValue),
      "trigger": .string("terminal-step-reserve"),
      "policySource": .string(LoopConvergencePolicySource.stepBudget.rawValue),
      "stepBudget": .integer(Int64(maxSteps)),
      "visitedSteps": .integer(Int64(visitedSteps)),
      "reservedTerminalSteps": .integer(Int64(reservedSteps)),
      "residualRisks": .array([
        .string("step budget reserved for terminal workflow stages")
      ])
    ]
    payload["loopGuardOutcome"] = .object(outcome)
    let sourceExecutionId = latest?.sourceStepExecutionId
      ?? session.executions.last?.executionId
      ?? "terminal-step-reserve"
    let replacement = WorkflowMessageAppendInput(
      workflowExecutionId: session.sessionId,
      fromStepId: latest?.fromStepId ?? session.executions.last?.stepId,
      toStepId: corridor.entryStepId,
      routingScope: .workflow,
      deliveryKind: .direct,
      sourceStepExecutionId: sourceExecutionId,
      transitionCondition: "terminal-step-reserve",
      payload: payload,
      artifactRefs: Array(Set(delivered.flatMap(\.artifactRefs))).sorted()
    )
    let result = try await store.redirectPendingWorkflowStep(WorkflowPendingStepRedirectInput(
      sessionId: session.sessionId,
      expectedCurrentStepId: currentStepId,
      displacedCommunicationIds: delivered.map(\.communicationId),
      replacementMessage: replacement
    ))
    return WorkflowTerminalReservationRedirect(
      result: result,
      loopGuardOutcome: .object(outcome)
    )
  }

  private static func convergenceGuardOutcome(violation: LoopConvergenceViolation) -> JSONObject {
    [
      "decision": .string(WorkflowLoopGuardAction.acceptWithResidualRisks.rawValue),
      "policySource": .string(LoopConvergencePolicySource.defaultPolicy.rawValue),
      "gateId": .string(violation.gateId),
      "violationKind": .string(violation.kind.rawValue),
      "gateVisits": .integer(Int64(violation.gateVisits)),
      "repeatedRounds": .integer(Int64(violation.repeatedRounds)),
      "findingFingerprints": .array(
        violation.fingerprints.prefix(maximumReportedLoopFindingFingerprints).map { .string($0.key) }
      ),
      "residualRisks": .array([
        .string("default loop convergence guard stopped further revision")
      ])
    ]
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
    if let loopGuard = publishResult.loopGuard {
      await emitRunEvent(loopStallEvent(
        workflowId: workflow.workflowId,
        session: publishResult.session,
        step: step,
        execution: publishResult.stepExecution,
        violation: loopGuard.violation,
        action: loopGuard.action.rawValue,
        policySource: loopGuard.policySource
      ), handler: request.eventHandler)
      if loopGuard.action == .fail {
        throw LoopConvergenceError(violation: loopGuard.violation)
      }
      return
    }

    guard let convergence = workflow.loop?.convergence,
          convergence.enabled,
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
      action: convergence.onStall.rawValue,
      policySource: .declared
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
    action: String,
    policySource: LoopConvergencePolicySource
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
      loopStallAction: action,
      loopStallGateVisits: violation.gateVisits,
      loopStallRepeatedRounds: violation.repeatedRounds,
      loopStallFingerprints: violation.fingerprints
        .prefix(maximumReportedLoopFindingFingerprints)
        .map(\.key),
      loopStallPolicySource: policySource.rawValue,
      nodeExecutions: session.executions.count
    )
  }

  func effectiveLoopConvergencePolicy(
    workflow: WorkflowDefinition,
    disableDefaultLoopGuard: Bool = false
  ) -> EffectiveLoopConvergencePolicy {
    if let loop = workflow.loop {
      guard let convergence = loop.convergence else {
        return .authoredInactive
      }
      return convergence.enabled ? .declared(convergence) : .disabled
    }
    return disableDefaultLoopGuard
      ? .disabled
      : .defaultPolicy(EffectiveLoopConvergencePolicy.synthesizedDefault)
  }
}
