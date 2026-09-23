import Foundation
import RielaCore

/// The work result presented to one optional agent director round. The judged
/// attempt is retained even after a newer director attempt finishes.
public struct AgentDirectorTaskView: Codable, Equatable, Sendable {
  public let task: WorkTask
  public let judgedAttempt: Attempt
  public let completion: CompletionVerdict
  public let guardViolations: [GuardViolation]
  public let openFindings: [Finding]
  public let evidenceSummary: [Evidence]
  public let remainingAttempts: Int

  public init(
    task: WorkTask,
    judgedAttempt: Attempt,
    completion: CompletionVerdict,
    guardViolations: [GuardViolation],
    openFindings: [Finding],
    evidenceSummary: [Evidence],
    remainingAttempts: Int
  ) {
    self.task = task
    self.judgedAttempt = judgedAttempt
    self.completion = completion
    self.guardViolations = guardViolations
    self.openFindings = openFindings
    self.evidenceSummary = evidenceSummary
    self.remainingAttempts = remainingAttempts
  }
}

public enum AgentDirectorValidation: Equatable, Sendable {
  case decision(Decision)
  case needsHuman(reason: String)
}

/// Checks one completed, nonrecursive child result. It does not launch a
/// workflow or write task state; the shared store applier owns application.
public enum AgentDirector {
  public static func validate(
    output: JSONObject,
    directorAttempt: Attempt,
    view: AgentDirectorTaskView,
    allowedKinds: Set<String>,
    causedBy: [EvidenceID],
    decisionId: DecisionID,
    now: Date = Date()
  ) -> AgentDirectorValidation {
    guard view.task.director.agentWorkflow != nil,
          view.task.id == view.judgedAttempt.taskId,
          view.task.id == directorAttempt.taskId,
          view.judgedAttempt.id != directorAttempt.id,
          view.judgedAttempt.state == .reconciled,
          view.judgedAttempt.entry != .director,
          directorAttempt.entry == .director,
          directorAttempt.state == .reconciled,
          directorAttempt.outcome?.sessionStatus == .completed,
          directorAttempt.generation > view.judgedAttempt.generation else {
      return .needsHuman(reason: "director child or judged work attempt is not terminal and nonrecursive")
    }
    guard case let .string(rawKind)? = output["kind"], allowedKinds.contains(rawKind) else {
      return .needsHuman(reason: "director output kind is missing or forbidden")
    }
    guard case let .string(rawReason)? = output["reason"] else {
      return .needsHuman(reason: "director output reason is missing")
    }
    let reason = rawReason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reason.isEmpty else {
      return .needsHuman(reason: "director output reason is empty")
    }

    let kind: DecisionKind
    let permittedKeys: Set<String>
    switch rawKind {
    case "accept":
      // Current store acceptance reads its newest attempt, which is the child.
      // Applying it now would judge child success instead of the work result.
      return .needsHuman(reason: "director acceptance requires judged-attempt completion support")
    case "reject":
      kind = .reject(reason: reason)
      permittedKeys = ["kind", "reason"]
    case "cancel":
      kind = .cancel
      permittedKeys = ["kind", "reason"]
    case "rerun":
      guard view.remainingAttempts > 0 else {
        return .needsHuman(reason: "director rerun exceeds the remaining attempt budget")
      }
      let stepId: String?
      if let value = output["fromStepId"] {
        guard case let .string(step) = value, !step.isEmpty else {
          return .needsHuman(reason: "director rerun step is invalid")
        }
        stepId = step
      } else {
        stepId = nil
      }
      kind = .rerun(fromStepId: stepId)
      permittedKeys = ["kind", "reason", "fromStepId"]
    case "recover":
      guard view.remainingAttempts > 0 else {
        return .needsHuman(reason: "director recovery exceeds the remaining attempt budget")
      }
      guard case let .string(gateId)? = output["fromGateId"], !gateId.isEmpty else {
        return .needsHuman(reason: "director recovery gate is missing")
      }
      kind = .recover(fromGateId: gateId)
      permittedKeys = ["kind", "reason", "fromGateId"]
    case "wait":
      guard case let .object(wait)? = output["wait"],
            wait.count == 1, case .string("human")? = wait["kind"] else {
        return .needsHuman(reason: "director wait must request a human decision")
      }
      kind = .wait(.human)
      permittedKeys = ["kind", "reason", "wait"]
    default:
      return .needsHuman(reason: "director output kind is outside P1 actions")
    }
    guard Set(output.keys).isSubset(of: permittedKeys) else {
      return .needsHuman(reason: "director output contains unsupported fields")
    }
    guard !requiresCausality(kind) || !causedBy.isEmpty else {
      return .needsHuman(reason: "director decision has no causal evidence")
    }
    var knownEvidence: [EvidenceID: Evidence] = [:]
    for evidence in view.evidenceSummary {
      guard knownEvidence.updateValue(evidence, forKey: evidence.id) == nil else {
        return .needsHuman(reason: "director task view contains duplicate evidence identity")
      }
    }
    guard causedBy.allSatisfy({ id in
      guard let evidence = knownEvidence[id] else { return false }
      return evidence.taskId == view.task.id && evidence.attemptId == view.judgedAttempt.id
    }) else {
      return .needsHuman(reason: "director causal evidence is outside the judged work attempt")
    }
    return .decision(Decision(
      id: decisionId,
      taskId: view.task.id,
      attemptId: view.judgedAttempt.id,
      producer: .agent(sessionId: directorAttempt.sessionId),
      kind: kind,
      reason: reason,
      causedBy: causedBy,
      createdAt: now
    ))
  }

  private static func requiresCausality(_ kind: DecisionKind) -> Bool {
    switch kind {
    case .reject, .cancel, .rerun, .recover: true
    default: false
    }
  }
}
