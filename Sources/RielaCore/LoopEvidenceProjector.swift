import Foundation

public struct LoopEvidenceProjectionInput: Sendable {
  public var workflow: WorkflowDefinition
  public var session: WorkflowSession
  public var workflowMessages: [WorkflowMessageRecord]
  public var workflowSource: LoopWorkflowSource
  public var variables: JSONObject
  public var recovery: LoopRecoveryLineage?
  public var policy: LoopPolicyEvidence
  public var includeWorkflowWithoutLoopMetadata: Bool
  /// Per-step cost evidence from the runner's live usage accumulator. The
  /// projector consumes this directly; it never re-reads persisted event rows
  /// (which drop the usage payload). Empty for pre-existing sessions and for
  /// runs where no usage was observed, in which case cost renders as not
  /// recorded rather than zero.
  public var costs: [LoopCostEvidence]

  public init(
    workflow: WorkflowDefinition,
    session: WorkflowSession,
    workflowMessages: [WorkflowMessageRecord] = [],
    workflowSource: LoopWorkflowSource,
    variables: JSONObject = [:],
    recovery: LoopRecoveryLineage? = nil,
    policy: LoopPolicyEvidence = LoopPolicyEvidence(),
    includeWorkflowWithoutLoopMetadata: Bool = false,
    costs: [LoopCostEvidence] = []
  ) {
    self.workflow = workflow
    self.session = session
    self.workflowMessages = workflowMessages
    self.workflowSource = workflowSource
    self.variables = variables
    self.recovery = recovery
    self.policy = policy
    self.includeWorkflowWithoutLoopMetadata = includeWorkflowWithoutLoopMetadata
    self.costs = costs
  }
}

public protocol LoopEvidenceProjecting: Sendable {
  func project(_ input: LoopEvidenceProjectionInput) throws -> LoopEvidenceManifest?
}

public struct DefaultLoopEvidenceProjector: LoopEvidenceProjecting {
  public init() {}

  public func project(_ input: LoopEvidenceProjectionInput) throws -> LoopEvidenceManifest? {
    guard input.workflow.loop != nil || input.includeWorkflowWithoutLoopMetadata else {
      return nil
    }

    let artifactRefs = artifactRefs(from: input.workflowMessages)
    // Prefer explicit accumulator output; otherwise recover cost from the
    // session's executions' recorded backend-event usage.
    let costs = input.costs.isEmpty
      ? LoopCostAccumulator.evidence(from: input.session.executions)
      : input.costs
    let projectedGateResults = input.workflow.loop.map { gateResults(from: input, loop: $0) } ?? []
    let projectedConvergence = convergenceProjection(from: input)
    let updatedAt = input.session.executions.map(\.updatedAt).max() ?? input.session.updatedAt
    let budgetProjection = budgetProjection(from: input, costs: costs, now: updatedAt)
    let evidenceTagsByStepId = Dictionary(uniqueKeysWithValues: input.workflow.steps.map { ($0.id, $0.loop?.evidenceTags ?? []) })

    return LoopEvidenceManifest(
      schemaVersion: 1,
      manifestId: "loop-evidence-\(input.session.sessionId)",
      workflowId: input.workflow.workflowId,
      sessionId: input.session.sessionId,
      workflowSource: input.workflowSource,
      workflowDefinitionDigest: nil,
      variablesDigest: nil,
      worktree: nil,
      policy: mergedPolicy(input.policy, budgetDecision: budgetProjection.decision),
      recovery: input.recovery,
      convergence: projectedConvergence.evidence,
      costs: costs,
      costSummary: costs.isEmpty ? nil : LoopCostSummary.make(from: costs),
      steps: input.session.executions.map { execution in
        LoopStepEvidence(
          stepId: execution.stepId,
          nodeId: execution.nodeId,
          stepExecutionId: execution.executionId,
          backend: execution.backend?.rawValue,
          model: execution.adapterOutput?.model,
          status: execution.status.rawValue,
          artifactRefs: artifactRefsByExecutionId(from: input.workflowMessages)[execution.executionId] ?? [],
          acceptedOutputSummary: acceptedOutputSummary(execution.acceptedOutput?.payload),
          evidenceTags: evidenceTagsByStepId[execution.stepId] ?? []
        )
      },
      gates: projectedGateResults,
      artifacts: artifactRefs,
      changedFiles: [],
      commands: [],
      verification: [],
      implementationPlans: [],
      residualRisks: projectedConvergence.residualRisks + budgetProjection.residualRisks,
      redaction: redactionSummary(loop: input.workflow.loop),
      createdAt: input.session.createdAt,
      updatedAt: updatedAt
    )
  }

  /// Projects the declared loop budget into evidence: a policy decision that
  /// records consumption against the declared bounds, plus an accepted
  /// residual risk when a warn-mode budget was exceeded. Evaluation is
  /// deterministic — wall-clock uses the session's persisted timestamps, and
  /// a session failed with `budgetExceeded` always records the fail decision
  /// even when re-evaluation from persisted rows cannot reproduce the live
  /// reading.
  private func budgetProjection(
    from input: LoopEvidenceProjectionInput,
    costs: [LoopCostEvidence],
    now: Date
  ) -> (decision: LoopPolicyDecision?, residualRisks: [LoopResidualRisk]) {
    guard let budget = input.workflow.loop?.budget else {
      return (nil, [])
    }
    let violation = DeterministicWorkflowRunner.loopBudgetViolationDetails(
      budget: budget, session: input.session, now: now
    )
    let consumedTokens = LoopCostSummary.make(from: costs).totalTokens.map(String.init) ?? "unrecorded"
    let bounds = [
      budget.maxTotalTokens.map { "maxTotalTokens=\($0)" },
      budget.maxWallClockMs.map { "maxWallClockMs=\($0)" },
      budget.maxSessionAttempts.map { "maxSessionAttempts=\($0)" }
    ].compactMap { $0 }.joined(separator: ", ")
    if input.session.failureKind == .budgetExceeded {
      return (LoopPolicyDecision(
        id: "loop-budget",
        policy: "budget",
        decision: "exceeded-fail",
        reason: violation?.diagnostic
          ?? "session failed with budgetExceeded (consumed \(consumedTokens) tokens; declared \(bounds))"
      ), [])
    }
    guard let violation else {
      return (LoopPolicyDecision(
        id: "loop-budget",
        policy: "budget",
        decision: "within-budget",
        reason: "consumed \(consumedTokens) tokens; declared \(bounds)"
      ), [])
    }
    let decision = LoopPolicyDecision(
      id: "loop-budget",
      policy: "budget",
      decision: budget.onExceeded == "warn" ? "exceeded-warn" : "exceeded-fail",
      reason: violation.diagnostic
    )
    guard budget.onExceeded == "warn" else {
      return (decision, [])
    }
    return (decision, [LoopResidualRisk(
      severity: "medium",
      message: violation.diagnostic,
      owner: "loop-budget",
      accepted: true
    )])
  }

  private func mergedPolicy(
    _ policy: LoopPolicyEvidence,
    budgetDecision: LoopPolicyDecision?
  ) -> LoopPolicyEvidence {
    guard let budgetDecision else {
      return policy
    }
    var merged = policy
    merged.decisions.append(budgetDecision)
    return merged
  }

  private func redactionSummary(loop: WorkflowLoopMetadata?) -> LoopRedactionSummary {
    var warnings = [
      "workflowDefinitionDigest, variablesDigest, worktree, changedFiles, commands, verification, and implementationPlans are not projected in this slice"
    ]
    if loop == nil {
      warnings.append("workflow.loop metadata is absent; explicit projection includes runtime step evidence only")
    }
    return LoopRedactionSummary(
      policyName: loop?.policies?.redaction?.secretPolicy ?? "not-configured",
      status: "summary-only",
      warnings: warnings
    )
  }

  private func convergenceProjection(from input: LoopEvidenceProjectionInput) -> (
    evidence: LoopConvergenceEvidence?, residualRisks: [LoopResidualRisk]
  ) {
    guard let declaration = input.workflow.loop?.convergence else {
      return (nil, [])
    }
    var tracker = LoopConvergenceTracker(declaration: declaration)
    let parser = loopGateParser(workflow: input.workflow)
    var gateVisitCounts: [String: Int] = [:]
    var violation: LoopConvergenceViolation?
    for execution in input.session.executions {
      guard let result = parser.result(from: execution) else {
        continue
      }
      let check = tracker.recordGateVisit(
        gateId: result.gateId,
        decision: result.decision,
        findings: result.blockingFindings
      )
      gateVisitCounts[result.gateId] = check.gateVisits
      violation = violation ?? check.violation
    }
    let evidence = LoopConvergenceEvidence(
      gateVisitCounts: gateVisitCounts,
      stallDetected: violation != nil,
      stalledGateId: violation?.gateId,
      repeatedRounds: violation?.repeatedRounds,
      action: violation == nil ? nil : declaration.onStall.rawValue,
      diagnostics: [violation?.diagnostic].compactMap { $0 }
    )
    guard declaration.onStall == .warn, let violation else {
      return (evidence, [])
    }
    return (evidence, [LoopResidualRisk(
      severity: "high",
      message: violation.diagnostic,
      owner: "loop-convergence-guard",
      accepted: true
    )])
  }

  private func gateResults(from input: LoopEvidenceProjectionInput, loop: WorkflowLoopMetadata) -> [LoopGateResult] {
    let parser = loopGateParser(workflow: input.workflow)
    var results: [LoopGateResult] = input.session.executions.compactMap { execution in
      parser.result(from: execution)
    }

    let resultGateIds = Set(results.map(\.gateId))
    for gate in loop.gates where gate.required && !resultGateIds.contains(gate.id) {
      results.append(missingRequiredGateResult(gate: gate))
    }
    return results
  }

  private func missingRequiredGateResult(gate: LoopGateDeclaration) -> LoopGateResult {
    LoopGateResult(
      gateId: gate.id,
      stepId: gate.stepId,
      stepExecutionId: "missing",
      decision: .rejected,
      severityCounts: LoopFindingSeverityCounts(high: 1),
      blockingFindings: [
        LoopBlockingFinding(
          id: "missing-required-gate-\(gate.id)",
          severity: "high",
          message: "Required loop gate did not produce a structured loopGate result"
        )
      ],
      diagnostics: ["required loop gate '\(gate.id)' was missing from accepted outputs"]
    )
  }
}

private func artifactRefs(from messages: [WorkflowMessageRecord]) -> [LoopArtifactRef] {
  Array(Set(messages.flatMap(\.artifactRefs))).sorted().map { ref in
    LoopArtifactRef(
      id: ref,
      path: ref,
      kind: "runtime-artifact",
      digest: nil,
      producerStepExecutionId: messages.first { $0.artifactRefs.contains(ref) }?.sourceStepExecutionId,
      redactionStatus: "unknown",
      retentionClass: "runtime-owned"
    )
  }
}

private func artifactRefsByExecutionId(from messages: [WorkflowMessageRecord]) -> [String: [String]] {
  var result: [String: Set<String>] = [:]
  for message in messages {
    result[message.sourceStepExecutionId, default: []].formUnion(message.artifactRefs)
  }
  return result.mapValues { Array($0).sorted() }
}

private func acceptedOutputSummary(_ payload: JSONObject?) -> String? {
  guard let payload else {
    return nil
  }
  let value = JSONValue.object(payload)
  guard let summary = try? value.compactJSONString() else {
    return nil
  }
  return summary.count > 500 ? String(summary.prefix(497)) + "..." : summary
}
