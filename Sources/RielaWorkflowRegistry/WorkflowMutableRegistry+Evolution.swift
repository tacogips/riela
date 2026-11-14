import Foundation
import RielaCore

extension WorkflowMutableRegistry {
  func applyRequestedActivation(_ record: WorkflowMutableRegistryTransaction) throws {
    guard let activationState = record.requestedActivationState else { return }
    guard WorkflowActivationStore.coordinatorLockHeld || (definitionRecorder == nil && record.definitionChange != nil) else {
      throw WorkflowRegistryError(
        code: .registryIOFailure,
        message: "mutable workflow activation recovery requires the registry coordinator"
      )
    }
    let origin = WorkflowOriginIdentity(
      scope: .user, sourceKind: .workflow, provenance: .mutable, name: record.workflowId,
      workflowId: record.workflowId,
      canonicalLocator: root.appendingPathComponent(record.workflowId, isDirectory: true).path
    )
    try WorkflowActivationStore().set(activationState, for: origin)
  }

  func refusePendingDefinitionChange(workflowId: String, pinned: WorkflowMutableRegistryPinnedRoot) throws {
    guard definitionRecorder == nil else { return }
    let url = transactionsRoot.appendingPathComponent("\(workflowId).json")
    guard let data = try pinned.readRegularIfPresent(url) else { return }
    let record = try JSONDecoder().decode(WorkflowMutableRegistryTransaction.self, from: data)
    try validate(record, expectedWorkflowId: workflowId)
    guard record.definitionChange != nil else { return }
    throw WorkflowRegistryError(code: .definitionSyncFailed,
      message: "definition history pending for '\(workflowId)'; retry with a definition-recording surface",
      workflowId: workflowId)
  }

  func defaultAttribution(operation: WorkflowDefinitionOperation, action: String) -> WorkflowDefinitionChangeAttribution {
    WorkflowDefinitionChangeAttribution(operation: operation, actor: definitionActor,
      reason: "registry \(action) via \(surfaceLabel)")
  }

  func captureDefinitionBaseline(workflowId: String, transactionId: String,
                                 attribution: WorkflowDefinitionChangeAttribution) throws {
    guard let definitionRecorder else { return }
    do {
      _ = try definitionRecorder.captureBaselineIfAbsent(workflowName: workflowId,
        liveDirectory: root.appendingPathComponent(workflowId, isDirectory: true), sourceScope: .user,
        transactionId: transactionId, actor: attribution.actor, operation: attribution.operation,
        bundleSnapshotBefore: "registry-before-\(transactionId)")
    } catch {
      throw WorkflowRegistryError(code: .definitionBaselineFailed, message: "definition baseline failed: \(error)", workflowId: workflowId)
    }
  }

  func releaseRollbackClaim(_ record: WorkflowMutableRegistryTransaction) throws {
    guard let id = record.definitionChange?.rollbackProposalId, let definitionRecorder else { return }
    do {
      _ = try WorkflowRollbackProposalStore(rootDirectory: definitionRecorder.storeRoot(
        workflowName: record.workflowId, sourceScope: .user)).transition(proposalId: id, from: [.applying],
          to: .pending, decidedActor: nil, decisionReason: nil, failureCode: nil, diagnostics: [],
          expectedClaimTransactionId: record.transactionId)
    } catch let error as WorkflowDefinitionStoreError where error.code == .rollbackProposalNotPending {
      return
    }
  }

  /// Called under the registry's workflow lock. Snapshot IDs bind retries and
  /// recovery to the same transaction; a snapshot records an observed value,
  /// not a claim that a later mutation succeeded.
  @discardableResult
  func captureEvolutionSnapshot(
    workflowId: String, transactionId: String, beforeMutation: Bool,
    pinned: WorkflowMutableRegistryPinnedRoot
  ) throws -> String {
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
    return snapshotId
  }
}
