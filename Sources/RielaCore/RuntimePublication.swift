import Foundation

public enum WorkflowPublicationBody: Equatable, Sendable {
  case failure(AdapterExecutionError, adapterOutput: AdapterExecutionOutput? = nil)
  case adapterOutput(AdapterExecutionOutput)
  case inlineCandidate(JSONObject)
  case candidatePath(URL, RuntimeCandidatePathReservation)
  case none
}

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
    allowsNoOutput: Bool = false
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
  }
}

public struct WorkflowPublicationResult: Equatable, Sendable {
  public var session: WorkflowSession
  public var stepExecution: WorkflowStepExecution
  public var publishedMessages: [WorkflowMessageRecord]
  public var nextStepId: String?
  public var rootOutput: JSONObject?

  public init(
    session: WorkflowSession,
    stepExecution: WorkflowStepExecution,
    publishedMessages: [WorkflowMessageRecord],
    nextStepId: String? = nil,
    rootOutput: JSONObject? = nil
  ) {
    self.session = session
    self.stepExecution = stepExecution
    self.publishedMessages = publishedMessages
    self.nextStepId = nextStepId
    self.rootOutput = rootOutput
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

public struct InMemoryWorkflowOutputPublisher: WorkflowOutputPublishing {
  public var store: any WorkflowRuntimeStore
  public var validator: any WorkflowOutputValidating
  public var candidatePathReader: any CandidatePathReading
  public var candidatePathFinalizer: RuntimeCandidatePathFinalizer?
  public var clock: any WorkflowRuntimeClock
  public var simulatesCrossWorkflowDispatch: Bool

  public init(
    store: any WorkflowRuntimeStore,
    validator: any WorkflowOutputValidating = DefaultWorkflowOutputValidator(),
    candidatePathReader: any CandidatePathReading = DefaultCandidatePathReader(),
    candidatePathFinalizer: RuntimeCandidatePathFinalizer? = nil,
    clock: any WorkflowRuntimeClock = SystemWorkflowRuntimeClock(),
    simulatesCrossWorkflowDispatch: Bool = false
  ) {
    self.store = store
    self.validator = validator
    self.candidatePathReader = candidatePathReader
    self.candidatePathFinalizer = candidatePathFinalizer
    self.clock = clock
    self.simulatesCrossWorkflowDispatch = simulatesCrossWorkflowDispatch
  }

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
    guard validation.status == .accepted, let payload = validation.payload else {
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

    let publishableTransitions = request.transitions.filter { shouldPublish(transition: $0, candidate: candidate) }
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

    let publishesRootOutput = request.publishesRootOutput || (!request.transitions.isEmpty && publishableTransitions.isEmpty)
    let nextStepId = self.nextStepId(from: publishableTransitions)
    let acceptedOutput = WorkflowAcceptedOutputMetadata(
      payload: payload,
      when: candidate.when,
      isRootOutput: publishesRootOutput,
      acceptedAt: clock.now(),
      routingDiagnostics: candidate.routingDiagnostics
    )

    let messageInputs = publishableTransitions
      .map { transition in
        WorkflowMessageAppendInput(
          workflowExecutionId: request.sessionId,
          fromStepId: request.stepId,
          toStepId: transition.resumeStepId ?? transition.toStepId,
          routingScope: .workflow,
          deliveryKind: .direct,
          sourceStepExecutionId: recordedExecution.executionId,
          transitionCondition: transition.label,
          payload: payload
        )
      }
    let publishedMessages: [WorkflowMessageRecord]
    do {
      publishedMessages = try await store.appendWorkflowMessages(messageInputs)
    } catch {
      _ = try await store.updateStepExecution(
        WorkflowStepExecutionUpdateInput(
          sessionId: request.sessionId,
          executionId: recordedExecution.executionId,
          status: .failed,
          acceptedOutput: nil,
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
        acceptedOutput: acceptedOutput,
        adapterOutput: adapterOutputMetadata,
        usage: adapterUsage,
        completesRootWithoutOutput: request.completesRootWithoutOutput,
        currentStepId: nextStepId
      )
    )

    guard let session = try await store.loadSession(id: request.sessionId) else {
      throw WorkflowRuntimeStoreError.sessionNotFound(request.sessionId)
    }
    return WorkflowPublicationResult(
      session: session,
      stepExecution: completedExecution,
      publishedMessages: publishedMessages,
      nextStepId: nextStepId,
      rootOutput: publishesRootOutput ? payload : nil
    )
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

  private func shouldPublish(transition: WorkflowStepTransition, candidate: RuntimeOutputCandidate) -> Bool {
    WorkflowBranchEvaluator().evaluate(label: transition.label, when: candidate.when, payload: candidate.payload)
  }

  private func unsupportedTransitionReason(in transitions: [WorkflowStepTransition]) -> String? {
    for transition in transitions {
      if transition.toWorkflowId != nil && transition.resumeStepId == nil {
        return "cross-workflow transitions are not supported by this in-memory publisher"
      }
      if transition.toWorkflowId != nil && !simulatesCrossWorkflowDispatch {
        return "cross-workflow transitions are not supported by this in-memory publisher"
      }
      if transition.toWorkflowId == nil && transition.resumeStepId != nil {
        return "resume-step transitions are not supported by this in-memory publisher"
      }
      if transition.fanout != nil {
        return "fanout transitions are not supported by this in-memory publisher"
      }
    }
    return nil
  }

  private func nextStepId(from publishableTransitions: [WorkflowStepTransition]) -> String? {
    publishableTransitions.first.map { $0.resumeStepId ?? $0.toStepId }
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
