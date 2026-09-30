import Foundation

public struct HandoverBriefRenderer: Sendable {
  public init() {}

  public func render(_ packet: HandoverPacket) -> String {
    render(packet, progressNote: nil)
  }

  func render(_ packet: HandoverPacket, progressNote: String?) -> String {
    var lines = ["# Handover \(packet.id.rawValue)", "", "Task: \(packet.taskId.rawValue)", "Intent: \(packet.intentId.rawValue)", "", "## Why", reasonText(packet.reason)]
    switch packet.reason {
    case let .userInputRequired(question):
      lines += ["", "## Question", question.text]
      if !question.options.isEmpty { lines.append("Options: \(question.options.map { "\($0.id): \($0.label)" }.joined(separator: ", "))") }
      if let impact = question.impact { lines.append("Impact: \(impact)") }
    case let .userPresenceRequired(requirement):
      lines += ["", "## Presence required", requirement.instructions]
    default: break
    }
    lines += ["", "## Accepted"]
    lines += packet.progress.acceptedSteps.map { "- \($0.stepId) (\($0.stepExecutionId))" }
    lines += ["", "## Remaining", packet.progress.remainingSteps.joined(separator: ", "), "", "## Deliverables"]
    lines += packet.deliverables.map(renderDeliverable)
    lines += ["", "## Open findings"]
    lines += packet.progress.openFindings.map { "- \($0.severity.rawValue): \($0.message)" }
    let budget = packet.progress.remainingBudget
    let attemptsLeft = remaining(budget.maxAttempts, used: budget.attemptsUsed)
    let tokensLeft = remaining(budget.maxTotalTokens, used: budget.tokensUsed)
    let wallClockLeft = remaining(budget.maxWallClockMs, used: budget.wallClockMsUsed)
    lines += ["", "## Budget remaining", "Attempts: \(attemptsLeft); tokens: \(tokensLeft); wall clock ms: \(wallClockLeft)"]
    if let note = progressNote { lines += ["", "## Agent note", note] }
    return lines.joined(separator: "\n") + "\n"
  }

  private func reasonText(_ reason: HandoverReason) -> String {
    switch reason {
    case .userInputRequired: "The task needs an answer from the user."
    case .userPresenceRequired: "The task needs the user present on this host."
    case .ownerLost: "The previous task owner was lost."
    case let .inactivity(stepId, idleMs): "Step \(stepId) was inactive for \(idleMs) ms."
    case let .operatorMove(reason): "The task was moved by an operator: \(reason)"
    }
  }

  private func renderDeliverable(_ value: DeliverableRef) -> String {
    switch value {
    case let .repository(repository):
      return "- Repository: git fetch \(repository.remote) \(repository.branch)\ngit checkout \(repository.branch)"
    case let .document(document):
      return "- Documents: \(document.store)/\(document.instance ?? "default"): \(document.ids.joined(separator: ", "))"
    case let .localOnly(local): return "- \(local.path) (not transferable)"
    case let .artifactBundle(bundle): return "- Artifact bundle: \(bundle.location.serialized)"
    }
  }

  private func remaining(_ maximum: Int?, used: Int) -> String {
    guard let maximum else { return "unlimited" }
    return String(max(0, maximum - used))
  }
}
