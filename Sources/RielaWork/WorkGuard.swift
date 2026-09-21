import Foundation

public enum BudgetDimension: String, Codable, CaseIterable, Sendable {
  case attempts
  case tokens
  case wallClock
  case proposals
}

/// A typed guard observation. The dispatcher persists this as
/// `guardViolation` evidence before it asks a director for a decision.
public enum GuardViolation: Codable, Equatable, Sendable {
  case inactivity(stepId: String, idleMs: Int)
  case gateVisitsExceeded(gateId: String, visits: Int)
  case repeatedFindings(gateId: String, rounds: Int)
  case budget(BudgetDimension, used: Int, limit: Int)

  private enum CodingKeys: String, CodingKey {
    case kind
    case stepId
    case idleMs
    case gateId
    case visits
    case rounds
    case dimension
    case used
    case limit
  }

  private enum Kind: String, Codable {
    case inactivity
    case gateVisitsExceeded
    case repeatedFindings
    case budget
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .inactivity:
      self = .inactivity(
        stepId: try container.decode(String.self, forKey: .stepId),
        idleMs: try container.decode(Int.self, forKey: .idleMs)
      )
    case .gateVisitsExceeded:
      self = .gateVisitsExceeded(
        gateId: try container.decode(String.self, forKey: .gateId),
        visits: try container.decode(Int.self, forKey: .visits)
      )
    case .repeatedFindings:
      self = .repeatedFindings(
        gateId: try container.decode(String.self, forKey: .gateId),
        rounds: try container.decode(Int.self, forKey: .rounds)
      )
    case .budget:
      self = .budget(
        try container.decode(BudgetDimension.self, forKey: .dimension),
        used: try container.decode(Int.self, forKey: .used),
        limit: try container.decode(Int.self, forKey: .limit)
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .inactivity(stepId, idleMs):
      try container.encode(Kind.inactivity, forKey: .kind)
      try container.encode(stepId, forKey: .stepId)
      try container.encode(idleMs, forKey: .idleMs)
    case let .gateVisitsExceeded(gateId, visits):
      try container.encode(Kind.gateVisitsExceeded, forKey: .kind)
      try container.encode(gateId, forKey: .gateId)
      try container.encode(visits, forKey: .visits)
    case let .repeatedFindings(gateId, rounds):
      try container.encode(Kind.repeatedFindings, forKey: .kind)
      try container.encode(gateId, forKey: .gateId)
      try container.encode(rounds, forKey: .rounds)
    case let .budget(dimension, used, limit):
      try container.encode(Kind.budget, forKey: .kind)
      try container.encode(dimension, forKey: .dimension)
      try container.encode(used, forKey: .used)
      try container.encode(limit, forKey: .limit)
    }
  }

  public var summary: String {
    switch self {
    case let .inactivity(stepId, idleMs):
      return "step \(stepId) was inactive for \(idleMs)ms"
    case let .gateVisitsExceeded(gateId, visits):
      return "gate \(gateId) was visited \(visits) times"
    case let .repeatedFindings(gateId, rounds):
      return "gate \(gateId) repeated findings for \(rounds) rounds"
    case let .budget(dimension, used, limit):
      return "\(dimension.rawValue) budget exhausted (\(used)/\(limit))"
    }
  }
}

/// One immutable detector input assembled by the dispatcher.
public struct GuardSnapshot: Codable, Equatable, Sendable {
  public var attemptCount: Int
  public var totalTokens: Int
  public var wallClockMs: Int
  public var proposalCount: Int
  public var activeStepId: String?
  public var heartbeatBackend: String?
  public var idleMs: Int?
  public var gateVisits: [String: Int]
  public var repeatedFindingRounds: [String: Int]

  public init(
    attemptCount: Int = 0,
    totalTokens: Int = 0,
    wallClockMs: Int = 0,
    proposalCount: Int = 0,
    activeStepId: String? = nil,
    heartbeatBackend: String? = nil,
    idleMs: Int? = nil,
    gateVisits: [String: Int] = [:],
    repeatedFindingRounds: [String: Int] = [:]
  ) {
    self.attemptCount = attemptCount
    self.totalTokens = totalTokens
    self.wallClockMs = wallClockMs
    self.proposalCount = proposalCount
    self.activeStepId = activeStepId
    self.heartbeatBackend = heartbeatBackend
    self.idleMs = idleMs
    self.gateVisits = gateVisits
    self.repeatedFindingRounds = repeatedFindingRounds
  }
}

/// Pure, stable-order evaluation for all three guard detectors.
public enum WorkGuard {
  public static func evaluate(policy: GuardPolicy, snapshot: GuardSnapshot) -> [GuardViolation] {
    var result: [GuardViolation] = []
    if let budget = policy.budget {
      appendBudget(.attempts, used: snapshot.attemptCount, limit: budget.maxAttempts, to: &result)
      appendBudget(.tokens, used: snapshot.totalTokens, limit: budget.maxTotalTokens, to: &result)
      appendBudget(.wallClock, used: snapshot.wallClockMs, limit: budget.maxWallClockMs, to: &result)
      appendBudget(.proposals, used: snapshot.proposalCount, limit: budget.maxProposals, to: &result)
    }
    if let convergence = policy.convergence {
      if let limit = convergence.maxGateVisits {
        for gateId in snapshot.gateVisits.keys.sorted() {
          let visits = snapshot.gateVisits[gateId, default: 0]
          // Preserve LoopConvergenceTracker semantics: the configured value
          // is the number of visits allowed, so the next visit violates it.
          if visits > limit {
            result.append(.gateVisitsExceeded(gateId: gateId, visits: visits))
          }
        }
      }
      if let limit = convergence.maxRepeatedFindingRounds {
        for gateId in snapshot.repeatedFindingRounds.keys.sorted() {
          let rounds = snapshot.repeatedFindingRounds[gateId, default: 0]
          if rounds >= limit {
            result.append(.repeatedFindings(gateId: gateId, rounds: rounds))
          }
        }
      }
    }
    if let inactivity = policy.inactivity,
       let stepId = snapshot.activeStepId,
       let backend = snapshot.heartbeatBackend,
       inactivity.heartbeatBackends.contains(backend),
       let idleMs = snapshot.idleMs,
       idleMs >= inactivity.stallTimeoutMs {
      result.append(.inactivity(stepId: stepId, idleMs: idleMs))
    }
    return result
  }

  private static func appendBudget(
    _ dimension: BudgetDimension,
    used: Int,
    limit: Int?,
    to result: inout [GuardViolation]
  ) {
    guard let limit, used >= limit else { return }
    result.append(.budget(dimension, used: used, limit: limit))
  }
}
