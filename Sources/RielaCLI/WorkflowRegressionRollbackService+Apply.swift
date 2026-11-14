import Foundation
import RielaCore
import RielaWorkflowRegistry

extension WorkflowRegressionRollbackService {
  func recoverClaims(workflowName: String, root: String) throws {
    let proposals = WorkflowRollbackProposalStore(rootDirectory: root)
    let applying = try proposals.list(workflowName: workflowName, status: .applying, limit: 500)
    guard !applying.isEmpty else { return }
    let store = WorkflowDefinitionStore(rootDirectory: root)
    guard let head = try store.head(workflowName: workflowName) else {
      throw WorkflowRegressionRollbackError(code: "definition_version_not_retained", message: "definition head is unavailable")
    }
    let sourceScope = WorkflowScope(rawValue: head.sourceScope) ?? .auto
    let expected = URL(fileURLWithPath: head.sourceDirectory).resolvingSymlinksInPath().standardizedFileURL
    let version = try store.version(versionId: head.currentVersionId)
    func releaseObservedClaims() throws {
      for proposal in applying {
        guard let transactionId = proposal.claimTransactionId else { continue }
        do {
          _ = try proposals.transition(proposalId: proposal.proposalId, from: [.applying], to: .pending,
            decidedActor: nil, decisionReason: nil, failureCode: nil, diagnostics: [], expectedClaimTransactionId: transactionId)
        } catch let error as WorkflowDefinitionStoreError where error.code == .rollbackProposalNotPending {
          // The claim was completed or replaced while recovery was running.
        }
      }
    }
    if version?.provenance == WorkflowProvenance.mutable.rawValue {
      let registry = WorkflowMutableRegistry(definitionRecorder: recorder())
      let actual = registry.root.appendingPathComponent(workflowName).resolvingSymlinksInPath().standardizedFileURL
      guard actual == expected else {
        throw WorkflowRegressionRollbackError(code: "rollback_snapshot_unavailable", message: "workflow source directory changed")
      }
      try registry.withWorkflowPinnedAccess(workflowId: workflowName) { _ in
        try releaseObservedClaims()
      }
    } else {
      let resolver = FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false)
      let bundle = try resolver.resolve(.init(workflowName: workflowName, scope: sourceScope, workingDirectory: workingDirectory))
      let actual = URL(fileURLWithPath: bundle.workflowDirectory).resolvingSymlinksInPath().standardizedFileURL
      guard actual == expected else {
        throw WorkflowRegressionRollbackError(code: "rollback_snapshot_unavailable", message: "workflow source directory changed")
      }
      let target = try WorkflowHistoryIdentityResolver.identity(for: bundle)
      let historyRoot = try WorkflowHistoryIdentityResolver.historyRoot(for: target,
        workingDirectory: URL(fileURLWithPath: workingDirectory), configuredRoot: bundle.workflow.loop?.selfEvolution?.historyRoot)
      try withWorkflowTargetLock(target: target, owner: "rollback claim recovery") {
        _ = try WorkflowDirectoryTransactionCoordinator().recover(historyRoot: historyRoot, target: target,
          lockAlreadyHeld: true, recorder: recorder())
        try releaseObservedClaims()
      }
    }
  }

  func failPendingBundleAfterRecovery(root: String, proposal: WorkflowRollbackProposal, reason: String?,
                                      actor: WorkflowDefinitionActor, failureCode: String) throws {
    try recoverClaims(workflowName: proposal.workflowName, root: root)
    let proposals = WorkflowRollbackProposalStore(rootDirectory: root)
    guard try proposals.proposal(id: proposal.proposalId)?.status == .pending else { return }
    do {
      _ = try proposals.transition(proposalId: proposal.proposalId, from: [.pending], to: .failed,
        decidedActor: actor, decisionReason: reason, failureCode: failureCode, diagnostics: [])
    } catch let error as WorkflowDefinitionStoreError where error.code == .rollbackProposalNotPending {
      // Another decision or claim won the race.
    }
  }

  func approveInBundle(root: String, workflowName: String, proposal: WorkflowRollbackProposal,
                       reason: String?, actor: WorkflowDefinitionActor) throws -> WorkflowRollbackProposal {
    let proposals = WorkflowRollbackProposalStore(rootDirectory: root)
    let store = WorkflowDefinitionStore(rootDirectory: root)
    guard let head = try store.head(workflowName: workflowName), head.currentVersionId == proposal.regressedVersionId else {
      _ = try proposals.transition(proposalId: proposal.proposalId, from: [.pending], to: .superseded,
        decidedActor: actor, decisionReason: reason, failureCode: nil, diagnostics: [])
      throw WorkflowRegressionRollbackError(code: "rollback_superseded", message: "definition head changed")
    }
    guard let snapshotId = proposal.bundleSnapshotId else {
      _ = try proposals.transition(proposalId: proposal.proposalId, from: [.pending], to: .failed,
        decidedActor: actor, decisionReason: reason, failureCode: "rollback_snapshot_unavailable", diagnostics: [])
      throw WorkflowRegressionRollbackError(code: "rollback_snapshot_unavailable", message: "rollback snapshot is unavailable")
    }
    let sourceScope = WorkflowScope(rawValue: head.sourceScope) ?? .auto
    let options = WorkflowResolutionOptions(workflowName: workflowName, scope: sourceScope,
      workingDirectory: workingDirectory)
    let bundle = try FileSystemWorkflowBundleResolver().resolve(options)
    let actual = URL(fileURLWithPath: bundle.workflowDirectory).resolvingSymlinksInPath().standardizedFileURL
    let expected = URL(fileURLWithPath: head.sourceDirectory).resolvingSymlinksInPath().standardizedFileURL
    guard actual == expected else {
      _ = try proposals.transition(proposalId: proposal.proposalId, from: [.pending], to: .failed,
        decidedActor: actor, decisionReason: reason, failureCode: "rollback_snapshot_unavailable", diagnostics: ["sourceMismatch"])
      throw WorkflowRegressionRollbackError(code: "rollback_snapshot_unavailable", message: "workflow source directory changed")
    }
    let kinds = proposal.regressions.map(\.kind).joined(separator: ", ")
    var text = "regression rollback of \(proposal.regressedVersionId) to \(proposal.rollbackToVersionId): \(kinds)"
    text += " (baseline \(proposal.baselineSessionId), target \(proposal.targetSessionId))"
    if let reason, !reason.isEmpty { text += "; approved: \(reason)" }
    let evidence: [WorkflowDefinitionEvidenceRef] = [.init(kind: .rollbackProposal, id: proposal.proposalId),
      .init(kind: .session, id: proposal.baselineSessionId), .init(kind: .session, id: proposal.targetSessionId)]
    let attribution = WorkflowDefinitionChangeAttribution(operation: .rollback, actor: actor, reason: text,
      evidence: evidence, expectedHeadVersionId: proposal.regressedVersionId, rollbackProposalId: proposal.proposalId)
    let request = WorkflowSnapshotTargetRequest(workflowName: workflowName, scope: sourceScope,
      workflowDefinitionDir: nil, workingDirectory: workingDirectory)
    do {
      _ = try snapshotService.restore(request, snapshotId: snapshotId, approved: true, reason: text,
        actor: actor, attribution: attribution, beforePublication: { transactionId in
          _ = try proposals.claim(proposalId: proposal.proposalId, expectedHeadVersionId: proposal.regressedVersionId,
            claimTransactionId: transactionId)
        }, recorder: recorder())
    } catch let error as WorkflowDefinitionStoreError where error.code == .staleHead {
      throw WorkflowRegressionRollbackError(code: "rollback_superseded", message: error.message)
    } catch let error as WorkflowDefinitionStoreError where error.code == .rollbackProposalNotPending {
      let current = try proposals.proposal(id: proposal.proposalId)
      throw WorkflowRegressionRollbackError(code: current?.status == .applying ? "rollback_in_progress" : "rollback_proposal_not_pending",
        message: error.message)
    } catch let error as WorkflowRegistryError where error.code == .definitionSyncFailed {
      throw WorkflowRegressionRollbackError(code: "definition_sync_failed", message: error.message)
    } catch let error as CLIUsageError where error.message.hasPrefix("definition_sync_failed:") {
      throw WorkflowRegressionRollbackError(code: "definition_sync_failed", message: error.message)
    } catch let error as CLIUsageError where error.message.hasPrefix("workflow restore refused dirty conflicts:") {
      try failPendingBundleAfterRecovery(root: root, proposal: proposal, reason: reason, actor: actor,
        failureCode: "restore_dirty_conflicts")
      throw WorkflowRegressionRollbackError(code: "restore_dirty_conflicts", message: error.message)
    } catch let error as WorkflowHistoryValidationError {
      try failPendingBundleAfterRecovery(root: root, proposal: proposal, reason: reason, actor: actor,
        failureCode: "rollback_snapshot_unavailable")
      throw WorkflowRegressionRollbackError(code: "rollback_snapshot_unavailable", message: error.description)
    } catch WorkflowResolutionError.invalidWorkflow(let diagnostics) {
      try failPendingBundleAfterRecovery(root: root, proposal: proposal, reason: reason, actor: actor,
        failureCode: "invalid_definition")
      throw WorkflowRegressionRollbackError(code: "invalid_definition", message: String(describing: diagnostics))
    } catch {
      try recoverClaims(workflowName: workflowName, root: root)
      throw error
    }
    guard let result = try proposals.proposal(id: proposal.proposalId), result.status == .applied else {
      throw WorkflowRegressionRollbackError(code: "definition_sync_failed", message: "rollback definition sync did not complete")
    }
    if let appliedId = result.appliedVersionId,
       let applied = try store.version(versionId: appliedId),
       let target = try store.version(versionId: proposal.rollbackToVersionId),
       applied.documentDigest != target.documentDigest {
      return try proposals.appendAppliedDiagnostic(proposalId: proposal.proposalId,
        expectedAppliedVersionId: appliedId, diagnostic: "rollbackDigestMismatch")
    }
    return result
  }
}
