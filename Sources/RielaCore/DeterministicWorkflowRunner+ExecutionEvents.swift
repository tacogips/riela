import Foundation

struct WorkflowStepStartedExecutionRecord: Sendable {
  var execution: WorkflowStepExecution
  var backendEventContext: WorkflowBackendEventEmissionContext
}

struct WorkflowBackendEventEmissionContext: Sendable {
  var sessionId: String
  var status: WorkflowSessionStatus
  var currentStepId: String?
  var nodeExecutions: Int
}

extension DeterministicWorkflowRunner {
  func recordStepStartedExecution(
    workflowId: String,
    sessionId: String,
    step: WorkflowStepRef,
    attempt: Int,
    backend: NodeExecutionBackend?,
    handler: WorkflowRunEventHandler?
  ) async throws -> WorkflowStepStartedExecutionRecord {
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
    return WorkflowStepStartedExecutionRecord(
      execution: execution,
      backendEventContext: WorkflowBackendEventEmissionContext(
        sessionId: updatedSession.sessionId,
        status: updatedSession.status,
        currentStepId: updatedSession.currentStepId,
        nodeExecutions: updatedSession.executions.count
      )
    )
  }

  func adapterExecutionContext(
    deadline: Date?,
    workflowId: String,
    step: WorkflowStepRef,
    execution: WorkflowStepExecution,
    eventContext: WorkflowBackendEventEmissionContext,
    handler: WorkflowRunEventHandler?
  ) -> AdapterExecutionContext {
    AdapterExecutionContext(deadline: deadline) { backendEvent in
      guard !backendEvent.eventType.isEmpty else {
        return
      }
      let receipt = try? await self.store.recordStepBackendEventReceipt(
        WorkflowStepBackendEventInput(
          sessionId: eventContext.sessionId,
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
      guard let receipt else {
        return
      }
      var enrichedEvent = backendEvent
      enrichedEvent.sequence = receipt.sequence
      enrichedEvent.at = receipt.at
      await self.emitBackendEvent(
        workflowId: workflowId,
        eventContext: eventContext,
        step: step,
        executionId: receipt.executionId,
        backendEvent: enrichedEvent,
        handler: handler
      )
    }
  }
}
