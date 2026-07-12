import Foundation

/// Per-gate decision and severity-count change between two runs.
public struct LoopGateChange: Codable, Equatable, Sendable {
  public var gateId: String
  public var baseDecision: LoopGateDecision?
  public var targetDecision: LoopGateDecision?
  /// `target - base` per severity bucket (0 when a side is absent).
  public var severityCountsDelta: LoopFindingSeverityCounts

  public init(
    gateId: String,
    baseDecision: LoopGateDecision?,
    targetDecision: LoopGateDecision?,
    severityCountsDelta: LoopFindingSeverityCounts
  ) {
    self.gateId = gateId
    self.baseDecision = baseDecision
    self.targetDecision = targetDecision
    self.severityCountsDelta = severityCountsDelta
  }
}

/// A verification command whose outcome flipped between two runs. Commands are
/// keyed by their resolved `argvSummary` because command ids are not stable
/// across sessions.
public struct LoopVerificationChange: Codable, Equatable, Sendable {
  public var commandSummary: String
  public var baseOutcome: String?
  public var targetOutcome: String?

  public init(commandSummary: String, baseOutcome: String?, targetOutcome: String?) {
    self.commandSummary = commandSummary
    self.baseOutcome = baseOutcome
    self.targetOutcome = targetOutcome
  }
}

/// Residual risks added or resolved between two runs, matched by
/// `(severity, message)`.
public struct LoopResidualRiskDelta: Codable, Equatable, Sendable {
  public var added: [LoopResidualRisk]
  public var resolved: [LoopResidualRisk]

  public init(added: [LoopResidualRisk] = [], resolved: [LoopResidualRisk] = []) {
    self.added = added
    self.resolved = resolved
  }
}

/// Per-dimension cost deltas (`target - base`), populated only when both runs
/// carry that dimension.
public struct LoopCostSummaryDelta: Codable, Equatable, Sendable {
  public var totalInputTokensDelta: Int?
  public var totalOutputTokensDelta: Int?
  public var totalTokensDelta: Int?
  public var totalDurationMsDelta: Int?

  public init(
    totalInputTokensDelta: Int? = nil,
    totalOutputTokensDelta: Int? = nil,
    totalTokensDelta: Int? = nil,
    totalDurationMsDelta: Int? = nil
  ) {
    self.totalInputTokensDelta = totalInputTokensDelta
    self.totalOutputTokensDelta = totalOutputTokensDelta
    self.totalTokensDelta = totalTokensDelta
    self.totalDurationMsDelta = totalDurationMsDelta
  }
}

/// Evidence-level comparison of two runs. Computed on read from two persisted
/// manifests; nothing new is stored. See design S4.
public struct LoopEvidenceDiff: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var baseSessionId: String
  public var targetSessionId: String
  public var sameWorkflow: Bool
  public var workflowDefinitionDigestChanged: Bool?
  public var gateChanges: [LoopGateChange]
  public var blockingFindingsAdded: [LoopBlockingFinding]
  public var blockingFindingsResolved: [LoopBlockingFinding]
  public var changedFilesAdded: [String]
  public var changedFilesRemoved: [String]
  public var verificationChanges: [LoopVerificationChange]
  public var residualRiskDelta: LoopResidualRiskDelta
  public var costDelta: LoopCostSummaryDelta?
  public var diagnostics: [String]

  public init(
    schemaVersion: Int = 1,
    baseSessionId: String,
    targetSessionId: String,
    sameWorkflow: Bool,
    workflowDefinitionDigestChanged: Bool? = nil,
    gateChanges: [LoopGateChange] = [],
    blockingFindingsAdded: [LoopBlockingFinding] = [],
    blockingFindingsResolved: [LoopBlockingFinding] = [],
    changedFilesAdded: [String] = [],
    changedFilesRemoved: [String] = [],
    verificationChanges: [LoopVerificationChange] = [],
    residualRiskDelta: LoopResidualRiskDelta = LoopResidualRiskDelta(),
    costDelta: LoopCostSummaryDelta? = nil,
    diagnostics: [String] = []
  ) {
    self.schemaVersion = schemaVersion
    self.baseSessionId = baseSessionId
    self.targetSessionId = targetSessionId
    self.sameWorkflow = sameWorkflow
    self.workflowDefinitionDigestChanged = workflowDefinitionDigestChanged
    self.gateChanges = gateChanges
    self.blockingFindingsAdded = blockingFindingsAdded
    self.blockingFindingsResolved = blockingFindingsResolved
    self.changedFilesAdded = changedFilesAdded
    self.changedFilesRemoved = changedFilesRemoved
    self.verificationChanges = verificationChanges
    self.residualRiskDelta = residualRiskDelta
    self.costDelta = costDelta
    self.diagnostics = diagnostics
  }
}

/// Pure, deterministic evidence diff. No I/O. Matching rules are intentionally
/// dumb (see design S4): gates by `gateId`; blocking findings by
/// `(filePath, message)` with line drift tolerated (path-less findings bucket
/// under `(nil, message)`); changed files by path; verification by the
/// `commandRef`-resolved `argvSummary` string.
public enum LoopEvidenceDiffer {
  public static func diff(base: LoopEvidenceManifest, target: LoopEvidenceManifest) -> LoopEvidenceDiff {
    var diagnostics: [String] = []
    let sameWorkflow = base.workflowId == target.workflowId
    if !sameWorkflow {
      diagnostics.append(
        "cross-workflow diff: base workflow \(base.workflowId) != target workflow \(target.workflowId)"
      )
    }

    let digestChanged: Bool?
    if let baseDigest = base.workflowDefinitionDigest, let targetDigest = target.workflowDefinitionDigest {
      digestChanged = baseDigest != targetDigest
    } else {
      digestChanged = nil
    }

    let gateChanges = self.gateChanges(base: base.gates, target: target.gates)
    let (findingsAdded, findingsResolved) = blockingFindingDiff(base: base.gates, target: target.gates)
    let (filesAdded, filesRemoved) = changedFileDiff(base: base.changedFiles, target: target.changedFiles)
    let verificationChanges = self.verificationChanges(base: base, target: target)
    let residualRiskDelta = self.residualRiskDelta(base: base.residualRisks, target: target.residualRisks)

    var costDelta: LoopCostSummaryDelta?
    if let baseCost = base.costSummary, let targetCost = target.costSummary {
      costDelta = self.costDelta(base: baseCost, target: targetCost)
      if baseCost.isPartial || targetCost.isPartial {
        diagnostics.append("cost delta is partial: at least one run has steps without usage evidence")
      }
    } else if base.costSummary != nil || target.costSummary != nil {
      diagnostics.append("cost delta omitted: only one run recorded a cost summary")
    }

    return LoopEvidenceDiff(
      baseSessionId: base.sessionId,
      targetSessionId: target.sessionId,
      sameWorkflow: sameWorkflow,
      workflowDefinitionDigestChanged: digestChanged,
      gateChanges: gateChanges,
      blockingFindingsAdded: findingsAdded,
      blockingFindingsResolved: findingsResolved,
      changedFilesAdded: filesAdded,
      changedFilesRemoved: filesRemoved,
      verificationChanges: verificationChanges,
      residualRiskDelta: residualRiskDelta,
      costDelta: costDelta,
      diagnostics: diagnostics
    )
  }

  private static func gateChanges(
    base: [LoopGateResult],
    target: [LoopGateResult]
  ) -> [LoopGateChange] {
    let baseByGate = Dictionary(base.map { ($0.gateId, $0) }, uniquingKeysWith: { first, _ in first })
    let targetByGate = Dictionary(target.map { ($0.gateId, $0) }, uniquingKeysWith: { first, _ in first })
    let gateIds = Set(baseByGate.keys).union(targetByGate.keys).sorted()
    var changes: [LoopGateChange] = []
    for gateId in gateIds {
      let baseGate = baseByGate[gateId]
      let targetGate = targetByGate[gateId]
      let delta = severityDelta(
        base: baseGate?.severityCounts ?? LoopFindingSeverityCounts(),
        target: targetGate?.severityCounts ?? LoopFindingSeverityCounts()
      )
      let decisionChanged = baseGate?.decision != targetGate?.decision
      let severityChanged = delta != LoopFindingSeverityCounts()
      guard decisionChanged || severityChanged else { continue }
      changes.append(LoopGateChange(
        gateId: gateId,
        baseDecision: baseGate?.decision,
        targetDecision: targetGate?.decision,
        severityCountsDelta: delta
      ))
    }
    return changes
  }

  private static func blockingFindingDiff(
    base: [LoopGateResult],
    target: [LoopGateResult]
  ) -> (added: [LoopBlockingFinding], resolved: [LoopBlockingFinding]) {
    let baseFindings = findingsByKey(base)
    let targetFindings = findingsByKey(target)
    let added = targetFindings
      .filter { baseFindings[$0.key] == nil }
      .sorted { findingKeyLess($0.key, $1.key) }
      .map(\.value)
    let resolved = baseFindings
      .filter { targetFindings[$0.key] == nil }
      .sorted { findingKeyLess($0.key, $1.key) }
      .map(\.value)
    return (added, resolved)
  }

  private static func findingsByKey(
    _ gates: [LoopGateResult]
  ) -> [FindingKey: LoopBlockingFinding] {
    var result: [FindingKey: LoopBlockingFinding] = [:]
    for gate in gates {
      for finding in gate.blockingFindings {
        let key = FindingKey(filePath: finding.filePath, message: finding.message)
        if result[key] == nil { result[key] = finding }
      }
    }
    return result
  }

  private static func changedFileDiff(
    base: [LoopChangedFile],
    target: [LoopChangedFile]
  ) -> (added: [String], removed: [String]) {
    let basePaths = Set(base.map(\.path))
    let targetPaths = Set(target.map(\.path))
    let added = targetPaths.subtracting(basePaths).sorted()
    let removed = basePaths.subtracting(targetPaths).sorted()
    return (added, removed)
  }

  private static func verificationChanges(
    base: LoopEvidenceManifest,
    target: LoopEvidenceManifest
  ) -> [LoopVerificationChange] {
    let baseOutcomes = verificationOutcomes(base)
    let targetOutcomes = verificationOutcomes(target)
    let summaries = Set(baseOutcomes.keys).union(targetOutcomes.keys).sorted()
    var changes: [LoopVerificationChange] = []
    for summary in summaries {
      let baseOutcome = baseOutcomes[summary]
      let targetOutcome = targetOutcomes[summary]
      guard baseOutcome != targetOutcome else { continue }
      changes.append(LoopVerificationChange(
        commandSummary: summary,
        baseOutcome: baseOutcome,
        targetOutcome: targetOutcome
      ))
    }
    return changes
  }

  private static func verificationOutcomes(_ manifest: LoopEvidenceManifest) -> [String: String] {
    let commandSummaries = Dictionary(
      manifest.commands.map { ($0.id, $0.argvSummary) },
      uniquingKeysWith: { first, _ in first }
    )
    var outcomes: [String: String] = [:]
    for verification in manifest.verification {
      let summary = verification.commandRef.flatMap { commandSummaries[$0] }
        ?? verification.commandRef
        ?? verification.id
      // Last write wins deterministically only if identical; otherwise keep the
      // first so repeated summaries do not thrash. Verification records for the
      // same command summary are expected to agree within a run.
      if outcomes[summary] == nil { outcomes[summary] = verification.outcome }
    }
    return outcomes
  }

  private static func residualRiskDelta(
    base: [LoopResidualRisk],
    target: [LoopResidualRisk]
  ) -> LoopResidualRiskDelta {
    let baseByKey = risksByKey(base)
    let targetByKey = risksByKey(target)
    let added = targetByKey
      .filter { baseByKey[$0.key] == nil }
      .sorted { riskKeyLess($0.key, $1.key) }
      .map(\.value)
    let resolved = baseByKey
      .filter { targetByKey[$0.key] == nil }
      .sorted { riskKeyLess($0.key, $1.key) }
      .map(\.value)
    return LoopResidualRiskDelta(added: added, resolved: resolved)
  }

  private static func risksByKey(_ risks: [LoopResidualRisk]) -> [RiskKey: LoopResidualRisk] {
    var result: [RiskKey: LoopResidualRisk] = [:]
    for risk in risks {
      let key = RiskKey(severity: risk.severity, message: risk.message)
      if result[key] == nil { result[key] = risk }
    }
    return result
  }

  private static func costDelta(base: LoopCostSummary, target: LoopCostSummary) -> LoopCostSummaryDelta {
    LoopCostSummaryDelta(
      totalInputTokensDelta: delta(base.totalInputTokens, target.totalInputTokens),
      totalOutputTokensDelta: delta(base.totalOutputTokens, target.totalOutputTokens),
      totalTokensDelta: delta(base.totalTokens, target.totalTokens),
      totalDurationMsDelta: delta(base.totalDurationMs, target.totalDurationMs)
    )
  }

  private static func delta(_ base: Int?, _ target: Int?) -> Int? {
    guard let base, let target else { return nil }
    return target - base
  }

  private static func severityDelta(
    base: LoopFindingSeverityCounts,
    target: LoopFindingSeverityCounts
  ) -> LoopFindingSeverityCounts {
    LoopFindingSeverityCounts(
      high: target.high - base.high,
      medium: target.medium - base.medium,
      low: target.low - base.low,
      informational: target.informational - base.informational
    )
  }

  private struct FindingKey: Hashable {
    var filePath: String?
    var message: String
  }

  private struct RiskKey: Hashable {
    var severity: String
    var message: String
  }

  private static func findingKeyLess(_ lhs: FindingKey, _ rhs: FindingKey) -> Bool {
    if (lhs.filePath ?? "") != (rhs.filePath ?? "") {
      return (lhs.filePath ?? "") < (rhs.filePath ?? "")
    }
    return lhs.message < rhs.message
  }

  private static func riskKeyLess(_ lhs: RiskKey, _ rhs: RiskKey) -> Bool {
    if lhs.severity != rhs.severity { return lhs.severity < rhs.severity }
    return lhs.message < rhs.message
  }
}
