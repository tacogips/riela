import Foundation

extension DeterministicWorkflowRunner {
  func emitSessionStartedEvent(
    workflowId: String,
    session: WorkflowSession,
    handler: WorkflowRunEventHandler?
  ) async {
    await emitRunEvent(
      .init(
        type: .sessionStarted,
        workflowId: workflowId,
        sessionId: session.sessionId,
        status: session.status,
        currentStepId: session.currentStepId
      ),
      handler: handler
    )
  }

  func emitStepStartedEvent(
    workflowId: String,
    session: WorkflowSession,
    step: WorkflowStepRef,
    handler: WorkflowRunEventHandler?
  ) async {
    await emitRunEvent(
      .init(
        type: .stepStarted,
        workflowId: workflowId,
        sessionId: session.sessionId,
        status: session.status,
        currentStepId: step.id,
        stepId: step.id,
        nodeId: step.nodeId
      ),
      handler: handler
    )
  }

  func emitStepCompletedEvent(
    workflowId: String,
    session: WorkflowSession,
    step: WorkflowStepRef,
    publishResult: WorkflowPublicationResult,
    publishedTransitions: Int,
    handler: WorkflowRunEventHandler?
  ) async {
    await emitRunEvent(
      .init(
        type: .stepCompleted,
        workflowId: workflowId,
        sessionId: session.sessionId,
        status: session.status,
        currentStepId: session.currentStepId,
        stepId: step.id,
        nodeId: step.nodeId,
        executionId: publishResult.stepExecution.executionId,
        nodeExecutions: session.executions.count,
        transitions: publishedTransitions
      ),
      handler: handler
    )
  }

  func emitSessionCompletedEvent(result: WorkflowRunResult, handler: WorkflowRunEventHandler?) async {
    await emitRunEvent(
      .init(
        type: .sessionCompleted,
        workflowId: result.workflowId,
        sessionId: result.session.sessionId,
        status: result.session.status,
        currentStepId: result.session.currentStepId,
        exitCode: result.exitCode,
        nodeExecutions: result.nodeExecutions,
        transitions: result.transitions
      ),
      handler: handler
    )
  }

  private func emitRunEvent(_ event: WorkflowRunEvent, handler: WorkflowRunEventHandler?) async {
    guard let handler else {
      return
    }
    await handler(event)
  }
}
