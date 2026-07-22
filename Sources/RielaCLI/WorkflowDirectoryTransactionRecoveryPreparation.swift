import Foundation
import RielaCore

struct WorkflowDirectoryRecoveryContext {
  var record: WorkflowDirectoryTransactionRecord
  var recordURL: URL
  var live: URL
  var staging: URL
  var rollback: URL
  var parent: URL
  var stableMarker: URL
  var detachedRoot: WorkflowDetachedOwnershipPinnedRoot?
}

extension WorkflowDirectoryTransactionCoordinator {
  func prepareLockedRecovery(
    transactions: URL,
    active: URL,
    historyRoot: URL,
    target: WorkflowBundleIdentity
  ) throws -> WorkflowDirectoryRecoveryContext? {
    guard try directoryExistsWithoutFollowingLinks(transactions) else { return nil }
    guard let discovered = try discoverWorkflowTransaction(
      transactions: transactions,
      active: active,
      historyRoot: historyRoot
    ) else { return nil }
    guard discovered.record.target == target else {
      throw CLIUsageError("workflow transaction recovery target does not match the locked canonical target")
    }
    let record = discovered.record
    let snapshot = try WorkflowHistoryStore(root: historyRoot).loadSnapshot(
      record.preOperationSnapshotId,
      expectedIdentity: record.target
    )
    guard snapshot.bundleDigest == record.beforeBundleDigest else {
      throw CLIUsageError("recovery snapshot does not match the transaction before digest")
    }
    let live = record.physicalOwnershipRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? URL(fileURLWithPath: record.target.ownershipRoot, isDirectory: true)
    let detachedRoot = try record.physicalOwnershipRoot.map {
      try WorkflowDetachedOwnershipPinnedRoot(candidate: URL(fileURLWithPath: $0), requireRoot: false)
    }
    let stableMarker = WorkflowTransactionStableMetadata.url(forOwnershipRoot: live)
    try validateWorkflowTransactionStableMetadata(
      record: record,
      marker: stableMarker,
      historyRoot: historyRoot,
      detachedRoot: detachedRoot
    )
    if let detachedRoot {
      try detachedRecoveryValidatedHook()
      try detachedRoot.requireConfiguredPathIdentity()
    }
    return WorkflowDirectoryRecoveryContext(
      record: record,
      recordURL: discovered.recordURL,
      live: live,
      staging: URL(fileURLWithPath: record.stagingPath, isDirectory: true),
      rollback: URL(fileURLWithPath: record.rollbackPath, isDirectory: true),
      parent: live.deletingLastPathComponent(),
      stableMarker: stableMarker,
      detachedRoot: detachedRoot
    )
  }
}
