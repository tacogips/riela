import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class WorkflowAuditRetryTests: XCTestCase {
  func testMutationRetryRejectsEveryBoundFieldMismatch() throws {
    let root = try temporaryHistoryRoot()
    let fields = ["snapshot", "before", "verification", "review", "change-set"]
    for field in fields {
      let transactionId = "transaction-mismatch-\(field)"
      let record = mutationRecord(transactionId: transactionId, root: root)
      var existing = finalMutationEvidence(from: record)
      switch field {
      case "snapshot": existing.snapshotId = "snapshot-other"
      case "before": existing.beforeBundleDigest = String(repeating: "c", count: 64)
      case "verification": existing.validation[0].diagnosticSummary = "attacker verification"
      case "review": existing.review?.reviewerStepExecutionId = "review-other"
      case "change-set": existing.changeSetId = "change-set-other"
      default: XCTFail("unhandled field")
      }
      try WorkflowHistorySecurePersistence.writeCanonical(
        existing,
        to: root.appendingPathComponent("audits/\(transactionId).json"),
        historyRoot: root,
        overwrite: false
      )
      XCTAssertThrowsError(try WorkflowOperationAuditStore.persist(
        record,
        resultBundleDigest: record.expectedAfterBundleDigest,
        outcome: .applied,
        historyRoot: root
      ), field)
    }
  }

  func testTransactionAndRestoreRetryRejectKindSnapshotDigestVerificationAndRestoredSetMismatch() throws {
    let root = try temporaryHistoryRoot()
    let record = mutationRecord(transactionId: "transaction-audit-mismatch", root: root)
    let desired = WorkflowDirectoryTransactionAudit(
      transaction: record,
      resultBundleDigest: record.expectedAfterBundleDigest,
      outcome: .applied
    )
    let mutations: [(String, (inout WorkflowDirectoryTransactionAudit) -> Void)] = [
      ("kind", { $0.kind = .restore }),
      ("snapshot", { $0.preOperationSnapshotId = "snapshot-other" }),
      ("before", { $0.beforeBundleDigest = String(repeating: "c", count: 64) }),
      ("verification", { $0.verification[0].diagnosticSummary = "other" })
    ]
    for (_, mutation) in mutations {
      var existing = desired
      mutation(&existing)
      let intended = WorkflowDirectoryTransactionAudit(
        transaction: record,
        resultBundleDigest: record.expectedAfterBundleDigest,
        outcome: .applied
      )
      let url = root.appendingPathComponent("audits/transaction-\(intended.transactionId).json")
      try WorkflowHistorySecurePersistence.writeCanonical(existing, to: url, historyRoot: root, overwrite: false)
      XCTAssertThrowsError(try FileWorkflowTransactionAuditStore().persist(intended, historyRoot: root))
      try removePair(url, root: root)
    }

    let restoreRecord = restoreTransactionRecord(root: root)
    var existingRestore: WorkflowRestoreRecord
    switch restoreRecord.operationAuditIntent {
    case let .restore(value):
      existingRestore = value
    case .mutation:
      throw CLIUsageError("expected restore intent")
    }
    existingRestore.resultBundleDigest = restoreRecord.expectedAfterBundleDigest
    existingRestore.completedAt = Date(timeIntervalSince1970: 2)
    existingRestore.outcome = .restored
    existingRestore.restoredFiles = ["other.json"]
    try WorkflowHistorySecurePersistence.writeCanonical(
      existingRestore,
      to: root.appendingPathComponent("restores/\(existingRestore.restoreId).json"),
      historyRoot: root,
      overwrite: false
    )
    XCTAssertThrowsError(try WorkflowOperationAuditStore.persist(
      restoreRecord,
      resultBundleDigest: restoreRecord.expectedAfterBundleDigest,
      outcome: .restored,
      historyRoot: root
    ))
  }

  private func mutationRecord(transactionId: String, root: URL) -> WorkflowDirectoryTransactionRecord {
    let target = target(root: root)
    let before = String(repeating: "a", count: 64)
    let after = String(repeating: "b", count: 64)
    let review = WorkflowChangeSetReviewEvidence(
      gateId: "gate", gateResultId: "gate-result", decision: .accepted,
      reviewedProposalId: "proposal", reviewedProposalDigest: after,
      reviewedBeforeBundleDigest: before, reviewerStepId: "review",
      reviewerStepExecutionId: "review-exec", reviewedAt: Date(timeIntervalSince1970: 0)
    )
    let evidence = LoopWorkflowMutationEvidence(
      mode: "reviewed-change-set", changeSetId: "change-set", snapshotId: "snapshot-before",
      transactionId: transactionId, target: target, beforeBundleDigest: before,
      afterBundleDigest: after, review: review, applied: false, restored: false, outcome: .failed
    )
    return WorkflowDirectoryTransactionRecord(
      transactionId: transactionId, kind: .apply, target: target,
      beforeBundleDigest: before, expectedAfterBundleDigest: after,
      preOperationSnapshotId: "snapshot-before", beforeUnownedInventory: [],
      expectedAfterUnownedInventory: [], operationAuditIntent: .mutation(evidence),
      stagingPath: root.appendingPathComponent(".workflow.riela-stage-\(transactionId)").path,
      rollbackPath: root.appendingPathComponent(".workflow.riela-rollback-\(transactionId)").path,
      phase: .published,
      verification: [LoopVerificationEvidence(id: "workflow-validate", outcome: "passed", diagnosticSummary: "verified")]
    )
  }

  private func finalMutationEvidence(from record: WorkflowDirectoryTransactionRecord) -> LoopWorkflowMutationEvidence {
    guard case var .mutation(evidence) = record.operationAuditIntent else { fatalError("expected mutation") }
    evidence.afterBundleDigest = record.expectedAfterBundleDigest
    evidence.validation = record.verification
    evidence.applied = true
    evidence.outcome = .applied
    return evidence
  }

  private func restoreTransactionRecord(root: URL) -> WorkflowDirectoryTransactionRecord {
    let transactionId = "transaction-restore-mismatch"
    let target = target(root: root)
    let before = String(repeating: "a", count: 64)
    let after = String(repeating: "b", count: 64)
    let restore = WorkflowRestoreRecord(
      restoreId: "restore-mismatch", target: target, sourceSnapshotId: "snapshot-source",
      preRestoreSnapshotId: "snapshot-before", requestedBundleDigest: after,
      beforeBundleDigest: before, approved: true, dirtyConflictPolicy: "reject",
      restoredFiles: ["workflow.json"], transactionId: transactionId,
      startedAt: Date(timeIntervalSince1970: 1), outcome: .failed
    )
    return WorkflowDirectoryTransactionRecord(
      transactionId: transactionId, kind: .restore, target: target,
      beforeBundleDigest: before, expectedAfterBundleDigest: after,
      preOperationSnapshotId: "snapshot-before", beforeUnownedInventory: [],
      expectedAfterUnownedInventory: [], operationAuditIntent: .restore(restore),
      stagingPath: root.appendingPathComponent(".workflow.riela-stage-\(transactionId)").path,
      rollbackPath: root.appendingPathComponent(".workflow.riela-rollback-\(transactionId)").path,
      phase: .published
    )
  }

  private func target(root: URL) -> WorkflowBundleIdentity {
    let workflow = root.appendingPathComponent("workflow", isDirectory: true).standardizedFileURL.path
    return WorkflowBundleIdentity(
      workflowId: "workflow", sourceScope: .project, sourceKind: .authoredWorkflow,
      workflowDirectory: workflow, ownershipRoot: workflow, sourceMutable: true
    )
  }

  private func temporaryHistoryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-audit-retry-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  private func removePair(_ url: URL, root: URL) throws {
    try FileManager.default.removeItem(at: url)
    try FileManager.default.removeItem(at: WorkflowHistorySecurePersistence.digestSidecar(for: url))
  }
}
