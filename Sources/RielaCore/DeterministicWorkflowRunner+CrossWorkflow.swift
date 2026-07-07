import Foundation

/// Live cross-workflow dispatch: run the callee workflow to completion in a
/// child session, then deliver the callee root output to the caller's resume
/// step as the inbound workflow message.
extension DeterministicWorkflowRunner {
  static let maxCrossWorkflowDispatchDepth = 8

  func dispatchCrossWorkflowCallee(
    directive: WorkflowCrossWorkflowDispatchDirective,
    parentSessionId: String,
    parentStepId: String,
    request: DeterministicWorkflowRunRequest
  ) async throws {
    guard let calleeResolver else {
      throw DeterministicWorkflowRunnerError.crossWorkflowDispatchFailed(
        workflowId: directive.workflowId,
        reason: "no callee workflow resolver is wired for live cross-workflow dispatch"
      )
    }
    guard request.crossWorkflowDispatchDepth < Self.maxCrossWorkflowDispatchDepth else {
      throw DeterministicWorkflowRunnerError.crossWorkflowDispatchFailed(
        workflowId: directive.workflowId,
        reason: "cross-workflow dispatch depth exceeded \(Self.maxCrossWorkflowDispatchDepth); check workflows for a call cycle"
      )
    }

    let callee: ResolvedWorkflowCallee
    do {
      callee = try await calleeResolver.resolveCallee(workflowId: directive.workflowId)
    } catch {
      throw DeterministicWorkflowRunnerError.crossWorkflowDispatchFailed(
        workflowId: directive.workflowId,
        reason: "failed to resolve callee workflow: \(String(describing: error))"
      )
    }
    guard callee.workflow.workflowId == directive.workflowId else {
      throw DeterministicWorkflowRunnerError.crossWorkflowDispatchFailed(
        workflowId: directive.workflowId,
        reason: "resolved workflow has workflowId '\(callee.workflow.workflowId)', expected '\(directive.workflowId)'"
      )
    }

    var calleeWorkflow = callee.workflow
    guard calleeWorkflow.steps.contains(where: { $0.id == directive.calleeEntryStepId }) else {
      throw DeterministicWorkflowRunnerError.crossWorkflowDispatchFailed(
        workflowId: directive.workflowId,
        reason: "callee workflow has no step '\(directive.calleeEntryStepId)' to enter"
      )
    }
    calleeWorkflow.entryStepId = directive.calleeEntryStepId

    let calleeRequest = DeterministicWorkflowRunRequest(
      workflow: calleeWorkflow,
      nodePayloads: callee.nodePayloads,
      variables: directive.handoffPayload,
      defaultTimeoutMs: request.defaultTimeoutMs,
      memoryRootDirectory: request.memoryRootDirectory,
      agentSilenceWarningMs: request.agentSilenceWarningMs,
      agentSilenceMonitorIntervalMs: request.agentSilenceMonitorIntervalMs,
      eventHandler: request.eventHandler,
      crossWorkflowDispatchDepth: request.crossWorkflowDispatchDepth + 1
    )
    let calleeResult: WorkflowRunResult
    do {
      calleeResult = try await run(calleeRequest)
    } catch {
      if isWorkflowRunCancellation(error) {
        throw error
      }
      throw DeterministicWorkflowRunnerError.crossWorkflowDispatchFailed(
        workflowId: directive.workflowId,
        reason: "callee workflow run failed: \(workflowRunFailureReason(error))"
      )
    }
    guard calleeResult.status == .completed else {
      throw DeterministicWorkflowRunnerError.crossWorkflowDispatchFailed(
        workflowId: directive.workflowId,
        reason: "callee session '\(calleeResult.session.sessionId)' ended with status '\(calleeResult.status.rawValue)'"
      )
    }

    var resumePayload = calleeResult.rootOutput ?? [:]
    resumePayload["_rielaCrossWorkflow"] = .object([
      "workflowId": .string(directive.workflowId),
      "sessionId": .string(calleeResult.session.sessionId),
      "status": .string(calleeResult.status.rawValue)
    ])
    _ = try await store.appendWorkflowMessage(WorkflowMessageAppendInput(
      workflowExecutionId: parentSessionId,
      fromStepId: parentStepId,
      toStepId: directive.resumeStepId,
      routingScope: .workflow,
      deliveryKind: .direct,
      sourceStepExecutionId: directive.sourceStepExecutionId,
      transitionCondition: directive.transitionLabel,
      payload: resumePayload
    ))
  }
}
