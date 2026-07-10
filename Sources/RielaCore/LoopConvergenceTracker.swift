import Foundation

public enum LoopConvergenceStallAction: String, Codable, Equatable, Sendable {
  case fail
  case warn
}

public enum LoopConvergenceViolationKind: String, Codable, Equatable, Sendable {
  case gateVisitsExceeded
  case repeatedFindingsStall
}

public struct LoopConvergenceViolation: Codable, Equatable, Sendable {
  public var kind: LoopConvergenceViolationKind
  public var gateId: String
  public var gateVisits: Int
  public var repeatedRounds: Int
  public var fingerprints: [LoopFindingFingerprint]

  public init(
    kind: LoopConvergenceViolationKind,
    gateId: String,
    gateVisits: Int,
    repeatedRounds: Int,
    fingerprints: [LoopFindingFingerprint] = []
  ) {
    self.kind = kind
    self.gateId = gateId
    self.gateVisits = gateVisits
    self.repeatedRounds = repeatedRounds
    self.fingerprints = fingerprints
  }
}

public struct LoopConvergenceCheck: Equatable, Sendable {
  public var gateVisits: Int
  public var repeatedRounds: Int
  public var violation: LoopConvergenceViolation?

  public init(gateVisits: Int, repeatedRounds: Int, violation: LoopConvergenceViolation? = nil) {
    self.gateVisits = gateVisits
    self.repeatedRounds = repeatedRounds
    self.violation = violation
  }
}

public struct LoopConvergenceTracker: Sendable {
  private var declaration: LoopConvergenceDeclaration
  private var states: [String: GateState] = [:]

  public init(declaration: LoopConvergenceDeclaration) {
    self.declaration = declaration
  }

  public mutating func recordGateVisit(
    gateId: String,
    decision: LoopGateDecision,
    findings: [LoopBlockingFinding]
  ) -> LoopConvergenceCheck {
    var state = states[gateId] ?? GateState()
    state.visitCount += 1

    let fingerprints = Set(findings.map(LoopFindingFingerprint.make(from:)))
    if decision == .rejected || decision == .needsWork {
      state.repeatedRounds = state.lastRejectedFingerprints == fingerprints ? state.repeatedRounds + 1 : 1
      state.lastRejectedFingerprints = fingerprints
    } else {
      state.repeatedRounds = 0
      state.lastRejectedFingerprints = nil
    }

    states[gateId] = state

    let sortedFingerprints = fingerprints.sorted { $0.key < $1.key }
    if let maxGateVisits = declaration.maxGateVisits, state.visitCount > maxGateVisits {
      return LoopConvergenceCheck(
        gateVisits: state.visitCount,
        repeatedRounds: state.repeatedRounds,
        violation: LoopConvergenceViolation(
          kind: .gateVisitsExceeded,
          gateId: gateId,
          gateVisits: state.visitCount,
          repeatedRounds: state.repeatedRounds,
          fingerprints: sortedFingerprints
        )
      )
    }

    if let maxRepeatedFindingRounds = declaration.maxRepeatedFindingRounds,
       state.repeatedRounds >= maxRepeatedFindingRounds {
      return LoopConvergenceCheck(
        gateVisits: state.visitCount,
        repeatedRounds: state.repeatedRounds,
        violation: LoopConvergenceViolation(
          kind: .repeatedFindingsStall,
          gateId: gateId,
          gateVisits: state.visitCount,
          repeatedRounds: state.repeatedRounds,
          fingerprints: sortedFingerprints
        )
      )
    }

    return LoopConvergenceCheck(gateVisits: state.visitCount, repeatedRounds: state.repeatedRounds)
  }
}

private struct GateState: Sendable {
  var visitCount = 0
  var lastRejectedFingerprints: Set<LoopFindingFingerprint>?
  var repeatedRounds = 0
}
