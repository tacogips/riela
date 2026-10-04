import Foundation

extension DeterministicWorkflowRunner {
  func executeAndPublish(
    adapterInput: AdapterExecutionInput,
    sessionId: String,
    step: WorkflowStepRef,
    basePayload: AgentNodePayload,
    transitions: [WorkflowStepTransition],
    request: DeterministicWorkflowRunRequest,
    executionIndex: Int
  ) async throws -> WorkflowPublicationResult {
    let maxAttempts = maxValidationAttempts(from: basePayload.output)
    var lastValidationError: Error?
    for attempt in 1...maxAttempts {
      let startedExecution = try await recordStepStartedExecution(
        workflowId: request.workflow.workflowId,
        sessionId: sessionId,
        step: step,
        attempt: attempt,
        backend: basePayload.executionBackend,
        backendWorkingDirectory: resolvedBackendWorkingDirectory(
          backend: basePayload.executionBackend,
          configuredWorkingDirectory: basePayload.workingDirectory,
          workspaceRoot: fanoutWorkspaceRoot
        ),
        inputSnapshot: try historyInvocationSnapshot(adapterInput, request: request, step: step, payload: basePayload),
        effectiveStepBudget: request.effectiveStepBudget,
        handler: request.eventHandler
      )
      let execution = startedExecution.execution
      var attemptInput = adapterInput
      attemptInput.executionIndex = executionIndex
      attemptInput.output = basePayload.output == nil
        ? nil
        : AdapterOutputAttemptContext(maxValidationAttempts: maxAttempts, attempt: attempt)
      let adapterOutput: AdapterExecutionOutput
      do {
        let context = adapterExecutionContext(
          deadline: deadline(for: step, request: request),
          workflowId: request.workflow.workflowId,
          step: step,
          execution: execution,
          eventContext: startedExecution.backendEventContext,
          handler: request.eventHandler
        )
        let silenceMonitor = startAgentSilenceMonitorIfNeeded(
          request: request,
          workflowId: request.workflow.workflowId,
          step: step,
          execution: execution,
          eventContext: startedExecution.backendEventContext
        )
        defer {
          silenceMonitor?.cancel()
        }
        adapterOutput = try await executePlacedAdapter(attemptInput, step: step, executionId: "\(sessionId)/\(execution.executionId)", context: context)
      } catch let validationError as WorkflowPublicationError {
        guard case let .validationRejected(reason) = validationError else { throw validationError }
        try await recordAdapterValidationRejection(
          execution,
          sessionId: sessionId,
          reason: reason,
          failsSession: attempt >= maxAttempts
        )
        guard attempt < maxAttempts else { throw validationError }
        lastValidationError = validationError
        continue
      } catch let adapterFailure as AdapterExecutionError {
        return try await publishAdapterFailure(
          adapterFailure,
          sessionId: sessionId,
          step: step,
          attempt: attempt,
          backend: basePayload.executionBackend,
          transitions: transitions
        )
      } catch {
        if isWorkflowRunCancellation(error) {
          throw error
        }
        let adapterFailure = AdapterExecutionError(.providerError, String(describing: error))
        return try await publishAdapterFailure(
          adapterFailure,
          sessionId: sessionId,
          step: step,
          attempt: attempt,
          backend: basePayload.executionBackend,
          transitions: transitions,
          throwing: error
        )
      }
      try await checkpointNestedEffectCompletion(request)
      let routingReconciler = workflowRoutingReconciler(
        workflow: request.workflow,
        step: step,
        disableDefaultLoopGuard: request.disableDefaultLoopGuard
      )
      do {
        return try await publisher.publishAcceptedOutput(
          WorkflowPublicationRequest(
            sessionId: sessionId,
            stepId: step.id,
            nodeId: step.nodeId,
            attempt: attempt,
            backend: basePayload.executionBackend,
            body: .adapterOutput(adapterOutput),
            outputContract: workflowOutputContract(from: basePayload.output),
            routingReconciler: routingReconciler,
            transitions: transitions,
            publishesRootOutput: transitions.isEmpty,
            prePersistenceRoutingDecider: workflowPrePersistenceRoutingDecider(
              workflow: request.workflow,
              step: step,
              request: request
            ),
            preCommitPublicationHook: nestedInvocationPreCommitPublicationHook(
              workflow: request.workflow,
              step: step,
              request: request
            ),
            carriedPayloadFields: carriedLoopGuardPayload(from: request),
            retriesValidationRejection: attempt < maxAttempts
          )
        )
      } catch let error as WorkflowPublicationError {
        guard case .validationRejected = error, attempt < maxAttempts else {
          throw error
        }
        lastValidationError = error
      }
    }
    throw lastValidationError ?? WorkflowPublicationError.validationRejected("output validation rejected candidate")
  }

}
