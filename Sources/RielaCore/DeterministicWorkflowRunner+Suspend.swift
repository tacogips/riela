import Foundation

extension DeterministicWorkflowRunner {
  func requestedSuspendRecord(
    publishResult: WorkflowPublicationResult,
    step: WorkflowStepRef,
    request: DeterministicWorkflowRunRequest
  ) async -> SuspendRecord? {
    if let handover = publishResult.handover {
      let executionId = publishResult.stepExecution.executionId
      return SuspendRecord(
        reasonKind: handover.reason,
        stepId: handover.resumeStepId ?? step.id,
        stepExecutionId: executionId,
        question: handover.question,
        presence: handover.presence,
        progressNote: handover.progressNote,
        suspendedAt: Date(),
        producer: .stepExecution(executionId)
      )
    }
    // A dispatching transition (fanout or cross-workflow) must run its dispatch before any suspension;
    // suspending at its target or resume step would drop the fanout items/join or skip the callee.
    guard publishResult.crossWorkflowDispatch == nil, publishResult.fanoutDispatch == nil,
          let nextStepId = publishResult.nextStepId,
          var record = await request.boundaryHandover?(nextStepId) else {
      return nil
    }
    record.stepId = nextStepId
    return record
  }

  func suspendSession(
    _ record: SuspendRecord,
    workflowId: String,
    session: WorkflowSession,
    transitions: Int,
    request: DeterministicWorkflowRunRequest,
    ownedWorkflowRunId: String?
  ) async throws -> WorkflowRunResult {
    let suspended = try await store.suspendSession(
      WorkflowSessionSuspendInput(sessionId: session.sessionId, record: record, now: Date())
    )
    await emitHandoverEvent(workflowId: workflowId, session: suspended, record: record, handler: request.eventHandler)
    let result = WorkflowRunResult(
      workflowId: workflowId,
      session: suspended,
      rootOutput: nil,
      exitCode: 5,
      transitions: transitions
    )
    await emitSessionCompletedEvent(result: result, handler: request.eventHandler)
    await finishOwnedWorkflowRun(ownedWorkflowRunId)
    return result
  }
}
