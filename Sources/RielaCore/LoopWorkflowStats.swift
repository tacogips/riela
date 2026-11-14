import Foundation

/// Aggregate statistics over a bounded window of a workflow's loop runs.
/// Computed on read from `LoopSessionOverview` rows (which carry the frozen
/// per-gate outcomes and cost summary); no materialized metrics tables.
public struct LoopWorkflowStats: Codable, Equatable, Sendable {
  public var workflowId: String
  public var windowRuns: Int
  public var completedRuns: Int
  public var failedRuns: Int
  public var acceptedRuns: Int
  public var gateFailureCounts: [String: Int]
  public var rerunCount: Int
  public var meanDurationMs: Int?
  public var meanTotalTokens: Int?
  public var lastAcceptedSessionId: String?
  public var diagnostics: [String]

  public init(
    workflowId: String,
    windowRuns: Int = 0,
    completedRuns: Int = 0,
    failedRuns: Int = 0,
    acceptedRuns: Int = 0,
    gateFailureCounts: [String: Int] = [:],
    rerunCount: Int = 0,
    meanDurationMs: Int? = nil,
    meanTotalTokens: Int? = nil,
    lastAcceptedSessionId: String? = nil,
    diagnostics: [String] = []
  ) {
    self.workflowId = workflowId
    self.windowRuns = windowRuns
    self.completedRuns = completedRuns
    self.failedRuns = failedRuns
    self.acceptedRuns = acceptedRuns
    self.gateFailureCounts = gateFailureCounts
    self.rerunCount = rerunCount
    self.meanDurationMs = meanDurationMs
    self.meanTotalTokens = meanTotalTokens
    self.lastAcceptedSessionId = lastAcceptedSessionId
    self.diagnostics = diagnostics
  }

  /// Pure aggregation over a run series (newest first). `limit` bounds the
  /// window (default 50). Requiredness comes from each overview's frozen
  /// `gateOutcomes`; workflow definitions are never re-read.
  ///
  /// A run counts as accepted when it has at least one required gate outcome and
  /// every required gate outcome is `.accepted`. `gateFailureCounts` tallies
  /// gates whose decision was rejected or needs-work. `meanDurationMs` is the
  /// mean session wall-clock (updated − created); `meanTotalTokens` averages only
  /// rows that recorded a cost summary with a token total.
  public static func aggregate(
    workflowId: String,
    overviews: [LoopSessionOverview],
    limit: Int = 50
  ) -> LoopWorkflowStats {
    let window = Array(overviews.prefix(max(0, limit)))
    var completed = 0
    var failed = 0
    var accepted = 0
    var rerun = 0
    var gateFailureCounts: [String: Int] = [:]
    var durationSumMs = 0
    var durationCount = 0
    var tokenSum = 0
    var tokenCount = 0
    var lastAcceptedSessionId: String?
    var rowsWithoutCost = 0
    var rowsWithoutEvidence = 0

    for overview in window {
      switch overview.sessionStatus {
      case WorkflowSessionStatus.completed.rawValue: completed += 1
      case WorkflowSessionStatus.failed.rawValue: failed += 1
      default: break
      }
      if overview.entryMode == "rerun" { rerun += 1 }

      let outcomes = overview.gateOutcomes ?? []
      for outcome in outcomes where outcome.decision == .rejected || outcome.decision == .needsWork {
        gateFailureCounts[outcome.gateId, default: 0] += 1
      }
      let requiredOutcomes = outcomes.filter { $0.required == true }
      if !requiredOutcomes.isEmpty, requiredOutcomes.allSatisfy({ $0.decision == .accepted }) {
        accepted += 1
        if lastAcceptedSessionId == nil { lastAcceptedSessionId = overview.sessionId }
      }

      let durationMs = Int((overview.updatedAt.timeIntervalSince(overview.createdAt) * 1_000).rounded())
      if durationMs >= 0 {
        durationSumMs += durationMs
        durationCount += 1
      }

      if let total = overview.cost?.totalTokens {
        tokenSum += total
        tokenCount += 1
      } else {
        rowsWithoutCost += 1
      }
      if !overview.loopEvidenceRecorded { rowsWithoutEvidence += 1 }
    }

    var diagnostics: [String] = []
    if rowsWithoutCost > 0 {
      diagnostics.append("\(rowsWithoutCost) of \(window.count) runs have no recorded cost; token mean is partial")
    }
    if rowsWithoutEvidence > 0 {
      diagnostics.append("\(rowsWithoutEvidence) of \(window.count) runs recorded no loop evidence")
    }
    if window.count < overviews.count {
      diagnostics.append("window limited to \(window.count) of \(overviews.count) available runs")
    }

    return LoopWorkflowStats(
      workflowId: workflowId,
      windowRuns: window.count,
      completedRuns: completed,
      failedRuns: failed,
      acceptedRuns: accepted,
      gateFailureCounts: gateFailureCounts,
      rerunCount: rerun,
      meanDurationMs: durationCount == 0 ? nil : durationSumMs / durationCount,
      meanTotalTokens: tokenCount == 0 ? nil : tokenSum / tokenCount,
      lastAcceptedSessionId: lastAcceptedSessionId,
      diagnostics: diagnostics
    )
  }
}
