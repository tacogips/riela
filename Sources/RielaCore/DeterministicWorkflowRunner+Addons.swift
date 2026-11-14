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
    let attachments = try await projectedAddonAttachments(
      addon: addon,
      sessionId: sessionId,
      workflow: workflow,
      step: step,
      transitions: transitions,
      request: request,
      executionIndex: executionIndex
    )
    let addonInput = WorkflowAddonExecutionInput(
      workflowId: workflow.workflowId,
      stepId: step.id,
      nodeId: step.nodeId,
      addon: addon,
      variables: request.variables,
      resolvedInputPayload: workflowAddonResolvedInputPayload(resolvedInputPayload, session: session),
      attachments: attachments
    )
    guard let addonResolver else {
      let adapterFailure = AdapterExecutionError(.providerError, "missing add-on resolver for '\(addon.name)'")
      try await publishFailureAndThrow(
        adapterFailure,
        sessionId: sessionId,
        step: step,
        attempt: executionIndex,
        transitions: transitions
      )
    }

    let adapterOutput = try await executeAddon(
      addonResolver,
      input: addonInput,
      sessionId: sessionId,
      workflow: workflow,
      step: step,
      transitions: transitions,
      request: request,
      executionIndex: executionIndex
    )

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

  private func projectedAddonAttachments(
    addon: WorkflowNodeAddonRef,
    sessionId: String,
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    transitions: [WorkflowStepTransition],
    request: DeterministicWorkflowRunRequest,
    executionIndex: Int
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
      try await publishFailureAndThrow(
        projectionError.adapterError,
        sessionId: sessionId,
        step: step,
        attempt: executionIndex,
        transitions: transitions
      )
    } catch {
      if isWorkflowRunCancellation(error) {
        throw error
      }
      let adapterFailure = AdapterExecutionError(.policyBlocked, "native_attachment_projection_failed: \(String(describing: error))")
      try await publishFailureAndThrow(
        adapterFailure,
        sessionId: sessionId,
        step: step,
        attempt: executionIndex,
        transitions: transitions
      )
    }
  }

  private func executeAddon(
    _ addonResolver: any WorkflowAddonResolving,
    input addonInput: WorkflowAddonExecutionInput,
    sessionId: String,
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    transitions: [WorkflowStepTransition],
    request: DeterministicWorkflowRunRequest,
    executionIndex: Int
  ) async throws -> AdapterExecutionOutput {
    do {
      _ = try await recordStepStartedExecution(
        workflowId: workflow.workflowId,
        sessionId: sessionId,
        step: step,
        attempt: executionIndex,
        backend: nil,
        handler: request.eventHandler
      )
      return try await addonResolver.execute(
        addonInput,
        context: AdapterExecutionContext(deadline: deadline(for: step, request: request))
      )
    } catch let adapterFailure as AdapterExecutionError {
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
      try await publishFailureAndThrow(
        adapterFailure,
        sessionId: sessionId,
        step: step,
        attempt: executionIndex,
        transitions: transitions,
        throwing: error
      )
    }
  }
}
