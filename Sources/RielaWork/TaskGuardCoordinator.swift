import Foundation
import RielaCore

public struct RunnerGuardSignals: Equatable, Sendable {
  public var gateVisits: [String: Int]
  public var repeatedFindingRounds: [String: Int]

  public init(gateVisits: [String: Int] = [:], repeatedFindingRounds: [String: Int] = [:]) {
    self.gateVisits = gateVisits
    self.repeatedFindingRounds = repeatedFindingRounds
  }

  public init(gateResults: [LoopGateResult]) {
    var tracker = LoopConvergenceTracker(declaration: LoopConvergenceDeclaration())
    var visits: [String: Int] = [:]
    var rounds: [String: Int] = [:]
    for gate in gateResults {
      let check = tracker.recordGateVisit(
        gateId: gate.gateId,
        decision: gate.decision,
        findings: gate.blockingFindings
      )
      visits[gate.gateId] = check.gateVisits
      rounds[gate.gateId] = check.repeatedRounds
    }
    self.init(gateVisits: visits, repeatedFindingRounds: rounds)
  }
}

/// Adapts runner state into the immutable task-level guard input without
/// reimplementing the runner's convergence or budget detectors.
public enum TaskGuardSnapshotAdapter {
  public static func make(
    attempts: [Attempt],
    session: WorkflowSession?,
    wallClockMs: Int,
    proposalCount: Int = 0,
    signals: RunnerGuardSignals = RunnerGuardSignals(),
    now: Date = Date()
  ) -> GuardSnapshot {
    let running = session?.executions.last(where: { $0.status == .running })
    var costsByExecution: [String: LoopCostEvidence] = [:]
    for attempt in attempts {
      for cost in attempt.outcome?.costs ?? [] {
        // Runner event replay may repeat a step's cumulative cost record. Its
        // attempt-scoped execution identity makes the latest record authoritative.
        costsByExecution["\(attempt.id.rawValue)\u{0}\(cost.stepExecutionId)"] = cost
      }
    }
    let totalTokens = costsByExecution.values
      .compactMap(\.totalTokens)
      .reduce(0, +)
    let idleMs = running.map {
      let lastProgress = $0.lastBackendEventAt ?? $0.createdAt
      return max(0, Int(now.timeIntervalSince(lastProgress) * 1_000))
    }
    return GuardSnapshot(
      attemptCount: attempts.count,
      totalTokens: totalTokens,
      wallClockMs: max(0, wallClockMs),
      proposalCount: max(0, proposalCount),
      activeStepId: running?.stepId,
      heartbeatBackend: running?.backend?.rawValue,
      idleMs: idleMs,
      gateVisits: signals.gateVisits,
      repeatedFindingRounds: signals.repeatedFindingRounds
    )
  }
}

public struct GuardDirectorApplication: Equatable, Sendable {
  public var violations: [GuardViolation]
  public var evidence: [Evidence]
  /// A warning persists evidence but deliberately does not force a decision.
  public var resolution: DirectorResolution?
  public var application: DecisionApplication?
  public var requiresDirectorChild: Bool

  public init(
    violations: [GuardViolation],
    evidence: [Evidence],
    resolution: DirectorResolution?,
    application: DecisionApplication?,
    requiresDirectorChild: Bool = false
  ) {
    self.violations = violations
    self.evidence = evidence
    self.resolution = resolution
    self.application = application
    self.requiresDirectorChild = requiresDirectorChild
  }
}

public struct TaskGuardCoordinator: Sendable {
  public var store: WorkStore

  public init(store: WorkStore) {
    self.store = store
  }

  public static func violations(
    task: WorkTask, latestAttempt: Attempt?, snapshot: GuardSnapshot, terminal: Bool = false
  ) -> [GuardViolation] {
    var violations = WorkGuard.evaluate(policy: task.guardPolicy, snapshot: snapshot)
    if terminal, let attempt = latestAttempt, attempt.state == .reconciled,
       attempt.outcome?.sessionStatus == .failed,
       let limit = task.guardPolicy.budget?.maxAttempts,
       snapshot.attemptCount >= limit {
      let rules = task.director.deterministic
      let kind = attempt.outcome?.failureKind
      if (kind == .adapterFailure && rules.rerunOnAdapterFailure)
        || (kind == .nodeTimeout && rules.rerunOnNodeTimeout) {
        violations.append(.budget(.attempts, used: snapshot.attemptCount, limit: limit))
      }
    }
    return violations
  }

  /// Persists every violation before director evaluation, then routes the
  /// resulting policy decision through the same durable applier humans use.
  public func evaluateAndApply(
    task: WorkTask,
    latestAttempt: Attempt?,
    snapshot: GuardSnapshot,
    completion: CompletionVerdict,
    failedStepId: String?,
    attemptFailureEvidenceId: EvidenceID? = nil,
    gateEvidenceIds: [String: EvidenceID] = [:],
    completionEvidenceIds: [EvidenceID] = [],
    violationEvidenceIds: [EvidenceID],
    decisionId: DecisionID,
    decisionEvidenceId: EvidenceID,
    liveInactivityObservation: LiveInactivityObservation? = nil,
    terminal: Bool = false,
    now: Date = Date()
  ) throws -> GuardDirectorApplication {
    let violations = Self.violations(
      task: task, latestAttempt: latestAttempt, snapshot: snapshot, terminal: terminal
    )
    guard violations.count == violationEvidenceIds.count else {
      throw WorkStoreError("one evidence id is required for every guard violation")
    }
    let evidence = zip(violations, violationEvidenceIds).map { violation, id in
      Evidence(
        id: id,
        taskId: task.id,
        attemptId: latestAttempt?.id,
        kind: .guardViolation,
        producedBy: .runtime,
        payloadRef: .inline(Self.payload(for: violation)),
        createdAt: now
      )
    }
    let canonicalEvidence = try store.saveImmutableGuardEvidence(evidence)
    // Warnings preserve non-budget observations without forcing a policy
    // action. Budget exhaustion is always actionable: warn must not let a
    // task exceed an admitted resource limit.
    if task.guardPolicy.onViolation == .warn,
       !violations.isEmpty,
       !violations.contains(where: { $0.isBudgetViolation }) {
      return GuardDirectorApplication(
        violations: violations,
        evidence: canonicalEvidence,
        resolution: nil,
        application: nil
      )
    }
    let guardEvidence = zip(violations, violationEvidenceIds).map {
      GuardViolationEvidence(violation: $0.0, evidenceId: $0.1)
    }
    let deterministicResolution = DeterministicDirector.decide(DeterministicDirectorInput(
      task: task,
      latestAttempt: latestAttempt,
      attemptCount: snapshot.attemptCount,
      failedStepId: failedStepId,
      attemptFailureEvidenceId: attemptFailureEvidenceId,
      gateEvidenceIds: gateEvidenceIds,
      completion: completion,
      completionEvidenceIds: completionEvidenceIds,
      guardEvidence: guardEvidence
    ))
    let resolution: DirectorResolution
    if task.guardPolicy.onViolation == .fail,
       let evidenceId = deterministicResolution.causedBy.first,
       let violation = guardEvidence.first(where: { $0.evidenceId == evidenceId }) {
      resolution = DirectorResolution(
        kind: .stop(GuardViolationRef(evidenceId: evidenceId, summary: violation.violation.summary)),
        rule: "guard-policy-fail",
        reason: violation.violation.summary,
        causedBy: [evidenceId]
      )
    } else {
      resolution = deterministicResolution
    }
    let guardEscalation =
      task.director.humanEscalation.escalateOnGuardViolation
        && task.guardPolicy.onViolation == .askDirector && !violations.isEmpty
        && !violations.contains(where: { $0.isBudgetViolation })
        && !completion.isSatisfied
    let permitsFailedEscalation: Bool
    switch resolution.kind {
    case .wait(.human), .rerun: permitsFailedEscalation = true
    default: permitsFailedEscalation = false
    }
    let hasCapacity = task.guardPolicy.budget?.maxAttempts.map { snapshot.attemptCount < $0 } ?? true
    let failedEscalation = permitsFailedEscalation && hasCapacity
      && (task.director.humanEscalation.escalateAfterFailedAttempts.map {
        snapshot.attemptCount >= $0 && latestAttempt?.outcome?.sessionStatus == .failed
      } ?? false)
    if task.director.agentWorkflow != nil, latestAttempt?.entry != .director,
       latestAttempt?.state == .reconciled, guardEscalation || failedEscalation {
      return GuardDirectorApplication(
        violations: violations, evidence: canonicalEvidence,
        resolution: resolution, application: nil, requiresDirectorChild: true
      )
    }
    let decision = Decision(
      id: decisionId,
      taskId: task.id,
      attemptId: latestAttempt?.id,
      producer: .policy(rule: resolution.rule),
      kind: resolution.kind,
      reason: resolution.reason,
      causedBy: resolution.causedBy,
      createdAt: now
    )
    let pendingReservation = resolution.kind.requestedEntry.map {
      PendingAttemptReservation(
        id: "pending-\(decisionId.rawValue)",
        taskId: task.id,
        decisionId: decisionId,
        predecessorAttemptId: latestAttempt?.id,
        entry: $0
      )
    }
    let application = try store.applyDecision(
      decision,
      expectedTaskVersion: task.version,
      completion: completion,
      decisionEvidenceId: decisionEvidenceId,
      pendingReservation: pendingReservation,
      liveInactivityObservation: liveInactivityObservation
    )
    return GuardDirectorApplication(
      violations: violations,
      evidence: canonicalEvidence,
      resolution: resolution,
      application: application
    )
  }

  private static func payload(for violation: GuardViolation) -> JSONObject {
    var payload: JSONObject = ["summary": .string(violation.summary)]
    switch violation {
    case let .inactivity(stepId, idleMs):
      payload["kind"] = .string("inactivity")
      payload["stepId"] = .string(stepId)
      payload["idleMs"] = .integer(Int64(idleMs))
    case let .gateVisitsExceeded(gateId, visits):
      payload["kind"] = .string("gateVisitsExceeded")
      payload["gateId"] = .string(gateId)
      payload["visits"] = .integer(Int64(visits))
    case let .repeatedFindings(gateId, rounds):
      payload["kind"] = .string("repeatedFindings")
      payload["gateId"] = .string(gateId)
      payload["rounds"] = .integer(Int64(rounds))
    case let .budget(dimension, used, limit):
      payload["kind"] = .string("budget")
      payload["dimension"] = .string(dimension.rawValue)
      payload["used"] = .integer(Int64(used))
      payload["limit"] = .integer(Int64(limit))
    }
    return payload
  }

}

private extension DecisionKind {
  var requestedEntry: AttemptEntry? {
    switch self {
    case .start: .start
    case .resume: .resume
    case let .rerun(fromStepId): .rerunFromStep(fromStepId)
    case let .recover(fromGateId): .recoverFromGate(fromGateId)
    default: nil
    }
  }
}

private extension GuardViolation {
  var isBudgetViolation: Bool {
    if case .budget = self { return true }
    return false
  }
}
