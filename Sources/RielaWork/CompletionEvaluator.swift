import Foundation
import RielaCore

/// The gate payload's acceptance judgement (design section 16).
///
/// The runtime cannot evaluate natural language and must not pretend to, so
/// the judgement is made inside the attempt, by the agent, validated by the
/// authored output contract, and read back from the gate payload here.
public struct GateAcceptance: Codable, Equatable, Sendable {
  public var met: Bool
  public var note: String?

  public init(met: Bool, note: String? = nil) {
    self.met = met
    self.note = note
  }
}

/// Reads `loopGate.acceptance` out of a gate step's accepted output.
///
/// `RielaCore`'s `LoopGatePayloadParser` is internal and is deliberately not
/// modified (accepted delta D3); this decodes the one field the task layer
/// needs, and only that field.
public enum GateAcceptanceParser {
  /// `{ "met": Bool, "note": String? }` under the step output's `loopGate`
  /// object. Anything else — a missing object, a missing `met`, a `met` that
  /// is not a boolean — reads as absent, never as met.
  public static func acceptance(inGatePayload payload: JSONObject) -> GateAcceptance? {
    guard case let .object(acceptance)? = payload["acceptance"],
          case let .bool(met)? = acceptance["met"] else {
      return nil
    }
    var note: String?
    if case let .string(value)? = acceptance["note"] {
      note = value
    }
    return GateAcceptance(met: met, note: note)
  }

  /// The acceptance judgement of a whole attempt: the required gates'
  /// latest accepted outputs, merged.
  ///
  /// The merge is fail-closed. No gate carrying an `acceptance` object reads
  /// as absent; any gate saying `met: false` makes the whole attempt not met;
  /// only an all-affirmative set is met. A hallucinated completion cannot
  /// close a task, and one dissenting gate cannot be outvoted.
  public static func acceptance(
    requiredGates: [GateDeclaration],
    session: WorkflowSession
  ) -> GateAcceptance? {
    let stepIds = Set(requiredGates.filter(\.required).map(\.stepId))
    guard !stepIds.isEmpty else {
      return nil
    }
    var judgements: [GateAcceptance] = []
    var latestByStep: [String: WorkflowStepExecution] = [:]
    for execution in session.executions where stepIds.contains(execution.stepId) {
      guard execution.acceptedOutput != nil else { continue }
      latestByStep[execution.stepId] = execution
    }
    for stepId in stepIds.sorted() {
      guard let payload = latestByStep[stepId]?.acceptedOutput?.payload,
            case let .object(gatePayload)? = payload["loopGate"],
            let judgement = acceptance(inGatePayload: gatePayload) else {
        continue
      }
      judgements.append(judgement)
    }
    guard !judgements.isEmpty else {
      return nil
    }
    return GateAcceptance(
      met: judgements.allSatisfy(\.met),
      note: judgements.compactMap(\.note).first
    )
  }
}

/// One verification requirement's observed result.
public struct VerificationOutcome: Codable, Equatable, Sendable {
  public var name: String
  public var passed: Bool
  public var evidenceId: EvidenceID?

  public init(name: String, passed: Bool, evidenceId: EvidenceID? = nil) {
    self.name = name
    self.passed = passed
    self.evidenceId = evidenceId
  }
}

/// Everything the completion check reads that is not on the attempt outcome.
public struct CompletionLedger: Equatable, Sendable {
  public var verification: [VerificationOutcome]
  public var findings: [Finding]
  public var acceptance: GateAcceptance?

  public init(
    verification: [VerificationOutcome] = [],
    findings: [Finding] = [],
    acceptance: GateAcceptance? = nil
  ) {
    self.verification = verification
    self.findings = findings
    self.acceptance = acceptance
  }
}

public enum UnmetRequirement: Codable, Equatable, Sendable {
  case gateNotAccepted(gateId: String)
  case verificationMissing(name: String)
  case verificationFailed(name: String)
  case openBlockingFinding(fingerprint: String)
  case acceptanceNotMet
  case acceptanceAbsent
  case humanAcceptRequired

  private enum CodingKeys: String, CodingKey {
    case kind
    case gateId
    case name
    case fingerprint
  }

  private enum Kind: String, Codable {
    case gateNotAccepted
    case verificationMissing
    case verificationFailed
    case openBlockingFinding
    case acceptanceNotMet
    case acceptanceAbsent
    case humanAcceptRequired
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .gateNotAccepted:
      self = .gateNotAccepted(gateId: try container.decode(String.self, forKey: .gateId))
    case .verificationMissing:
      self = .verificationMissing(name: try container.decode(String.self, forKey: .name))
    case .verificationFailed:
      self = .verificationFailed(name: try container.decode(String.self, forKey: .name))
    case .openBlockingFinding:
      self = .openBlockingFinding(fingerprint: try container.decode(String.self, forKey: .fingerprint))
    case .acceptanceNotMet:
      self = .acceptanceNotMet
    case .acceptanceAbsent:
      self = .acceptanceAbsent
    case .humanAcceptRequired:
      self = .humanAcceptRequired
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .gateNotAccepted(gateId):
      try container.encode(Kind.gateNotAccepted, forKey: .kind)
      try container.encode(gateId, forKey: .gateId)
    case let .verificationMissing(name):
      try container.encode(Kind.verificationMissing, forKey: .kind)
      try container.encode(name, forKey: .name)
    case let .verificationFailed(name):
      try container.encode(Kind.verificationFailed, forKey: .kind)
      try container.encode(name, forKey: .name)
    case let .openBlockingFinding(fingerprint):
      try container.encode(Kind.openBlockingFinding, forKey: .kind)
      try container.encode(fingerprint, forKey: .fingerprint)
    case .acceptanceNotMet:
      try container.encode(Kind.acceptanceNotMet, forKey: .kind)
    case .acceptanceAbsent:
      try container.encode(Kind.acceptanceAbsent, forKey: .kind)
    case .humanAcceptRequired:
      try container.encode(Kind.humanAcceptRequired, forKey: .kind)
    }
  }
}

public enum CompletionVerdict: Codable, Equatable, Sendable {
  case satisfied
  case unmet([UnmetRequirement])

  public var isSatisfied: Bool {
    if case .satisfied = self { return true }
    return false
  }

  public var unmetRequirements: [UnmetRequirement] {
    if case let .unmet(requirements) = self { return requirements }
    return []
  }

  private enum CodingKeys: String, CodingKey {
    case verdict
    case unmet
  }

  private enum Kind: String, Codable {
    case satisfied
    case unmet
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .verdict) {
    case .satisfied:
      self = .satisfied
    case .unmet:
      self = .unmet(try container.decode([UnmetRequirement].self, forKey: .unmet))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .satisfied:
      try container.encode(Kind.satisfied, forKey: .verdict)
    case let .unmet(requirements):
      try container.encode(Kind.unmet, forKey: .verdict)
      try container.encode(requirements, forKey: .unmet)
    }
  }
}

/// The rule of design section 5, as a pure function.
///
/// A task cannot succeed unless every required gate's latest result is
/// accepted, every verification requirement has passing evidence in the
/// accepting attempt, no open blocking finding remains, and — when the task
/// declares natural-language acceptance — the gate payload says it was met.
/// This lifts the monja verifier and the loop CI verdict into one check.
/// It reads no store and calls no director.
public enum CompletionEvaluator {
  public static func evaluate(
    contract: CompletionContract,
    attemptOutcome: AttemptOutcome,
    ledger: CompletionLedger
  ) -> CompletionVerdict {
    var unmet: [UnmetRequirement] = []

    let latest = Dictionary(
      attemptOutcome.latestGateResults.map { ($0.gateId, $0) },
      uniquingKeysWith: { _, next in next }
    )
    for gate in contract.gates where gate.required {
      guard let result = latest[gate.id], result.decision == .accepted else {
        unmet.append(.gateNotAccepted(gateId: gate.id))
        continue
      }
      // A gate that was accepted while still carrying blocking findings has
      // not really passed; `loop gates --check` already refuses it today.
      if !result.blockingFindings.isEmpty {
        unmet.append(.gateNotAccepted(gateId: gate.id))
      }
    }

    let outcomes = Dictionary(
      ledger.verification.map { ($0.name, $0) },
      uniquingKeysWith: { _, next in next }
    )
    for requirement in contract.verification {
      guard let outcome = outcomes[requirement.name] else {
        unmet.append(.verificationMissing(name: requirement.name))
        continue
      }
      if !outcome.passed {
        unmet.append(.verificationFailed(name: requirement.name))
      }
    }

    for finding in ledger.findings where finding.blocksCompletion {
      unmet.append(.openBlockingFinding(fingerprint: finding.fingerprint.key))
    }

    // Tasks without natural-language criteria skip the acceptance check
    // entirely; tasks with them need an explicit affirmative.
    if !contract.acceptance.isEmpty {
      switch ledger.acceptance {
      case .none:
        unmet.append(.acceptanceAbsent)
      case let .some(acceptance) where !acceptance.met:
        unmet.append(.acceptanceNotMet)
      default:
        break
      }
    }

    if contract.requiresHumanAccept {
      unmet.append(.humanAcceptRequired)
    }

    return unmet.isEmpty ? .satisfied : .unmet(unmet)
  }
}
