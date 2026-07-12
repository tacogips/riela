import Foundation

/// One notification channel (design S12). Endpoint values never live in the
/// workflow bundle: `webhook` resolves its URL (and optional bearer token)
/// from named environment variables at dispatch time; `command` runs an argv
/// with the payload on stdin.
public struct LoopNotificationChannelDeclaration: Codable, Equatable, Sendable {
  public var type: String
  public var urlEnv: String?
  public var bearerTokenEnv: String?
  public var argv: [String]

  private enum CodingKeys: String, CodingKey {
    case type
    case urlEnv
    case bearerTokenEnv
    case argv
  }

  public init(type: String, urlEnv: String? = nil, bearerTokenEnv: String? = nil, argv: [String] = []) {
    self.type = type
    self.urlEnv = urlEnv
    self.bearerTokenEnv = bearerTokenEnv
    self.argv = argv
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
    self.urlEnv = try container.decodeIfPresent(String.self, forKey: .urlEnv)
    self.bearerTokenEnv = try container.decodeIfPresent(String.self, forKey: .bearerTokenEnv)
    self.argv = try container.decodeIfPresent([String].self, forKey: .argv) ?? []
  }
}

/// Authored terminal-outcome notification metadata (design S12).
public struct LoopNotificationDeclaration: Codable, Equatable, Sendable {
  public var on: [String]
  public var channels: [LoopNotificationChannelDeclaration]

  private enum CodingKeys: String, CodingKey {
    case on
    case channels
  }

  public init(on: [String] = [], channels: [LoopNotificationChannelDeclaration] = []) {
    self.on = on
    self.channels = channels
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.on = try container.decodeIfPresent([String].self, forKey: .on) ?? []
    self.channels = try container.decodeIfPresent([LoopNotificationChannelDeclaration].self, forKey: .channels) ?? []
  }
}

public enum LoopOutcome: String, Codable, Equatable, Sendable, CaseIterable {
  case accepted
  case rejected
  case stalled
  case failed
}

/// Classifies the terminal loop outcome from the terminal session plus the
/// evidence manifest (design S12). Returns nil for non-terminal sessions.
public enum LoopOutcomeClassifier {
  public static func outcome(
    session: WorkflowSession,
    manifest: LoopEvidenceManifest?,
    requiredGateIds: [String]
  ) -> LoopOutcome? {
    switch session.status {
    case .completed:
      let latest = Dictionary(
        (manifest?.gates ?? []).map { ($0.gateId, $0) },
        uniquingKeysWith: { _, next in next }
      )
      let allAccepted = requiredGateIds.allSatisfy { latest[$0]?.decision == .accepted }
      return allAccepted ? .accepted : .rejected
    case .failed:
      return session.failureKind == .loopNotConverging ? .stalled : .failed
    default:
      return nil
    }
  }
}

/// Export-safe, schema-versioned notification payload (design S12): ids,
/// counts, decisions, and timestamps only — no prompt text, no finding
/// messages, no variable or environment values, no file paths.
public struct LoopOutcomeNotification: Codable, Equatable, Sendable {
  public struct GateDecision: Codable, Equatable, Sendable {
    public var gateId: String
    public var decision: String

    public init(gateId: String, decision: String) {
      self.gateId = gateId
      self.decision = decision
    }
  }

  public var schemaVersion: Int
  public var workflowId: String
  public var sessionId: String
  public var outcome: String
  public var entryMode: String?
  public var lastGateDecision: String?
  public var gateDecisions: [GateDecision]
  public var blockingFindingCount: Int
  public var costSummary: LoopCostSummary?
  public var startedAt: Date
  public var endedAt: Date

  public init(
    schemaVersion: Int = 1,
    workflowId: String,
    sessionId: String,
    outcome: String,
    entryMode: String? = nil,
    lastGateDecision: String? = nil,
    gateDecisions: [GateDecision] = [],
    blockingFindingCount: Int = 0,
    costSummary: LoopCostSummary? = nil,
    startedAt: Date,
    endedAt: Date
  ) {
    self.schemaVersion = schemaVersion
    self.workflowId = workflowId
    self.sessionId = sessionId
    self.outcome = outcome
    self.entryMode = entryMode
    self.lastGateDecision = lastGateDecision
    self.gateDecisions = gateDecisions
    self.blockingFindingCount = blockingFindingCount
    self.costSummary = costSummary
    self.startedAt = startedAt
    self.endedAt = endedAt
  }

  /// Builds the export-safe payload from the terminal session + manifest.
  public static func make(
    session: WorkflowSession,
    manifest: LoopEvidenceManifest?,
    outcome: LoopOutcome
  ) -> LoopOutcomeNotification {
    let latestGates = orderedLatestGates(manifest?.gates ?? [])
    return LoopOutcomeNotification(
      workflowId: session.workflowId,
      sessionId: session.sessionId,
      outcome: outcome.rawValue,
      entryMode: manifest?.recovery?.entryMode.rawValue,
      lastGateDecision: latestGates.last?.decision.rawValue,
      gateDecisions: latestGates.map { GateDecision(gateId: $0.gateId, decision: $0.decision.rawValue) },
      blockingFindingCount: latestGates.reduce(0) { $0 + $1.blockingFindings.count },
      costSummary: manifest?.costSummary,
      startedAt: session.createdAt,
      endedAt: session.updatedAt
    )
  }

  /// Latest visit per gate, in first-visit order (deterministic output).
  private static func orderedLatestGates(_ gates: [LoopGateResult]) -> [LoopGateResult] {
    var order: [String] = []
    var latest: [String: LoopGateResult] = [:]
    for gate in gates {
      if latest[gate.gateId] == nil {
        order.append(gate.gateId)
      }
      latest[gate.gateId] = gate
    }
    return order.compactMap { latest[$0] }
  }
}
