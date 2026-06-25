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
    await recordTelemetry(for: event)
    guard let handler else {
      return
    }
    await handler(event)
  }

  private func recordTelemetry(for event: WorkflowRunEvent) async {
    let attributes = telemetryAttributes(for: event)
    switch event.type {
    case .sessionStarted:
      await telemetry.recordLog(RielaTelemetryLog(name: "riela.workflow.start", attributes: attributes))
      await telemetry.recordMetric(RielaTelemetryMetric(name: "riela.workflow.run.count", value: 1, attributes: attributes))
    case .stepStarted:
      await telemetry.recordLog(RielaTelemetryLog(name: "riela.workflow.step.start", attributes: attributes))
    case .stepCompleted:
      await telemetry.recordSpan(RielaTelemetrySpan(
        name: "riela.workflow.step",
        status: event.status == .failed ? .error : .ok,
        startedAt: Date(),
        attributes: attributes
      ))
      await telemetry.recordMetric(RielaTelemetryMetric(name: "riela.workflow.step.count", value: 1, attributes: attributes))
    case .sessionCompleted:
      await telemetry.recordSpan(RielaTelemetrySpan(
        name: "riela.workflow.run",
        status: event.status == .failed ? .error : .ok,
        startedAt: Date(),
        attributes: attributes
      ))
      await telemetry.recordMetric(RielaTelemetryMetric(name: "riela.workflow.run.complete.count", value: 1, attributes: attributes))
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
    return attributes
  }
}
