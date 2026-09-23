extension DeterministicWorkflowRunner {
  func persistFanoutJoinCursor(
    session: WorkflowSession,
    publishResult: WorkflowPublicationResult,
    joinStepId: String
  ) async throws -> WorkflowSession {
    _ = try await store.updateStepExecution(WorkflowStepExecutionUpdateInput(
      sessionId: session.sessionId,
      executionId: publishResult.stepExecution.executionId,
      status: publishResult.stepExecution.status,
      acceptedOutput: publishResult.stepExecution.acceptedOutput,
      adapterOutput: publishResult.stepExecution.adapterOutput,
      usage: publishResult.stepExecution.usage,
      currentStepId: joinStepId
    ))
    guard let updatedSession = try await store.loadSession(id: session.sessionId) else {
      throw WorkflowRuntimeStoreError.sessionNotFound(session.sessionId)
    }
    return updatedSession
  }
}
