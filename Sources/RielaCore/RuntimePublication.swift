import Foundation

public enum WorkflowPublicationBody: Equatable, Sendable {
  case failure(AdapterExecutionError, adapterOutput: AdapterExecutionOutput? = nil)
  case adapterOutput(AdapterExecutionOutput)
  case inlineCandidate(JSONObject)
  case candidatePath(URL, RuntimeCandidatePathReservation)
  case none
}

public enum WorkflowLoopGuardAction: String, Codable, Equatable, Sendable {
  case fail
  case warn
  case acceptWithResidualRisks = "accept-with-residual-risks"
}

public struct WorkflowLoopGuardPublication: Equatable, Sendable {
  public var violation: LoopConvergenceViolation
  public var action: WorkflowLoopGuardAction
  public var policySource: LoopConvergencePolicySource

  public init(
    violation: LoopConvergenceViolation,
    action: WorkflowLoopGuardAction,
    policySource: LoopConvergencePolicySource
  ) {
    self.violation = violation
    self.action = action
    self.policySource = policySource
  }
}

public struct WorkflowPrePersistenceRoutingContext: Equatable, Sendable {
  public var session: WorkflowSession
  public var stepExecution: WorkflowStepExecution
  public var payload: JSONObject
  public var when: [String: Bool]
  public var selectedTransitions: [WorkflowStepTransition]
  public var publishesRootOutput: Bool
  public var completesRootWithoutOutput: Bool
  public var intendedSuccessfulStatus: WorkflowStepExecutionStatus

  public init(
    session: WorkflowSession,
    stepExecution: WorkflowStepExecution,
    payload: JSONObject,
    when: [String: Bool],
    selectedTransitions: [WorkflowStepTransition],
    publishesRootOutput: Bool,
    completesRootWithoutOutput: Bool,
    intendedSuccessfulStatus: WorkflowStepExecutionStatus
  ) {
    self.session = session
    self.stepExecution = stepExecution
    self.payload = payload
    self.when = when
    self.selectedTransitions = selectedTransitions
    self.publishesRootOutput = publishesRootOutput
    self.completesRootWithoutOutput = completesRootWithoutOutput
    self.intendedSuccessfulStatus = intendedSuccessfulStatus
  }
}

public struct WorkflowPrePersistenceRoutingDecision: Equatable, Sendable {
  public var selectedTransitions: [WorkflowStepTransition]
  public var routedPayload: JSONObject
  public var publishesRootOutput: Bool
  public var completesRootWithoutOutput: Bool
  public var loopGuard: WorkflowLoopGuardPublication?

  public init(
    selectedTransitions: [WorkflowStepTransition],
    routedPayload: JSONObject,
    publishesRootOutput: Bool,
    completesRootWithoutOutput: Bool,
    loopGuard: WorkflowLoopGuardPublication? = nil
  ) {
    self.selectedTransitions = selectedTransitions
    self.routedPayload = routedPayload
    self.publishesRootOutput = publishesRootOutput
    self.completesRootWithoutOutput = completesRootWithoutOutput
    self.loopGuard = loopGuard
  }

  public static func unchanged(
    _ context: WorkflowPrePersistenceRoutingContext
  ) -> WorkflowPrePersistenceRoutingDecision {
    WorkflowPrePersistenceRoutingDecision(
      selectedTransitions: context.selectedTransitions,
      routedPayload: context.payload,
      publishesRootOutput: context.publishesRootOutput,
      completesRootWithoutOutput: context.completesRootWithoutOutput
    )
  }
}

public typealias WorkflowPrePersistenceRoutingDecider = @Sendable (
  WorkflowPrePersistenceRoutingContext
) throws -> WorkflowPrePersistenceRoutingDecision

public struct WorkflowPublicationRequest: Sendable {
  public var sessionId: String
  public var stepId: String
  public var nodeId: String
  public var attempt: Int
  public var backend: NodeExecutionBackend?
  public var body: WorkflowPublicationBody
  public var outputContract: WorkflowOutputContract?
  public var routingReconciler: OutputContractRoutingReconciler?
  public var transitions: [WorkflowStepTransition]
  public var publishesRootOutput: Bool
  public var successfulExecutionStatus: WorkflowStepExecutionStatus
  public var completesRootWithoutOutput: Bool
  public var allowsNoOutput: Bool
  public var transitionSelectionMode: WorkflowPublicationTransitionSelectionMode
  public var noSelectionDisposition: WorkflowPublicationNoSelectionDisposition
  public var prePersistenceRoutingDecider: WorkflowPrePersistenceRoutingDecider?
  public var carriedPayloadFields: JSONObject

  public init(
    sessionId: String,
    stepId: String,
    nodeId: String,
    attempt: Int,
    backend: NodeExecutionBackend? = nil,
    body: WorkflowPublicationBody = .none,
    outputContract: WorkflowOutputContract? = nil,
    routingReconciler: OutputContractRoutingReconciler? = nil,
    transitions: [WorkflowStepTransition] = [],
    publishesRootOutput: Bool = false,
    successfulExecutionStatus: WorkflowStepExecutionStatus = .completed,
    completesRootWithoutOutput: Bool = false,
    allowsNoOutput: Bool = false,
    transitionSelectionMode: WorkflowPublicationTransitionSelectionMode = .rejectMultiple,
    noSelectionDisposition: WorkflowPublicationNoSelectionDisposition = .publishPayloadAsRoot,
    prePersistenceRoutingDecider: WorkflowPrePersistenceRoutingDecider? = nil,
    carriedPayloadFields: JSONObject = [:]
  ) {
    self.sessionId = sessionId
    self.stepId = stepId
    self.nodeId = nodeId
    self.attempt = attempt
    self.backend = backend
    self.body = body
    self.outputContract = outputContract
    self.routingReconciler = routingReconciler
    self.transitions = transitions
    self.publishesRootOutput = publishesRootOutput
    self.successfulExecutionStatus = successfulExecutionStatus
    self.completesRootWithoutOutput = completesRootWithoutOutput
    self.allowsNoOutput = allowsNoOutput
    self.transitionSelectionMode = transitionSelectionMode
    self.noSelectionDisposition = noSelectionDisposition
    self.prePersistenceRoutingDecider = prePersistenceRoutingDecider
    self.carriedPayloadFields = carriedPayloadFields
  }
}

/// Instruction produced when a live run selects a cross-workflow transition:
/// the runner must dispatch the callee workflow and, once it completes,
/// deliver the callee root output to `resumeStepId` in the caller session.
public struct WorkflowCrossWorkflowDispatchDirective: Equatable, Sendable {
  public var workflowId: String
  public var calleeEntryStepId: String
  public var resumeStepId: String
  public var transitionLabel: String?
  public var handoffPayload: JSONObject
  public var sourceStepExecutionId: String

  public init(
    workflowId: String,
    calleeEntryStepId: String,
    resumeStepId: String,
    transitionLabel: String? = nil,
    handoffPayload: JSONObject,
    sourceStepExecutionId: String
  ) {
    self.workflowId = workflowId
    self.calleeEntryStepId = calleeEntryStepId
    self.resumeStepId = resumeStepId
    self.transitionLabel = transitionLabel
    self.handoffPayload = handoffPayload
    self.sourceStepExecutionId = sourceStepExecutionId
  }
}

/// Instruction produced when a live run selects a local fanout transition: the
/// runner must execute the branch sub-paths and deliver the joined result to
/// `joinStepId`.
public struct WorkflowFanoutDispatchDirective: Equatable, Sendable {
  public var groupId: String
  public var workflowId: String?
  public var sourceStepId: String
  public var targetStepId: String
  public var joinStepId: String
  public var transitionLabel: String?
  public var sourceStepExecutionId: String
  public var itemsFrom: String
  public var itemVariable: String?
  public var concurrency: Int?
  public var failurePolicy: WorkflowFanoutFailurePolicy
  public var resultOrder: WorkflowFanoutResultOrder
  public var writeOwnership: WorkflowFanoutWriteOwnership?
  public var sourcePayload: JSONObject

  public init(
    groupId: String,
    workflowId: String? = nil,
    sourceStepId: String,
    targetStepId: String,
    joinStepId: String,
    transitionLabel: String? = nil,
    sourceStepExecutionId: String,
    itemsFrom: String,
    itemVariable: String? = nil,
    concurrency: Int? = nil,
    failurePolicy: WorkflowFanoutFailurePolicy = .failFast,
    resultOrder: WorkflowFanoutResultOrder = .input,
    writeOwnership: WorkflowFanoutWriteOwnership? = nil,
    sourcePayload: JSONObject
  ) {
    self.groupId = groupId
    self.workflowId = workflowId
    self.sourceStepId = sourceStepId
    self.targetStepId = targetStepId
    self.joinStepId = joinStepId
    self.transitionLabel = transitionLabel
    self.sourceStepExecutionId = sourceStepExecutionId
    self.itemsFrom = itemsFrom
    self.itemVariable = itemVariable
    self.concurrency = concurrency
    self.failurePolicy = failurePolicy
    self.resultOrder = resultOrder
    self.writeOwnership = writeOwnership
    self.sourcePayload = sourcePayload
  }
}

public struct WorkflowPublicationResult: Equatable, Sendable {
  public var session: WorkflowSession
  public var stepExecution: WorkflowStepExecution
  public var publishedMessages: [WorkflowMessageRecord]
  public var nextStepId: String?
  public var rootOutput: JSONObject?
  public var crossWorkflowDispatch: WorkflowCrossWorkflowDispatchDirective?
  public var fanoutDispatch: WorkflowFanoutDispatchDirective?
  public var loopGuard: WorkflowLoopGuardPublication?

  public init(
    session: WorkflowSession,
    stepExecution: WorkflowStepExecution,
    publishedMessages: [WorkflowMessageRecord],
    nextStepId: String? = nil,
    rootOutput: JSONObject? = nil,
    crossWorkflowDispatch: WorkflowCrossWorkflowDispatchDirective? = nil,
    fanoutDispatch: WorkflowFanoutDispatchDirective? = nil,
    loopGuard: WorkflowLoopGuardPublication? = nil
  ) {
    self.session = session
    self.stepExecution = stepExecution
    self.publishedMessages = publishedMessages
    self.nextStepId = nextStepId
    self.rootOutput = rootOutput
    self.crossWorkflowDispatch = crossWorkflowDispatch
    self.fanoutDispatch = fanoutDispatch
    self.loopGuard = loopGuard
  }
}

public enum WorkflowPublicationError: Error, Equatable, Sendable {
  case noCandidateOutput
  case unsupportedTransition(String)
  case validationRejected(String)
}

public protocol WorkflowOutputPublishing: Sendable {
  func publishAcceptedOutput(_ request: WorkflowPublicationRequest) async throws -> WorkflowPublicationResult
}

public typealias RuntimeCandidatePathFinalizer = @Sendable (RuntimeCandidatePathReservation) async throws -> Void
public typealias WorkflowTransitionPredicateEvaluator = @Sendable (
  WorkflowStepTransition,
  RuntimeOutputCandidate
) -> Bool

public struct InMemoryWorkflowOutputPublisher: WorkflowOutputPublishing {
  public var store: any WorkflowRuntimeStore
  public var validator: any WorkflowOutputValidating
  public var candidatePathReader: any CandidatePathReading
  public var candidatePathFinalizer: RuntimeCandidatePathFinalizer?
  public var clock: any WorkflowRuntimeClock
  public var simulatesCrossWorkflowDispatch: Bool
  public var supportsLiveCrossWorkflowDispatch: Bool
  public var transitionPredicateEvaluator: WorkflowTransitionPredicateEvaluator

  public init(
    store: any WorkflowRuntimeStore,
    validator: any WorkflowOutputValidating = DefaultWorkflowOutputValidator(),
    candidatePathReader: any CandidatePathReading = DefaultCandidatePathReader(),
    candidatePathFinalizer: RuntimeCandidatePathFinalizer? = nil,
    clock: any WorkflowRuntimeClock = SystemWorkflowRuntimeClock(),
    simulatesCrossWorkflowDispatch: Bool = false,
    supportsLiveCrossWorkflowDispatch: Bool = false,
    transitionPredicateEvaluator: @escaping WorkflowTransitionPredicateEvaluator = { transition, candidate in
      WorkflowBranchEvaluator().evaluate(
        label: transition.label,
        when: candidate.when,
        payload: candidate.payload
      )
    }
  ) {
    self.store = store
    self.validator = validator
    self.candidatePathReader = candidatePathReader
    self.candidatePathFinalizer = candidatePathFinalizer
    self.clock = clock
    self.simulatesCrossWorkflowDispatch = simulatesCrossWorkflowDispatch
    self.supportsLiveCrossWorkflowDispatch = supportsLiveCrossWorkflowDispatch
    self.transitionPredicateEvaluator = transitionPredicateEvaluator
  }

  // Publication owns validation, single-pass selection, and staged transaction finalization atomically.
  // swiftlint:disable:next function_body_length
  public func publishAcceptedOutput(_ request: WorkflowPublicationRequest) async throws -> WorkflowPublicationResult {
    let recordedExecution: WorkflowStepExecution
    if let existingExecution = try await runningExecution(for: request) {
      recordedExecution = existingExecution
    } else {
      recordedExecution = try await store.recordStepExecution(
        WorkflowStepExecutionRecordInput(
          sessionId: request.sessionId,
          stepId: request.stepId,
          nodeId: request.nodeId,
          attempt: request.attempt,
          backend: request.backend
        )
      )
    }
    let adapterOutputMetadata = request.adapterOutputMetadataSource.map {
      WorkflowAdapterOutputMetadata(
        provider: $0.provider,
        model: $0.model,
        completionPassed: $0.completionPassed,
        when: $0.when
      )
    }
    let adapterUsage = request.adapterOutputMetadataSource?.usage
    if recordedExecution.pendingRoutePublication != nil {
      return try await finishStagedPublication(request: request, execution: recordedExecution)
    }
    if case let .failure(adapterFailure, _) = request.body {
      _ = try await store.updateStepExecution(
        WorkflowStepExecutionUpdateInput(
          sessionId: request.sessionId,
          executionId: recordedExecution.executionId,
          status: .failed,
          adapterOutput: adapterOutputMetadata,
          failureReason: "\(adapterFailure.code.rawValue): \(adapterFailure.message)",
          usage: adapterUsage
        )
      )
      try? await finalizeCandidatePathIfNeeded(for: request)
      throw adapterFailure
    }

    if request.allowsNoOutput && request.body == .none {
      do {
        try await finalizeCandidatePathIfNeeded(for: request)
      } catch {
        _ = try await store.updateStepExecution(
          WorkflowStepExecutionUpdateInput(
            sessionId: request.sessionId,
            executionId: recordedExecution.executionId,
            status: .failed,
            adapterOutput: adapterOutputMetadata,
            failureReason: String(describing: error),
            usage: adapterUsage
          )
        )
        throw error
      }
      let completedExecution = try await store.updateStepExecution(
        WorkflowStepExecutionUpdateInput(
          sessionId: request.sessionId,
          executionId: recordedExecution.executionId,
          status: request.successfulExecutionStatus,
          adapterOutput: adapterOutputMetadata,
          usage: adapterUsage,
          completesRootWithoutOutput: request.publishesRootOutput || request.completesRootWithoutOutput
        )
      )
      guard let session = try await store.loadSession(id: request.sessionId) else {
        throw WorkflowRuntimeStoreError.sessionNotFound(request.sessionId)
      }
      return WorkflowPublicationResult(
        session: session,
        stepExecution: completedExecution,
        publishedMessages: [],
        nextStepId: nil,
        rootOutput: nil
      )
    }

    let candidate: RuntimeOutputCandidate
    do {
      candidate = try await runtimeCandidate(from: request)
    } catch {
      try? await finalizeCandidatePathIfNeeded(for: request)
      _ = try await store.updateStepExecution(
        WorkflowStepExecutionUpdateInput(
          sessionId: request.sessionId,
          executionId: recordedExecution.executionId,
          status: .failed,
          adapterOutput: adapterOutputMetadata,
          failureReason: String(describing: error),
          usage: adapterUsage
        )
      )
      throw error
    }
    do {
      try await finalizeCandidatePathIfNeeded(for: request)
    } catch {
      _ = try await store.updateStepExecution(
        WorkflowStepExecutionUpdateInput(
          sessionId: request.sessionId,
          executionId: recordedExecution.executionId,
          status: .failed,
          adapterOutput: adapterOutputMetadata,
          failureReason: String(describing: error),
          usage: adapterUsage
        )
      )
      throw error
    }

    let validation = try validator.validate(candidate, contract: request.outputContract)
    guard validation.status == .accepted, let validatedPayload = validation.payload else {
      let reason = validation.reason ?? "output validation rejected candidate"
      let failedExecution = try await store.updateStepExecution(
        WorkflowStepExecutionUpdateInput(
          sessionId: request.sessionId,
          executionId: recordedExecution.executionId,
          status: .failed,
          adapterOutput: adapterOutputMetadata,
          failureReason: reason,
          usage: adapterUsage
        )
      )
      let session = try await store.loadSession(id: request.sessionId)
      throw WorkflowPublicationError.validationRejected(failedExecution.failureReason ?? session?.status.rawValue ?? reason)
    }
    var payload = validatedPayload
    for (key, value) in request.carriedPayloadFields {
      payload[key] = value
    }

    let publishableTransitions: [WorkflowStepTransition]
    do {
      publishableTransitions = try selectedTransitions(request: request, candidate: candidate)
    } catch {
      let failureReason: String
      if let adapterFailure = error as? AdapterExecutionError {
        failureReason = "\(adapterFailure.code.rawValue): \(adapterFailure.message)"
      } else {
        failureReason = String(describing: error)
      }
      _ = try await store.updateStepExecution(
        WorkflowStepExecutionUpdateInput(
          sessionId: request.sessionId,
          executionId: recordedExecution.executionId,
          status: .failed,
          adapterOutput: adapterOutputMetadata,
          failureReason: failureReason,
          usage: adapterUsage
        )
      )
      throw error
    }
    if let reason = unsupportedTransitionReason(in: publishableTransitions) {
      _ = try await store.updateStepExecution(
        WorkflowStepExecutionUpdateInput(
          sessionId: request.sessionId,
          executionId: recordedExecution.executionId,
          status: .failed,
          adapterOutput: adapterOutputMetadata,
          failureReason: reason,
          usage: adapterUsage
        )
      )
      throw WorkflowPublicationError.unsupportedTransition(reason)
    }

    let ordinaryCompletion = completionDisposition(
      request: request,
      selectedTransitions: publishableTransitions
    )
    let acceptedOutput = WorkflowAcceptedOutputMetadata(
      payload: payload,
      when: candidate.when,
      isRootOutput: ordinaryCompletion.publishesRootOutput,
      acceptedAt: clock.now(),
      routingDiagnostics: candidate.routingDiagnostics
    )

    if request.prePersistenceRoutingDecider != nil {
      let staged = try await store.stageWorkflowPublication(WorkflowPublicationStageInput(
        sessionId: request.sessionId,
        executionId: recordedExecution.executionId,
        acceptedOutput: acceptedOutput,
        adapterOutput: adapterOutputMetadata,
        usage: adapterUsage,
        pendingRoutePublication: WorkflowPendingRoutePublication(
          selectedTransitions: publishableTransitions,
          publishesRootOutput: ordinaryCompletion.publishesRootOutput,
          completesRootWithoutOutput: ordinaryCompletion.completesRootWithoutOutput,
          noSelectionDisposition: request.noSelectionDisposition,
          intendedSuccessfulStatus: request.successfulExecutionStatus
        )
      ))
      return try await finishStagedPublication(request: request, execution: staged.execution)
    }

    return try await commitDirectPublication(
      request: request,
      execution: recordedExecution,
      acceptedOutput: acceptedOutput,
      adapterOutput: adapterOutputMetadata,
      usage: adapterUsage,
      selectedTransitions: publishableTransitions,
      routedPayload: payload,
      publishesRootOutput: ordinaryCompletion.publishesRootOutput,
      completesRootWithoutOutput: ordinaryCompletion.completesRootWithoutOutput
    )
  }

  private func finishStagedPublication(
    request: WorkflowPublicationRequest,
    execution: WorkflowStepExecution
  ) async throws -> WorkflowPublicationResult {
    guard let pending = execution.pendingRoutePublication,
          let acceptedOutput = execution.acceptedOutput,
          let decider = request.prePersistenceRoutingDecider,
          let session = try await store.loadSession(id: request.sessionId) else {
      throw WorkflowRuntimeStoreError.messageAppendRejected("pending publication cannot be resumed")
    }
    let context = WorkflowPrePersistenceRoutingContext(
      session: session,
      stepExecution: execution,
      payload: acceptedOutput.payload,
      when: acceptedOutput.when,
      selectedTransitions: pending.selectedTransitions,
      publishesRootOutput: pending.publishesRootOutput,
      completesRootWithoutOutput: pending.completesRootWithoutOutput,
      intendedSuccessfulStatus: pending.intendedSuccessfulStatus
    )
    let decision: WorkflowPrePersistenceRoutingDecision
    do {
      decision = try decider(context)
      if let reason = unsupportedTransitionReason(in: decision.selectedTransitions) {
        throw WorkflowPublicationError.unsupportedTransition(reason)
      }
    } catch {
      _ = try? await store.abortWorkflowPublication(WorkflowPublicationAbortInput(
        sessionId: request.sessionId,
        executionId: execution.executionId,
        reason: String(describing: error)
      ))
      throw error
    }
    let nextStepId = self.nextStepId(from: decision.selectedTransitions)
    let messageInputs = publicationMessageInputs(
      request: request,
      executionId: execution.executionId,
      transitions: decision.selectedTransitions,
      payload: decision.routedPayload
    )
    let committed: WorkflowPublicationCommitResult
    do {
      committed = try await store.commitWorkflowPublication(WorkflowPublicationCommitInput(
        sessionId: request.sessionId,
        executionId: execution.executionId,
        messageInputs: messageInputs,
        currentStepId: nextStepId,
        publishesRootOutput: decision.publishesRootOutput,
        completesRootWithoutOutput: decision.completesRootWithoutOutput
      ))
    } catch {
      _ = try? await store.abortWorkflowPublication(WorkflowPublicationAbortInput(
        sessionId: request.sessionId,
        executionId: execution.executionId,
        reason: String(describing: error)
      ))
      throw error
    }
    return publicationResult(
      request: request,
      session: committed.session,
      execution: committed.execution,
      messages: committed.messages,
      selectedTransitions: decision.selectedTransitions,
      payload: decision.routedPayload,
      publishesRootOutput: decision.publishesRootOutput,
      loopGuard: decision.loopGuard
    )
  }

  private func commitDirectPublication(
    request: WorkflowPublicationRequest,
    execution: WorkflowStepExecution,
    acceptedOutput: WorkflowAcceptedOutputMetadata,
    adapterOutput: WorkflowAdapterOutputMetadata?,
    usage: AdapterUsage?,
    selectedTransitions: [WorkflowStepTransition],
    routedPayload: JSONObject,
    publishesRootOutput: Bool,
    completesRootWithoutOutput: Bool
  ) async throws -> WorkflowPublicationResult {
    let nextStepId = self.nextStepId(from: selectedTransitions)
    let messageInputs = publicationMessageInputs(
      request: request,
      executionId: execution.executionId,
      transitions: selectedTransitions,
      payload: routedPayload
    )
    let publishedMessages: [WorkflowMessageRecord]
    do {
      publishedMessages = try await store.appendWorkflowMessages(messageInputs)
    } catch {
      _ = try await store.updateStepExecution(
        WorkflowStepExecutionUpdateInput(
          sessionId: request.sessionId,
          executionId: execution.executionId,
          status: .failed,
          adapterOutput: adapterOutput,
          failureReason: String(describing: error),
          usage: usage
        )
      )
      throw error
    }
    let completedExecution = try await store.updateStepExecution(
      WorkflowStepExecutionUpdateInput(
        sessionId: request.sessionId,
        executionId: execution.executionId,
        status: request.successfulExecutionStatus,
        acceptedOutput: acceptedOutput,
        adapterOutput: adapterOutput,
        usage: usage,
        completesRootWithoutOutput: completesRootWithoutOutput,
        currentStepId: nextStepId
      )
    )
    guard let session = try await store.loadSession(id: request.sessionId) else {
      throw WorkflowRuntimeStoreError.sessionNotFound(request.sessionId)
    }
    return publicationResult(
      request: request,
      session: session,
      execution: completedExecution,
      messages: publishedMessages,
      selectedTransitions: selectedTransitions,
      payload: routedPayload,
      publishesRootOutput: publishesRootOutput,
      loopGuard: nil
    )
  }

  private func publicationResult(
    request: WorkflowPublicationRequest,
    session: WorkflowSession,
    execution: WorkflowStepExecution,
    messages: [WorkflowMessageRecord],
    selectedTransitions: [WorkflowStepTransition],
    payload: JSONObject,
    publishesRootOutput: Bool,
    loopGuard: WorkflowLoopGuardPublication?
  ) -> WorkflowPublicationResult {
    WorkflowPublicationResult(
      session: session,
      stepExecution: execution,
      publishedMessages: messages,
      nextStepId: nextStepId(from: selectedTransitions),
      rootOutput: publishesRootOutput ? payload : nil,
      crossWorkflowDispatch: liveCrossWorkflowDispatchDirective(
        in: selectedTransitions,
        handoffPayload: payload,
        sourceStepExecutionId: execution.executionId
      ),
      fanoutDispatch: liveFanoutDispatchDirective(
        in: selectedTransitions,
        sourceStepId: request.stepId,
        sourcePayload: payload,
        sourceStepExecutionId: execution.executionId
      ),
      loopGuard: loopGuard
    )
  }

  private func publicationMessageInputs(
    request: WorkflowPublicationRequest,
    executionId: String,
    transitions: [WorkflowStepTransition],
    payload: JSONObject
  ) -> [WorkflowMessageAppendInput] {
    transitions
      .filter { !isLiveCrossWorkflowDispatchTransition($0) && !isLiveFanoutDispatchTransition($0) }
      .map { transition in
        WorkflowMessageAppendInput(
          workflowExecutionId: request.sessionId,
          fromStepId: request.stepId,
          toStepId: transition.resumeStepId ?? transition.toStepId,
          routingScope: .workflow,
          deliveryKind: .direct,
          sourceStepExecutionId: executionId,
          transitionCondition: transition.label,
          payload: payload
        )
      }
  }

  private func selectedTransitions(
    request: WorkflowPublicationRequest,
    candidate: RuntimeOutputCandidate
  ) throws -> [WorkflowStepTransition] {
    switch request.transitionSelectionMode {
    case .firstMatch:
      for transition in request.transitions where transitionPredicateEvaluator(transition, candidate) {
        return [transition]
      }
      return []
    case .rejectMultiple:
      var selected: [WorkflowStepTransition] = []
      for transition in request.transitions where transitionPredicateEvaluator(transition, candidate) {
        selected.append(transition)
      }
      guard selected.count <= 1 else {
        throw AdapterExecutionError(
          .invalidOutput,
          "multiple direct transitions are not supported by this sequential runner"
        )
      }
      return selected
    }
  }

  private func completionDisposition(
    request: WorkflowPublicationRequest,
    selectedTransitions: [WorkflowStepTransition]
  ) -> (publishesRootOutput: Bool, completesRootWithoutOutput: Bool) {
    guard selectedTransitions.isEmpty else {
      return (false, false)
    }
    if request.publishesRootOutput {
      return (true, false)
    }
    if request.completesRootWithoutOutput {
      return (false, true)
    }
    if request.noSelectionDisposition == .completeRootWithoutOutput {
      return (false, true)
    }
    guard !request.transitions.isEmpty else {
      return (false, false)
    }
    return (true, false)
  }

  private func runningExecution(for request: WorkflowPublicationRequest) async throws -> WorkflowStepExecution? {
    guard let session = try await store.loadSession(id: request.sessionId) else {
      throw WorkflowRuntimeStoreError.sessionNotFound(request.sessionId)
    }
    return session.executions.last {
      $0.stepId == request.stepId &&
        $0.nodeId == request.nodeId &&
        $0.attempt == request.attempt &&
        $0.status == .running
    }
  }

  private func runtimeCandidate(from request: WorkflowPublicationRequest) async throws -> RuntimeOutputCandidate {
    switch request.body {
    case .failure:
      throw WorkflowPublicationError.noCandidateOutput
    case let .adapterOutput(adapterOutput):
      return try normalizeRuntimeAdapterOutput(adapterOutput, routingReconciler: request.routingReconciler)
    case let .inlineCandidate(inlineCandidate):
      return try normalizeRuntimeInlineCandidate(inlineCandidate, routingReconciler: request.routingReconciler)
    case let .candidatePath(candidatePath, reservation):
      guard candidatePath.standardizedFileURL == reservation.candidatePath.standardizedFileURL else {
        throw RuntimeOutputCandidateError.candidatePathDoesNotMatchReservation(candidatePath.path)
      }
      return try await candidatePathReader.readCandidate(
        from: candidatePath,
        stagingDirectory: reservation.stagingDirectory,
        attemptStartedAt: reservation.attemptStartedAt,
        requiresObjectPayload: request.outputContract?.requiredObject ?? false,
        routingReconciler: request.routingReconciler
      )
    case .none:
      throw WorkflowPublicationError.noCandidateOutput
    }
  }

  private func finalizeCandidatePathIfNeeded(for request: WorkflowPublicationRequest) async throws {
    guard case let .candidatePath(_, reservation) = request.body else {
      return
    }
    if let candidatePathFinalizer {
      try await candidatePathFinalizer(reservation)
      return
    }
    guard let finalizationRootDirectory = reservation.finalizationRootDirectory else {
      return
    }
    try FileManager.default.createDirectory(at: finalizationRootDirectory, withIntermediateDirectories: true)
    let root = finalizationRootDirectory.standardizedFileURL.resolvingSymlinksInPath()
    let stagingDirectory = reservation.stagingDirectory.standardizedFileURL.resolvingSymlinksInPath()
    guard isFileURL(stagingDirectory, inside: root) else {
      throw RuntimeCandidatePathStagingError.stagingPathEscapesRoot(stagingDirectory.path)
    }
    if FileManager.default.fileExists(atPath: reservation.stagingDirectory.path) {
      try FileManager.default.removeItem(at: reservation.stagingDirectory)
    }
  }

  private func unsupportedTransitionReason(in transitions: [WorkflowStepTransition]) -> String? {
    for transition in transitions {
      if transition.toWorkflowId != nil && transition.resumeStepId == nil {
        return "cross-workflow transitions are not supported by this in-memory publisher"
      }
      if transition.toWorkflowId != nil &&
        !simulatesCrossWorkflowDispatch &&
        !supportsLiveCrossWorkflowDispatch &&
        transition.fanout == nil {
        return "cross-workflow dispatch requires a callee workflow resolver; live runs without one cannot dispatch '\(transition.toWorkflowId ?? "")'"
      }
      if transition.toWorkflowId == nil && transition.resumeStepId != nil {
        return "resume-step transitions are not supported by this in-memory publisher"
      }
    }
    return nil
  }

  private func nextStepId(from publishableTransitions: [WorkflowStepTransition]) -> String? {
    publishableTransitions.first.map { $0.resumeStepId ?? $0.toStepId }
  }

  private func isLiveCrossWorkflowDispatchTransition(_ transition: WorkflowStepTransition) -> Bool {
    !simulatesCrossWorkflowDispatch &&
      supportsLiveCrossWorkflowDispatch &&
      transition.toWorkflowId != nil &&
      transition.resumeStepId != nil &&
      transition.fanout == nil
  }

  private func isLiveFanoutDispatchTransition(_ transition: WorkflowStepTransition) -> Bool {
    transition.fanout != nil
  }

  private func liveCrossWorkflowDispatchDirective(
    in publishableTransitions: [WorkflowStepTransition],
    handoffPayload: JSONObject,
    sourceStepExecutionId: String
  ) -> WorkflowCrossWorkflowDispatchDirective? {
    guard let transition = publishableTransitions.first(where: { isLiveCrossWorkflowDispatchTransition($0) }),
          let toWorkflowId = transition.toWorkflowId,
          let resumeStepId = transition.resumeStepId else {
      return nil
    }
    return WorkflowCrossWorkflowDispatchDirective(
      workflowId: toWorkflowId,
      calleeEntryStepId: transition.toStepId,
      resumeStepId: resumeStepId,
      transitionLabel: transition.label,
      handoffPayload: handoffPayload,
      sourceStepExecutionId: sourceStepExecutionId
    )
  }

  private func liveFanoutDispatchDirective(
    in publishableTransitions: [WorkflowStepTransition],
    sourceStepId: String,
    sourcePayload: JSONObject,
    sourceStepExecutionId: String
  ) -> WorkflowFanoutDispatchDirective? {
    guard let transition = publishableTransitions.first(where: isLiveFanoutDispatchTransition),
          let fanout = transition.fanout else {
      return nil
    }
    return WorkflowFanoutDispatchDirective(
      groupId: fanout.groupId,
      workflowId: transition.toWorkflowId,
      sourceStepId: sourceStepId,
      targetStepId: transition.toStepId,
      joinStepId: fanout.joinStepId,
      transitionLabel: transition.label,
      sourceStepExecutionId: sourceStepExecutionId,
      itemsFrom: fanout.itemsFrom,
      itemVariable: fanout.itemVariable,
      concurrency: fanout.concurrency,
      failurePolicy: fanout.failurePolicy ?? .failFast,
      resultOrder: fanout.resultOrder ?? .input,
      writeOwnership: fanout.writeOwnership,
      sourcePayload: sourcePayload
    )
  }
}

private extension WorkflowPublicationRequest {
  var adapterOutputMetadataSource: AdapterExecutionOutput? {
    switch body {
    case let .failure(_, adapterOutput):
      adapterOutput
    case let .adapterOutput(adapterOutput):
      adapterOutput
    case .inlineCandidate, .candidatePath, .none:
      nil
    }
  }
}

private func isFileURL(_ url: URL, inside directory: URL) -> Bool {
  let path = url.path
  let directoryPath = directory.path
  return path == directoryPath || path.hasPrefix(directoryPath + "/")
}
