import Foundation

public struct LoopGateSummaryCounts: Codable, Equatable, Sendable {
  public var accepted: Int
  public var rejected: Int
  public var needsWork: Int
  public var skipped: Int

  public init(accepted: Int = 0, rejected: Int = 0, needsWork: Int = 0, skipped: Int = 0) {
    self.accepted = accepted
    self.rejected = rejected
    self.needsWork = needsWork
    self.skipped = skipped
  }
}

public struct LoopGateOutcome: Codable, Equatable, Sendable {
  public var gateId: String
  public var stepId: String
  public var decision: LoopGateDecision
  public var required: Bool?
  public var blockingFindingCount: Int

  public init(
    gateId: String,
    stepId: String,
    decision: LoopGateDecision,
    required: Bool? = nil,
    blockingFindingCount: Int = 0
  ) {
    self.gateId = gateId
    self.stepId = stepId
    self.decision = decision
    self.required = required
    self.blockingFindingCount = blockingFindingCount
  }
}

public struct LoopSessionSummary: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var loopKind: String?
  public var loopRequired: Bool?
  public var gateOutcomes: [LoopGateOutcome]
  public var lastGateDecision: String?
  public var blockingFindingCount: Int
  public var entryMode: String?
  public var sourceSessionId: String?
  public var rootSessionId: String?
  public var attemptNumber: Int?
  public var cost: LoopCostSummary?
  public var evidenceUpdatedAt: Date

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case loopKind
    case loopRequired
    case gateOutcomes
    case lastGateDecision
    case blockingFindingCount
    case entryMode
    case sourceSessionId
    case rootSessionId
    case attemptNumber
    case cost
    case evidenceUpdatedAt
  }

  public init(
    schemaVersion: Int = 1,
    loopKind: String? = nil,
    loopRequired: Bool? = nil,
    gateOutcomes: [LoopGateOutcome] = [],
    lastGateDecision: String? = nil,
    blockingFindingCount: Int = 0,
    entryMode: String? = nil,
    sourceSessionId: String? = nil,
    rootSessionId: String? = nil,
    attemptNumber: Int? = nil,
    cost: LoopCostSummary? = nil,
    evidenceUpdatedAt: Date
  ) {
    self.schemaVersion = schemaVersion
    self.loopKind = loopKind
    self.loopRequired = loopRequired
    self.gateOutcomes = gateOutcomes
    self.lastGateDecision = lastGateDecision
    self.blockingFindingCount = blockingFindingCount
    self.entryMode = entryMode
    self.sourceSessionId = sourceSessionId
    self.rootSessionId = rootSessionId
    self.attemptNumber = attemptNumber
    self.cost = cost
    self.evidenceUpdatedAt = evidenceUpdatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    self.loopKind = try container.decodeIfPresent(String.self, forKey: .loopKind)
    self.loopRequired = try container.decodeIfPresent(Bool.self, forKey: .loopRequired)
    self.gateOutcomes = try container.decodeIfPresent([LoopGateOutcome].self, forKey: .gateOutcomes) ?? []
    self.lastGateDecision = try container.decodeIfPresent(String.self, forKey: .lastGateDecision)
    self.blockingFindingCount = try container.decodeIfPresent(Int.self, forKey: .blockingFindingCount) ?? 0
    self.entryMode = try container.decodeIfPresent(String.self, forKey: .entryMode)
    self.sourceSessionId = try container.decodeIfPresent(String.self, forKey: .sourceSessionId)
    self.rootSessionId = try container.decodeIfPresent(String.self, forKey: .rootSessionId)
    self.attemptNumber = try container.decodeIfPresent(Int.self, forKey: .attemptNumber)
    self.cost = try container.decodeIfPresent(LoopCostSummary.self, forKey: .cost)
    self.evidenceUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .evidenceUpdatedAt) ?? Date(timeIntervalSince1970: 0)
  }

  public static func make(
    manifest: LoopEvidenceManifest,
    loopMetadata: WorkflowLoopMetadata? = nil
  ) -> LoopSessionSummary {
    let requiredByGateId = (loopMetadata?.gates ?? []).reduce(into: [String: Bool]()) { values, gate in
      values[gate.id] = gate.required
    }
    let outcomes = manifest.gates.map { gate in
      LoopGateOutcome(
        gateId: gate.gateId,
        stepId: gate.stepId,
        decision: gate.decision,
        required: requiredByGateId[gate.gateId],
        blockingFindingCount: gate.blockingFindings.count
      )
    }
    return LoopSessionSummary(
      loopKind: loopMetadata?.kind,
      loopRequired: loopMetadata?.required,
      gateOutcomes: outcomes,
      lastGateDecision: outcomes.last?.decision.rawValue,
      blockingFindingCount: outcomes.reduce(0) { $0 + $1.blockingFindingCount },
      entryMode: manifest.recovery?.entryMode.rawValue,
      sourceSessionId: manifest.recovery?.sourceSessionId,
      rootSessionId: nil,
      attemptNumber: nil,
      cost: nil,
      evidenceUpdatedAt: manifest.updatedAt
    )
  }
}

public struct LoopCostSummary: Codable, Equatable, Sendable {
  public var totalInputTokens: Int?
  public var totalOutputTokens: Int?
  public var totalTokens: Int?
  public var totalDurationMs: Int?
  public var stepsWithUsage: Int
  public var stepsWithoutUsage: Int

  public init(
    totalInputTokens: Int? = nil,
    totalOutputTokens: Int? = nil,
    totalTokens: Int? = nil,
    totalDurationMs: Int? = nil,
    stepsWithUsage: Int = 0,
    stepsWithoutUsage: Int = 0
  ) {
    self.totalInputTokens = totalInputTokens
    self.totalOutputTokens = totalOutputTokens
    self.totalTokens = totalTokens
    self.totalDurationMs = totalDurationMs
    self.stepsWithUsage = stepsWithUsage
    self.stepsWithoutUsage = stepsWithoutUsage
  }
}

public struct LoopSessionOverview: Codable, Equatable, Sendable {
  public var workflowId: String
  public var sessionId: String
  public var sessionStatus: String
  public var loopKind: String?
  public var loopRequired: Bool?
  public var loopEvidenceRecorded: Bool
  public var gateSummary: LoopGateSummaryCounts?
  public var blockingFindingCount: Int?
  public var lastGateDecision: String?
  public var entryMode: String?
  public var sourceSessionId: String?
  public var cost: LoopCostSummary?
  /// Frozen per-gate outcomes (with requiredness) carried through from the
  /// session summary. Optional for legacy overviews; consumers treat nil as
  /// empty. Enables faithful `loop stats` aggregation ("all *required* gates
  /// accepted") without re-reading workflow definitions.
  public var gateOutcomes: [LoopGateOutcome]?
  public var possiblyStale: Bool
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    workflowId: String,
    sessionId: String,
    sessionStatus: String,
    loopKind: String? = nil,
    loopRequired: Bool? = nil,
    loopEvidenceRecorded: Bool = false,
    gateSummary: LoopGateSummaryCounts? = nil,
    blockingFindingCount: Int? = nil,
    lastGateDecision: String? = nil,
    entryMode: String? = nil,
    sourceSessionId: String? = nil,
    cost: LoopCostSummary? = nil,
    gateOutcomes: [LoopGateOutcome]? = nil,
    possiblyStale: Bool = false,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.workflowId = workflowId
    self.sessionId = sessionId
    self.sessionStatus = sessionStatus
    self.loopKind = loopKind
    self.loopRequired = loopRequired
    self.loopEvidenceRecorded = loopEvidenceRecorded
    self.gateSummary = gateSummary
    self.blockingFindingCount = blockingFindingCount
    self.lastGateDecision = lastGateDecision
    self.entryMode = entryMode
    self.sourceSessionId = sourceSessionId
    self.cost = cost
    self.gateOutcomes = gateOutcomes
    self.possiblyStale = possiblyStale
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public static func make(
    session: WorkflowSession,
    summary: LoopSessionSummary?,
    now: Date = Date(),
    staleInterval: TimeInterval = 600
  ) -> LoopSessionOverview {
    make(
      workflowId: session.workflowId,
      sessionId: session.sessionId,
      sessionStatus: session.status.rawValue,
      createdAt: session.createdAt,
      updatedAt: session.updatedAt,
      summary: summary,
      now: now,
      staleInterval: staleInterval
    )
  }

  public static func make(
    workflowId: String,
    sessionId: String,
    sessionStatus: String,
    createdAt: Date,
    updatedAt: Date,
    summary: LoopSessionSummary?,
    now: Date = Date(),
    staleInterval: TimeInterval = 600
  ) -> LoopSessionOverview {
    let gateSummary = summary.map { summary in
      summary.gateOutcomes.reduce(into: LoopGateSummaryCounts()) { counts, outcome in
        switch outcome.decision {
        case .accepted:
          counts.accepted += 1
        case .rejected:
          counts.rejected += 1
        case .needsWork:
          counts.needsWork += 1
        case .skipped:
          counts.skipped += 1
        }
      }
    }
    return LoopSessionOverview(
      workflowId: workflowId,
      sessionId: sessionId,
      sessionStatus: sessionStatus,
      loopKind: summary?.loopKind,
      loopRequired: summary?.loopRequired,
      loopEvidenceRecorded: summary != nil,
      gateSummary: gateSummary,
      blockingFindingCount: summary?.blockingFindingCount,
      lastGateDecision: summary?.lastGateDecision,
      entryMode: summary?.entryMode,
      sourceSessionId: summary?.sourceSessionId,
      cost: summary?.cost,
      gateOutcomes: summary?.gateOutcomes,
      possiblyStale: sessionStatus == WorkflowSessionStatus.running.rawValue
        && now.timeIntervalSince(updatedAt) > staleInterval,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}
