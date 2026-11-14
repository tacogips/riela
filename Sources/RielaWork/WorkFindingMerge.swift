import Foundation
import RielaCore

/// One identity for findings, whichever producer they came from.
///
/// `LoopBlockingFinding` and `WorkflowReviewFinding` merge into one `Finding`
/// (design section 8). The identity is `LoopFindingFingerprint`, unchanged:
/// an authored id wins, and everything else falls back to file path plus
/// whitespace-normalized message.
public enum WorkFindingMerge {
  public static func fingerprint(for finding: LoopBlockingFinding) -> LoopFindingFingerprint {
    LoopFindingFingerprint.make(from: finding)
  }

  /// A review finding is fingerprinted through the same function, so a gate
  /// that reports a finding the reviewer already reported produces one row.
  public static func fingerprint(for finding: WorkflowReviewFinding) -> LoopFindingFingerprint {
    LoopFindingFingerprint.make(from: LoopBlockingFinding(
      id: finding.id,
      severity: finding.severity.rawValue,
      filePath: finding.filePath,
      line: finding.line,
      message: finding.message
    ))
  }

  /// Maps a loop gate's free-text severity onto the one severity scale.
  ///
  /// The review aliases (`high|blocker|critical`, `mid|medium|major`,
  /// `low|minor`) are reused as-is. `informational` is loop vocabulary that
  /// the review scale never had and is explicitly non-blocking. Anything else
  /// is unrecognized, and an unrecognized severity is treated as `high`: a
  /// typo must not quietly stop a finding from blocking completion.
  public static func severity(fromLoopSeverity raw: String) -> FindingSeverity {
    if let mapped = FindingSeverity(reviewValue: raw) {
      return mapped
    }
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "informational", "info", "note":
      return .low
    default:
      return .high
    }
  }

  public static func finding(
    from blocking: LoopBlockingFinding,
    gateId: String,
    sourceStepExecutionId: String
  ) -> Finding {
    let fingerprint = fingerprint(for: blocking)
    return Finding(
      id: blocking.id.isEmpty ? fingerprint.key : blocking.id,
      fingerprint: fingerprint,
      severity: severity(fromLoopSeverity: blocking.severity),
      status: .open,
      gateId: gateId,
      sourceStepExecutionId: sourceStepExecutionId,
      filePath: blocking.filePath,
      line: blocking.line,
      message: blocking.message
    )
  }

  public static func finding(from review: WorkflowReviewFinding) -> Finding {
    Finding(
      id: review.id,
      fingerprint: fingerprint(for: review),
      severity: review.severity,
      status: review.status,
      gateId: nil,
      sourceStepExecutionId: review.sourceStepExecutionId,
      targetStepId: review.targetStepId,
      filePath: review.filePath,
      line: review.line,
      message: review.message,
      feedback: review.feedback
    )
  }

  /// Collapses findings that share a fingerprint, preserving first-seen order.
  ///
  /// Merging is fail-closed and additive: the most severe severity wins, a
  /// still-open status wins over a resolved one, and a field the first record
  /// left empty is filled from a later one. Nothing is ever downgraded, so a
  /// second reporter cannot weaken a finding.
  public static func merge(_ findings: [Finding]) -> [Finding] {
    var order: [LoopFindingFingerprint] = []
    var merged: [LoopFindingFingerprint: Finding] = [:]
    for finding in findings {
      guard var existing = merged[finding.fingerprint] else {
        order.append(finding.fingerprint)
        merged[finding.fingerprint] = finding
        continue
      }
      existing.severity = mostSevere(existing.severity, finding.severity)
      existing.status = leastResolved(existing.status, finding.status)
      existing.gateId = existing.gateId ?? finding.gateId
      existing.targetStepId = existing.targetStepId ?? finding.targetStepId
      existing.filePath = existing.filePath ?? finding.filePath
      existing.line = existing.line ?? finding.line
      existing.feedback = existing.feedback ?? finding.feedback
      merged[finding.fingerprint] = existing
    }
    return order.compactMap { merged[$0] }
  }

  static func mostSevere(_ lhs: FindingSeverity, _ rhs: FindingSeverity) -> FindingSeverity {
    rank(rhs) > rank(lhs) ? rhs : lhs
  }

  static func leastResolved(_ lhs: FindingStatus, _ rhs: FindingStatus) -> FindingStatus {
    lhs == .open || rhs == .open ? .open : lhs
  }

  private static func rank(_ severity: FindingSeverity) -> Int {
    switch severity {
    case .low: return 0
    case .mid: return 1
    case .high: return 2
    }
  }
}
