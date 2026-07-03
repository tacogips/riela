import Foundation

extension DeterministicWorkflowRunner {
  func skipFilteredStepIfNeeded(
    registryNode: WorkflowNodeRegistryRef,
    requestVariables: JSONObject,
    resolvedInputPayload: JSONObject,
    sessionId: String,
    step: WorkflowStepRef,
    transitions: [WorkflowStepTransition],
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
      step: step,
      transitions: transitions,
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
    step: WorkflowStepRef,
    transitions: [WorkflowStepTransition],
    executionIndex: Int
  ) async throws -> WorkflowPublicationResult {
    let selectedTransitions = transitionAfterSkippedInputFilter(from: transitions).map { [$0] } ?? []
    return try await publisher.publishAcceptedOutput(
      WorkflowPublicationRequest(
        sessionId: sessionId,
        stepId: step.id,
        nodeId: step.nodeId,
        attempt: executionIndex,
        body: .inlineCandidate(skippedInputFilterCandidatePayload),
        transitions: selectedTransitions,
        successfulExecutionStatus: .skipped,
        completesRootWithoutOutput: selectedTransitions.isEmpty
      )
    )
  }

  private func transitionAfterSkippedInputFilter(from transitions: [WorkflowStepTransition]) -> WorkflowStepTransition? {
    transitions.first { transition in
      WorkflowBranchEvaluator().evaluate(
        label: transition.label,
        when: skippedInputFilterCandidate.when,
        payload: skippedInputFilterCandidate.payload
      )
    }
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
