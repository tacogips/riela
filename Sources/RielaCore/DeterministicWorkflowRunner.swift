import Foundation
import RielaObservability

public struct DeterministicWorkflowRunRequest: Sendable {
  public var workflow: WorkflowDefinition
  public var nodePayloads: [String: AgentNodePayload]
  public var variables: JSONObject
  public var maxSteps: Int?
  public var maxConcurrency: Int?
  public var maxLoopIterations: Int?
  public var defaultTimeoutMs: Int?
  public var timeoutMs: Int?
  public var addonAttachments: [String: WorkflowAddonAttachmentValue]
  public var addonAttachmentDescriptors: [String: WorkflowAddonAttachmentDescriptor]
  public var rerunFromSessionId: String?
  public var rerunFromStepId: String?
  public var resumeSessionId: String?
  public var memoryRootDirectory: String?
  public var eventHandler: WorkflowRunEventHandler?

  public init(
    workflow: WorkflowDefinition,
    nodePayloads: [String: AgentNodePayload] = [:],
    variables: JSONObject = [:],
    maxSteps: Int? = nil,
    maxConcurrency: Int? = nil,
    maxLoopIterations: Int? = nil,
    defaultTimeoutMs: Int? = nil,
    timeoutMs: Int? = nil,
    addonAttachments: [String: WorkflowAddonAttachmentValue] = [:],
    addonAttachmentDescriptors: [String: WorkflowAddonAttachmentDescriptor] = [:],
    rerunFromSessionId: String? = nil,
    rerunFromStepId: String? = nil,
    resumeSessionId: String? = nil,
    memoryRootDirectory: String? = nil,
    eventHandler: WorkflowRunEventHandler? = nil
  ) {
    self.workflow = workflow
    self.nodePayloads = nodePayloads
    self.variables = variables
    self.maxSteps = maxSteps
    self.maxConcurrency = maxConcurrency
    self.maxLoopIterations = maxLoopIterations
    self.defaultTimeoutMs = defaultTimeoutMs
    self.timeoutMs = timeoutMs
    self.addonAttachments = addonAttachments
    self.addonAttachmentDescriptors = addonAttachmentDescriptors
    self.rerunFromSessionId = rerunFromSessionId
    self.rerunFromStepId = rerunFromStepId
    self.resumeSessionId = resumeSessionId
    self.memoryRootDirectory = memoryRootDirectory
    self.eventHandler = eventHandler
  }
}

public struct WorkflowRunResult: Codable, Equatable, Sendable {
  public var workflowId: String
  public var session: WorkflowSession
  public var rootOutput: JSONObject?
  public var exitCode: Int32
  public var status: WorkflowSessionStatus
  public var nodeExecutions: Int
  public var transitions: Int
  public var supervision: JSONObject?
  public var loopEvidence: LoopEvidenceSummary?
  public var recovery: LoopRecoveryLineage?

  public init(
    workflowId: String,
    session: WorkflowSession,
    rootOutput: JSONObject?,
    exitCode: Int32,
    transitions: Int,
    supervision: JSONObject? = nil,
    loopEvidence: LoopEvidenceSummary? = nil,
    recovery: LoopRecoveryLineage? = nil
  ) {
    self.workflowId = workflowId
    self.session = session
    self.rootOutput = rootOutput
    self.exitCode = exitCode
    self.status = session.status
    self.nodeExecutions = session.executions.count
    self.transitions = transitions
    self.supervision = supervision
    self.loopEvidence = loopEvidence
    self.recovery = recovery
  }
}

public protocol DeterministicWorkflowRunning: Sendable {
  func run(_ request: DeterministicWorkflowRunRequest) async throws -> WorkflowRunResult
}

public struct DeterministicWorkflowRunner: DeterministicWorkflowRunning {
  public var store: any WorkflowRuntimeStore
  public var adapter: any NodeAdapter
  public var addonResolver: (any WorkflowAddonResolving)?
  public var attachmentProjector: any WorkflowAddonAttachmentProjecting
  public var stdioNodeExecutor: (any WorkflowStdioNodeExecuting)?
  public var publisher: any WorkflowOutputPublishing
  public var inputResolver: any WorkflowMessageInputResolving
  public var inputFilterEvaluator: WorkflowInputFilterEvaluator
  public var inputFilterLogger: any WorkflowInputFilterLogging
  public var loopPolicyEvaluator: any LoopPolicyEvaluating
  public var telemetry: any RielaTelemetry

  public init(
    store: (any WorkflowRuntimeStore)? = nil,
    adapter: any NodeAdapter = DeterministicLocalNodeAdapter(),
    addonResolver: (any WorkflowAddonResolving)? = nil,
    attachmentProjector: any WorkflowAddonAttachmentProjecting = InlineWorkflowAddonAttachmentProjector(),
    stdioNodeExecutor: (any WorkflowStdioNodeExecuting)? = nil,
    publisher: (any WorkflowOutputPublishing)? = nil,
    inputResolver: any WorkflowMessageInputResolving = DefaultWorkflowMessageInputResolver(),
    inputFilterEvaluator: WorkflowInputFilterEvaluator = WorkflowInputFilterEvaluator(),
    inputFilterLogger: any WorkflowInputFilterLogging = StandardErrorWorkflowInputFilterLogger(),
    loopPolicyEvaluator: any LoopPolicyEvaluating = DefaultLoopPolicyEvaluator(),
    telemetry: any RielaTelemetry = NoOpRielaTelemetry()
  ) {
    let resolvedStore = store ?? InMemoryWorkflowRuntimeStore()
    self.store = resolvedStore
    self.adapter = adapter
    self.addonResolver = addonResolver
    self.attachmentProjector = attachmentProjector
    self.stdioNodeExecutor = stdioNodeExecutor
    self.publisher = publisher ?? InMemoryWorkflowOutputPublisher(store: resolvedStore)
    self.inputResolver = inputResolver
    self.inputFilterEvaluator = inputFilterEvaluator
    self.inputFilterLogger = inputFilterLogger
    self.loopPolicyEvaluator = loopPolicyEvaluator
    self.telemetry = telemetry
  }

  public func run(_ request: DeterministicWorkflowRunRequest) async throws -> WorkflowRunResult {
    var interruptedSessionId: String?
    do {
    let diagnostics = DefaultWorkflowValidator().validate(request.workflow)
    if let diagnostic = diagnostics.first(where: { $0.severity == .error }) {
      throw DeterministicWorkflowRunnerError.invalidWorkflow("\(diagnostic.path): \(diagnostic.message)")
    }
    let capabilityGaps = Self.unsupportedFeatures(in: request.workflow, maxConcurrency: request.maxConcurrency)
    if let gap = capabilityGaps.first {
      throw DeterministicWorkflowRunnerError.invalidWorkflow("\(gap.path): \(gap.message)")
    }
    try enforceRequiredLoopPolicyPreflight(request)
    let executionPlan = WorkflowExecutionPlan(workflow: request.workflow)

    do {
      try WorkflowSessionEntryValidation.validateMutuallyExclusiveSessionEntryModes(
        resumeSessionId: request.resumeSessionId,
        rerunFromSessionId: request.rerunFromSessionId,
        continueFromWorkflowExecutionId: nil
      )
    } catch let error as WorkflowSessionEntryValidationError {
      throw DeterministicWorkflowRunnerError.resumeValidation(errorMessage(error))
    }
    var effectiveRequest = request

    let entryStepId: String
    var session: WorkflowSession
    var currentStepId: String?
    let recoveryLineage: LoopRecoveryLineage
    if let resumeSessionId = request.resumeSessionId {
      guard let existing = try await store.loadSession(id: resumeSessionId) else {
        throw DeterministicWorkflowRunnerError.resumeValidation("resume session not found: \(resumeSessionId)")
      }
      guard existing.workflowId == request.workflow.workflowId else {
        throw DeterministicWorkflowRunnerError.resumeValidation("session workflow does not match command workflow")
      }
      let resumeLineage = resumeRecoveryLineage(sourceSessionId: resumeSessionId)
      if existing.status == .completed || existing.status == .failed {
        let terminalResult = WorkflowRunResult(
          workflowId: request.workflow.workflowId,
          session: existing,
          rootOutput: terminalRootOutput(from: existing),
          exitCode: existing.status == .completed ? 0 : 1,
          transitions: 0,
          recovery: resumeLineage
        )
        await emitSessionCompletedEvent(result: terminalResult, handler: request.eventHandler)
        return terminalResult
      }
      session = existing
      currentStepId = existing.currentStepId ?? existing.entryStepId
      entryStepId = existing.entryStepId
      recoveryLineage = resumeLineage
    } else if let rerunFromSessionId = request.rerunFromSessionId {
      guard let sourceSession = try await store.loadSession(id: rerunFromSessionId) else {
        throw DeterministicWorkflowRunnerError.rerunValidation("source session not found: \(rerunFromSessionId)")
      }
      guard sourceSession.workflowId == request.workflow.workflowId else {
        throw DeterministicWorkflowRunnerError.rerunValidation("source session workflow does not match command workflow")
      }
      do {
        entryStepId = try WorkflowSessionEntryValidation.validateRerunTarget(
          workflow: request.workflow,
          sourceSession: sourceSession,
          rerunStepId: request.rerunFromStepId
        )
      } catch let error as WorkflowSessionEntryValidationError {
        throw DeterministicWorkflowRunnerError.rerunValidation(errorMessage(error))
      }
      session = try await store.createSession(
        WorkflowSessionCreateInput(workflowId: request.workflow.workflowId, entryStepId: entryStepId)
      )
      for (key, value) in WorkflowReviewFindingReplayContext.variables(
        from: sourceSession.reviewFindings,
        targetStepId: entryStepId
      ) {
        effectiveRequest.variables[key] = value
      }
      currentStepId = entryStepId
      recoveryLineage = rerunRecoveryLineage(
        sourceSession: sourceSession,
        sourceStepId: entryStepId,
        childSessionId: session.sessionId
      )
    } else {
      entryStepId = request.workflow.entryStepId
      session = try await store.createSession(
        WorkflowSessionCreateInput(workflowId: request.workflow.workflowId, entryStepId: entryStepId)
      )
      currentStepId = entryStepId
      recoveryLineage = runRecoveryLineage()
    }

    interruptedSessionId = session.sessionId
    await emitSessionStartedEvent(workflowId: effectiveRequest.workflow.workflowId, session: session, handler: effectiveRequest.eventHandler)

    var visitedSteps = 0
    var publishedTransitions = 0
    var rootOutput: JSONObject?
    var executionCounts: [String: Int] = [:]
    let maxLoopIterations = effectiveRequest.maxLoopIterations ?? effectiveRequest.workflow.defaults.maxLoopIterations
    let maxSteps = effectiveRequest.maxSteps ?? max(1, effectiveRequest.workflow.steps.count + maxLoopIterations)

    while let stepId = currentStepId {
      visitedSteps += 1
      if visitedSteps > maxSteps {
        throw DeterministicWorkflowRunnerError.maxStepsExceeded(maxSteps)
      }
      guard let step = executionPlan.step(id: stepId) else {
        throw DeterministicWorkflowRunnerError.missingStep(stepId)
      }
      guard let registryNode = executionPlan.registryNode(id: step.nodeId) else {
        throw DeterministicWorkflowRunnerError.missingNode(step.nodeId)
      }
      let executionIndex = (executionCounts[step.id] ?? 0) + 1
      executionCounts[step.id] = executionIndex
      let resolvedInput = try await inputResolver.resolveInput(for: session.sessionId, stepId: step.id, store: store)
      let transitions = step.transitions ?? []
      if let publishResult = try await skipFilteredStepIfNeeded(
        registryNode: registryNode, requestVariables: effectiveRequest.variables, resolvedInputPayload: resolvedInput.payload,
        sessionId: session.sessionId, step: step, transitions: transitions, executionIndex: executionIndex
      ) {
        session = publishResult.session
        publishedTransitions += publishResult.publishedMessages.count
        await emitStepCompletedEvent(
          workflowId: effectiveRequest.workflow.workflowId,
          session: session,
          step: step,
          publishResult: publishResult,
          publishedTransitions: publishedTransitions,
          handler: effectiveRequest.eventHandler
        )
        currentStepId = publishResult.nextStepId
        continue
      }
      let publishResult = try await executeNodeAndRecordMemory(
        registryNode: registryNode,
        request: effectiveRequest,
        session: session,
        step: step,
        resolvedInput: resolvedInput,
        transitions: transitions,
        executionIndex: executionIndex
      )
      session = publishResult.session
      publishedTransitions += publishResult.publishedMessages.count
      rootOutput = publishResult.rootOutput ?? rootOutput
      await emitStepCompletedEvent(
        workflowId: effectiveRequest.workflow.workflowId,
        session: session,
        step: step,
        publishResult: publishResult,
        publishedTransitions: publishedTransitions,
        handler: effectiveRequest.eventHandler
      )
      currentStepId = publishResult.nextStepId
    }

    guard let loadedSession = try await store.loadSession(id: session.sessionId) else {
      throw WorkflowRuntimeStoreError.sessionNotFound(session.sessionId)
    }
    let completedResult = WorkflowRunResult(
      workflowId: effectiveRequest.workflow.workflowId,
      session: loadedSession,
      rootOutput: rootOutput,
      exitCode: loadedSession.status == .completed ? 0 : 1,
      transitions: publishedTransitions,
      recovery: recoveryLineage
    )
    await emitSessionCompletedEvent(result: completedResult, handler: effectiveRequest.eventHandler)
    return completedResult
    } catch {
      if isWorkflowRunCancellation(error), let interruptedSessionId {
        await markInterruptedSessionFailed(sessionId: interruptedSessionId, request: request)
      }
      throw error
    }
  }

  private func executeNodeAndRecordMemory(
    registryNode: WorkflowNodeRegistryRef,
    request: DeterministicWorkflowRunRequest,
    session: WorkflowSession,
    step: WorkflowStepRef,
    resolvedInput: WorkflowResolvedMessageInput,
    transitions: [WorkflowStepTransition],
    executionIndex: Int
  ) async throws -> WorkflowPublicationResult {
    let publishResult: WorkflowPublicationResult
    let basePayload = request.nodePayloads[step.nodeId]
    let recordsAutomaticMemory = shouldRecordAutomaticMemory(for: registryNode)
    try registerMemoryMetadata(
      workflow: request.workflow,
      step: step,
      payload: basePayload,
      request: request
    )
    do {
      if let basePayload {
        publishResult = try await executePayloadNodeAndRecordMemory(
          basePayload: basePayload,
          request: request,
          session: session,
          step: step,
          resolvedInput: resolvedInput,
          transitions: transitions,
          executionIndex: executionIndex
        )
      } else if let addon = registryNode.addon {
        if recordsAutomaticMemory {
          try recordNodeMemoryInbox(
            workflow: request.workflow,
            step: step,
            payload: nil,
            request: request,
            session: session,
            executionIndex: executionIndex,
            resolvedInput: resolvedInput
          )
        }
        publishResult = try await executeAddonAndPublish(
          addon: addon,
          session: session,
          sessionId: session.sessionId,
          workflow: request.workflow,
          step: step,
          resolvedInputPayload: resolvedInput.payload,
          transitions: transitions,
          request: request,
          executionIndex: executionIndex
        )
      } else {
        throw DeterministicWorkflowRunnerError.missingNodePayload(step.nodeId)
      }
    } catch {
      if recordsAutomaticMemory {
        try recordNodeMemoryFailureOutbox(
          workflow: request.workflow,
          step: step,
          payload: basePayload,
          request: request,
          sessionId: session.sessionId,
          executionIndex: executionIndex,
          error: error
        )
      }
      throw error
    }
    if recordsAutomaticMemory {
      try recordNodeMemoryOutbox(
        workflow: request.workflow,
        step: step,
        payload: basePayload,
        request: request,
        publishResult: publishResult,
        executionIndex: executionIndex
      )
    }
    return publishResult
  }

  private func executePayloadNodeAndRecordMemory(
    basePayload: AgentNodePayload,
    request: DeterministicWorkflowRunRequest,
    session: WorkflowSession,
    step: WorkflowStepRef,
    resolvedInput: WorkflowResolvedMessageInput,
    transitions: [WorkflowStepTransition],
    executionIndex: Int
  ) async throws -> WorkflowPublicationResult {
    try recordNodeMemoryInbox(
      workflow: request.workflow,
      step: step,
      payload: basePayload,
      request: request,
      session: session,
      executionIndex: executionIndex,
      resolvedInput: resolvedInput
    )
    if let stdioNodeKind = workflowStdioNodeExecutionKind(for: basePayload) {
      var executionPayload = basePayload
      executionPayload.id = step.id
      return try await executeStdioNodeAndPublish(
        kind: stdioNodeKind,
        payload: executionPayload,
        sessionId: session.sessionId,
        workflow: request.workflow,
        step: step,
        resolvedInputPayload: resolvedInput.payload,
        transitions: transitions,
        request: request,
        executionIndex: executionIndex
      )
    }
    var executionPayload = try payload(basePayload, applyingPromptVariantFrom: step)
    executionPayload.id = step.id
    let mergedVariables = promptVariables(
      workflow: request.workflow,
      step: step,
      payload: executionPayload,
      requestVariables: request.variables,
      resolvedInputPayload: resolvedInput.payload
    )
    let prompts = composedPrompts(
      workflow: request.workflow,
      step: step,
      payload: executionPayload,
      variables: mergedVariables
    )
    let agentEnvironment: [String: String]
    do {
      agentEnvironment = try resolveAgentEnvironment(
        executionPayload.agentEnvironment,
        variables: mergedVariables
      )
    } catch let error as AgentEnvironmentResolutionError {
      throw AdapterExecutionError(.policyBlocked, error.localizedDescription)
    }
    let adapterInput = AdapterExecutionInput(
      node: executionPayload,
      promptText: prompts.promptText,
      systemPromptText: prompts.systemPromptText,
      sessionPolicy: step.sessionPolicy ?? executionPayload.sessionPolicy,
      arguments: request.variables,
      mergedVariables: mergedVariables,
      agentEnvironment: agentEnvironment
    )
    return try await executeAndPublish(
      adapterInput: adapterInput,
      sessionId: session.sessionId,
      step: step,
      basePayload: basePayload,
      transitions: transitions,
      request: request,
      executionIndex: executionIndex
    )
  }

  private func executeStdioNodeAndPublish(
    kind: WorkflowStdioNodeExecutionKind,
    payload: AgentNodePayload,
    sessionId: String,
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    resolvedInputPayload: JSONObject,
    transitions: [WorkflowStepTransition],
    request: DeterministicWorkflowRunRequest,
    executionIndex: Int
  ) async throws -> WorkflowPublicationResult {
    guard let stdioNodeExecutor else {
      let adapterFailure = AdapterExecutionError(.providerError, "missing stdio-node executor for '\(kind.rawValue)' node '\(step.nodeId)'")
      try await publishFailureAndThrow(
        adapterFailure,
        sessionId: sessionId,
        step: step,
        attempt: executionIndex,
        transitions: transitions
      )
    }

    do {
      let startedExecution = try await recordStepStartedExecution(
        workflowId: workflow.workflowId,
        sessionId: sessionId,
        step: step,
        attempt: executionIndex,
        backend: payload.executionBackend,
        handler: request.eventHandler
      )
      let execution = startedExecution.execution
      let availableMemories = effectiveNodeMemories(workflow: workflow, step: step, payload: payload)
      let result = try await stdioNodeExecutor.execute(
        WorkflowStdioNodeExecutionInput(
          workflowId: workflow.workflowId,
          sessionId: sessionId,
          stepId: step.id,
          nodeId: step.nodeId,
          executionIndex: executionIndex,
          kind: kind,
          node: payload,
          variables: request.variables,
          resolvedInputPayload: resolvedInputPayload,
          memoryRootDirectory: availableMemories.isEmpty ? nil : resolvedMemoryRootDirectory(request: request),
          availableMemories: availableMemories,
          policy: stdioPolicyContext(workflow: workflow, step: step, payload: payload, request: request)
        ),
        context: adapterExecutionContext(
          deadline: deadline(for: step, request: request),
          workflowId: workflow.workflowId,
          step: step,
          execution: execution,
          eventContext: startedExecution.backendEventContext,
          handler: request.eventHandler
        )
      )
      let routingReconciler = workflowRoutingReconciler(workflow: workflow, step: step)
      if let payload = result.payload {
        let candidate = try normalizeRuntimeInlineCandidate(payload, routingReconciler: routingReconciler)
        if let adapterFailure = multiplePublishableTransitionFailure(transitions: transitions, candidate: candidate) {
          try await publishFailureAndThrow(
            adapterFailure,
            sessionId: sessionId,
            step: step,
            attempt: executionIndex,
            transitions: transitions
          )
        }
      }
      return try await publisher.publishAcceptedOutput(
        WorkflowPublicationRequest(
          sessionId: sessionId,
          stepId: step.id,
          nodeId: step.nodeId,
          attempt: executionIndex,
          body: result.payload.map(WorkflowPublicationBody.inlineCandidate) ?? .none,
          outputContract: workflowOutputContract(from: payload.output),
          routingReconciler: routingReconciler,
          transitions: transitions,
          publishesRootOutput: transitions.isEmpty,
          allowsNoOutput: result.payload == nil
        )
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

  private func executeAndPublish(
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
        adapterOutput = try await adapter.execute(
          attemptInput,
          context: adapterExecutionContext(
            deadline: deadline(for: step, request: request),
            workflowId: request.workflow.workflowId,
            step: step,
            execution: execution,
            eventContext: startedExecution.backendEventContext,
            handler: request.eventHandler
          )
        )
      } catch let adapterFailure as AdapterExecutionError {
        try await publishFailureAndThrow(
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
        try await publishFailureAndThrow(
          adapterFailure,
          sessionId: sessionId,
          step: step,
          attempt: attempt,
          backend: basePayload.executionBackend,
          transitions: transitions,
          throwing: error
        )
      }
      let candidate: RuntimeOutputCandidate
      let routingReconciler = workflowRoutingReconciler(workflow: request.workflow, step: step)
      do {
        candidate = try normalizeRuntimeAdapterOutput(adapterOutput, routingReconciler: routingReconciler)
      } catch let adapterFailure as AdapterExecutionError {
        try await publishFailureAndThrow(
          adapterFailure,
          sessionId: sessionId,
          step: step,
          attempt: attempt,
          backend: basePayload.executionBackend,
          transitions: transitions
        )
      }
      if let adapterFailure = multiplePublishableTransitionFailure(transitions: transitions, candidate: candidate) {
        try await publishFailureAndThrow(
          adapterFailure,
          sessionId: sessionId,
          step: step,
          attempt: attempt,
          backend: basePayload.executionBackend,
          transitions: transitions
        )
      }
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
            publishesRootOutput: transitions.isEmpty
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

  private func executeAddonAndPublish(
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
    let attachments: [String: WorkflowAddonAttachmentValue]
    do {
      attachments = try await attachmentProjector.project(
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
      let adapterFailure = projectionError.adapterError
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
      let adapterFailure = AdapterExecutionError(.policyBlocked, "native_attachment_projection_failed: \(String(describing: error))")
      try await publishFailureAndThrow(
        adapterFailure,
        sessionId: sessionId,
        step: step,
        attempt: executionIndex,
        transitions: transitions
      )
    }

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

    let adapterOutput: AdapterExecutionOutput
    do {
      _ = try await recordStepStartedExecution(
        workflowId: workflow.workflowId,
        sessionId: sessionId,
        step: step,
        attempt: executionIndex,
        backend: nil,
        handler: request.eventHandler
      )
      adapterOutput = try await addonResolver.execute(
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

    let routingReconciler = workflowRoutingReconciler(workflow: workflow, step: step)
    let candidate = try normalizeRuntimeAdapterOutput(adapterOutput, routingReconciler: routingReconciler)
    if let adapterFailure = multiplePublishableTransitionFailure(transitions: transitions, candidate: candidate) {
      try await publishFailureAndThrow(
        adapterFailure,
        sessionId: sessionId,
        step: step,
        attempt: executionIndex,
        adapterOutput: adapterOutput,
        transitions: transitions
      )
    }
    return try await publisher.publishAcceptedOutput(
      WorkflowPublicationRequest(
        sessionId: sessionId,
        stepId: step.id,
        nodeId: step.nodeId,
        attempt: executionIndex,
        body: .adapterOutput(adapterOutput),
        routingReconciler: routingReconciler,
        transitions: transitions,
        publishesRootOutput: transitions.isEmpty
      )
    )
  }

}
