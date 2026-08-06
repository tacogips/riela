import Foundation

extension DeterministicWorkflowRunner {
  func executeAddonAndPublish(
    addon: WorkflowNodeAddonRef,
    session: WorkflowSession,
    sessionId: String,
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    resolvedInputPayload: JSONObject,
    transitions: [WorkflowStepTransition],
    request: DeterministicWorkflowRunRequest,
    executionIndex: Int
  ) async throws -> WorkflowPublicationResult {
    let adapterOutput: AdapterExecutionOutput
    do {
      let attachments = try await projectedAddonAttachments(
        addon: addon,
        sessionId: sessionId,
        workflow: workflow,
        step: step,
        request: request
      )
      guard let addonResolver else {
        throw AdapterExecutionError(.providerError, "missing add-on resolver for '\(addon.name)'")
      }
      let predecessorExecutionIds = retryPredecessorExecutionIds(
        session: session,
        step: step
      )
      let startedExecution = try await recordStepStartedExecution(
        workflowId: workflow.workflowId,
        sessionId: sessionId,
        step: step,
        attempt: executionIndex,
        backend: nil,
        handler: request.eventHandler
      )
      let addonInput = WorkflowAddonExecutionInput(
        workflowId: workflow.workflowId,
        stepId: step.id,
        nodeId: step.nodeId,
        addon: addon,
        variables: request.variables,
        resolvedInputPayload: workflowAddonResolvedInputPayload(resolvedInputPayload, session: session),
        attachments: attachments,
        executionIdentity: WorkflowAddonExecutionIdentity(
          workflowExecutionId: sessionId,
          stepExecutionId: startedExecution.execution.executionId,
          attempt: executionIndex,
          predecessorStepExecutionId: predecessorExecutionIds.first,
          predecessorStepExecutionIds: predecessorExecutionIds
        )
      )
      adapterOutput = try await addonResolver.execute(
        addonInput,
        context: AdapterExecutionContext(deadline: deadline(for: step, request: request))
      )
    } catch let adapterFailure as AdapterExecutionError {
      if step.failurePolicy == .advisory {
        return try await publishAdvisoryFailure(
          adapterFailure,
          sessionId: sessionId,
          step: step,
          attempt: executionIndex,
          transitions: transitions
        )
      }
      try await publishFailureAndThrow(
        adapterFailure,
        sessionId: sessionId,
        step: step,
        attempt: executionIndex,
        transitions: transitions
      )
    } catch {
      if isWorkflowRunCancellation(error) {
        throw error
      }
      let adapterFailure = AdapterExecutionError(.providerError, String(describing: error))
      if step.failurePolicy == .advisory {
        return try await publishAdvisoryFailure(
          adapterFailure,
          sessionId: sessionId,
          step: step,
          attempt: executionIndex,
          transitions: transitions
        )
      }
      try await publishFailureAndThrow(
        adapterFailure,
        sessionId: sessionId,
        step: step,
        attempt: executionIndex,
        transitions: transitions,
        throwing: error
      )
    }
    let routingReconciler = workflowRoutingReconciler(
      workflow: workflow,
      step: step,
      disableDefaultLoopGuard: request.disableDefaultLoopGuard
    )
    return try await publisher.publishAcceptedOutput(
      WorkflowPublicationRequest(
        sessionId: sessionId,
        stepId: step.id,
        nodeId: step.nodeId,
        attempt: executionIndex,
        body: .adapterOutput(adapterOutput),
        routingReconciler: routingReconciler,
        transitions: transitions,
        publishesRootOutput: transitions.isEmpty,
        prePersistenceRoutingDecider: workflowPrePersistenceRoutingDecider(
          workflow: workflow,
          step: step,
          request: request
        ),
        carriedPayloadFields: carriedLoopGuardPayload(from: request)
      )
    )
  }

  private func retryPredecessorExecutionIds(
    session: WorkflowSession,
    step: WorkflowStepRef
  ) -> [String] {
    let matchingExecutions = session.executions.filter {
      $0.stepId == step.id && $0.nodeId == step.nodeId
    }
    guard let previousExecution = matchingExecutions.last,
          isUnacceptedRetryPredecessor(previousExecution) else {
      return []
    }
    return matchingExecutions.reversed().prefix {
      isUnacceptedRetryPredecessor($0)
    }.map(\.executionId)
  }

  private func isUnacceptedRetryPredecessor(_ execution: WorkflowStepExecution) -> Bool {
    (execution.status == .failed || execution.status == .running)
      && execution.acceptedOutput == nil
  }

  private func projectedAddonAttachments(
    addon: WorkflowNodeAddonRef,
    sessionId: String,
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    request: DeterministicWorkflowRunRequest
  ) async throws -> [String: WorkflowAddonAttachmentValue] {
    do {
      return try await attachmentProjector.project(
        WorkflowAddonAttachmentProjectionRequest(
          workflowId: workflow.workflowId,
          sessionId: sessionId,
          stepId: step.id,
          nodeId: step.nodeId,
          addon: addon,
          preprojectedAttachments: request.addonAttachments,
          descriptors: request.addonAttachmentDescriptors
        )
      )
    } catch let projectionError as WorkflowAddonAttachmentProjectionError {
      throw projectionError.adapterError
    } catch {
      if isWorkflowRunCancellation(error) {
        throw error
      }
      throw AdapterExecutionError(.policyBlocked, "native_attachment_projection_failed: \(String(describing: error))")
    }
  }

  func reconcileAcceptedFinalizations(in session: WorkflowSession) async {
    guard let acknowledger = addonResolver as? any WorkflowAddonFinalizationAcknowledging else {
      return
    }
    let tokens = Set<WorkflowAddonFinalizationToken>(session.executions.compactMap { execution in
      guard execution.status == .completed else {
        return nil
      }
      return execution.acceptedOutput?.runtimeFinalizationToken
    })
    for token in tokens {
      try? await acknowledger.acknowledgeAcceptedFinalization(token)
    }
  }

  func acknowledgeAcceptedFinalization(in execution: WorkflowStepExecution) async {
    guard execution.status == .completed,
          let token = execution.acceptedOutput?.runtimeFinalizationToken,
          let acknowledger = addonResolver as? any WorkflowAddonFinalizationAcknowledging else {
      return
    }
    try? await acknowledger.acknowledgeAcceptedFinalization(token)
  }

  func recordTerminalFinalization(in session: WorkflowSession) async {
    let isTerminal = session.status == .completed || (
      session.status == .failed && session.failureKind != .maxStepsExceeded
    )
    guard isTerminal,
          let recorder = addonResolver as? any WorkflowAddonTerminalRecording else {
      return
    }
    try? await recorder.recordTerminalFinalization(
      workflowExecutionId: session.sessionId,
      stepExecutionIds: session.executions.map(\.executionId)
    )
  }
}
