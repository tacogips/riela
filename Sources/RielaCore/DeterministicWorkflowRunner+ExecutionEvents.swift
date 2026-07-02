import Foundation

extension DeterministicWorkflowRunner {
  func recordStepStartedExecution(
    workflowId: String,
    sessionId: String,
    step: WorkflowStepRef,
    attempt: Int,
    backend: NodeExecutionBackend?,
    handler: WorkflowRunEventHandler?
  ) async throws -> WorkflowStepExecution {
    let execution = try await store.recordStepExecution(
      WorkflowStepExecutionRecordInput(
        sessionId: sessionId,
        stepId: step.id,
        nodeId: step.nodeId,
        attempt: attempt,
        backend: backend
      )
    )
    guard let updatedSession = try await store.loadSession(id: sessionId) else {
      throw WorkflowRuntimeStoreError.sessionNotFound(sessionId)
    }
    await emitStepStartedEvent(
      workflowId: workflowId,
      session: updatedSession,
      step: step,
      execution: execution,
      handler: handler
    )
    return execution
  }

  func adapterExecutionContext(
    deadline: Date?,
    workflowId: String,
    sessionId: String,
    step: WorkflowStepRef,
    execution: WorkflowStepExecution,
    handler: WorkflowRunEventHandler?
  ) -> AdapterExecutionContext {
    AdapterExecutionContext(deadline: deadline) { backendEvent in
      guard !backendEvent.eventType.isEmpty else {
        return
      }
      let updatedExecution = try? await self.store.recordStepBackendEvent(
        WorkflowStepBackendEventInput(
          sessionId: sessionId,
          executionId: execution.executionId,
          eventType: backendEvent.eventType,
          channel: backendEvent.channel,
          contentDelta: backendEvent.contentDelta,
          contentSnapshot: backendEvent.contentSnapshot,
          isDelta: backendEvent.isDelta,
          toolName: backendEvent.toolName,
          usage: backendEvent.usage,
          sequence: nil,
          at: backendEvent.at
        )
      )
      guard let updatedExecution,
            let updatedSession = try? await self.store.loadSession(id: sessionId) else {
        return
      }
      var enrichedEvent = backendEvent
      enrichedEvent.sequence = updatedExecution.backendEventCount
      enrichedEvent.at = updatedExecution.lastBackendEventAt
      await self.emitBackendEvent(
        workflowId: workflowId,
        session: updatedSession,
        step: step,
        execution: updatedExecution,
        backendEvent: enrichedEvent,
        handler: handler
      )
    }
  }
}
