import Foundation

extension DeterministicWorkflowRunner {
  func validatedExecutionPlan(
    for request: DeterministicWorkflowRunRequest
  ) throws -> WorkflowExecutionPlan {
    let diagnostics = DefaultWorkflowValidator().validate(
      request.workflow,
      nodePayloads: request.nodePayloads
    )
    if let diagnostic = diagnostics.first(where: { $0.severity == .error }) {
      throw DeterministicWorkflowRunnerError.invalidWorkflow("\(diagnostic.path): \(diagnostic.message)")
    }
    let supportsCrossWorkflowDispatch = simulatesCrossWorkflowDispatch || calleeResolver != nil
    let capabilityGaps = Self.unsupportedFeatures(
      in: request.workflow,
      maxConcurrency: request.maxConcurrency,
      supportsCrossWorkflowDispatch: supportsCrossWorkflowDispatch
    )
    if let gap = capabilityGaps.first(where: { $0.severity == .error }) {
      throw DeterministicWorkflowRunnerError.invalidWorkflow("\(gap.path): \(gap.message)")
    }
    if !supportsCrossWorkflowDispatch,
       let gap = capabilityGaps.first(where: { $0.path.hasSuffix(".transitions.toWorkflowId") }) {
      throw DeterministicWorkflowRunnerError.invalidWorkflow("\(gap.path): \(gap.message)")
    }
    try enforceRequiredLoopPolicyPreflight(request)
    return WorkflowExecutionPlan(workflow: request.workflow)
  }

  func validateSessionEntryModes(_ request: DeterministicWorkflowRunRequest) throws {
    do {
      try WorkflowSessionEntryValidation.validateMutuallyExclusiveSessionEntryModes(
        resumeSessionId: request.resumeSessionId,
        rerunFromSessionId: request.rerunFromSessionId,
        continueFromWorkflowExecutionId: nil
      )
    } catch let error as WorkflowSessionEntryValidationError {
      throw DeterministicWorkflowRunnerError.resumeValidation(errorMessage(error))
    }
  }

  func lifecycleIdentity(
    request: DeterministicWorkflowRunRequest,
    sessionId: String
  ) -> (workflowRunId: String, ownedWorkflowRunId: String?) {
    let workflowRunId = request.workflowRunId ?? sessionId
    return (workflowRunId, request.workflowRunId == nil ? workflowRunId : nil)
  }

  func finishOwnedWorkflowRun(_ workflowRunId: String?) async {
    guard let workflowRunId else {
      return
    }
    await adapter.workflowRunDidEnd(WorkflowRunLifecycleContext(workflowRunId: workflowRunId))
  }
}
