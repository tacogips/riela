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

public enum WorkflowRunEventType: String, Codable, Equatable, Sendable {
  case sessionStarted = "session_started"
  case stepStarted = "step_started"
  case backendEvent = "backend_event"
  case stepCompleted = "step_completed"
  case sessionCompleted = "session_completed"
}

public struct WorkflowRunEvent: Codable, Equatable, Sendable {
  public var type: WorkflowRunEventType
  public var workflowId: String
  public var sessionId: String
  public var status: WorkflowSessionStatus?
  public var currentStepId: String?
  public var stepId: String?
  public var nodeId: String?
  public var executionId: String?
  public var backendEventType: String?
  public var backendEventChannel: String?
  public var backendEventContent: String?
  public var backendEventIsDelta: Bool?
  public var backendEventSequence: Int?
  public var backendToolName: String?
  public var backendEventUsage: JSONObject?
  public var exitCode: Int32?
  public var nodeExecutions: Int?
  public var transitions: Int?

  public init(
    type: WorkflowRunEventType,
    workflowId: String,
    sessionId: String,
    status: WorkflowSessionStatus? = nil,
    currentStepId: String? = nil,
    stepId: String? = nil,
    nodeId: String? = nil,
    executionId: String? = nil,
    backendEventType: String? = nil,
    backendEventChannel: String? = nil,
    backendEventContent: String? = nil,
    backendEventIsDelta: Bool? = nil,
    backendEventSequence: Int? = nil,
    backendToolName: String? = nil,
    backendEventUsage: JSONObject? = nil,
    exitCode: Int32? = nil,
    nodeExecutions: Int? = nil,
    transitions: Int? = nil
  ) {
    self.type = type
    self.workflowId = workflowId
    self.sessionId = sessionId
    self.status = status
    self.currentStepId = currentStepId
    self.stepId = stepId
    self.nodeId = nodeId
    self.executionId = executionId
    self.backendEventType = backendEventType
    self.backendEventChannel = backendEventChannel
    self.backendEventContent = backendEventContent
    self.backendEventIsDelta = backendEventIsDelta
    self.backendEventSequence = backendEventSequence
    self.backendToolName = backendToolName
    self.backendEventUsage = backendEventUsage
    self.exitCode = exitCode
    self.nodeExecutions = nodeExecutions
    self.transitions = transitions
  }
}

public typealias WorkflowRunEventHandler = @Sendable (WorkflowRunEvent) async -> Void

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
    try enforceRequiredLoopPolicyPreflight(request)

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
      guard let step = effectiveRequest.workflow.steps.first(where: { $0.id == stepId }) else {
        throw DeterministicWorkflowRunnerError.missingStep(stepId)
      }
      guard let registryNode = effectiveRequest.workflow.nodeRegistry.first(where: { $0.id == step.nodeId }) else {
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
        currentStepId = publishResult.publishedMessages.first?.toStepId
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
      currentStepId = publishResult.publishedMessages.first?.toStepId
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
      _ = try? await publisher.publishAcceptedOutput(
        WorkflowPublicationRequest(
          sessionId: sessionId,
          stepId: step.id,
          nodeId: step.nodeId,
          attempt: executionIndex,
          adapterFailure: adapterFailure,
          transitions: transitions,
          publishesRootOutput: transitions.isEmpty
        )
      )
      throw adapterFailure
    }

    do {
      let execution = try await recordStepStartedExecution(
        workflowId: workflow.workflowId,
        sessionId: sessionId,
        step: step,
        attempt: executionIndex,
        backend: payload.executionBackend,
        handler: request.eventHandler
      )
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
          sessionId: sessionId,
          step: step,
          execution: execution,
          handler: request.eventHandler
        )
      )
      if let payload = result.payload {
        let candidate = try normalizeRuntimeInlineCandidate(payload)
        if let adapterFailure = multiplePublishableTransitionFailure(transitions: transitions, candidate: candidate) {
          _ = try? await publisher.publishAcceptedOutput(
            WorkflowPublicationRequest(
              sessionId: sessionId,
              stepId: step.id,
              nodeId: step.nodeId,
              attempt: executionIndex,
              adapterFailure: adapterFailure,
              transitions: transitions,
              publishesRootOutput: transitions.isEmpty
            )
          )
          throw adapterFailure
        }
      }
      return try await publisher.publishAcceptedOutput(
        WorkflowPublicationRequest(
          sessionId: sessionId,
          stepId: step.id,
          nodeId: step.nodeId,
          attempt: executionIndex,
          inlineCandidate: result.payload,
          outputContract: workflowOutputContract(from: payload.output),
          transitions: transitions,
          publishesRootOutput: transitions.isEmpty,
          allowsNoOutput: result.payload == nil
        )
      )
    } catch let adapterFailure as AdapterExecutionError {
      _ = try? await publisher.publishAcceptedOutput(
        WorkflowPublicationRequest(
          sessionId: sessionId,
          stepId: step.id,
          nodeId: step.nodeId,
          attempt: executionIndex,
          adapterFailure: adapterFailure,
          transitions: transitions,
          publishesRootOutput: transitions.isEmpty
        )
      )
      throw adapterFailure
    } catch {
      if isWorkflowRunCancellation(error) {
        throw error
      }
      let adapterFailure = AdapterExecutionError(.providerError, String(describing: error))
      _ = try? await publisher.publishAcceptedOutput(
        WorkflowPublicationRequest(
          sessionId: sessionId,
          stepId: step.id,
          nodeId: step.nodeId,
          attempt: executionIndex,
          adapterFailure: adapterFailure,
          transitions: transitions,
          publishesRootOutput: transitions.isEmpty
        )
      )
      throw error
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
      let execution = try await recordStepStartedExecution(
        workflowId: request.workflow.workflowId,
        sessionId: sessionId,
        step: step,
        attempt: attempt,
        backend: basePayload.executionBackend,
        handler: request.eventHandler
      )
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
            sessionId: sessionId,
            step: step,
            execution: execution,
            handler: request.eventHandler
          )
        )
      } catch let adapterFailure as AdapterExecutionError {
        _ = try? await publisher.publishAcceptedOutput(
          WorkflowPublicationRequest(
            sessionId: sessionId,
            stepId: step.id,
            nodeId: step.nodeId,
            attempt: attempt,
            backend: basePayload.executionBackend,
            adapterFailure: adapterFailure,
            transitions: transitions,
            publishesRootOutput: transitions.isEmpty
          )
        )
        throw adapterFailure
      } catch {
        if isWorkflowRunCancellation(error) {
          throw error
        }
        let adapterFailure = AdapterExecutionError(.providerError, String(describing: error))
        _ = try? await publisher.publishAcceptedOutput(
          WorkflowPublicationRequest(
            sessionId: sessionId,
            stepId: step.id,
            nodeId: step.nodeId,
            attempt: attempt,
            backend: basePayload.executionBackend,
            adapterFailure: adapterFailure,
            transitions: transitions,
            publishesRootOutput: transitions.isEmpty
          )
        )
        throw error
      }
      let candidate: RuntimeOutputCandidate
      do {
        candidate = try normalizeRuntimeAdapterOutput(adapterOutput)
      } catch let adapterFailure as AdapterExecutionError {
        _ = try? await publisher.publishAcceptedOutput(
          WorkflowPublicationRequest(
            sessionId: sessionId,
            stepId: step.id,
            nodeId: step.nodeId,
            attempt: attempt,
            backend: basePayload.executionBackend,
            adapterFailure: adapterFailure,
            transitions: transitions,
            publishesRootOutput: transitions.isEmpty
          )
        )
        throw adapterFailure
      }
      if let adapterFailure = multiplePublishableTransitionFailure(transitions: transitions, candidate: candidate) {
        _ = try? await publisher.publishAcceptedOutput(
          WorkflowPublicationRequest(
            sessionId: sessionId,
            stepId: step.id,
            nodeId: step.nodeId,
            attempt: attempt,
            backend: basePayload.executionBackend,
            adapterFailure: adapterFailure,
            transitions: transitions,
            publishesRootOutput: transitions.isEmpty
          )
        )
        throw adapterFailure
      }
      do {
        return try await publisher.publishAcceptedOutput(
          WorkflowPublicationRequest(
            sessionId: sessionId,
            stepId: step.id,
            nodeId: step.nodeId,
            attempt: attempt,
            backend: basePayload.executionBackend,
            adapterOutput: adapterOutput,
            outputContract: workflowOutputContract(from: basePayload.output),
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
      _ = try? await publisher.publishAcceptedOutput(
        WorkflowPublicationRequest(
          sessionId: sessionId,
          stepId: step.id,
          nodeId: step.nodeId,
          attempt: executionIndex,
          adapterFailure: adapterFailure,
          transitions: transitions,
          publishesRootOutput: transitions.isEmpty
        )
      )
      throw adapterFailure
    } catch {
      if isWorkflowRunCancellation(error) {
        throw error
      }
      let adapterFailure = AdapterExecutionError(.policyBlocked, "native_attachment_projection_failed: \(String(describing: error))")
      _ = try? await publisher.publishAcceptedOutput(
        WorkflowPublicationRequest(
          sessionId: sessionId,
          stepId: step.id,
          nodeId: step.nodeId,
          attempt: executionIndex,
          adapterFailure: adapterFailure,
          transitions: transitions,
          publishesRootOutput: transitions.isEmpty
        )
      )
      throw adapterFailure
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
      _ = try? await publisher.publishAcceptedOutput(
        WorkflowPublicationRequest(
          sessionId: sessionId,
          stepId: step.id,
          nodeId: step.nodeId,
          attempt: executionIndex,
          adapterFailure: adapterFailure,
          transitions: transitions,
          publishesRootOutput: transitions.isEmpty
        )
      )
      throw adapterFailure
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
      _ = try? await publisher.publishAcceptedOutput(
        WorkflowPublicationRequest(
          sessionId: sessionId,
          stepId: step.id,
          nodeId: step.nodeId,
          attempt: executionIndex,
          adapterFailure: adapterFailure,
          transitions: transitions,
          publishesRootOutput: transitions.isEmpty
        )
      )
      throw adapterFailure
    } catch {
      if isWorkflowRunCancellation(error) {
        throw error
      }
      let adapterFailure = AdapterExecutionError(.providerError, String(describing: error))
      _ = try? await publisher.publishAcceptedOutput(
        WorkflowPublicationRequest(
          sessionId: sessionId,
          stepId: step.id,
          nodeId: step.nodeId,
          attempt: executionIndex,
          adapterFailure: adapterFailure,
          transitions: transitions,
          publishesRootOutput: transitions.isEmpty
        )
      )
      throw error
    }

    let candidate = try normalizeRuntimeAdapterOutput(adapterOutput)
    if let adapterFailure = multiplePublishableTransitionFailure(transitions: transitions, candidate: candidate) {
      _ = try? await publisher.publishAcceptedOutput(
        WorkflowPublicationRequest(
          sessionId: sessionId,
          stepId: step.id,
          nodeId: step.nodeId,
          attempt: executionIndex,
          adapterFailure: adapterFailure,
          adapterOutput: adapterOutput,
          transitions: transitions,
          publishesRootOutput: transitions.isEmpty
        )
      )
      throw adapterFailure
    }
    return try await publisher.publishAcceptedOutput(
      WorkflowPublicationRequest(
        sessionId: sessionId,
        stepId: step.id,
        nodeId: step.nodeId,
        attempt: executionIndex,
        adapterOutput: adapterOutput,
        transitions: transitions,
        publishesRootOutput: transitions.isEmpty
      )
    )
  }

}
