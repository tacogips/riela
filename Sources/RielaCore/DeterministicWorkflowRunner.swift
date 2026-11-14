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
  /// Recovery lineage recorded on the source session's evidence manifest,
  /// supplied by callers that can read persisted manifests (the CLI). Rerun
  /// entries derive `rootSessionId`/`attemptNumber` from it; absent lineage is
  /// treated as attempt one.
  public var sourceRecoveryLineage: LoopRecoveryLineage?
  public var memoryRootDirectory: String?
  public var agentSilenceWarningMs: Int?
  public var agentSilenceMonitorIntervalMs: Int
  public var effectiveInstance: EffectiveWorkflowInstance?
  public var eventHandler: WorkflowRunEventHandler?
  /// Nesting depth of live cross-workflow dispatch. Top-level runs are 0;
  /// each dispatched callee run increments it so runaway workflow-call cycles
  /// fail loudly instead of recursing without bound.
  public var crossWorkflowDispatchDepth: Int
  var stopBeforeStepId: String?

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
    sourceRecoveryLineage: LoopRecoveryLineage? = nil,
    memoryRootDirectory: String? = nil,
    agentSilenceWarningMs: Int? = nil,
    agentSilenceMonitorIntervalMs: Int = 1_000,
    effectiveInstance: EffectiveWorkflowInstance? = nil,
    eventHandler: WorkflowRunEventHandler? = nil,
    crossWorkflowDispatchDepth: Int = 0,
    stopBeforeStepId: String? = nil
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
    self.sourceRecoveryLineage = sourceRecoveryLineage
    self.memoryRootDirectory = memoryRootDirectory
    self.agentSilenceWarningMs = agentSilenceWarningMs
    self.agentSilenceMonitorIntervalMs = agentSilenceMonitorIntervalMs
    self.effectiveInstance = effectiveInstance
    self.eventHandler = eventHandler
    self.crossWorkflowDispatchDepth = crossWorkflowDispatchDepth
    self.stopBeforeStepId = stopBeforeStepId
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
  public var simulatesCrossWorkflowDispatch: Bool
  public var calleeResolver: (any WorkflowCalleeResolving)?

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
    telemetry: any RielaTelemetry = NoOpRielaTelemetry(),
    simulatesCrossWorkflowDispatch: Bool = false,
    calleeResolver: (any WorkflowCalleeResolving)? = nil
  ) {
    let resolvedStore = store ?? InMemoryWorkflowRuntimeStore()
    self.store = resolvedStore
    self.adapter = adapter
    self.addonResolver = addonResolver
    self.attachmentProjector = attachmentProjector
    self.stdioNodeExecutor = stdioNodeExecutor
    self.publisher = publisher ?? InMemoryWorkflowOutputPublisher(
      store: resolvedStore,
      simulatesCrossWorkflowDispatch: simulatesCrossWorkflowDispatch,
      supportsLiveCrossWorkflowDispatch: calleeResolver != nil
    )
    self.inputResolver = inputResolver
    self.inputFilterEvaluator = inputFilterEvaluator
    self.inputFilterLogger = inputFilterLogger
    self.loopPolicyEvaluator = loopPolicyEvaluator
    self.telemetry = telemetry
    self.simulatesCrossWorkflowDispatch = simulatesCrossWorkflowDispatch
    self.calleeResolver = calleeResolver
  }

  public func run(_ request: DeterministicWorkflowRunRequest) async throws -> WorkflowRunResult {
    var interruptedSessionId: String?
    var pendingStepBudgetDiagnostic: WorkflowStepBudgetDiagnostic?
    do {
    let diagnostics = DefaultWorkflowValidator().validate(request.workflow)
    if let diagnostic = diagnostics.first(where: { $0.severity == .error }) {
      throw DeterministicWorkflowRunnerError.invalidWorkflow("\(diagnostic.path): \(diagnostic.message)")
    }
    let supportsCrossWorkflowDispatch = simulatesCrossWorkflowDispatch || calleeResolver != nil
    let capabilityGaps = Self.unsupportedFeatures(
      in: request.workflow,
      maxConcurrency: request.maxConcurrency,
      supportsCrossWorkflowDispatch: supportsCrossWorkflowDispatch
    )
    if let gap = capabilityGaps.first(where: { $0.severity == .error }) {
      throw DeterministicWorkflowRunnerError.invalidWorkflow("\(gap.path): \(gap.message)")
    }
    if !supportsCrossWorkflowDispatch,
       let gap = capabilityGaps.first(where: { $0.path.hasSuffix(".transitions.toWorkflowId") }) {
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

    let entryContext: SessionEntryContext
    switch try await resolveSessionEntry(request) {
    case let .terminal(result):
      return result
    case let .proceed(context):
      entryContext = context
    }
    var session = entryContext.session
    var currentStepId = entryContext.currentStepId
    let recoveryLineage = entryContext.recoveryLineage
    for (key, value) in entryContext.variableOverrides {
      effectiveRequest.variables[key] = value
    }

    interruptedSessionId = session.sessionId
    try enforceLoopSessionAttempts(lineage: recoveryLineage, workflow: effectiveRequest.workflow)
    await emitSessionStartedEvent(workflowId: effectiveRequest.workflow.workflowId, session: session, handler: effectiveRequest.eventHandler)

    var loopBudgetEventEmitted = false
    var visitedSteps = 0
    var publishedTransitions = 0
    var rootOutput: JSONObject?
    var executionCounts: [String: Int] = [:]
    let maxLoopIterations = effectiveRequest.maxLoopIterations ?? effectiveRequest.workflow.defaults.maxLoopIterations
    let maxStepsSource: WorkflowStepBudgetSource = effectiveRequest.maxSteps == nil ? .computedDefault : .commandLine
    let maxSteps = effectiveRequest.maxSteps ?? max(1, effectiveRequest.workflow.steps.count + maxLoopIterations)

    while let stepId = currentStepId {
      visitedSteps += 1
      if visitedSteps > maxSteps {
        pendingStepBudgetDiagnostic = stepBudgetDiagnostic(
          session: session,
          stepBudget: maxSteps,
          executionCount: maxSteps,
          maxLoopIterations: maxLoopIterations,
          budgetSource: maxStepsSource,
          executionCounts: executionCounts,
          unscheduledStepId: stepId
        )
        throw DeterministicWorkflowRunnerError.maxStepsExceeded(maxSteps)
      }
      // Step-boundary budget check: accumulated cost/wall-clock from completed
      // steps is evaluated before the next step is dispatched.
      try await enforceLoopBudgetAtStepBoundary(
        visitedSteps: visitedSteps,
        sessionId: session.sessionId,
        workflow: effectiveRequest.workflow,
        eventHandler: effectiveRequest.eventHandler,
        budgetEventEmitted: &loopBudgetEventEmitted
      )
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
        try await enforceLoopConvergenceIfNeeded(
          publishResult: publishResult,
          workflow: effectiveRequest.workflow,
          step: step,
          request: effectiveRequest
        )
        publishedTransitions += publishResult.publishedMessages.count
        await emitStepCompletedEvent(
          workflowId: effectiveRequest.workflow.workflowId,
          session: session,
          step: step,
          publishResult: publishResult,
          publishedTransitions: publishedTransitions,
          handler: effectiveRequest.eventHandler
        )
        if let dispatch = publishResult.crossWorkflowDispatch {
          try await dispatchCrossWorkflowCallee(
            directive: dispatch,
            parentSessionId: session.sessionId,
            parentStepId: step.id,
            request: effectiveRequest
          )
          publishedTransitions += 1
        }
        if let dispatch = publishResult.fanoutDispatch {
          let fanoutJoin = try await dispatchFanout(
            directive: dispatch,
            parentSessionId: session.sessionId,
            parentStepId: step.id,
            request: effectiveRequest
          )
          effectiveRequest.variables["fanoutJoin"] = .object(fanoutJoin)
          publishedTransitions += 1
          currentStepId = dispatch.joinStepId
          continue
        }
        if let stoppedRootOutput = try await branchRootOutputIfStoppingBeforeStep(
          publishResult: publishResult,
          request: effectiveRequest
        ) {
          rootOutput = stoppedRootOutput
          currentStepId = nil
          continue
        }
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
      try await enforceLoopConvergenceIfNeeded(
        publishResult: publishResult,
        workflow: effectiveRequest.workflow,
        step: step,
        request: effectiveRequest
      )
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
      if let dispatch = publishResult.crossWorkflowDispatch {
        try await dispatchCrossWorkflowCallee(
          directive: dispatch,
          parentSessionId: session.sessionId,
          parentStepId: step.id,
          request: effectiveRequest
        )
        publishedTransitions += 1
      }
      if let dispatch = publishResult.fanoutDispatch {
        let fanoutJoin = try await dispatchFanout(
          directive: dispatch,
          parentSessionId: session.sessionId,
          parentStepId: step.id,
          request: effectiveRequest
        )
        effectiveRequest.variables["fanoutJoin"] = .object(fanoutJoin)
        publishedTransitions += 1
        currentStepId = dispatch.joinStepId
        continue
      }
      if let stoppedRootOutput = try await branchRootOutputIfStoppingBeforeStep(
        publishResult: publishResult,
        request: effectiveRequest
      ) {
        rootOutput = stoppedRootOutput
        currentStepId = nil
        continue
      }
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
      if let interruptedSessionId {
        await finalizeInterruptedSessionFailed(
          sessionId: interruptedSessionId,
          request: request,
          error: error,
          stepBudgetDiagnostic: pendingStepBudgetDiagnostic
        )
      }
      throw error
    }
  }

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
          registryNode: registryNode,
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
    registryNode: WorkflowNodeRegistryRef,
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
    if let projection = basePayload.output?.projection {
      return try await executeOutputProjectionAndPublish(
        projection: projection,
        registryNode: registryNode,
        payload: basePayload,
        sessionId: session.sessionId,
        workflow: request.workflow,
        step: step,
        resolvedInputPayload: resolvedInput.payload,
        transitions: transitions,
        request: request,
        executionIndex: executionIndex
      )
    }
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

  private func executeOutputProjectionAndPublish(
    projection: WorkflowOutputProjection,
    registryNode: WorkflowNodeRegistryRef,
    payload: AgentNodePayload,
    sessionId: String,
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    resolvedInputPayload: JSONObject,
    transitions: [WorkflowStepTransition],
    request: DeterministicWorkflowRunRequest,
    executionIndex: Int
  ) async throws -> WorkflowPublicationResult {
    guard registryNode.kind == .output else {
      let adapterFailure = AdapterExecutionError(.invalidOutput, "output projection is only supported for kind: output nodes")
      try await publishFailureAndThrow(
        adapterFailure,
        sessionId: sessionId,
        step: step,
        attempt: executionIndex,
        transitions: transitions
      )
    }
    _ = try await recordStepStartedExecution(
      workflowId: workflow.workflowId,
      sessionId: sessionId,
      step: step,
      attempt: executionIndex,
      backend: payload.executionBackend,
      handler: request.eventHandler
    )
    let projectedPayload = try outputProjectionPayload(
      projection,
      resolvedInputPayload: resolvedInputPayload
    )
    let routingReconciler = workflowRoutingReconciler(workflow: workflow, step: step)
    let candidate = try normalizeRuntimeInlineCandidate(projectedPayload, routingReconciler: routingReconciler)
    if let adapterFailure = multiplePublishableTransitionFailure(transitions: transitions, candidate: candidate) {
      try await publishFailureAndThrow(
        adapterFailure,
        sessionId: sessionId,
        step: step,
        attempt: executionIndex,
        transitions: transitions
      )
    }
    return try await publisher.publishAcceptedOutput(
      WorkflowPublicationRequest(
        sessionId: sessionId,
        stepId: step.id,
        nodeId: step.nodeId,
        attempt: executionIndex,
        backend: payload.executionBackend,
        body: .inlineCandidate(projectedPayload),
        outputContract: workflowOutputContract(from: payload.output),
        routingReconciler: routingReconciler,
        transitions: transitions,
        publishesRootOutput: transitions.isEmpty
      )
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
        adapterOutput = try await adapter.execute(
          attemptInput,
          context: context
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

}
