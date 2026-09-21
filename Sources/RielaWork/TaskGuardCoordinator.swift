import Foundation
import RielaCore

public struct RunnerGuardSignals: Equatable, Sendable {
  public var gateVisits: [String: Int]
  public var repeatedFindingRounds: [String: Int]

  public init(gateVisits: [String: Int] = [:], repeatedFindingRounds: [String: Int] = [:]) {
    self.gateVisits = gateVisits
    self.repeatedFindingRounds = repeatedFindingRounds
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
    let totalTokens = attempts
      .flatMap { $0.outcome?.costs ?? [] }
      .compactMap(\.totalTokens)
      .reduce(0, +)
    let idleMs = running?.lastBackendEventAt.map {
      max(0, Int(now.timeIntervalSince($0) * 1_000))
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
  public var resolution: DirectorResolution
  public var application: DecisionApplication

  public init(
    violations: [GuardViolation],
    evidence: [Evidence],
    resolution: DirectorResolution,
    application: DecisionApplication
  ) {
    self.violations = violations
    self.evidence = evidence
    self.resolution = resolution
    self.application = application
  }
}

public struct TaskGuardCoordinator: Sendable {
  public var store: WorkStore

  public init(store: WorkStore) {
    self.store = store
  }

  /// Persists every violation before director evaluation, then routes the
  /// resulting policy decision through the same durable applier humans use.
  public func evaluateAndApply(
    task: WorkTask,
    latestAttempt: Attempt?,
    snapshot: GuardSnapshot,
    completion: CompletionVerdict,
    failedStepId: String?,
    violationEvidenceIds: [EvidenceID],
    decisionId: DecisionID,
    decisionEvidenceId: EvidenceID,
    now: Date = Date()
  ) throws -> GuardDirectorApplication {
    let violations = WorkGuard.evaluate(policy: task.guardPolicy, snapshot: snapshot)
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
    try store.saveEvidence(evidence)
    let guardEvidence = zip(violations, violationEvidenceIds).map {
      GuardViolationEvidence(violation: $0.0, evidenceId: $0.1)
    }
    let resolution = DeterministicDirector.decide(DeterministicDirectorInput(
      task: task,
      latestAttempt: latestAttempt,
      attemptCount: snapshot.attemptCount,
      failedStepId: failedStepId,
      completion: completion,
      guardEvidence: guardEvidence
    ))
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
    let application = try store.applyDecision(
      decision,
      expectedTaskVersion: task.version,
      completion: completion,
      decisionEvidenceId: decisionEvidenceId
    )
    return GuardDirectorApplication(
      violations: violations,
      evidence: evidence,
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
