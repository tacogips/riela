import Foundation

/// One classified regression between a baseline run and a target run.
public struct LoopRegression: Codable, Equatable, Sendable {
  /// `required-gate-downgrade`, `blocking-findings-added`, or
  /// `verification-flip` (design S10).
  public var kind: String
  public var gateId: String?
  public var detail: String

  public init(kind: String, gateId: String? = nil, detail: String) {
    self.kind = kind
    self.gateId = gateId
    self.detail = detail
  }
}

/// Result of comparing a target run against the accepted baseline (design
/// S10). Pure data; computed on read, never stored.
public struct LoopRegressionVerdict: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var workflowId: String
  public var baselineSessionId: String
  public var targetSessionId: String
  public var regressions: [LoopRegression]
  public var diff: LoopEvidenceDiff
  public var diagnostics: [String]

  public var hasRegression: Bool {
    !regressions.isEmpty
  }

  public init(
    schemaVersion: Int = 1,
    workflowId: String,
    baselineSessionId: String,
    targetSessionId: String,
    regressions: [LoopRegression] = [],
    diff: LoopEvidenceDiff,
    diagnostics: [String] = []
  ) {
    self.schemaVersion = schemaVersion
    self.workflowId = workflowId
    self.baselineSessionId = baselineSessionId
    self.targetSessionId = targetSessionId
    self.regressions = regressions
    self.diff = diff
    self.diagnostics = diagnostics
  }
}

/// Classifies regressions from two evidence manifests per design S10. Pure
/// function over persisted data: requiredness comes from the caller (frozen
/// gate requiredness or authored metadata), never re-read from disk here.
public enum LoopRegressionClassifier {
  public static func verdict(
    base: LoopEvidenceManifest,
    target: LoopEvidenceManifest,
    requiredGateIds: Set<String>
  ) -> LoopRegressionVerdict {
    let diff = LoopEvidenceDiffer.diff(base: base, target: target)
    var regressions: [LoopRegression] = []

    let baseLatest = latestGateResults(base)
    let targetLatest = latestGateResults(target)
    for gateId in requiredGateIds.sorted() {
      let baseResult = baseLatest[gateId]
      let targetResult = targetLatest[gateId]
      // Downgrade: accepted in baseline, no longer accepted (or missing) in
      // the target. A gate absent from the baseline cannot downgrade.
      if baseResult?.decision == .accepted, targetResult?.decision != .accepted {
        let targetDecision = targetResult?.decision.rawValue ?? "missing"
        regressions.append(LoopRegression(
          kind: "required-gate-downgrade",
          gateId: gateId,
          detail: "required gate '\(gateId)' was accepted in baseline; target is \(targetDecision)"
        ))
      }
      // New blocking findings on a required gate, matched by (filePath,
      // message) with line drift tolerated (same rule as the differ).
      if let targetResult {
        let baseKeys = Set((baseResult?.blockingFindings ?? []).map { findingKey($0) })
        let added = targetResult.blockingFindings.filter { !baseKeys.contains(findingKey($0)) }
        if !added.isEmpty {
          regressions.append(LoopRegression(
            kind: "blocking-findings-added",
            gateId: gateId,
            detail: "required gate '\(gateId)' gained \(added.count) blocking finding(s)"
          ))
        }
      }
    }

    for change in diff.verificationChanges where isPassOutcome(change.baseOutcome) && isFailOutcome(change.targetOutcome) {
      regressions.append(LoopRegression(
        kind: "verification-flip",
        detail: "verification '\(change.commandSummary)' flipped \(change.baseOutcome ?? "?") -> \(change.targetOutcome ?? "?")"
      ))
    }

    return LoopRegressionVerdict(
      workflowId: target.workflowId,
      baselineSessionId: base.sessionId,
      targetSessionId: target.sessionId,
      regressions: regressions,
      diff: diff,
      diagnostics: diff.diagnostics
    )
  }

  /// Latest visit per gate id, mirroring the gates `--check` evaluation rule.
  private static func latestGateResults(_ manifest: LoopEvidenceManifest) -> [String: LoopGateResult] {
    Dictionary(manifest.gates.map { ($0.gateId, $0) }, uniquingKeysWith: { _, next in next })
  }

  private static func findingKey(_ finding: LoopBlockingFinding) -> String {
    "\(finding.filePath ?? "<none>")|\(finding.message)"
  }

  private static func isPassOutcome(_ outcome: String?) -> Bool {
    guard let outcome else {
      return false
    }
    return ["passed", "pass", "succeeded", "success", "ok"].contains(outcome.lowercased())
  }

  private static func isFailOutcome(_ outcome: String?) -> Bool {
    guard let outcome else {
      return false
    }
    return ["failed", "fail", "error", "timeout"].contains(outcome.lowercased())
  }
}
