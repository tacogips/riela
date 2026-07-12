import Foundation
import RielaCore

enum WorkflowPreflightAttemptStatus: String, Codable, Equatable, Sendable {
  case attempted
  case transactionStarted = "transaction-started"
  case failed
}

struct WorkflowPreflightAttemptRecord: Codable, Equatable, Sendable {
  var schemaVersion: Int = 1
  var attemptId: String
  var transactionId: String
  var kind: WorkflowDirectoryTransactionKind
  var target: WorkflowBundleIdentity
  var expectedBeforeBundleDigest: String
  var expectedAfterBundleDigest: String
  var preOperationSnapshotId: String
  var status: WorkflowPreflightAttemptStatus
  var mutationOccurred: Bool
  var diagnostics: [String]
  var startedAt: Date
  var completedAt: Date?
}

protocol WorkflowPreflightAttemptPersisting: Sendable {
  func persist(_ record: WorkflowPreflightAttemptRecord, historyRoot: URL) throws
}

struct FileWorkflowPreflightAttemptStore: WorkflowPreflightAttemptPersisting {
  func persist(_ record: WorkflowPreflightAttemptRecord, historyRoot: URL) throws {
    try validate(record)
    let url = historyRoot.appendingPathComponent("attempts/\(record.attemptId).json")
    if try historyEntryExistsWithoutFollowingLinks(url) {
      let existing = try WorkflowHistorySecurePersistence.readCanonical(
        WorkflowPreflightAttemptRecord.self,
        from: url,
        historyRoot: historyRoot
      )
      try validateTransition(from: existing, to: record)
      if existing == record { return }
    }
    try WorkflowHistorySecurePersistence.writeCanonical(record, to: url, historyRoot: historyRoot)
  }

  private func validate(_ record: WorkflowPreflightAttemptRecord) throws {
    guard record.schemaVersion == 1, !record.mutationOccurred else {
      throw CLIUsageError("invalid workflow preflight attempt record")
    }
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(record.attemptId)
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(record.transactionId)
    guard record.diagnostics == record.diagnostics.sorted(),
          Set(record.diagnostics).count == record.diagnostics.count,
          (record.status == .failed) == (record.completedAt != nil) else {
      throw CLIUsageError("workflow preflight attempt status is inconsistent")
    }
  }

  private func validateTransition(
    from existing: WorkflowPreflightAttemptRecord,
    to next: WorkflowPreflightAttemptRecord
  ) throws {
    var existingBase = existing
    var nextBase = next
    existingBase.status = .attempted
    nextBase.status = .attempted
    existingBase.diagnostics = []
    nextBase.diagnostics = []
    existingBase.completedAt = nil
    nextBase.completedAt = nil
    guard existingBase == nextBase else {
      throw CLIUsageError("workflow preflight attempt retry changed immutable intent")
    }
    let allowed: [WorkflowPreflightAttemptStatus: Set<WorkflowPreflightAttemptStatus>] = [
      .attempted: [.attempted, .transactionStarted, .failed],
      .transactionStarted: [.transactionStarted],
      .failed: [.failed]
    ]
    guard allowed[existing.status]?.contains(next.status) == true,
          Set(existing.diagnostics).isSubset(of: Set(next.diagnostics)) else {
      throw CLIUsageError("workflow preflight attempt transition is noncanonical")
    }
  }
}
