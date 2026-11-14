import Foundation
import RielaCore

struct WorkflowRuntimeReviewFinalizer: Sendable {
  func finalize(
    proposalId: String,
    expectedIdentity: WorkflowBundleIdentity,
    historyRoot: URL,
    workflow: WorkflowDefinition,
    runtimeSnapshot: WorkflowRuntimePersistenceSnapshot
  ) throws -> WorkflowChangeSet {
    guard runtimeSnapshot.session.status == .completed else {
      throw CLIUsageError("workflow review session must be completed before finalization")
    }
    let store = WorkflowChangeSetStore(root: historyRoot)
    let proposal = try store.loadProposal(proposalId, expectedIdentity: expectedIdentity)
    let (review, gateEvidence) = try reviewEvidence(
      proposal: proposal,
      workflow: workflow,
      runtimeSnapshot: runtimeSnapshot
    )
    try WorkflowRuntimeGateEvidenceStore(root: historyRoot).publish(gateEvidence)
    return try store.finalize(
      proposalId: proposalId,
      expectedIdentity: expectedIdentity,
      review: review
    )
  }

  private func reviewEvidence(
    proposal: WorkflowChangeProposal,
    workflow: WorkflowDefinition,
    runtimeSnapshot: WorkflowRuntimePersistenceSnapshot
  ) throws -> (WorkflowChangeSetReviewEvidence, WorkflowRuntimeGateEvidence) {
    let gate = try WorkflowReviewGatePolicy.requiredGate(in: workflow)
    guard runtimeSnapshot.session.workflowId == workflow.workflowId,
          let manifest = runtimeSnapshot.loopEvidence,
          manifest.workflowId == workflow.workflowId,
          manifest.sessionId == runtimeSnapshot.session.sessionId else {
      throw CLIUsageError("review session does not contain runtime-owned evidence for the target workflow declaration")
    }
    let matchingExecutions = runtimeSnapshot.session.executions.filter {
      $0.stepId == gate.stepId && $0.status == .completed
    }
    guard matchingExecutions.count == 1, let execution = matchingExecutions.first else {
      throw CLIUsageError("review session did not complete the exact declared required review-gate step")
    }
    let matchingResults = manifest.gates.filter {
      $0.gateId == gate.id
        && $0.stepId == gate.stepId
        && $0.stepExecutionId == execution.executionId
    }
    guard matchingResults.count == 1, let gateResult = matchingResults.first else {
      throw CLIUsageError("review session lacks exact runtime-owned evidence for the declared review gate execution")
    }
    try WorkflowReviewGatePolicy.validate(gateResult, gate: gate)
    let resultId = try WorkflowRuntimeGateEvidenceStore.resultId(stepExecutionId: execution.executionId)
    guard let acceptedOutput = execution.acceptedOutput,
          case let .object(payload)? = acceptedOutput.payload["workflowChangeReview"] else {
      throw CLIUsageError("declared review gate did not produce workflowChangeReview evidence")
    }
    let allowedKeys: Set<String> = [
      "gateId", "decision", "reviewedProposalId",
      "reviewedProposalDigest", "reviewedBeforeBundleDigest", "evidenceReferences"
    ]
    guard Set(payload.keys) == allowedKeys else {
      throw CLIUsageError("runtime workflowChangeReview contains missing or unknown fields")
    }
    guard let gateId = payload["gateId"]?.stringValue,
          payload["decision"]?.stringValue == WorkflowChangeReviewDecision.accepted.rawValue,
          let reviewedProposalId = payload["reviewedProposalId"]?.stringValue,
          let reviewedProposalDigest = payload["reviewedProposalDigest"]?.stringValue,
          let reviewedBeforeBundleDigest = payload["reviewedBeforeBundleDigest"]?.stringValue,
          case let .array(referenceValues)? = payload["evidenceReferences"],
          referenceValues.allSatisfy({ $0.stringValue != nil }),
          case let .object(loopGate)? = acceptedOutput.payload["loopGate"],
          gateId == gate.id,
          loopGate["gateId"]?.stringValue == gate.id,
          loopGate["decision"]?.stringValue == LoopGateDecision.accepted.rawValue else {
      throw CLIUsageError("runtime review result is not an accepted structured gate result")
    }
    guard reviewedProposalId == proposal.proposalId,
          reviewedProposalDigest == proposal.proposalDigest,
          reviewedBeforeBundleDigest == proposal.beforeBundleDigest else {
      throw CLIUsageError("runtime review result does not bind the immutable proposal")
    }
    let evidence = WorkflowChangeSetReviewEvidence(
      gateId: gateId,
      gateResultId: resultId,
      decision: .accepted,
      reviewedProposalId: reviewedProposalId,
      reviewedProposalDigest: reviewedProposalDigest,
      reviewedBeforeBundleDigest: reviewedBeforeBundleDigest,
      reviewerStepId: execution.stepId,
      reviewerStepExecutionId: execution.executionId,
      reviewedAt: acceptedOutput.acceptedAt,
      evidenceReferences: referenceValues.compactMap(\.stringValue).sorted()
    )
    try WorkflowHistoryCanonicalCoding.validate(evidence)
    try WorkflowReviewGatePolicy.validate(gateResult, gate: gate, review: evidence)
    return (
      evidence,
      WorkflowRuntimeGateEvidence(
        resultId: resultId,
        workflowId: workflow.workflowId,
        sessionId: runtimeSnapshot.session.sessionId,
        result: gateResult
      )
    )
  }
}
