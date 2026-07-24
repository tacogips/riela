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
          metadata: backendEvent.metadata,
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

  func startAgentSilenceMonitorIfNeeded(
    request: DeterministicWorkflowRunRequest,
    workflowId: String,
    step: WorkflowStepRef,
    execution: WorkflowStepExecution,
    eventContext: WorkflowBackendEventEmissionContext
  ) -> Task<Void, Never>? {
    guard execution.backend?.cliAgentBackend != nil,
          let thresholdMs = request.agentSilenceWarningMs,
          thresholdMs > 0,
          request.agentSilenceMonitorIntervalMs > 0,
          request.eventHandler != nil else {
      return nil
    }
    return Task {
      var warningSignalAt: Date?
      var lastWarningSilentForMs = 0
      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: UInt64(request.agentSilenceMonitorIntervalMs) * 1_000_000)
        } catch {
          return
        }
        guard !Task.isCancelled,
              let current = try? await store.loadSession(id: eventContext.sessionId),
              let runningExecution = current.executions.last(where: { $0.executionId == execution.executionId }),
              runningExecution.status == .running else {
          return
        }
        guard let lastSignalAt = runningExecution.lastBackendEventAt else {
          continue
        }
        if warningSignalAt != lastSignalAt {
          warningSignalAt = lastSignalAt
          lastWarningSilentForMs = 0
        }
        let silentForMs = Int(Date().timeIntervalSince(lastSignalAt) * 1_000)
        guard silentForMs >= thresholdMs else {
          continue
        }
        guard silentForMs - lastWarningSilentForMs >= thresholdMs else {
          continue
        }
        await emitSilenceWarningEvent(
          workflowId: workflowId,
          eventContext: WorkflowBackendEventEmissionContext(
            sessionId: current.sessionId,
            status: current.status,
            currentStepId: current.currentStepId,
            nodeExecutions: current.executions.count
          ),
          step: step,
          executionId: execution.executionId,
          silentForMs: silentForMs,
          thresholdMs: thresholdMs,
          handler: request.eventHandler
        )
        lastWarningSilentForMs = silentForMs
      }
    }
  }
}
