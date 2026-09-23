import Foundation

extension DeterministicWorkflowRunner {
  /// Prepares immutable callee intent while the parent route is staged. The
  /// fail-closed runtime store commits this plan, the parent's accepted staged
  /// output, and its waiting checkpoint in one canonical SQLite transaction.
  func nestedInvocationPreCommitPublicationHook(
    workflow _: WorkflowDefinition,
    step: WorkflowStepRef,
    request: DeterministicWorkflowRunRequest
  ) -> WorkflowPreCommitPublicationHook? {
    guard !simulatesCrossWorkflowDispatch,
          nestedInvocationPersistenceStore != nil,
          calleeResolver != nil,
          step.transitions?.contains(where: {
            $0.toWorkflowId != nil && $0.resumeStepId != nil && $0.fanout == nil
          }) == true else {
      return nil
    }
    return { context in
      let transitions = context.selectedTransitions.filter {
        $0.toWorkflowId != nil && $0.resumeStepId != nil && $0.fanout == nil
      }
      guard transitions.count <= 1 else {
        throw DeterministicWorkflowRunnerError.invalidWorkflow(
          "step '\(step.id)' selected more than one nested callee"
        )
      }
      guard let transition = transitions.first,
            let workflowId = transition.toWorkflowId,
            let resumeStepId = transition.resumeStepId,
          let resolver = self.calleeResolver else {
        return nil
      }
      let callee: ResolvedWorkflowCallee
      do {
        callee = try await resolver.resolveCallee(workflowId: workflowId)
      } catch {
        throw DeterministicWorkflowRunnerError.crossWorkflowDispatchFailed(
          workflowId: workflowId,
          reason: "failed to resolve callee before parent publication: \(String(describing: error))"
        )
      }
      guard callee.workflow.workflowId == workflowId,
            callee.workflow.steps.contains(where: { $0.id == transition.toStepId }) else {
        throw DeterministicWorkflowRunnerError.crossWorkflowDispatchFailed(
          workflowId: workflowId,
          reason: "callee does not match the accepted invocation intent"
        )
      }
      var immutableWorkflow = callee.workflow
      immutableWorkflow.entryStepId = transition.toStepId
      let persistence = try self.requiredNestedInvocationPersistenceStore()
      if let existing = try persistence.nestedInvocationRecord(
        parentSessionId: context.session.sessionId,
        sourceStepExecutionId: context.stepExecution.executionId,
        branchId: "cross-workflow"
      ) {
        return WorkflowNestedPublicationPlan(reservation: existing.reservation)
      }
      let childSessionId = try self.nestedSessionID(
        parentSessionId: context.session.sessionId,
        sourceExecutionId: context.stepExecution.executionId,
        branchId: "cross-workflow"
      )
      let now = Date()
      let child = WorkflowSession(
        workflowId: immutableWorkflow.workflowId,
        sessionId: childSessionId,
        status: .created,
        entryStepId: transition.toStepId,
        currentStepId: transition.toStepId,
        createdAt: now,
        updatedAt: now,
        parentSessionId: context.session.sessionId,
        rootSessionId: request.rootSessionId ?? context.session.rootSessionId ?? context.session.sessionId
      )
      let plan = WorkflowNestedPublicationPlan(reservation: WorkflowNestedInvocationReservation(
        parentSessionId: context.session.sessionId,
        parentStepId: step.id,
        resumeStepId: resumeStepId,
        sourceStepExecutionId: context.stepExecution.executionId,
        branchId: "cross-workflow",
        childSnapshot: WorkflowRuntimePersistenceSnapshot(session: child),
        calleeWorkflow: immutableWorkflow,
        calleeNodePayloads: callee.nodePayloads,
        calleeRevision: nestedCalleeRevision(workflow: immutableWorkflow, nodePayloads: callee.nodePayloads)
      ))
      if self.store is any WorkflowNestedPublicationCommitting {
        // This is a process-death seam for the pre-reservation window. The
        // parent is still only staged, so reopening recomputes the same plan
        // and reaches the canonical transaction without any child effect.
        try await self.nestedInvocationRecoveryCheckpointer?.reached(.prepared)
        return plan
      }
      // Core-only/in-memory callers retain their prior recoverable behavior.
      // They do not claim the production SQLite atomicity capability.
      _ = try await self.reserveNestedSession(
        workflow: immutableWorkflow,
        nodePayloads: callee.nodePayloads,
        entryStepId: transition.toStepId,
        parentSessionId: context.session.sessionId,
        rootSessionId: request.rootSessionId ?? context.session.rootSessionId ?? context.session.sessionId,
        parentStepId: step.id,
        resumeStepId: resumeStepId,
        sourceExecutionId: context.stepExecution.executionId,
        branchId: "cross-workflow"
      )
      return nil
    }
  }

  private func requiredNestedInvocationPersistenceStore() throws -> SQLiteWorkflowRuntimePersistenceStore {
    guard let nestedInvocationPersistenceStore else {
      throw WorkflowRuntimePersistenceStoreError.notFound("nested invocation persistence store")
    }
    return nestedInvocationPersistenceStore
  }
}
