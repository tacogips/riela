import Foundation

public enum SpecialistDecisionKind: String, Codable, CaseIterable, Sendable {
  case claim
  case decline
  case clarification
  case status
  /// The configured provider did not return a usable decision before the
  /// round deadline.  Persisting this is materially different from silently
  /// dropping the specialist: replay must settle the same round.
  case unavailable
}

/// A validated decision from a configured specialist. `specialistId` is
/// matched against trusted configuration by the CLI composition layer; model
/// output alone never grants access to a workflow or an external credential.
public struct SpecialistDecision: Codable, Equatable, Sendable {
  public var specialistId: String
  public var kind: SpecialistDecisionKind
  public var reason: String

  public init(specialistId: String, kind: SpecialistDecisionKind, reason: String = "") {
    self.specialistId = specialistId
    self.kind = kind
    self.reason = String(reason.prefix(512))
  }
}

public enum SpecialistRoutingOutcome: String, Codable, Equatable, Sendable {
  case status
  case newWork
  case routingClarification = "routing_clarification"
  case needsClarification = "needs_clarification"
  case unclaimed
}

public struct SpecialistRoutingSettlement: Codable, Equatable, Sendable {
  public var outcome: SpecialistRoutingOutcome
  public var selectedSpecialistId: String?
  public var claimants: [String]

  public init(outcome: SpecialistRoutingOutcome, selectedSpecialistId: String? = nil, claimants: [String] = []) {
    self.outcome = outcome
    self.selectedSpecialistId = selectedSpecialistId
    self.claimants = claimants
  }
}

/// Pure, order-independent settlement for persisted specialist results.  It
/// deliberately decides status/mixed requests before it permits ownership, so
/// a status question cannot create a task, capacity claim, tracker action, or
/// child dispatch as an accidental side effect of an LLM answer.
public enum SpecialistRequestRouter {
  public static func settle(
    route: SpecialistRequestRoute,
    decisions: [SpecialistDecision],
    eligibleSpecialistIDs: Set<String>,
    priority: [String]
  ) -> SpecialistRoutingSettlement {
    if route == .status || route == .cancel {
      return SpecialistRoutingSettlement(outcome: .status)
    }
    let valid = decisions.filter { eligibleSpecialistIDs.contains($0.specialistId) }
    let claims = Array(Set(valid.filter { $0.kind == .claim }.map(\.specialistId))).sorted()
    let askedStatus = valid.contains { $0.kind == .status }
    if askedStatus, !claims.isEmpty { return SpecialistRoutingSettlement(outcome: .routingClarification, claimants: claims) }
    if askedStatus { return SpecialistRoutingSettlement(outcome: .status) }
    if !claims.isEmpty {
      var order: [String: Int] = [:]
      for (index, specialistId) in priority.enumerated() where order[specialistId] == nil {
        order[specialistId] = index
      }
      let selected = claims.min { (order[$0] ?? Int.max, $0) < (order[$1] ?? Int.max, $1) }
      return SpecialistRoutingSettlement(outcome: .newWork, selectedSpecialistId: selected, claimants: claims)
    }
    if valid.contains(where: { $0.kind == .clarification }) { return SpecialistRoutingSettlement(outcome: .needsClarification) }
    return SpecialistRoutingSettlement(outcome: .unclaimed)
  }
}
