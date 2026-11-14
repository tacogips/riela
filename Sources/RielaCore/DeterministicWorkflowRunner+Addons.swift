import Foundation
import RielaObservability

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
      guard addonResolver != nil || (step.placement != nil && distributedExecutor != nil) else {
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
        inputSnapshot: [
          "variables": .object(request.variables),
          "resolvedInputPayload": .object(workflowAddonResolvedInputPayload(resolvedInputPayload, session: session))
        ],
        handler: request.eventHandler
      )
      let operationExecutionId: String
      do {
        operationExecutionId = try WorkflowAddonExecutionIdentity.deriveOperationExecutionId(
          stepExecutionId: startedExecution.execution.executionId,
          predecessorStepExecutionId: predecessorExecutionIds.first,
          predecessorStepExecutionIds: predecessorExecutionIds
        )
      } catch let error as WorkflowAddonOperationIdentityError {
        throw AdapterExecutionError(.invalidInput, error.diagnosticCode)
      }
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
          operationExecutionId: operationExecutionId,
          attempt: executionIndex,
          predecessorStepExecutionId: predecessorExecutionIds.first,
          predecessorStepExecutionIds: predecessorExecutionIds
        )
      )
      adapterOutput = try await executePlacedAddon(
        addonInput, step: step, executionId: "\(sessionId)/\(startedExecution.execution.executionId)",
        context: adapterExecutionContext(
          deadline: deadline(for: step, request: request), workflowId: workflow.workflowId,
          step: step, execution: startedExecution.execution,
          eventContext: startedExecution.backendEventContext, handler: request.eventHandler
        )
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
    try await checkpointNestedEffectCompletion(request)
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
        preCommitPublicationHook: nestedInvocationPreCommitPublicationHook(
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

  /// Event type reported when an accepted add-on finalization (acknowledgment
  /// or terminal record) could not complete, for example because a shared
  /// admission pool stayed busy past the finalization deadline. The runtime
  /// record is unchanged; the add-on keeps its pending state for a re-drive.
  static let addonFinalizationSkippedEventType = "riela.addon.finalization.skipped"

  func reconcileAcceptedFinalizations(in session: WorkflowSession, handler: WorkflowRunEventHandler? = nil) async {
    guard let acknowledger = addonResolver as? any WorkflowAddonFinalizationAcknowledging else {
      return
    }
    var seen = Set<WorkflowAddonFinalizationToken>()
    for execution in session.executions where execution.status == .completed {
      guard let token = execution.acceptedOutput?.runtimeFinalizationToken, seen.insert(token).inserted else {
        continue
      }
      do {
        try await acknowledger.acknowledgeAcceptedFinalization(token)
      } catch {
        await reportSkippedAddonFinalization(error, operation: "acknowledge", session: session,
          execution: execution, handler: handler)
      }
    }
  }

  func acknowledgeAcceptedFinalization(
    in execution: WorkflowStepExecution,
    session: WorkflowSession? = nil,
    handler: WorkflowRunEventHandler? = nil
  ) async {
    guard execution.status == .completed,
          let token = execution.acceptedOutput?.runtimeFinalizationToken,
          let acknowledger = addonResolver as? any WorkflowAddonFinalizationAcknowledging else {
      return
    }
    do {
      try await acknowledger.acknowledgeAcceptedFinalization(token)
    } catch {
      await reportSkippedAddonFinalization(error, operation: "acknowledge", session: session,
        execution: execution, handler: handler)
    }
  }

  func recordTerminalFinalization(in session: WorkflowSession, handler: WorkflowRunEventHandler? = nil) async {
    let isTerminal = session.status == .completed || (
      session.status == .failed && session.failureKind != .maxStepsExceeded
    )
    guard isTerminal,
          let recorder = addonResolver as? any WorkflowAddonTerminalRecording else {
      return
    }
    do {
      try await recorder.recordTerminalFinalization(
        workflowExecutionId: session.sessionId,
        stepExecutionIds: session.executions.map(\.executionId)
      )
    } catch {
      await reportSkippedAddonFinalization(error, operation: "terminal", session: session,
        execution: nil, handler: handler)
    }
  }

  /// Finalization stays best-effort (it never fails an accepted step or a
  /// finished session), but it must not fail silently: every skip is logged
  /// as a warning and, when a run event handler is known, streamed as a
  /// backend event. Only the finite error code and a bounded message leave.
  private func reportSkippedAddonFinalization(
    _ error: any Error,
    operation: String,
    session: WorkflowSession?,
    execution: WorkflowStepExecution?,
    handler: WorkflowRunEventHandler?
  ) async {
    let adapterError = error as? AdapterExecutionError
    let code = adapterError?.code.rawValue ?? (isWorkflowRunCancellation(error) ? "cancelled" : "error")
    let reason = String((adapterError?.message ?? "add-on finalization failed").prefix(512))
    // Keys follow the telemetry redactor allowlist (`session.id` is always
    // redacted there, like on every other runner log).
    var attributes = ["finalization.kind": operation, "error_code": code, "error_class": reason,
      "runtime.surface": "workflow"]
    attributes["workflow.id"] = session?.workflowId
    attributes["session.id"] = session?.sessionId
    attributes["node.step.id"] = execution?.stepId
    await telemetry.recordLog(RielaTelemetryLog(name: "riela.workflow.addon.finalization.skipped",
      severity: "WARNING", attributes: attributes))
    guard let session, let handler else { return }
    await handler(WorkflowRunEvent(
      type: .backendEvent,
      workflowId: session.workflowId,
      sessionId: session.sessionId,
      status: session.status,
      currentStepId: session.currentStepId,
      stepId: execution?.stepId,
      nodeId: execution?.nodeId,
      executionId: execution?.executionId,
      backendEventType: Self.addonFinalizationSkippedEventType,
      backendEventMetadata: ["operation": .string(operation), "errorCode": .string(code), "reason": .string(reason)]
    ))
  }
}
