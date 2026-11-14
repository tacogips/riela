import Foundation
import RielaCore

enum WorkflowOperationAuditStore {
  static func url(for record: WorkflowDirectoryTransactionRecord, historyRoot: URL) -> URL {
    switch record.operationAuditIntent {
    case .mutation:
      historyRoot.appendingPathComponent("audits/\(record.transactionId).json")
    case let .restore(restore):
      historyRoot.appendingPathComponent("restores/\(restore.restoreId).json")
    }
  }

  static func persist(
    _ record: WorkflowDirectoryTransactionRecord,
    resultBundleDigest: String,
    outcome: WorkflowHistoryOutcome,
    historyRoot: URL
  ) throws {
    switch record.operationAuditIntent {
    case var .mutation(evidence):
      evidence.afterBundleDigest = resultBundleDigest
      evidence.validation = mergedVerification(evidence.validation, record.verification)
      evidence.applied = outcome == .applied
      evidence.restored = false
      evidence.outcome = outcome
      try WorkflowHistoryCanonicalCoding.validate(evidence)
      let url = url(for: record, historyRoot: historyRoot)
      if try historyEntryExistsWithoutFollowingLinks(url) {
        let existing = try WorkflowHistorySecurePersistence.readCanonical(
          LoopWorkflowMutationEvidence.self,
          from: url,
          historyRoot: historyRoot
        )
        try WorkflowHistoryCanonicalCoding.validate(existing)
        guard existing == evidence else {
          throw CLIUsageError("existing workflow mutation audit does not match recovery intent")
        }
        return
      }
      try WorkflowHistorySecurePersistence.writeCanonical(evidence, to: url, historyRoot: historyRoot, overwrite: false)
    case var .restore(restore):
      restore.resultBundleDigest = resultBundleDigest
      restore.validation = mergedVerification(restore.validation, record.verification)
      restore.outcome = outcome
      let url = url(for: record, historyRoot: historyRoot)
      if try historyEntryExistsWithoutFollowingLinks(url) {
        let existing = try WorkflowHistorySecurePersistence.readCanonical(
          WorkflowRestoreRecord.self,
          from: url,
          historyRoot: historyRoot
        )
        try WorkflowHistoryCanonicalCoding.validate(existing)
        restore.completedAt = existing.completedAt
        try WorkflowHistoryCanonicalCoding.validate(restore)
        guard existing == restore else {
          throw CLIUsageError("existing workflow restore audit does not match recovery intent")
        }
        return
      }
      restore.completedAt = Date()
      try WorkflowHistoryCanonicalCoding.validate(restore)
      try WorkflowHistorySecurePersistence.writeCanonical(restore, to: url, historyRoot: historyRoot, overwrite: false)
    }
  }

  private static func mergedVerification(
    _ lhs: [LoopVerificationEvidence],
    _ rhs: [LoopVerificationEvidence]
  ) -> [LoopVerificationEvidence] {
    Dictionary((lhs + rhs).map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
      .values
      .sorted { $0.id < $1.id }
  }
}
