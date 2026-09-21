import Foundation
import RielaCore

public struct GuardViolationEvidence: Codable, Equatable, Sendable {
  public var violation: GuardViolation
  public var evidenceId: EvidenceID

  public init(violation: GuardViolation, evidenceId: EvidenceID) {
    self.violation = violation
    self.evidenceId = evidenceId
  }
}

/// Everything the policy director may inspect. It deliberately contains no
/// store or runner handle: directors decide, the dispatcher applies.
public struct DeterministicDirectorInput: Equatable, Sendable {
  public var task: WorkTask
  public var latestAttempt: Attempt?
  public var attemptCount: Int
  public var failedStepId: String?
  public var completion: CompletionVerdict
  public var guardEvidence: [GuardViolationEvidence]

  public init(
    task: WorkTask,
    latestAttempt: Attempt? = nil,
    attemptCount: Int = 0,
    failedStepId: String? = nil,
    completion: CompletionVerdict = .unmet([]),
    guardEvidence: [GuardViolationEvidence] = []
  ) {
    self.task = task
    self.latestAttempt = latestAttempt
    self.attemptCount = attemptCount
    self.failedStepId = failedStepId
    self.completion = completion
    self.guardEvidence = guardEvidence
  }
}

public struct DirectorResolution: Codable, Equatable, Sendable {
  public var kind: DecisionKind
  public var rule: String
  public var reason: String
  public var causedBy: [EvidenceID]

  public init(kind: DecisionKind, rule: String, reason: String, causedBy: [EvidenceID] = []) {
    self.kind = kind
    self.rule = rule
    self.reason = reason
    self.causedBy = causedBy
  }
}

/// The total, ordered policy table from design sections 6 and 17.
public enum DeterministicDirector {
  public static func decide(_ input: DeterministicDirectorInput) -> DirectorResolution {
    let violations = input.guardEvidence
    if let evidence = violations.first(where: { $0.violation.isBudget }) {
      return stop(evidence, rule: "budget-exhausted")
    }
    if let evidence = violations.first(where: { $0.violation.isConvergence }) {
      return stop(evidence, rule: "convergence-violated")
    }
    if let evidence = violations.first(where: { $0.violation.isInactivity }) {
      if input.task.director.deterministic.rerunOnInactivity, hasAttemptBudget(input) {
        return DirectorResolution(
          kind: .rerun(fromStepId: evidence.violation.stepId),
          rule: "inactivity-rerun",
          reason: evidence.violation.summary,
          causedBy: [evidence.evidenceId]
        )
      }
      return stop(evidence, rule: "inactivity-stop")
    }

    if let attempt = input.latestAttempt, attempt.outcome?.sessionStatus == .failed {
      let kind = attempt.outcome?.failureKind
      let rules = input.task.director.deterministic
      let rerunnable = (kind == .adapterFailure && rules.rerunOnAdapterFailure)
        || (kind == .nodeTimeout && rules.rerunOnNodeTimeout)
      if rerunnable, hasAttemptBudget(input) {
        return DirectorResolution(
          kind: .rerun(fromStepId: input.failedStepId),
          rule: "recoverable-attempt-failure",
          reason: "attempt failed with \(kind?.rawValue ?? "unknown")"
        )
      }
    }

    if let rejected = input.latestAttempt?.outcome?.latestGateResults.first(where: {
      $0.decision == .rejected || $0.decision == .needsWork
    }), input.task.director.deterministic.recoverOnGateRejection {
      return DirectorResolution(
        kind: .recover(fromGateId: rejected.gateId),
        rule: "gate-recovery",
        reason: "gate \(rejected.gateId) requires recovery"
      )
    }

    if input.completion == .satisfied {
      return DirectorResolution(kind: .accept, rule: "completion-satisfied", reason: "completion contract is satisfied")
    }
    if input.task.completion.requiresHumanAccept,
       input.completion == .unmet([.humanAcceptRequired]) {
      return DirectorResolution(kind: .wait(.human), rule: "human-accept-required", reason: "human acceptance is required")
    }
    return DirectorResolution(
      kind: .wait(.human),
      rule: "no-safe-automatic-decision",
      reason: "no deterministic rule can safely advance the task"
    )
  }

  private static func hasAttemptBudget(_ input: DeterministicDirectorInput) -> Bool {
    guard let limit = input.task.guardPolicy.budget?.maxAttempts else { return true }
    return input.attemptCount < limit
  }

  private static func stop(_ evidence: GuardViolationEvidence, rule: String) -> DirectorResolution {
    DirectorResolution(
      kind: .stop(GuardViolationRef(evidenceId: evidence.evidenceId, summary: evidence.violation.summary)),
      rule: rule,
      reason: evidence.violation.summary,
      causedBy: [evidence.evidenceId]
    )
  }
}

private extension GuardViolation {
  var isBudget: Bool {
    if case .budget = self { return true }
    return false
  }

  var isConvergence: Bool {
    switch self {
    case .gateVisitsExceeded, .repeatedFindings: return true
    case .inactivity, .budget: return false
    }
  }

  var isInactivity: Bool {
    if case .inactivity = self { return true }
    return false
  }

  var stepId: String? {
    if case let .inactivity(stepId, _) = self { return stepId }
    return nil
  }
}
