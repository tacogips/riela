import Foundation
import RielaCore

// LA3 loop analytics GraphQL DTOs (cost/overview/stats/diff), extracted from
// GraphQLContracts.swift to keep that file within the file-length budget.

public struct GraphQLLoopCostSummaryDTO: Codable, Equatable, Sendable {
  public var totalInputTokens: Int?
  public var totalOutputTokens: Int?
  public var totalTokens: Int?
  public var totalDurationMs: Int?
  public var stepsWithUsage: Int
  public var stepsWithoutUsage: Int
  public var partial: Bool

  public init(cost: LoopCostSummary) {
    self.totalInputTokens = cost.totalInputTokens
    self.totalOutputTokens = cost.totalOutputTokens
    self.totalTokens = cost.totalTokens
    self.totalDurationMs = cost.totalDurationMs
    self.stepsWithUsage = cost.stepsWithUsage
    self.stepsWithoutUsage = cost.stepsWithoutUsage
    self.partial = cost.isPartial
  }
}

public struct GraphQLLoopCostSummaryDeltaDTO: Codable, Equatable, Sendable {
  public var totalInputTokensDelta: Int?
  public var totalOutputTokensDelta: Int?
  public var totalTokensDelta: Int?
  public var totalDurationMsDelta: Int?

  public init(delta: LoopCostSummaryDelta) {
    self.totalInputTokensDelta = delta.totalInputTokensDelta
    self.totalOutputTokensDelta = delta.totalOutputTokensDelta
    self.totalTokensDelta = delta.totalTokensDelta
    self.totalDurationMsDelta = delta.totalDurationMsDelta
  }
}

public struct GraphQLLoopGateOutcomeDTO: Codable, Equatable, Sendable {
  public var gateId: String
  public var stepId: String
  public var decision: String
  public var required: Bool?
  public var blockingFindingCount: Int

  public init(outcome: LoopGateOutcome) {
    self.gateId = outcome.gateId
    self.stepId = outcome.stepId
    self.decision = outcome.decision.rawValue
    self.required = outcome.required
    self.blockingFindingCount = outcome.blockingFindingCount
  }
}

public struct GraphQLLoopGateFailureCountDTO: Codable, Equatable, Sendable {
  public var gateId: String
  public var count: Int
}

public struct GraphQLLoopGateChangeDTO: Codable, Equatable, Sendable {
  public var gateId: String
  public var baseDecision: String?
  public var targetDecision: String?
  public var severityCountsDelta: GraphQLLoopFindingSeverityCountsDTO

  public init(change: LoopGateChange) {
    self.gateId = change.gateId
    self.baseDecision = change.baseDecision?.rawValue
    self.targetDecision = change.targetDecision?.rawValue
    self.severityCountsDelta = GraphQLLoopFindingSeverityCountsDTO(counts: change.severityCountsDelta)
  }
}

public struct GraphQLLoopVerificationChangeDTO: Codable, Equatable, Sendable {
  public var commandSummary: String
  public var baseOutcome: String?
  public var targetOutcome: String?

  public init(change: LoopVerificationChange) {
    self.commandSummary = change.commandSummary
    self.baseOutcome = change.baseOutcome
    self.targetOutcome = change.targetOutcome
  }
}

public struct GraphQLLoopSessionOverviewDTO: Codable, Equatable, Sendable {
  public var workflowId: String
  public var sessionId: String
  public var sessionStatus: String
  public var loopKind: String?
  public var loopRequired: Bool?
  public var loopEvidenceRecorded: Bool
  public var blockingFindingCount: Int?
  public var lastGateDecision: String?
  public var entryMode: String?
  public var sourceSessionId: String?
  public var cost: GraphQLLoopCostSummaryDTO?
  public var gateOutcomes: [GraphQLLoopGateOutcomeDTO]
  public var possiblyStale: Bool
  public var createdAt: String
  public var updatedAt: String

  public init(overview: LoopSessionOverview) {
    self.workflowId = overview.workflowId
    self.sessionId = overview.sessionId
    self.sessionStatus = overview.sessionStatus
    self.loopKind = overview.loopKind
    self.loopRequired = overview.loopRequired
    self.loopEvidenceRecorded = overview.loopEvidenceRecorded
    self.blockingFindingCount = overview.blockingFindingCount
    self.lastGateDecision = overview.lastGateDecision
    self.entryMode = overview.entryMode
    self.sourceSessionId = overview.sourceSessionId
    self.cost = overview.cost.map(GraphQLLoopCostSummaryDTO.init)
    self.gateOutcomes = (overview.gateOutcomes ?? []).map(GraphQLLoopGateOutcomeDTO.init)
    self.possiblyStale = overview.possiblyStale
    self.createdAt = GraphQLContractProjector.iso8601String(overview.createdAt)
    self.updatedAt = GraphQLContractProjector.iso8601String(overview.updatedAt)
  }
}

public struct GraphQLLoopWorkflowStatsDTO: Codable, Equatable, Sendable {
  public var workflowId: String
  public var windowRuns: Int
  public var completedRuns: Int
  public var failedRuns: Int
  public var acceptedRuns: Int
  public var gateFailureCounts: [GraphQLLoopGateFailureCountDTO]
  public var rerunCount: Int
  public var meanDurationMs: Int?
  public var meanTotalTokens: Int?
  public var lastAcceptedSessionId: String?
  public var diagnostics: [String]

  public init(stats: LoopWorkflowStats) {
    self.workflowId = stats.workflowId
    self.windowRuns = stats.windowRuns
    self.completedRuns = stats.completedRuns
    self.failedRuns = stats.failedRuns
    self.acceptedRuns = stats.acceptedRuns
    self.gateFailureCounts = stats.gateFailureCounts
      .sorted { $0.key < $1.key }
      .map { GraphQLLoopGateFailureCountDTO(gateId: $0.key, count: $0.value) }
    self.rerunCount = stats.rerunCount
    self.meanDurationMs = stats.meanDurationMs
    self.meanTotalTokens = stats.meanTotalTokens
    self.lastAcceptedSessionId = stats.lastAcceptedSessionId
    self.diagnostics = stats.diagnostics
  }
}

public struct GraphQLLoopEvidenceDiffDTO: Codable, Equatable, Sendable {
  public var baseSessionId: String
  public var targetSessionId: String
  public var sameWorkflow: Bool
  public var workflowDefinitionDigestChanged: Bool?
  public var gateChanges: [GraphQLLoopGateChangeDTO]
  public var blockingFindingsAdded: [GraphQLLoopBlockingFindingDTO]
  public var blockingFindingsResolved: [GraphQLLoopBlockingFindingDTO]
  public var changedFilesAdded: [String]
  public var changedFilesRemoved: [String]
  public var verificationChanges: [GraphQLLoopVerificationChangeDTO]
  public var residualRisksAdded: [GraphQLLoopResidualRiskDTO]
  public var residualRisksResolved: [GraphQLLoopResidualRiskDTO]
  public var costDelta: GraphQLLoopCostSummaryDeltaDTO?
  public var diagnostics: [String]

  public init(diff: LoopEvidenceDiff) {
    self.baseSessionId = diff.baseSessionId
    self.targetSessionId = diff.targetSessionId
    self.sameWorkflow = diff.sameWorkflow
    self.workflowDefinitionDigestChanged = diff.workflowDefinitionDigestChanged
    self.gateChanges = diff.gateChanges.map(GraphQLLoopGateChangeDTO.init)
    self.blockingFindingsAdded = diff.blockingFindingsAdded.map(GraphQLLoopBlockingFindingDTO.init)
    self.blockingFindingsResolved = diff.blockingFindingsResolved.map(GraphQLLoopBlockingFindingDTO.init)
    self.changedFilesAdded = diff.changedFilesAdded
    self.changedFilesRemoved = diff.changedFilesRemoved
    self.verificationChanges = diff.verificationChanges.map(GraphQLLoopVerificationChangeDTO.init)
    self.residualRisksAdded = diff.residualRiskDelta.added.map(GraphQLLoopResidualRiskDTO.init)
    self.residualRisksResolved = diff.residualRiskDelta.resolved.map(GraphQLLoopResidualRiskDTO.init)
    self.costDelta = diff.costDelta.map(GraphQLLoopCostSummaryDeltaDTO.init)
    self.diagnostics = diff.diagnostics
  }
}

public struct GraphQLLoopSessionsResult: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var sessions: [GraphQLLoopSessionOverviewDTO]

  public init(result: GraphQLControlPlaneResult, sessions: [GraphQLLoopSessionOverviewDTO] = []) {
    self.result = result
    self.sessions = sessions
  }
}

public struct GraphQLLoopWorkflowStatsResult: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var stats: GraphQLLoopWorkflowStatsDTO?

  public init(result: GraphQLControlPlaneResult, stats: GraphQLLoopWorkflowStatsDTO? = nil) {
    self.result = result
    self.stats = stats
  }
}

public struct GraphQLLoopEvidenceDiffResult: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var diff: GraphQLLoopEvidenceDiffDTO?

  public init(result: GraphQLControlPlaneResult, diff: GraphQLLoopEvidenceDiffDTO? = nil) {
    self.result = result
    self.diff = diff
  }
}
