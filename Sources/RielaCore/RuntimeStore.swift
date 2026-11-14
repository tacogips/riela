import Foundation

public protocol WorkflowRuntimeClock: Sendable {
  func now() -> Date
}

public struct SystemWorkflowRuntimeClock: WorkflowRuntimeClock {
  public init() {}

  public func now() -> Date {
    Date()
  }
}

public struct FixedWorkflowRuntimeClock: WorkflowRuntimeClock {
  public var fixedDate: Date

  public init(_ fixedDate: Date) {
    self.fixedDate = fixedDate
  }

  public func now() -> Date {
    fixedDate
  }
}

public protocol WorkflowRuntimeIDGenerating: Sendable {
  func nextSessionId(workflowId: String) throws -> String
  func nextStepExecutionId(stepId: String, attempt: Int) throws -> String
  func nextCommunicationId() throws -> String
  func noteExistingSessionId(_ sessionId: String, workflowId: String)
  func noteExistingCommunicationId(_ communicationId: String)
}

extension WorkflowRuntimeIDGenerating {
  public func noteExistingSessionId(_ sessionId: String, workflowId: String) {}
  public func noteExistingCommunicationId(_ communicationId: String) {}
}

public final class MonotonicWorkflowRuntimeIDGenerator: WorkflowRuntimeIDGenerating, @unchecked Sendable {
  private let lock = NSLock()
  private var sessionCounter = 0
  private var executionCounter = 0
  private var communicationCounter = 0

  public init() {}

  public func nextSessionId(workflowId: String) throws -> String {
    lock.lock()
    defer { lock.unlock() }
    sessionCounter += 1
    return "\(workflowId)-session-\(sessionCounter)"
  }

  public func nextStepExecutionId(stepId: String, attempt: Int) throws -> String {
    lock.lock()
    defer { lock.unlock() }
    executionCounter += 1
    return "\(stepId)-attempt-\(attempt)-exec-\(executionCounter)"
  }

  public func nextCommunicationId() throws -> String {
    lock.lock()
    defer { lock.unlock() }
    communicationCounter += 1
    return "comm-\(String(format: "%06d", communicationCounter))"
  }

  public func noteExistingSessionId(_ sessionId: String, workflowId: String) {
    lock.lock()
    defer { lock.unlock() }
    let prefix = "\(workflowId)-session-"
    guard sessionId.hasPrefix(prefix) else {
      return
    }
    let suffix = sessionId.dropFirst(prefix.count)
    guard let parsed = Int(suffix) else {
      return
    }
    sessionCounter = max(sessionCounter, parsed)
  }

  public func noteExistingCommunicationId(_ communicationId: String) {
    lock.lock()
    defer { lock.unlock() }
    let prefix = "comm-"
    guard communicationId.hasPrefix(prefix) else {
      return
    }
    let suffix = communicationId.dropFirst(prefix.count)
    guard let parsed = Int(suffix) else {
      return
    }
    communicationCounter = max(communicationCounter, parsed)
  }
}

public struct WorkflowSessionCreateInput: Equatable, Sendable {
  public var workflowId: String
  public var entryStepId: String
  public var effectiveInstance: EffectiveWorkflowInstance?

  public init(
    workflowId: String,
    entryStepId: String,
    effectiveInstance: EffectiveWorkflowInstance? = nil
  ) {
    self.workflowId = workflowId
    self.entryStepId = entryStepId
    self.effectiveInstance = effectiveInstance
  }
}

public struct WorkflowStepExecutionRecordInput: Equatable, Sendable {
  public var sessionId: String
  public var stepId: String
  public var nodeId: String
  public var attempt: Int
  public var backend: NodeExecutionBackend?

  public init(sessionId: String, stepId: String, nodeId: String, attempt: Int, backend: NodeExecutionBackend? = nil) {
    self.sessionId = sessionId
    self.stepId = stepId
    self.nodeId = nodeId
    self.attempt = attempt
    self.backend = backend
  }
}

public struct WorkflowStepExecutionUpdateInput: Equatable, Sendable {
  public var sessionId: String
  public var executionId: String
  public var status: WorkflowStepExecutionStatus
  public var acceptedOutput: WorkflowAcceptedOutputMetadata?
  public var adapterOutput: WorkflowAdapterOutputMetadata?
  public var failureReason: String?
  public var usage: AdapterUsage?
  public var completesRootWithoutOutput: Bool
  public var currentStepId: String?
  public var pendingRoutePublication: WorkflowPendingRoutePublication?

  public init(
    sessionId: String,
    executionId: String,
    status: WorkflowStepExecutionStatus,
    acceptedOutput: WorkflowAcceptedOutputMetadata? = nil,
    adapterOutput: WorkflowAdapterOutputMetadata? = nil,
    failureReason: String? = nil,
    usage: AdapterUsage? = nil,
    completesRootWithoutOutput: Bool = false,
    currentStepId: String? = nil,
    pendingRoutePublication: WorkflowPendingRoutePublication? = nil
  ) {
    self.sessionId = sessionId
    self.executionId = executionId
    self.status = status
    self.acceptedOutput = acceptedOutput
    self.adapterOutput = adapterOutput
    self.failureReason = failureReason
    self.usage = usage
    self.completesRootWithoutOutput = completesRootWithoutOutput
    self.currentStepId = currentStepId
    self.pendingRoutePublication = pendingRoutePublication
  }
}

public struct WorkflowSessionFailureInput: Equatable, Sendable {
  public var sessionId: String
  public var reason: String
  public var failureKind: WorkflowSessionFailureKind?
  public var failedAt: Date?
  public var stepBudgetDiagnostic: WorkflowStepBudgetDiagnostic?

  public init(
    sessionId: String,
    reason: String,
    failureKind: WorkflowSessionFailureKind? = nil,
    failedAt: Date? = nil,
    stepBudgetDiagnostic: WorkflowStepBudgetDiagnostic? = nil
  ) {
    self.sessionId = sessionId
    self.reason = reason
    self.failureKind = failureKind
    self.failedAt = failedAt
    self.stepBudgetDiagnostic = stepBudgetDiagnostic
  }
}

public struct WorkflowStepBackendEventInput: Equatable, Sendable {
  public var sessionId: String
  public var executionId: String
  public var eventType: String
  public var channel: AdapterBackendEventChannel?
  public var contentDelta: String?
  public var contentSnapshot: String?
  public var isDelta: Bool
  public var toolName: String?
  public var usage: JSONObject?
  public var sequence: Int?
  public var at: Date?

  public init(
    sessionId: String,
    executionId: String,
    eventType: String,
    channel: AdapterBackendEventChannel? = nil,
    contentDelta: String? = nil,
    contentSnapshot: String? = nil,
    isDelta: Bool = false,
    toolName: String? = nil,
    usage: JSONObject? = nil,
    sequence: Int? = nil,
    at: Date? = nil
  ) {
    self.sessionId = sessionId
    self.executionId = executionId
    self.eventType = eventType
    self.channel = channel
    self.contentDelta = contentDelta
    self.contentSnapshot = contentSnapshot
    self.isDelta = isDelta
    self.toolName = toolName
    self.usage = usage
    self.sequence = sequence
    self.at = at
  }
}

public struct WorkflowBackendEventReceipt: Equatable, Sendable {
  public var executionId: String
  public var sequence: Int?
  public var at: Date?

  public init(executionId: String, sequence: Int?, at: Date?) {
    self.executionId = executionId
    self.sequence = sequence
    self.at = at
  }
}

public struct WorkflowMessageAppendInput: Equatable, Sendable {
  public var workflowExecutionId: String
  public var fromStepId: String?
  public var toStepId: String?
  public var routingScope: WorkflowMessageRoutingScope
  public var deliveryKind: WorkflowMessageDeliveryKind
  public var sourceStepExecutionId: String
  public var transitionCondition: String?
  public var payload: JSONObject
  public var artifactRefs: [String]

  public init(
    workflowExecutionId: String,
    fromStepId: String?,
    toStepId: String?,
    routingScope: WorkflowMessageRoutingScope = .workflow,
    deliveryKind: WorkflowMessageDeliveryKind = .direct,
    sourceStepExecutionId: String,
    transitionCondition: String? = nil,
    payload: JSONObject,
    artifactRefs: [String] = []
  ) {
    self.workflowExecutionId = workflowExecutionId
    self.fromStepId = fromStepId
    self.toStepId = toStepId
    self.routingScope = routingScope
    self.deliveryKind = deliveryKind
    self.sourceStepExecutionId = sourceStepExecutionId
    self.transitionCondition = transitionCondition
    self.payload = payload
    self.artifactRefs = artifactRefs
  }
}

public enum WorkflowRuntimeStoreError: Error, Equatable, Sendable {
  case sessionNotFound(String)
  case stepExecutionNotFound(String)
  case messageAppendRejected(String)
}

public protocol WorkflowRuntimeStore: Sendable {
  func createSession(_ input: WorkflowSessionCreateInput) async throws -> WorkflowSession
  func recordStepExecution(_ input: WorkflowStepExecutionRecordInput) async throws -> WorkflowStepExecution
  func updateStepExecution(_ input: WorkflowStepExecutionUpdateInput) async throws -> WorkflowStepExecution
  func stageWorkflowPublication(_ input: WorkflowPublicationStageInput) async throws -> WorkflowPublicationStageResult
  func commitWorkflowPublication(_ input: WorkflowPublicationCommitInput) async throws -> WorkflowPublicationCommitResult
  func abortWorkflowPublication(_ input: WorkflowPublicationAbortInput) async throws -> WorkflowStepExecution
  func redirectPendingWorkflowStep(_ input: WorkflowPendingStepRedirectInput) async throws -> WorkflowPendingStepRedirectResult
  func markSessionFailed(_ input: WorkflowSessionFailureInput) async throws -> WorkflowSession
  func recordStepBackendEvent(_ input: WorkflowStepBackendEventInput) async throws -> WorkflowStepExecution
  func recordStepBackendEventReceipt(_ input: WorkflowStepBackendEventInput) async throws -> WorkflowBackendEventReceipt
  func appendWorkflowMessage(_ input: WorkflowMessageAppendInput) async throws -> WorkflowMessageRecord
  func appendWorkflowMessages(_ inputs: [WorkflowMessageAppendInput]) async throws -> [WorkflowMessageRecord]
  func listMessages(for sessionId: String, toStepId: String?) async throws -> [WorkflowMessageRecord]
  func loadSession(id: String) async throws -> WorkflowSession?
}

public extension WorkflowRuntimeStore {
  func recordStepBackendEventReceipt(_ input: WorkflowStepBackendEventInput) async throws -> WorkflowBackendEventReceipt {
    let execution = try await recordStepBackendEvent(input)
    return WorkflowBackendEventReceipt(
      executionId: execution.executionId,
      sequence: execution.backendEventCount,
      at: execution.lastBackendEventAt
    )
  }
}

public actor InMemoryWorkflowRuntimeStore: WorkflowRuntimeStore {
  public typealias AppendFailurePredicate = @Sendable (WorkflowMessageAppendInput) -> String?

  let clock: any WorkflowRuntimeClock
  let idGenerator: any WorkflowRuntimeIDGenerating
  let appendFailurePredicate: AppendFailurePredicate?
  var sessions: [String: WorkflowSession] = [:]
  private var executionLiveTails: [String: WorkflowExecutionLiveTail] = [:]
  var messagesBySession: [String: [WorkflowMessageRecord]] = [:]
  var createdOrder = 0

  public init(
    clock: any WorkflowRuntimeClock = SystemWorkflowRuntimeClock(),
    idGenerator: any WorkflowRuntimeIDGenerating = MonotonicWorkflowRuntimeIDGenerator(),
    appendFailurePredicate: AppendFailurePredicate? = nil
  ) {
    self.clock = clock
    self.idGenerator = idGenerator
    self.appendFailurePredicate = appendFailurePredicate
  }

  public func seedSession(_ session: WorkflowSession) {
    idGenerator.noteExistingSessionId(session.sessionId, workflowId: session.workflowId)
    sessions[session.sessionId] = detachingBackendLiveTails(from: session)
    if messagesBySession[session.sessionId] == nil {
      messagesBySession[session.sessionId] = []
    }
  }

  public func seedWorkflowMessages(_ messages: [WorkflowMessageRecord]) {
    for message in messages {
      idGenerator.noteExistingCommunicationId(message.communicationId)
      createdOrder = max(createdOrder, message.createdOrder)
      messagesBySession[message.workflowExecutionId, default: []].append(message)
    }
    for sessionId in Array(messagesBySession.keys) {
      messagesBySession[sessionId]?.sort { $0.createdOrder < $1.createdOrder }
    }
  }

  public func latestSession(workflowId: String) -> WorkflowSession? {
    let latest = sessions.values
      .filter { $0.workflowId == workflowId }
      .sorted { $0.createdAt < $1.createdAt }
      .last
    return latest.map(projectBackendLiveTails(on:))
  }

  public func createSession(_ input: WorkflowSessionCreateInput) async throws -> WorkflowSession {
    let date = clock.now()
    let sessionId = try idGenerator.nextSessionId(workflowId: input.workflowId)
    let session = WorkflowSession(
      workflowId: input.workflowId,
      sessionId: sessionId,
      status: .created,
      entryStepId: input.entryStepId,
      currentStepId: input.entryStepId,
      createdAt: date,
      updatedAt: date,
      instanceIdentity: input.effectiveInstance?.identity,
      instanceKind: input.effectiveInstance?.kind.rawValue,
      instanceBaseIdentity: input.effectiveInstance?.baseIdentity,
      instanceConfiguration: input.effectiveInstance?.configurationJSONObject
    )
    sessions[sessionId] = session
    messagesBySession[sessionId] = []
    return session
  }

  public func recordStepExecution(_ input: WorkflowStepExecutionRecordInput) async throws -> WorkflowStepExecution {
    guard var session = sessions[input.sessionId] else {
      throw WorkflowRuntimeStoreError.sessionNotFound(input.sessionId)
    }
    let date = clock.now()
    let execution = WorkflowStepExecution(
      executionId: try idGenerator.nextStepExecutionId(stepId: input.stepId, attempt: input.attempt),
      stepId: input.stepId,
      nodeId: input.nodeId,
      attempt: input.attempt,
      backend: input.backend,
      status: .running,
      createdAt: date,
      updatedAt: date
    )
    session.status = .running
    session.currentStepId = input.stepId
    session.updatedAt = date
    session.failureReason = nil
    session.failureKind = nil
    session.failedAt = nil
    session.stepBudgetDiagnostic = nil
    session.executions.append(execution)
    sessions[input.sessionId] = session
    return execution
  }

  public func updateStepExecution(_ input: WorkflowStepExecutionUpdateInput) async throws -> WorkflowStepExecution {
    guard var session = sessions[input.sessionId] else {
      throw WorkflowRuntimeStoreError.sessionNotFound(input.sessionId)
    }
    guard let index = session.executions.firstIndex(where: { $0.executionId == input.executionId }) else {
      throw WorkflowRuntimeStoreError.stepExecutionNotFound(input.executionId)
    }

    let date = clock.now()
    var execution = session.executions[index]
    execution.status = input.status
    execution.acceptedOutput = input.acceptedOutput
    execution.adapterOutput = input.adapterOutput ?? execution.adapterOutput
    execution.failureReason = input.failureReason
    execution.usage = input.usage ?? execution.usage
    execution.pendingRoutePublication = input.pendingRoutePublication
    execution.updatedAt = date
    if let acceptedOutput = input.acceptedOutput {
      let extractedFindings = WorkflowReviewFindingExtractor.extract(
        from: acceptedOutput,
        sessionId: input.sessionId,
        execution: execution
      )
      if !extractedFindings.isEmpty {
        let extractedIds = Set(extractedFindings.map(\.id))
        session.reviewFindings.removeAll { extractedIds.contains($0.id) }
        session.reviewFindings.append(contentsOf: extractedFindings)
      }
    }
    session.executions[index] = execution
    session.updatedAt = date
    switch input.status {
    case .failed:
      session.status = .failed
    case .completed where input.acceptedOutput?.isRootOutput == true || input.completesRootWithoutOutput:
      session.status = .completed
    case .skipped where input.completesRootWithoutOutput:
      session.status = .completed
    case .completed, .running, .skipped:
      session.status = .running
    }
    if let currentStepId = input.currentStepId {
      session.currentStepId = currentStepId
    }
    let returnedExecution: WorkflowStepExecution
    if execution.status.isTerminal {
      returnedExecution = finalizeBackendLiveTail(on: execution)
      session.executions[index] = returnedExecution
    } else {
      session.executions[index] = execution.withoutBackendLiveTail()
      returnedExecution = projectBackendLiveTail(on: execution)
    }
    sessions[input.sessionId] = session
    return returnedExecution
  }

  public func markSessionFailed(_ input: WorkflowSessionFailureInput) async throws -> WorkflowSession {
    guard var session = sessions[input.sessionId] else {
      throw WorkflowRuntimeStoreError.sessionNotFound(input.sessionId)
    }

    let date = clock.now()
    session.status = .failed
    session.updatedAt = date
    session.failureReason = input.reason
    session.failureKind = input.failureKind
    session.failedAt = input.failedAt ?? date
    session.stepBudgetDiagnostic = input.stepBudgetDiagnostic
    session.executions = session.executions.map { execution in
      guard execution.status == .running else {
        return execution
      }
      var failedExecution = execution
      failedExecution.status = .failed
      failedExecution.failureReason = input.reason
      failedExecution.updatedAt = date
      return finalizeBackendLiveTail(on: failedExecution)
    }
    sessions[input.sessionId] = session
    return projectBackendLiveTails(on: session)
  }

  public func recordStepBackendEvent(_ input: WorkflowStepBackendEventInput) async throws -> WorkflowStepExecution {
    _ = try recordStepBackendEventReceiptLocked(input)
    guard let session = sessions[input.sessionId],
          let index = session.executions.firstIndex(where: { $0.executionId == input.executionId }) else {
      throw WorkflowRuntimeStoreError.stepExecutionNotFound(input.executionId)
    }
    return projectBackendLiveTail(on: session.executions[index])
  }

  public func recordStepBackendEventReceipt(_ input: WorkflowStepBackendEventInput) async throws -> WorkflowBackendEventReceipt {
    try recordStepBackendEventReceiptLocked(input)
  }

  private func recordStepBackendEventReceiptLocked(_ input: WorkflowStepBackendEventInput) throws -> WorkflowBackendEventReceipt {
    guard let session = sessions[input.sessionId] else {
      throw WorkflowRuntimeStoreError.sessionNotFound(input.sessionId)
    }
    guard let index = session.executions.firstIndex(where: { $0.executionId == input.executionId }) else {
      throw WorkflowRuntimeStoreError.stepExecutionNotFound(input.executionId)
    }
    let execution = projectBackendLiveTail(on: session.executions[index])
    guard execution.status == .running else {
      return WorkflowBackendEventReceipt(
        executionId: execution.executionId,
        sequence: execution.backendEventCount,
        at: execution.lastBackendEventAt
      )
    }

    let date = input.at ?? clock.now()
    var liveTail = executionLiveTails[input.executionId] ?? WorkflowExecutionLiveTail(execution: execution)
    let sequence = input.sequence ?? ((liveTail.backendEventCount ?? 0) + 1)
    liveTail.lastBackendEventAt = date
    liveTail.lastBackendEventType = input.eventType
    liveTail.backendEventCount = sequence
    appendRecentBackendEvent(to: &liveTail, input: input, sequence: sequence, date: date)
    updateStreamedResponseText(on: &liveTail, input: input)
    executionLiveTails[input.executionId] = liveTail
    return WorkflowBackendEventReceipt(
      executionId: input.executionId,
      sequence: sequence,
      at: date
    )
  }

  private func appendRecentBackendEvent(
    to liveTail: inout WorkflowExecutionLiveTail,
    input: WorkflowStepBackendEventInput,
    sequence: Int,
    date: Date
  ) {
    var events = liveTail.recentBackendEvents ?? []
    events.append(WorkflowBackendEventRecord(
      sequence: sequence,
      at: date,
      eventType: input.eventType,
      channel: input.channel,
      content: input.contentSnapshot ?? input.contentDelta,
      toolName: input.toolName,
      usage: input.usage
    ))
    if events.count > 100 {
      events.removeFirst(events.count - 100)
    }
    liveTail.recentBackendEvents = events
  }

  private func updateStreamedResponseText(
    on liveTail: inout WorkflowExecutionLiveTail,
    input: WorkflowStepBackendEventInput
  ) {
    guard input.channel == .assistant else {
      return
    }
    if let snapshot = input.contentSnapshot {
      liveTail.setStreamedResponseText(snapshot, byteCap: WorkflowStreamedResponseText.byteCap)
      return
    }
    guard let delta = input.contentDelta else {
      return
    }
    liveTail.appendStreamedResponseText(delta, byteCap: WorkflowStreamedResponseText.byteCap)
  }

  public func appendWorkflowMessage(_ input: WorkflowMessageAppendInput) async throws -> WorkflowMessageRecord {
    let records = try await appendWorkflowMessages([input])
    guard let record = records.first else {
      throw WorkflowRuntimeStoreError.messageAppendRejected("empty append")
    }
    return record
  }

  public func appendWorkflowMessages(_ inputs: [WorkflowMessageAppendInput]) async throws -> [WorkflowMessageRecord] {
    guard let firstInput = inputs.first else {
      return []
    }
    guard sessions[firstInput.workflowExecutionId] != nil else {
      throw WorkflowRuntimeStoreError.sessionNotFound(firstInput.workflowExecutionId)
    }
    for input in inputs {
      guard input.workflowExecutionId == firstInput.workflowExecutionId else {
        throw WorkflowRuntimeStoreError.sessionNotFound(input.workflowExecutionId)
      }
      if let reason = appendFailurePredicate?(input) {
        throw WorkflowRuntimeStoreError.messageAppendRejected(reason)
      }
    }

    var records: [WorkflowMessageRecord] = []
    for input in inputs {
      createdOrder += 1
      records.append(
        WorkflowMessageRecord(
          communicationId: try idGenerator.nextCommunicationId(),
          workflowExecutionId: input.workflowExecutionId,
          fromStepId: input.fromStepId,
          toStepId: input.toStepId,
          routingScope: input.routingScope,
          deliveryKind: input.deliveryKind,
          sourceStepExecutionId: input.sourceStepExecutionId,
          transitionCondition: input.transitionCondition,
          payload: input.payload,
          artifactRefs: input.artifactRefs,
          lifecycleStatus: .delivered,
          createdOrder: createdOrder,
          createdAt: clock.now()
        )
      )
    }
    messagesBySession[firstInput.workflowExecutionId, default: []].append(contentsOf: records)
    if var session = sessions[firstInput.workflowExecutionId] {
      session.updatedAt = records.last?.createdAt ?? session.updatedAt
      sessions[firstInput.workflowExecutionId] = session
    }
    return records
  }

  public func listMessages(for sessionId: String, toStepId: String?) async throws -> [WorkflowMessageRecord] {
    guard sessions[sessionId] != nil else {
      throw WorkflowRuntimeStoreError.sessionNotFound(sessionId)
    }
    let messages = messagesBySession[sessionId, default: []]
    guard let toStepId else {
      return messages.sorted { $0.createdOrder < $1.createdOrder }
    }
    return messages.filter { $0.toStepId == toStepId }.sorted { $0.createdOrder < $1.createdOrder }
  }

  public func loadSession(id: String) async throws -> WorkflowSession? {
    sessions[id].map(projectBackendLiveTails(on:))
  }

  func executionLiveTailCountForTesting() -> Int {
    executionLiveTails.count
  }

  private func detachingBackendLiveTails(from session: WorkflowSession) -> WorkflowSession {
    var detached = session
    detached.executions = session.executions.map { execution in
      guard execution.status == .running else {
        return execution
      }
      let liveTail = WorkflowExecutionLiveTail(execution: execution)
      if !liveTail.isEmpty {
        executionLiveTails[execution.executionId] = liveTail
      }
      return execution.withoutBackendLiveTail()
    }
    return detached
  }

  func projectBackendLiveTails(on session: WorkflowSession) -> WorkflowSession {
    var projected = session
    projected.executions = session.executions.map(projectBackendLiveTail(on:))
    return projected
  }

  func projectBackendLiveTail(on execution: WorkflowStepExecution) -> WorkflowStepExecution {
    executionLiveTails[execution.executionId]?.applying(to: execution) ?? execution
  }

  func finalizeBackendLiveTail(on execution: WorkflowStepExecution) -> WorkflowStepExecution {
    let finalized = projectBackendLiveTail(on: execution)
    executionLiveTails.removeValue(forKey: execution.executionId)
    return finalized
  }
}

private enum WorkflowStreamedResponseText {
  static let byteCap = 32 * 1024
}

private extension WorkflowStepExecutionStatus {
  var isTerminal: Bool {
    switch self {
    case .completed, .failed, .skipped:
      return true
    case .running:
      return false
    }
  }
}

private struct WorkflowExecutionLiveTail: Sendable {
  var lastBackendEventAt: Date?
  var lastBackendEventType: String?
  var backendEventCount: Int?
  var recentBackendEvents: [WorkflowBackendEventRecord]?
  var streamedResponseTextBuffer: StreamedResponseTextBuffer?

  init(execution: WorkflowStepExecution) {
    self.lastBackendEventAt = execution.lastBackendEventAt
    self.lastBackendEventType = execution.lastBackendEventType
    self.backendEventCount = execution.backendEventCount
    self.recentBackendEvents = execution.recentBackendEvents
    self.streamedResponseTextBuffer = execution.streamedResponseText.map {
      StreamedResponseTextBuffer(text: $0, byteCap: WorkflowStreamedResponseText.byteCap)
    }
  }

  var isEmpty: Bool {
    lastBackendEventAt == nil
      && lastBackendEventType == nil
      && backendEventCount == nil
      && recentBackendEvents == nil
      && streamedResponseTextBuffer == nil
  }

  mutating func setStreamedResponseText(_ text: String, byteCap: Int) {
    streamedResponseTextBuffer = StreamedResponseTextBuffer(text: text, byteCap: byteCap)
  }

  mutating func appendStreamedResponseText(_ delta: String, byteCap: Int) {
    var buffer = streamedResponseTextBuffer ?? StreamedResponseTextBuffer(byteCap: byteCap)
    buffer.append(delta, byteCap: byteCap)
    streamedResponseTextBuffer = buffer
  }

  func applying(to execution: WorkflowStepExecution) -> WorkflowStepExecution {
    var projected = execution
    projected.lastBackendEventAt = lastBackendEventAt
    projected.lastBackendEventType = lastBackendEventType
    projected.backendEventCount = backendEventCount
    projected.recentBackendEvents = recentBackendEvents
    projected.streamedResponseText = streamedResponseTextBuffer?.stringValue(byteCap: WorkflowStreamedResponseText.byteCap)
    return projected
  }
}

private struct StreamedResponseTextBuffer: Sendable {
  private var uncappedText: String?
  private var prefixBytes: [UInt8] = []
  private var suffixBytes: [UInt8] = []

  init(byteCap: Int) {
    uncappedText = ""
    prefixBytes.reserveCapacity(byteCap / 2)
    suffixBytes.reserveCapacity(byteCap - (byteCap / 2))
  }

  init(text: String, byteCap: Int) {
    self.init(byteCap: byteCap)
    set(text, byteCap: byteCap)
  }

  mutating func set(_ text: String, byteCap: Int) {
    guard text.utf8.count > byteCap else {
      uncappedText = text
      prefixBytes.removeAll(keepingCapacity: true)
      suffixBytes.removeAll(keepingCapacity: true)
      return
    }
    uncappedText = nil
    let prefixCap = byteCap / 2
    let suffixCap = byteCap - prefixCap
    prefixBytes = Self.prefixBytes(from: text, limit: prefixCap)
    suffixBytes = Self.suffixBytes(from: text, limit: suffixCap)
  }

  mutating func append(_ delta: String, byteCap: Int) {
    guard !delta.isEmpty else {
      return
    }
    if let current = uncappedText {
      guard current.utf8.count + delta.utf8.count > byteCap else {
        uncappedText = current + delta
        return
      }
      set(current + delta, byteCap: byteCap)
      return
    }

    let prefixCap = byteCap / 2
    let suffixCap = byteCap - prefixCap
    if prefixBytes.isEmpty {
      prefixBytes.reserveCapacity(prefixCap)
    }
    suffixBytes.append(contentsOf: delta.utf8)
    if suffixBytes.count > suffixCap {
      suffixBytes.removeFirst(suffixBytes.count - suffixCap)
    }
  }

  func stringValue(byteCap: Int) -> String {
    if let uncappedText {
      return uncappedText
    }
    let value = Self.utf8String(from: prefixBytes)
      + Self.utf8String(from: Self.dropLeadingContinuationBytes(suffixBytes))
    guard value.utf8.count > byteCap else {
      return value
    }
    return Self.byteBoundPrefix(value, limit: byteCap)
  }

  private static func prefixBytes(from text: String, limit: Int) -> [UInt8] {
    var output: [UInt8] = []
    output.reserveCapacity(limit)
    for character in text {
      let bytes = character.utf8
      guard output.count + bytes.count <= limit else {
        break
      }
      output.append(contentsOf: bytes)
    }
    return output
  }

  private static func suffixBytes(from text: String, limit: Int) -> [UInt8] {
    var chunks: [[UInt8]] = []
    chunks.reserveCapacity(limit)
    var bytes = 0
    for character in text.reversed() {
      let characterBytes = Array(character.utf8)
      guard bytes + characterBytes.count <= limit else {
        break
      }
      chunks.append(characterBytes)
      bytes += characterBytes.count
    }
    return chunks.reversed().flatMap { $0 }
  }

  private static func dropLeadingContinuationBytes(_ bytes: [UInt8]) -> [UInt8] {
    var index = bytes.startIndex
    while index < bytes.endIndex, bytes[index] & 0b1100_0000 == 0b1000_0000 {
      index = bytes.index(after: index)
    }
    return Array(bytes[index...])
  }

  private static func utf8String(from bytes: [UInt8]) -> String {
    String(data: Data(bytes), encoding: .utf8) ?? ""
  }

  private static func byteBoundPrefix(_ text: String, limit: Int) -> String {
    var prefix = ""
    prefix.reserveCapacity(limit)
    var bytes = 0
    for character in text {
      let characterBytes = character.utf8.count
      guard bytes + characterBytes <= limit else {
        break
      }
      prefix.append(character)
      bytes += characterBytes
    }
    return prefix
  }
}

private extension WorkflowStepExecution {
  func withoutBackendLiveTail() -> WorkflowStepExecution {
    var execution = self
    execution.lastBackendEventAt = nil
    execution.lastBackendEventType = nil
    execution.backendEventCount = nil
    execution.recentBackendEvents = nil
    execution.streamedResponseText = nil
    return execution
  }
}
