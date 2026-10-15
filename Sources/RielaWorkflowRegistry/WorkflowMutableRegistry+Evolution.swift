import Foundation
import RielaCore

extension WorkflowMutableRegistry {
  /// Called under the registry's workflow lock. Snapshot IDs bind retries and
  /// recovery to the same transaction; a snapshot records an observed value,
  /// not a claim that a later mutation succeeded.
  func captureEvolutionSnapshot(
    workflowId: String, transactionId: String, beforeMutation: Bool,
    pinned: WorkflowMutableRegistryPinnedRoot
  ) throws {
    try pinned.requireConfiguredPathIdentity()
    let directory = root.appendingPathComponent(workflowId, isDirectory: true)
    guard let definition = try pinned.readRegularIfPresent(directory.appendingPathComponent("workflow.json")),
      let object = try JSONSerialization.jsonObject(with: definition) as? [String: Any] else {
      throw CLIUsageError("cannot record workflow evolution without workflow.json")
    }
    let target = WorkflowBundleIdentity(
      workflowId: workflowId, sourceScope: .user, sourceKind: .authoredWorkflow,
      workflowDirectory: directory.path, ownershipRoot: directory.path,
      workflowContractVersion: object["workflowContractVersion"] as? String, sourceMutable: true
    )
    let loop = object["loop"] as? [String: Any]
    let evolution = loop?["selfEvolution"] as? [String: Any]
    try WorkflowEvolutionLocation.anchor(target: target, requestedRoot: evolution?["historyRoot"] as? String,
      registry: self, pinned: pinned)
    let historyRoot = try WorkflowHistoryIdentityResolver.historyRoot(
      for: target, workingDirectory: root, configuredRoot: evolution?["historyRoot"] as? String
    )
    let inventory = try WorkflowHistoryIdentityResolver.inventory(for: target)
    let store = WorkflowHistoryStore(root: historyRoot)
    let snapshotId = "registry-\(beforeMutation ? "before" : "after")-\(transactionId)"
    let snapshotPath = historyRoot.appendingPathComponent("snapshots/\(snapshotId)")
    if FileManager.default.fileExists(atPath: snapshotPath.path) {
      let existing = try store.loadSnapshot(snapshotId, expectedIdentity: target)
      guard existing.bundleDigest == inventory.bundleDigest else {
        throw WorkflowHistoryValidationError.integrityMismatch
      }
    } else {
      _ = try store.createSnapshot(inventory: inventory, snapshotId: snapshotId)
    }
    try pinned.requireConfiguredPathIdentity()
  }
}
