import Foundation
import RielaObservability

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
    execution: WorkflowStepExecution? = nil,
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
        nodeId: step.nodeId,
        executionId: execution?.executionId,
        nodeExecutions: execution == nil ? nil : session.executions.count
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
    let event = WorkflowRunEvent(
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
    )
    await recordCompletionTelemetry(
      for: event,
      startedAt: publishResult.stepExecution.createdAt,
      endedAt: publishResult.stepExecution.updatedAt
    )
    await emitRunEvent(
      event,
      handler: handler
    )
  }

  func emitBackendEvent(
    workflowId: String,
    eventContext: WorkflowBackendEventEmissionContext,
    step: WorkflowStepRef,
    executionId: String,
    backendEvent: AdapterBackendEvent,
    handler: WorkflowRunEventHandler?
  ) async {
    await emitRunEvent(
      .init(
        type: .backendEvent,
        workflowId: workflowId,
        sessionId: eventContext.sessionId,
        status: eventContext.status,
        currentStepId: eventContext.currentStepId,
        stepId: step.id,
        nodeId: step.nodeId,
        executionId: executionId,
        backendEventType: backendEvent.eventType,
        backendEventChannel: backendEvent.channel?.rawValue,
        backendEventContent: backendEvent.contentSnapshot ?? backendEvent.contentDelta,
        backendEventIsDelta: backendEvent.channel == nil ? nil : backendEvent.isDelta,
        backendEventSequence: backendEvent.sequence,
        backendToolName: backendEvent.toolName,
        backendEventUsage: backendEvent.usage,
        nodeExecutions: eventContext.nodeExecutions
      ),
      handler: handler
    )
  }

  func emitSilenceWarningEvent(
    workflowId: String,
    eventContext: WorkflowBackendEventEmissionContext,
    step: WorkflowStepRef,
    executionId: String,
    silentForMs: Int,
    thresholdMs: Int,
    handler: WorkflowRunEventHandler?
  ) async {
    await emitRunEvent(
      .init(
        type: .silenceWarning,
        workflowId: workflowId,
        sessionId: eventContext.sessionId,
        status: eventContext.status,
        currentStepId: eventContext.currentStepId,
        stepId: step.id,
        nodeId: step.nodeId,
        executionId: executionId,
        silentForMs: silentForMs,
        silenceThresholdMs: thresholdMs,
        nodeExecutions: eventContext.nodeExecutions
      ),
      handler: handler
    )
  }

  func emitSessionCompletedEvent(result: WorkflowRunResult, handler: WorkflowRunEventHandler?) async {
    let event = WorkflowRunEvent(
      type: .sessionCompleted,
      workflowId: result.workflowId,
      sessionId: result.session.sessionId,
      status: result.session.status,
      currentStepId: result.session.currentStepId,
      exitCode: result.exitCode,
      nodeExecutions: result.nodeExecutions,
      transitions: result.transitions
    )
    await recordCompletionTelemetry(for: event, startedAt: result.session.createdAt, endedAt: result.session.updatedAt)
    await emitRunEvent(
      event,
      handler: handler
    )
  }

  func emitRunEvent(_ event: WorkflowRunEvent, handler: WorkflowRunEventHandler?) async {
    await recordNonCompletionTelemetry(for: event)
    guard let handler else {
      return
    }
    await handler(event)
  }

  private func recordNonCompletionTelemetry(for event: WorkflowRunEvent) async {
    let attributes = telemetryAttributes(for: event)
    switch event.type {
    case .sessionStarted:
      await telemetry.recordLog(RielaTelemetryLog(name: "riela.workflow.start", attributes: attributes))
      await telemetry.recordMetric(RielaTelemetryMetric(name: "riela.workflow.run.count", value: 1, attributes: attributes))
    case .stepStarted:
      await telemetry.recordLog(RielaTelemetryLog(name: "riela.workflow.step.start", attributes: attributes))
    case .backendEvent:
      await telemetry.recordLog(RielaTelemetryLog(name: "riela.workflow.backend.event", attributes: attributes))
    case .silenceWarning:
      await telemetry.recordLog(RielaTelemetryLog(name: "riela.workflow.silence.warning", attributes: attributes))
    case .loopStall:
      await telemetry.recordLog(RielaTelemetryLog(name: "riela.workflow.loop.stall", severity: "WARNING", attributes: attributes))
    case .stepCompleted:
      break
    case .sessionCompleted:
      break
    }
  }

  private func recordCompletionTelemetry(for event: WorkflowRunEvent, startedAt: Date, endedAt: Date) async {
    let attributes = telemetryAttributes(for: event)
    switch event.type {
    case .stepCompleted:
      await telemetry.recordSpan(RielaTelemetrySpan(
        name: "riela.workflow.step",
        status: event.status == .failed ? .error : .ok,
        startedAt: startedAt,
        endedAt: endedAt,
        attributes: attributes
      ))
      await telemetry.recordMetric(RielaTelemetryMetric(name: "riela.workflow.step.count", value: 1, attributes: attributes))
    case .sessionCompleted:
      await telemetry.recordSpan(RielaTelemetrySpan(
        name: "riela.workflow.run",
        status: event.status == .failed ? .error : .ok,
        startedAt: startedAt,
        endedAt: endedAt,
        attributes: attributes
      ))
      await telemetry.recordMetric(RielaTelemetryMetric(name: "riela.workflow.run.complete.count", value: 1, attributes: attributes))
    case .sessionStarted, .stepStarted, .backendEvent, .silenceWarning, .loopStall:
      break
    }
  }

  private func telemetryAttributes(for event: WorkflowRunEvent) -> [String: String] {
    var attributes: [String: String] = [
      "workflow.id": event.workflowId,
      "session.id": event.sessionId,
      "runtime.surface": "workflow"
    ]
    if let status = event.status?.rawValue {
      attributes["status"] = status
    }
    if let currentStepId = event.currentStepId {
      attributes["step.id"] = currentStepId
    }
    if let stepId = event.stepId {
      attributes["node.step.id"] = stepId
    }
    if let nodeId = event.nodeId {
      attributes["node.id"] = nodeId
    }
    if let exitCode = event.exitCode {
      attributes["error_code"] = String(exitCode)
    }
    if let nodeExecutions = event.nodeExecutions {
      attributes["node.count"] = String(nodeExecutions)
    }
    if let transitions = event.transitions {
      attributes["transition.count"] = String(transitions)
    }
    if let backendEventType = event.backendEventType {
      attributes["backend.event.type"] = backendEventType
    }
    if let backendEventChannel = event.backendEventChannel {
      attributes["backend.event.channel"] = backendEventChannel
    }
    if let silentForMs = event.silentForMs {
      attributes["backend.silent_for_ms"] = String(silentForMs)
    }
    if let silenceThresholdMs = event.silenceThresholdMs {
      attributes["backend.silence_threshold_ms"] = String(silenceThresholdMs)
    }
    return attributes
  }
}
