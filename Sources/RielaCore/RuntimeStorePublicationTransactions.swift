import Foundation

public struct WorkflowPublicationStageInput: Equatable, Sendable {
  public var sessionId: String
  public var executionId: String
  public var acceptedOutput: WorkflowAcceptedOutputMetadata
  public var adapterOutput: WorkflowAdapterOutputMetadata?
  public var usage: AdapterUsage?
  public var pendingRoutePublication: WorkflowPendingRoutePublication

  public init(
    sessionId: String,
    executionId: String,
    acceptedOutput: WorkflowAcceptedOutputMetadata,
    adapterOutput: WorkflowAdapterOutputMetadata?,
    usage: AdapterUsage?,
    pendingRoutePublication: WorkflowPendingRoutePublication
  ) {
    self.sessionId = sessionId
    self.executionId = executionId
    self.acceptedOutput = acceptedOutput
    self.adapterOutput = adapterOutput
    self.usage = usage
    self.pendingRoutePublication = pendingRoutePublication
  }
}

public struct WorkflowPublicationStageResult: Equatable, Sendable {
  public var session: WorkflowSession
  public var execution: WorkflowStepExecution

  public init(session: WorkflowSession, execution: WorkflowStepExecution) {
    self.session = session
    self.execution = execution
  }
}

public struct WorkflowPublicationCommitInput: Equatable, Sendable {
  public var sessionId: String
  public var executionId: String
  public var messageInputs: [WorkflowMessageAppendInput]
  public var currentStepId: String?
  public var publishesRootOutput: Bool
  public var completesRootWithoutOutput: Bool

  public init(
    sessionId: String,
    executionId: String,
    messageInputs: [WorkflowMessageAppendInput],
    currentStepId: String?,
    publishesRootOutput: Bool,
    completesRootWithoutOutput: Bool
  ) {
    self.sessionId = sessionId
    self.executionId = executionId
    self.messageInputs = messageInputs
    self.currentStepId = currentStepId
    self.publishesRootOutput = publishesRootOutput
    self.completesRootWithoutOutput = completesRootWithoutOutput
  }
}

public struct WorkflowPublicationCommitResult: Equatable, Sendable {
  public var session: WorkflowSession
  public var execution: WorkflowStepExecution
  public var messages: [WorkflowMessageRecord]

  public init(session: WorkflowSession, execution: WorkflowStepExecution, messages: [WorkflowMessageRecord]) {
    self.session = session
    self.execution = execution
    self.messages = messages
  }
}

public struct WorkflowPublicationAbortInput: Equatable, Sendable {
  public var sessionId: String
  public var executionId: String
  public var reason: String

  public init(sessionId: String, executionId: String, reason: String) {
    self.sessionId = sessionId
    self.executionId = executionId
    self.reason = reason
  }
}

public struct WorkflowPendingStepRedirectInput: Equatable, Sendable {
  public var sessionId: String
  public var expectedCurrentStepId: String
  public var displacedCommunicationIds: [String]
  public var replacementMessage: WorkflowMessageAppendInput

  public init(
    sessionId: String,
    expectedCurrentStepId: String,
    displacedCommunicationIds: [String],
    replacementMessage: WorkflowMessageAppendInput
  ) {
    self.sessionId = sessionId
    self.expectedCurrentStepId = expectedCurrentStepId
    self.displacedCommunicationIds = displacedCommunicationIds
    self.replacementMessage = replacementMessage
  }
}

public struct WorkflowPendingStepRedirectResult: Equatable, Sendable {
  public var session: WorkflowSession
  public var replacementMessage: WorkflowMessageRecord

  public init(session: WorkflowSession, replacementMessage: WorkflowMessageRecord) {
    self.session = session
    self.replacementMessage = replacementMessage
  }
}

public extension WorkflowRuntimeStore {
  func stageWorkflowPublication(_ input: WorkflowPublicationStageInput) async throws -> WorkflowPublicationStageResult {
    throw WorkflowRuntimeStoreError.messageAppendRejected(
      "atomic staged publication is unavailable for this runtime store"
    )
  }

  func commitWorkflowPublication(_ input: WorkflowPublicationCommitInput) async throws -> WorkflowPublicationCommitResult {
    throw WorkflowRuntimeStoreError.messageAppendRejected(
      "atomic publication commit is unavailable for this runtime store"
    )
  }

  func abortWorkflowPublication(_ input: WorkflowPublicationAbortInput) async throws -> WorkflowStepExecution {
    throw WorkflowRuntimeStoreError.messageAppendRejected(
      "atomic publication abort is unavailable for this runtime store"
    )
  }

  func redirectPendingWorkflowStep(_ input: WorkflowPendingStepRedirectInput) async throws -> WorkflowPendingStepRedirectResult {
    throw WorkflowRuntimeStoreError.messageAppendRejected(
      "atomic pending-step redirect is unavailable for this runtime store"
    )
  }
}

public extension InMemoryWorkflowRuntimeStore {
  func stageWorkflowPublication(_ input: WorkflowPublicationStageInput) async throws -> WorkflowPublicationStageResult {
    guard var session = sessions[input.sessionId] else {
      throw WorkflowRuntimeStoreError.sessionNotFound(input.sessionId)
    }
    guard let index = session.executions.firstIndex(where: { $0.executionId == input.executionId }) else {
      throw WorkflowRuntimeStoreError.stepExecutionNotFound(input.executionId)
    }
    var execution = session.executions[index]
    if let pending = execution.pendingRoutePublication {
      guard pending == input.pendingRoutePublication,
            execution.acceptedOutput == input.acceptedOutput,
            execution.adapterOutput == input.adapterOutput,
            execution.usage == input.usage else {
        throw WorkflowRuntimeStoreError.messageAppendRejected("staged publication does not match persisted metadata")
      }
      return WorkflowPublicationStageResult(
        session: projectBackendLiveTails(on: session),
        execution: projectBackendLiveTail(on: execution)
      )
    }
    guard execution.status == .running else {
      throw WorkflowRuntimeStoreError.messageAppendRejected("cannot stage a terminal step execution")
    }
    let date = clock.now()
    execution.acceptedOutput = input.acceptedOutput
    execution.adapterOutput = input.adapterOutput ?? execution.adapterOutput
    execution.usage = input.usage ?? execution.usage
    execution.pendingRoutePublication = input.pendingRoutePublication
    execution.updatedAt = date
    session.executions[index] = execution
    session.updatedAt = date
    sessions[input.sessionId] = session
    return WorkflowPublicationStageResult(
      session: projectBackendLiveTails(on: session),
      execution: projectBackendLiveTail(on: execution)
    )
  }

  func commitWorkflowPublication(_ input: WorkflowPublicationCommitInput) async throws -> WorkflowPublicationCommitResult {
    guard var session = sessions[input.sessionId] else {
      throw WorkflowRuntimeStoreError.sessionNotFound(input.sessionId)
    }
    guard let index = session.executions.firstIndex(where: { $0.executionId == input.executionId }) else {
      throw WorkflowRuntimeStoreError.stepExecutionNotFound(input.executionId)
    }
    var execution = session.executions[index]
    guard let pending = execution.pendingRoutePublication else {
      guard execution.status == .completed || execution.status == .skipped else {
        throw WorkflowRuntimeStoreError.messageAppendRejected("execution has no pending publication")
      }
      let messages = messagesBySession[input.sessionId, default: []]
        .filter { $0.sourceStepExecutionId == input.executionId }
        .sorted { $0.createdOrder < $1.createdOrder }
      guard committedPublicationMatches(
        input: input,
        session: session,
        execution: execution,
        messages: messages
      ) else {
        throw WorkflowRuntimeStoreError.messageAppendRejected(
          "committed publication does not match retry input"
        )
      }
      return WorkflowPublicationCommitResult(
        session: projectBackendLiveTails(on: session),
        execution: projectBackendLiveTail(on: execution),
        messages: messages
      )
    }
    guard input.messageInputs.allSatisfy({
      $0.workflowExecutionId == input.sessionId && $0.sourceStepExecutionId == input.executionId
    }) else {
      throw WorkflowRuntimeStoreError.messageAppendRejected("publication messages do not match staged execution")
    }
    for message in input.messageInputs {
      if let reason = appendFailurePredicate?(message) {
        throw WorkflowRuntimeStoreError.messageAppendRejected(reason)
      }
    }

    let date = clock.now()
    let messages = try input.messageInputs.map { message in
      createdOrder += 1
      return WorkflowMessageRecord(
        communicationId: try idGenerator.nextCommunicationId(),
        workflowExecutionId: message.workflowExecutionId,
        fromStepId: message.fromStepId,
        toStepId: message.toStepId,
        routingScope: message.routingScope,
        deliveryKind: message.deliveryKind,
        sourceStepExecutionId: message.sourceStepExecutionId,
        transitionCondition: message.transitionCondition,
        payload: message.payload,
        artifactRefs: message.artifactRefs,
        lifecycleStatus: .delivered,
        createdOrder: createdOrder,
        createdAt: date
      )
    }
    messagesBySession[input.sessionId, default: []].append(contentsOf: messages)

    execution.status = pending.intendedSuccessfulStatus
    execution.pendingRoutePublication = nil
    execution.failureReason = nil
    if var acceptedOutput = execution.acceptedOutput {
      acceptedOutput.isRootOutput = input.publishesRootOutput
      execution.acceptedOutput = acceptedOutput
      let findings = WorkflowReviewFindingExtractor.extract(
        from: acceptedOutput,
        sessionId: input.sessionId,
        execution: execution
      )
      if !findings.isEmpty {
        let ids = Set(findings.map(\.id))
        session.reviewFindings.removeAll { ids.contains($0.id) }
        session.reviewFindings.append(contentsOf: findings)
      }
    }
    execution.updatedAt = date
    execution = finalizeBackendLiveTail(on: execution)
    session.executions[index] = execution
    session.currentStepId = input.currentStepId
    session.updatedAt = date
    if input.publishesRootOutput || input.completesRootWithoutOutput {
      session.status = .completed
    } else {
      session.status = .running
    }
    sessions[input.sessionId] = session
    return WorkflowPublicationCommitResult(
      session: projectBackendLiveTails(on: session),
      execution: execution,
      messages: messages
    )
  }

  func abortWorkflowPublication(_ input: WorkflowPublicationAbortInput) async throws -> WorkflowStepExecution {
    guard var session = sessions[input.sessionId] else {
      throw WorkflowRuntimeStoreError.sessionNotFound(input.sessionId)
    }
    guard let index = session.executions.firstIndex(where: { $0.executionId == input.executionId }) else {
      throw WorkflowRuntimeStoreError.stepExecutionNotFound(input.executionId)
    }
    let date = clock.now()
    var execution = session.executions[index]
    execution.status = .failed
    execution.acceptedOutput = nil
    execution.pendingRoutePublication = nil
    execution.failureReason = input.reason
    execution.updatedAt = date
    execution = finalizeBackendLiveTail(on: execution)
    session.executions[index] = execution
    session.status = .failed
    session.failureReason = input.reason
    session.updatedAt = date
    sessions[input.sessionId] = session
    return execution
  }

  func redirectPendingWorkflowStep(_ input: WorkflowPendingStepRedirectInput) async throws -> WorkflowPendingStepRedirectResult {
    guard var session = sessions[input.sessionId] else {
      throw WorkflowRuntimeStoreError.sessionNotFound(input.sessionId)
    }
    guard session.currentStepId == input.expectedCurrentStepId else {
      throw WorkflowRuntimeStoreError.messageAppendRejected("pending step changed before terminal redirect")
    }
    guard input.replacementMessage.workflowExecutionId == input.sessionId else {
      throw WorkflowRuntimeStoreError.messageAppendRejected("replacement message belongs to another session")
    }
    var storedMessages = messagesBySession[input.sessionId, default: []]
    let displacedIds = Set(input.displacedCommunicationIds)
    let displacedIndices = storedMessages.indices.filter { displacedIds.contains(storedMessages[$0].communicationId) }
    guard displacedIndices.count == displacedIds.count,
          displacedIndices.allSatisfy({
            storedMessages[$0].lifecycleStatus == .delivered &&
              storedMessages[$0].toStepId == input.expectedCurrentStepId
          }) else {
      throw WorkflowRuntimeStoreError.messageAppendRejected("displaced messages are stale or foreign")
    }
    if let reason = appendFailurePredicate?(input.replacementMessage) {
      throw WorkflowRuntimeStoreError.messageAppendRejected(reason)
    }
    for index in displacedIndices {
      storedMessages[index].lifecycleStatus = .superseded
    }
    let date = clock.now()
    createdOrder += 1
    let replacement = WorkflowMessageRecord(
      communicationId: try idGenerator.nextCommunicationId(),
      workflowExecutionId: input.replacementMessage.workflowExecutionId,
      fromStepId: input.replacementMessage.fromStepId,
      toStepId: input.replacementMessage.toStepId,
      routingScope: input.replacementMessage.routingScope,
      deliveryKind: input.replacementMessage.deliveryKind,
      sourceStepExecutionId: input.replacementMessage.sourceStepExecutionId,
      transitionCondition: input.replacementMessage.transitionCondition,
      payload: input.replacementMessage.payload,
      artifactRefs: input.replacementMessage.artifactRefs,
      lifecycleStatus: .delivered,
      createdOrder: createdOrder,
      createdAt: date
    )
    storedMessages.append(replacement)
    messagesBySession[input.sessionId] = storedMessages
    session.currentStepId = input.replacementMessage.toStepId
    session.updatedAt = date
    sessions[input.sessionId] = session
    return WorkflowPendingStepRedirectResult(
      session: projectBackendLiveTails(on: session),
      replacementMessage: replacement
    )
  }
}

private func committedPublicationMatches(
  input: WorkflowPublicationCommitInput,
  session: WorkflowSession,
  execution: WorkflowStepExecution,
  messages: [WorkflowMessageRecord]
) -> Bool {
  guard input.currentStepId == session.currentStepId,
        input.publishesRootOutput == (execution.acceptedOutput?.isRootOutput == true),
        input.completesRootWithoutOutput == (
          session.status == .completed &&
            execution.acceptedOutput?.isRootOutput != true &&
            session.currentStepId == nil &&
            messages.isEmpty
        ),
        input.messageInputs.count == messages.count else {
    return false
  }
  return zip(input.messageInputs, messages).allSatisfy { candidate, persisted in
    candidate.workflowExecutionId == persisted.workflowExecutionId &&
      candidate.fromStepId == persisted.fromStepId &&
      candidate.toStepId == persisted.toStepId &&
      candidate.routingScope == persisted.routingScope &&
      candidate.deliveryKind == persisted.deliveryKind &&
      candidate.sourceStepExecutionId == persisted.sourceStepExecutionId &&
      candidate.transitionCondition == persisted.transitionCondition &&
      candidate.payload == persisted.payload &&
      candidate.artifactRefs == persisted.artifactRefs &&
      persisted.lifecycleStatus == .delivered
  }
}
