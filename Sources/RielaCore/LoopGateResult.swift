import Foundation

public enum LoopGateDecision: String, Codable, Sendable {
  case accepted
  case rejected
  case needsWork = "needs_work"
  case skipped
}

public struct LoopFindingSeverityCounts: Codable, Equatable, Sendable {
  public var high: Int
  public var medium: Int
  public var low: Int
  public var informational: Int

  public init(high: Int = 0, medium: Int = 0, low: Int = 0, informational: Int = 0) {
    self.high = high
    self.medium = medium
    self.low = low
    self.informational = informational
  }
}

public struct LoopBlockingFinding: Codable, Equatable, Sendable {
  public var id: String
  public var severity: String
  public var filePath: String?
  public var line: Int?
  public var message: String
  public var evidenceRefs: [String]

  public init(
    id: String,
    severity: String,
    filePath: String? = nil,
    line: Int? = nil,
    message: String,
    evidenceRefs: [String] = []
  ) {
    self.id = id
    self.severity = severity
    self.filePath = filePath
    self.line = line
    self.message = message
    self.evidenceRefs = evidenceRefs
  }
}

public struct LoopGateResult: Codable, Equatable, Sendable {
  public var gateId: String
  public var stepId: String
  public var stepExecutionId: String
  public var decision: LoopGateDecision
  public var severityCounts: LoopFindingSeverityCounts
  public var blockingFindings: [LoopBlockingFinding]
  public var evidenceRefs: [String]
  public var rerunPolicy: String?
  public var residualRisks: [LoopResidualRisk]
  public var acceptedAt: Date?
  public var diagnostics: [String]

  public init(
    gateId: String,
    stepId: String,
    stepExecutionId: String,
    decision: LoopGateDecision,
    severityCounts: LoopFindingSeverityCounts = LoopFindingSeverityCounts(),
    blockingFindings: [LoopBlockingFinding] = [],
    evidenceRefs: [String] = [],
    rerunPolicy: String? = nil,
    residualRisks: [LoopResidualRisk] = [],
    acceptedAt: Date? = nil,
    diagnostics: [String] = []
  ) {
    self.gateId = gateId
    self.stepId = stepId
    self.stepExecutionId = stepExecutionId
    self.decision = decision
    self.severityCounts = severityCounts
    self.blockingFindings = blockingFindings
    self.evidenceRefs = evidenceRefs
    self.rerunPolicy = rerunPolicy
    self.residualRisks = residualRisks
    self.acceptedAt = acceptedAt
    self.diagnostics = diagnostics
  }
}
