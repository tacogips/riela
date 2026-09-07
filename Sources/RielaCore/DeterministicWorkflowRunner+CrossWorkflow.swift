import Foundation

/// Live cross-workflow dispatch: run the callee workflow to completion in a
/// child session, then deliver the callee root output to the caller's resume
/// step as the inbound workflow message.
extension DeterministicWorkflowRunner {
  static let maxCrossWorkflowDispatchDepth = 8

  func validateCrossWorkflowDispatchTargets(in workflow: WorkflowDefinition) async throws {
    guard !simulatesCrossWorkflowDispatch, let calleeResolver else {
      return
    }
    let callerStepIds = Set(workflow.steps.map(\.id))
    for reference in Self.crossWorkflowDispatchReferences(in: workflow) {
      guard callerStepIds.contains(reference.resumeStepId) else {
        throw DeterministicWorkflowRunnerError.invalidWorkflow(
          "\(reference.resumeStepPath): step '\(reference.stepId)' resumes at step " +
            "'\(reference.resumeStepId)' in workflow '\(workflow.workflowId)', but that caller resume step does not exist"
        )
      }
      let callee: ResolvedWorkflowCallee
      do {
        callee = try await calleeResolver.resolveCallee(workflowId: reference.workflowId)
      } catch {
        throw DeterministicWorkflowRunnerError.invalidWorkflow(
          "\(reference.path): step '\(reference.stepId)' references cross-workflow callee " +
            "'\(reference.workflowId)', but it could not be resolved before running: \(String(describing: error))"
        )
      }
      guard callee.workflow.workflowId == reference.workflowId else {
        throw DeterministicWorkflowRunnerError.invalidWorkflow(
          "\(reference.path): step '\(reference.stepId)' references cross-workflow callee " +
            "'\(reference.workflowId)', but resolver returned workflowId '\(callee.workflow.workflowId)'"
        )
      }
      guard callee.workflow.steps.contains(where: { $0.id == reference.calleeEntryStepId }) else {
        throw DeterministicWorkflowRunnerError.invalidWorkflow(
          "\(reference.path): step '\(reference.stepId)' dispatches to step " +
            "'\(reference.calleeEntryStepId)' in workflow '\(reference.workflowId)', but that callee step does not exist"
        )
      }
    }
  }

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

    let existingReservation = try nestedInvocationPersistenceStore?.nestedInvocationRecord(
      parentSessionId: parentSessionId,
      sourceStepExecutionId: directive.sourceStepExecutionId,
      branchId: "cross-workflow"
    )
    let callee: ResolvedWorkflowCallee
    if let existingReservation {
      guard let workflow = existingReservation.reservation.calleeWorkflow,
            let nodePayloads = existingReservation.reservation.calleeNodePayloads,
            let revision = existingReservation.reservation.calleeRevision,
            revision == nestedCalleeRevision(workflow: workflow, nodePayloads: nodePayloads) else {
        throw DeterministicWorkflowRunnerError.crossWorkflowDispatchFailed(
          workflowId: directive.workflowId,
          reason: "persisted nested invocation lacks an immutable authorized callee snapshot"
        )
      }
      callee = ResolvedWorkflowCallee(workflow: workflow, nodePayloads: nodePayloads)
    } else {
      do {
        callee = try await calleeResolver.resolveCallee(workflowId: directive.workflowId)
      } catch {
        throw DeterministicWorkflowRunnerError.crossWorkflowDispatchFailed(
          workflowId: directive.workflowId,
          reason: "failed to resolve callee workflow: \(String(describing: error))"
        )
      }
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
    let reservedChildSessionId = try await reserveNestedSession(
      workflow: calleeWorkflow,
      nodePayloads: callee.nodePayloads,
      entryStepId: directive.calleeEntryStepId,
      parentSessionId: parentSessionId,
      rootSessionId: request.rootSessionId ?? parentSessionId,
      parentStepId: parentStepId,
      resumeStepId: directive.resumeStepId,
      sourceExecutionId: directive.sourceStepExecutionId,
      branchId: "cross-workflow"
    )

    // Never treat an interrupted running child as a safe retry. A created
    // reservation has not entered its first node and can be resumed; a
    // running snapshot may already have performed a non-idempotent effect.
    // Persist that uncertainty before returning so repeated reopens are
    // fenced identically instead of each getting a chance to relaunch it.
    if let nestedInvocationPersistenceStore,
       let record = try nestedInvocationPersistenceStore.nestedInvocationRecord(
         parentSessionId: parentSessionId,
         sourceStepExecutionId: directive.sourceStepExecutionId,
         branchId: "cross-workflow"
       ) {
      if let reason = record.recoveryReason {
        throw DeterministicWorkflowRunnerError.crossWorkflowDispatchFailed(
          workflowId: directive.workflowId,
          reason: "nested child '\(reservedChildSessionId)' requires recovery: \(reason)"
        )
      }
      if let terminal = record.childTerminalSnapshot,
         terminal.session.status != .completed {
        throw DeterministicWorkflowRunnerError.crossWorkflowDispatchFailed(
          workflowId: directive.workflowId,
          reason: "nested child '\(reservedChildSessionId)' already ended with status '\(terminal.session.status.rawValue)'"
        )
      }
      if record.parentMessage != nil {
        return
      }
      if record.childTerminalSnapshot == nil,
         let childSnapshot = try? nestedInvocationPersistenceStore.load(sessionId: reservedChildSessionId),
         childSnapshot.session.status == .running {
        _ = try nestedInvocationPersistenceStore.requireNestedInvocationRecovery(
          reservation: record.reservation,
          reason: "child was running without a terminal receipt"
        )
        throw DeterministicWorkflowRunnerError.crossWorkflowDispatchFailed(
          workflowId: directive.workflowId,
          reason: "nested child '\(reservedChildSessionId)' has an unresolved in-flight effect"
        )
      }
    }

    var calleeRequest = DeterministicWorkflowRunRequest(
      workflow: calleeWorkflow,
      nodePayloads: callee.nodePayloads,
      variables: directive.handoffPayload,
      maxSteps: request.maxSteps,
      maxLoopIterations: request.maxLoopIterations,
      disableDefaultLoopGuard: request.disableDefaultLoopGuard,
      defaultTimeoutMs: request.defaultTimeoutMs,
      memoryRootDirectory: request.memoryRootDirectory,
      agentSilenceWarningMs: request.agentSilenceWarningMs,
      agentSilenceMonitorIntervalMs: request.agentSilenceMonitorIntervalMs,
      eventHandler: request.eventHandler,
      crossWorkflowDispatchDepth: request.crossWorkflowDispatchDepth + 1
    )
    calleeRequest.workflowRunId = request.workflowRunId
    calleeRequest.fanoutChangeContext = request.fanoutChangeContext
    calleeRequest.parentSessionId = parentSessionId
    calleeRequest.rootSessionId = request.rootSessionId ?? parentSessionId
    calleeRequest.resumeSessionId = reservedChildSessionId
    calleeRequest.isNestedCalleeEffectBoundary = true
    let calleeResult: WorkflowRunResult
    do {
      try await nestedInvocationRecoveryCheckpointer?.reached(.beforeChildNodeEffect)
      calleeResult = try await run(calleeRequest)
      if try await persistNestedTerminalIfNeeded(
        parentSessionId: parentSessionId,
        sourceExecutionId: directive.sourceStepExecutionId,
        branchId: "cross-workflow",
        terminalSession: calleeResult.session
      ) {
        try await nestedInvocationRecoveryCheckpointer?.reached(.childTerminalPersisted)
      }
      try await nestedInvocationRecoveryCheckpointer?.reached(.afterChildNodeResult)
    } catch {
      if error is NestedRecoveryInterruption {
        throw error
      }
      // A failed or cancelled child has a durable terminal session even
      // though it has no successful parent arrival. Record it before the
      // parent sees the failure so any reopen fails closed instead of
      // allocating a second child attempt.
      if let terminalChild = try? await store.loadSession(id: reservedChildSessionId),
         terminalChild.status == .failed {
        try await persistNestedTerminalIfNeeded(
          parentSessionId: parentSessionId,
          sourceExecutionId: directive.sourceStepExecutionId,
          branchId: "cross-workflow",
          terminalSession: terminalChild
        )
      }
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

    try await appendNestedResultOnce(
      parentSessionId: parentSessionId,
      parentStepId: parentStepId,
      resumeStepId: directive.resumeStepId,
      sourceExecutionId: directive.sourceStepExecutionId,
      transitionCondition: directive.transitionLabel,
      childSessionId: reservedChildSessionId,
      workflowId: directive.workflowId,
      status: calleeResult.status,
      payload: calleeResult.rootOutput ?? [:],
      terminalSession: calleeResult.session
    )
  }
}
