import Foundation

extension DeterministicWorkflowRunner {
  func skipFilteredStepIfNeeded(
    registryNode: WorkflowNodeRegistryRef,
    requestVariables: JSONObject,
    resolvedInputPayload: JSONObject,
    sessionId: String,
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    transitions: [WorkflowStepTransition],
    request: DeterministicWorkflowRunRequest,
    executionIndex: Int
  ) async throws -> WorkflowPublicationResult? {
    guard let inputFilters = registryNode.inputFilters, !inputFilters.isEmpty else {
      return nil
    }
    let decision = inputFilterEvaluator.evaluate(
      filters: inputFilters,
      variables: filterVariables(requestVariables: requestVariables, resolvedInputPayload: resolvedInputPayload),
      stepId: step.id,
      nodeId: step.nodeId
    )
    decision.issues.forEach { inputFilterLogger.log($0) }
    guard !decision.shouldRun else {
      return nil
    }
    return try await skipFilteredStepAndAdvance(
      sessionId: sessionId,
      workflow: workflow,
      step: step,
      transitions: transitions,
      request: request,
      executionIndex: executionIndex
    )
  }

  private func filterVariables(requestVariables: JSONObject, resolvedInputPayload: JSONObject) -> JSONObject {
    var variables = requestVariables
    for (key, value) in resolvedInputPayload {
      variables[key] = value
    }
    return variables
  }

  private func skipFilteredStepAndAdvance(
    sessionId: String,
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    transitions: [WorkflowStepTransition],
    request: DeterministicWorkflowRunRequest,
    executionIndex: Int
  ) async throws -> WorkflowPublicationResult {
    return try await publisher.publishAcceptedOutput(
      WorkflowPublicationRequest(
        sessionId: sessionId,
        stepId: step.id,
        nodeId: step.nodeId,
        attempt: executionIndex,
        body: .inlineCandidate(skippedInputFilterCandidatePayload),
        transitions: transitions,
        successfulExecutionStatus: .skipped,
        transitionSelectionMode: .firstMatch,
        noSelectionDisposition: .completeRootWithoutOutput,
        prePersistenceRoutingDecider: workflowPrePersistenceRoutingDecider(
          workflow: workflow,
          step: step,
          request: request
        ),
        carriedPayloadFields: carriedLoopGuardPayload(from: request)
      )
    )
  }
}

private let skippedInputFilterCandidate = RuntimeOutputCandidate(
  source: .inlineCandidate,
  payload: ["inputFilterSkipped": .bool(true)],
  when: ["input_filter_skipped": true]
)

private let skippedInputFilterCandidatePayload: JSONObject = [
  "completionPassed": .bool(true),
  "when": .object(["input_filter_skipped": .bool(true)]),
  "payload": .object(["inputFilterSkipped": .bool(true)])
]
