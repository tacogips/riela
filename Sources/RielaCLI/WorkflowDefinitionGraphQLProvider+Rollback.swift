import Foundation
import RielaCore
import RielaGraphQL

extension WorkflowDefinitionGraphQLProvider {
  public func workflowRollbackProposals(workflowName: String, storeScope: String?, status: String?, limit: Int?) async throws -> [GraphQLWorkflowRollbackProposal] {
    let parsedStatus = status.flatMap(WorkflowRollbackProposalStatus.init(rawValue:))
    guard status == nil || parsedStatus != nil, (1...1000).contains(limit ?? 100) else {
      throw rollbackGraphError("INVALID_DEFINITION_INPUT", "invalid status or limit")
    }
    return try rollbackErrors {
      try rollbackService(storeScope).list(workflowName: workflowName, status: parsedStatus, limit: limit ?? 100).map(rollbackDTO)
    }
  }

  public func checkWorkflowRegressionRollback(input: CheckWorkflowRegressionRollbackInput) async throws -> GraphQLCheckWorkflowRegressionRollbackPayload {
    let result = try rollbackErrors {
      try rollbackService(input.storeScope).check(workflowName: input.workflowName, targetSessionId: input.targetSessionId,
        actor: WorkflowDefinitionActor(kind: .api, id: nil))
    }
    return GraphQLCheckWorkflowRegressionRollbackPayload(outcome: result.outcome.rawValue, eligibilityCode: result.eligibilityCode,
      regressions: result.regressions.map(rollbackRegressionDTO), proposal: result.proposal.map(rollbackDTO), diagnostics: result.diagnostics)
  }

  public func approveWorkflowRollbackProposal(input: ApproveWorkflowRollbackProposalInput) async throws -> GraphQLWorkflowRollbackProposal {
    let actor = try rollbackActor(input.actorKind, input.actorId)
    return try rollbackErrors {
      rollbackDTO(try rollbackService(input.storeScope).approve(workflowName: input.workflowName, proposalId: input.proposalId, reason: input.reason, actor: actor))
    }
  }

  public func rejectWorkflowRollbackProposal(input: RejectWorkflowRollbackProposalInput) async throws -> GraphQLWorkflowRollbackProposal {
    let actor = try rollbackActor(input.actorKind, input.actorId)
    return try rollbackErrors {
      rollbackDTO(try rollbackService(input.storeScope).reject(workflowName: input.workflowName, proposalId: input.proposalId, reason: input.reason, actor: actor))
    }
  }

  private func rollbackService(_ scope: String?) throws -> WorkflowRegressionRollbackService {
    guard let parsed = WorkflowScope(rawValue: scope ?? "auto"), parsed != .direct else {
      throw rollbackGraphError("INVALID_DEFINITION_INPUT", "invalid workflow scope")
    }
    return WorkflowRegressionRollbackService(workingDirectory: workingDirectory, sessionStore: sessionStoreRoot, scope: parsed, environment: environment)
  }
}

private func rollbackActor(_ kind: String?, _ id: String?) throws -> WorkflowDefinitionActor {
  guard let parsed = WorkflowDefinitionActorKind(rawValue: kind ?? "api"), parsed == .api || parsed == .user else {
    throw rollbackGraphError("INVALID_DEFINITION_INPUT", "GraphQL actorKind must be api or user")
  }
  return WorkflowDefinitionActor(kind: parsed, id: id)
}

private func rollbackErrors<T>(_ body: () throws -> T) throws -> T {
  do { return try body() } catch let error as WorkflowRegressionRollbackError {
    if error.code == "reason_required" { throw rollbackGraphError("DEFINITION_REASON_REQUIRED", error.message) }
    let known = ["rollback_proposal_not_found", "rollback_proposal_not_pending", "rollback_superseded", "rollback_in_progress", "definition_sync_pending", "definition_sync_failed", "definition_rollback_in_progress"]
    throw rollbackGraphError(known.contains(error.code) ? error.code.uppercased() : "ROLLBACK_FAILED", "\(error.code): \(error.message)")
  } catch let error as WorkflowDefinitionGraphQLError {
    throw error
  } catch let error as WorkflowDefinitionStoreError {
    let code = error.code.rawValue
    let mapped = code == "definition_rollback_in_progress" ? code.uppercased() : "ROLLBACK_FAILED"
    throw rollbackGraphError(mapped, "\(code): \(error.message)")
  } catch {
    throw rollbackGraphError("ROLLBACK_FAILED", String(describing: error))
  }
}

private func rollbackGraphError(_ code: String, _ message: String) -> WorkflowDefinitionGraphQLError {
  WorkflowDefinitionGraphQLError(code: code, message: message)
}

private func rollbackRegressionDTO(_ value: WorkflowRollbackRegressionEntry) -> GraphQLWorkflowRollbackRegression {
  GraphQLWorkflowRollbackRegression(kind: value.kind, gateId: value.gateId, detail: value.detail)
}

private func rollbackDTO(_ value: WorkflowRollbackProposal) -> GraphQLWorkflowRollbackProposal {
  let formatter = ISO8601DateFormatter()
  return GraphQLWorkflowRollbackProposal(proposalId: value.proposalId, workflowName: value.workflowName,
    regressedVersionId: value.regressedVersionId, rollbackToVersionId: value.rollbackToVersionId, mode: value.mode.rawValue,
    bundleSnapshotId: value.bundleSnapshotId, baselineSessionId: value.baselineSessionId, targetSessionId: value.targetSessionId,
    regressions: value.regressions.map(rollbackRegressionDTO), policy: value.policy.rawValue, status: value.status.rawValue,
    decidedActor: value.decidedActor.map { GraphQLWorkflowDefinitionActor(kind: $0.kind.rawValue, id: $0.id) },
    decisionReason: value.decisionReason, appliedVersionId: value.appliedVersionId, appliedAuditId: value.appliedAuditId,
    failureCode: value.failureCode, diagnostics: value.diagnostics, createdAt: formatter.string(from: value.createdAt),
    updatedAt: formatter.string(from: value.updatedAt))
}
