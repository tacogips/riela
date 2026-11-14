import Foundation
import RielaCore

extension WorkflowDefinitionService {
  /// Restores a proposal's target in the same transaction that applies it.
  public func rollback(
    workflowName: String, toVersionId: String, expectedHeadVersionId: String,
    proposalId: String, reason: String, evidence: [WorkflowDefinitionEvidenceRef], actor: WorkflowDefinitionActor
  ) throws -> (WorkflowDefinitionVersion, WorkflowDefinitionAuditRecord) {
    try requireReason(reason)
    guard let proposal = try WorkflowRollbackProposalStore(rootDirectory: storeRoot).proposal(id: proposalId),
          proposal.workflowName == workflowName, proposal.mode == .store,
          proposal.regressedVersionId == expectedHeadVersionId, proposal.rollbackToVersionId == toVersionId else {
      throw WorkflowDefinitionStoreError(code: .rollbackProposalNotPending, message: "rollback proposal does not match target")
    }
    guard let current = try store.current(workflowName: workflowName) else {
      throw WorkflowDefinitionServiceError(code: .definitionNotRegistered, message: "definition not registered: \(workflowName)")
    }
    guard current.head.currentVersionId == expectedHeadVersionId else {
      throw WorkflowDefinitionStoreError(code: .staleHead, message: "definition head changed")
    }
    guard let target = try store.version(versionId: toVersionId), target.workflowName == workflowName,
          let data = try store.document(versionId: toVersionId) else {
      throw WorkflowDefinitionStoreError(code: .versionNotFound, message: "rollback target is not retained")
    }
    let diff = try diffDocuments(document(current.document), document(data))
    let write = WorkflowDefinitionWrite(
      workflowName: workflowName, operation: .rollback, documentData: data, documentDigest: target.documentDigest,
      sourceDirectory: current.version.sourceDirectory, sourceScope: current.version.sourceScope,
      provenance: current.version.provenance, actor: actor, reason: reason, evidence: evidence, diff: diff,
      expectedCurrentVersionId: expectedHeadVersionId, defaultHistoryRetention: defaultHistoryRetention,
      rollbackProposalId: proposalId
    )
    guard case let .created(version, audit) = try store.commit(write) else {
      throw WorkflowDefinitionServiceError(code: .invalidDefinition, message: "rollback did not create a version")
    }
    return (version, audit)
  }
}
