import Foundation

extension DeterministicWorkflowRunner {
  func isWorkflowRunCancellation(_ error: Error) -> Bool {
    error is CancellationError
  }

  func markInterruptedSessionFailed(
    sessionId: String,
    request: DeterministicWorkflowRunRequest
  ) async {
    guard let failedSession = try? await store.markSessionFailed(
      WorkflowSessionFailureInput(sessionId: sessionId, reason: "workflow run cancelled")
    ) else {
      return
    }

    let result = WorkflowRunResult(
      workflowId: request.workflow.workflowId,
      session: failedSession,
      rootOutput: terminalRootOutput(from: failedSession),
      exitCode: 1,
      transitions: 0
    )
    await emitSessionCompletedEvent(result: result, handler: request.eventHandler)
  }
}
