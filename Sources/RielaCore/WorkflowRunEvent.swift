import Foundation

public enum WorkflowRunEventType: String, Codable, Equatable, Sendable {
  case sessionStarted = "session_started"
  case stepStarted = "step_started"
  case backendEvent = "backend_event"
  case silenceWarning = "silence_warning"
  case loopStall = "loop_stall"
  case budgetExceeded = "budget_exceeded"
  case stepCompleted = "step_completed"
  case sessionCompleted = "session_completed"
}

public struct SessionEnvelope: Codable, Equatable, Sendable {
  public var workflowId: String
  public var sessionId: String
  public var status: WorkflowSessionStatus?
  public var currentStepId: String?

  public init(
    workflowId: String,
    sessionId: String,
    status: WorkflowSessionStatus? = nil,
    currentStepId: String? = nil
  ) {
    self.workflowId = workflowId
    self.sessionId = sessionId
    self.status = status
    self.currentStepId = currentStepId
  }
}

public struct StepEnvelope: Codable, Equatable, Sendable {
  public var stepId: String?
  public var nodeId: String?
  public var executionId: String?
  public var nodeExecutions: Int?

  public init(
    stepId: String? = nil,
    nodeId: String? = nil,
    executionId: String? = nil,
    nodeExecutions: Int? = nil
  ) {
    self.stepId = stepId
    self.nodeId = nodeId
    self.executionId = executionId
    self.nodeExecutions = nodeExecutions
  }
}

public struct BackendEventPayload: Codable, Equatable, Sendable {
  public var backendEventType: String?
  public var backendSessionId: String?
  public var backendEventChannel: String?
  public var backendEventContent: String?
  public var backendEventIsDelta: Bool?
  public var backendEventSequence: Int?
  public var backendToolName: String?
  public var backendEventUsage: JSONObject?
  public var backendEventMetadata: JSONObject?

  public init(
    backendEventType: String? = nil,
    backendSessionId: String? = nil,
    backendEventChannel: String? = nil,
    backendEventContent: String? = nil,
    backendEventIsDelta: Bool? = nil,
    backendEventSequence: Int? = nil,
    backendToolName: String? = nil,
    backendEventUsage: JSONObject? = nil,
    backendEventMetadata: JSONObject? = nil
  ) {
    self.backendEventType = backendEventType
    self.backendSessionId = backendSessionId
    self.backendEventChannel = backendEventChannel
    self.backendEventContent = backendEventContent
    self.backendEventIsDelta = backendEventIsDelta
    self.backendEventSequence = backendEventSequence
    self.backendToolName = backendToolName
    self.backendEventUsage = backendEventUsage
    self.backendEventMetadata = backendEventMetadata
  }
}

public struct StepCompletionPayload: Codable, Equatable, Sendable {
  public var transitions: Int?

  public init(transitions: Int? = nil) {
    self.transitions = transitions
  }
}

public struct SilenceWarningPayload: Codable, Equatable, Sendable {
  public var silentForMs: Int
  public var silenceThresholdMs: Int

  public init(silentForMs: Int, silenceThresholdMs: Int) {
    self.silentForMs = silentForMs
    self.silenceThresholdMs = silenceThresholdMs
  }
}

public struct LoopStallPayload: Codable, Equatable, Sendable {
  public var gateId: String
  public var violationKind: String
  public var action: String
  public var gateVisits: Int
  public var repeatedRounds: Int
  public var fingerprints: [String]
  public var policySource: String?

  public init(
    gateId: String,
    violationKind: String,
    action: String,
    gateVisits: Int,
    repeatedRounds: Int,
    fingerprints: [String] = [],
    policySource: String? = nil
  ) {
    self.gateId = gateId
    self.violationKind = violationKind
    self.action = action
    self.gateVisits = gateVisits
    self.repeatedRounds = repeatedRounds
    self.fingerprints = fingerprints
    self.policySource = policySource
  }
}

public struct LoopBudgetExceededPayload: Codable, Equatable, Sendable {
  public var diagnostic: String
  public var action: String
  public var consumedTokens: Int?
  public var maxTotalTokens: Int?
  public var elapsedMs: Int?
  public var maxWallClockMs: Int?

  public init(
    diagnostic: String,
    action: String,
    consumedTokens: Int? = nil,
    maxTotalTokens: Int? = nil,
    elapsedMs: Int? = nil,
    maxWallClockMs: Int? = nil
  ) {
    self.diagnostic = diagnostic
    self.action = action
    self.consumedTokens = consumedTokens
    self.maxTotalTokens = maxTotalTokens
    self.elapsedMs = elapsedMs
    self.maxWallClockMs = maxWallClockMs
  }
}

public struct SessionCompletionPayload: Codable, Equatable, Sendable {
  public var exitCode: Int32?
  public var nodeExecutions: Int?
  public var transitions: Int?

  public init(
    exitCode: Int32? = nil,
    nodeExecutions: Int? = nil,
    transitions: Int? = nil
  ) {
    self.exitCode = exitCode
    self.nodeExecutions = nodeExecutions
    self.transitions = transitions
  }
}

public enum WorkflowRunEvent: Equatable, Sendable {
  case sessionStarted(SessionEnvelope)
  case stepStarted(SessionEnvelope, StepEnvelope)
  case backendEvent(SessionEnvelope, StepEnvelope, BackendEventPayload)
  case silenceWarning(SessionEnvelope, StepEnvelope, SilenceWarningPayload)
  case loopStall(SessionEnvelope, StepEnvelope, LoopStallPayload)
  case budgetExceeded(SessionEnvelope, StepEnvelope, LoopBudgetExceededPayload)
  case stepCompleted(SessionEnvelope, StepEnvelope, StepCompletionPayload)
  case sessionCompleted(SessionEnvelope, SessionCompletionPayload)

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
    backendSessionId: String? = nil,
    backendEventChannel: String? = nil,
    backendEventContent: String? = nil,
    backendEventIsDelta: Bool? = nil,
    backendEventSequence: Int? = nil,
    backendToolName: String? = nil,
    backendEventUsage: JSONObject? = nil,
    backendEventMetadata: JSONObject? = nil,
    silentForMs: Int? = nil,
    silenceThresholdMs: Int? = nil,
    loopStallGateId: String? = nil,
    loopStallViolationKind: String? = nil,
    loopStallAction: String? = nil,
    loopStallGateVisits: Int? = nil,
    loopStallRepeatedRounds: Int? = nil,
    loopStallFingerprints: [String]? = nil,
    loopStallPolicySource: String? = nil,
    loopBudgetDiagnostic: String? = nil,
    loopBudgetAction: String? = nil,
    loopBudgetConsumedTokens: Int? = nil,
    loopBudgetMaxTotalTokens: Int? = nil,
    loopBudgetElapsedMs: Int? = nil,
    loopBudgetMaxWallClockMs: Int? = nil,
    exitCode: Int32? = nil,
    nodeExecutions: Int? = nil,
    transitions: Int? = nil
  ) {
    let session = SessionEnvelope(
      workflowId: workflowId,
      sessionId: sessionId,
      status: status,
      currentStepId: currentStepId
    )
    let step = StepEnvelope(
      stepId: stepId,
      nodeId: nodeId,
      executionId: executionId,
      nodeExecutions: nodeExecutions
    )
    switch type {
    case .sessionStarted:
      self = .sessionStarted(session)
    case .stepStarted:
      self = .stepStarted(session, step)
    case .backendEvent:
      self = .backendEvent(
        session,
        step,
        BackendEventPayload(
          backendEventType: backendEventType,
          backendSessionId: backendSessionId,
          backendEventChannel: backendEventChannel,
          backendEventContent: backendEventContent,
          backendEventIsDelta: backendEventIsDelta,
          backendEventSequence: backendEventSequence,
          backendToolName: backendToolName,
          backendEventUsage: backendEventUsage,
          backendEventMetadata: backendEventMetadata
        )
      )
    case .silenceWarning:
      self = .silenceWarning(
        session,
        step,
        SilenceWarningPayload(
          silentForMs: silentForMs ?? 0,
          silenceThresholdMs: silenceThresholdMs ?? 0
        )
      )
    case .loopStall:
      self = .loopStall(
        session,
        step,
        LoopStallPayload(
          gateId: loopStallGateId ?? "",
          violationKind: loopStallViolationKind ?? "",
          action: loopStallAction ?? "",
          gateVisits: loopStallGateVisits ?? 0,
          repeatedRounds: loopStallRepeatedRounds ?? 0,
          fingerprints: loopStallFingerprints ?? [],
          policySource: loopStallPolicySource
        )
      )
    case .budgetExceeded:
      self = .budgetExceeded(
        session,
        step,
        LoopBudgetExceededPayload(
          diagnostic: loopBudgetDiagnostic ?? "",
          action: loopBudgetAction ?? "",
          consumedTokens: loopBudgetConsumedTokens,
          maxTotalTokens: loopBudgetMaxTotalTokens,
          elapsedMs: loopBudgetElapsedMs,
          maxWallClockMs: loopBudgetMaxWallClockMs
        )
      )
    case .stepCompleted:
      self = .stepCompleted(session, step, StepCompletionPayload(transitions: transitions))
    case .sessionCompleted:
      self = .sessionCompleted(
        session,
        SessionCompletionPayload(
          exitCode: exitCode,
          nodeExecutions: nodeExecutions,
          transitions: transitions
        )
      )
    }
  }
}

public extension WorkflowRunEvent {
  var type: WorkflowRunEventType {
    switch self {
    case .sessionStarted:
      .sessionStarted
    case .stepStarted:
      .stepStarted
    case .backendEvent:
      .backendEvent
    case .silenceWarning:
      .silenceWarning
    case .loopStall:
      .loopStall
    case .budgetExceeded:
      .budgetExceeded
    case .stepCompleted:
      .stepCompleted
    case .sessionCompleted:
      .sessionCompleted
    }
  }

  var workflowId: String {
    session.workflowId
  }

  var sessionId: String {
    session.sessionId
  }

  var status: WorkflowSessionStatus? {
    session.status
  }

  var currentStepId: String? {
    session.currentStepId
  }

  var stepId: String? {
    step?.stepId
  }

  var nodeId: String? {
    step?.nodeId
  }

  var executionId: String? {
    step?.executionId
  }

  var backendEventType: String? {
    backendEventPayload?.backendEventType
  }

  var backendSessionId: String? {
    backendEventPayload?.backendSessionId
  }

  var backendEventChannel: String? {
    backendEventPayload?.backendEventChannel
  }

  var backendEventContent: String? {
    backendEventPayload?.backendEventContent
  }

  var backendEventIsDelta: Bool? {
    backendEventPayload?.backendEventIsDelta
  }

  var backendEventSequence: Int? {
    backendEventPayload?.backendEventSequence
  }

  var backendToolName: String? {
    backendEventPayload?.backendToolName
  }

  var backendEventUsage: JSONObject? {
    backendEventPayload?.backendEventUsage
  }

  var backendEventMetadata: JSONObject? {
    backendEventPayload?.backendEventMetadata
  }

  var exitCode: Int32? {
    sessionCompletionPayload?.exitCode
  }

  var nodeExecutions: Int? {
    switch self {
    case let .stepStarted(_, step), let .backendEvent(_, step, _), let .loopStall(_, step, _), let .stepCompleted(_, step, _):
      step.nodeExecutions
    case let .silenceWarning(_, step, _), let .budgetExceeded(_, step, _):
      step.nodeExecutions
    case let .sessionCompleted(_, payload):
      payload.nodeExecutions
    case .sessionStarted:
      nil
    }
  }

  var transitions: Int? {
    switch self {
    case let .stepCompleted(_, _, payload):
      payload.transitions
    case let .sessionCompleted(_, payload):
      payload.transitions
    case .sessionStarted, .stepStarted, .backendEvent, .silenceWarning, .loopStall, .budgetExceeded:
      nil
    }
  }

  private var session: SessionEnvelope {
    switch self {
    case let .sessionStarted(session),
         let .stepStarted(session, _),
         let .backendEvent(session, _, _),
         let .silenceWarning(session, _, _),
         let .loopStall(session, _, _),
         let .budgetExceeded(session, _, _),
         let .stepCompleted(session, _, _),
         let .sessionCompleted(session, _):
      session
    }
  }

  private var step: StepEnvelope? {
    switch self {
    case let .stepStarted(_, step),
         let .backendEvent(_, step, _),
         let .silenceWarning(_, step, _),
         let .loopStall(_, step, _),
         let .budgetExceeded(_, step, _),
         let .stepCompleted(_, step, _):
      step
    case .sessionStarted, .sessionCompleted:
      nil
    }
  }

  private var backendEventPayload: BackendEventPayload? {
    switch self {
    case let .backendEvent(_, _, payload):
      payload
    case .sessionStarted, .stepStarted, .silenceWarning, .loopStall, .budgetExceeded, .stepCompleted, .sessionCompleted:
      nil
    }
  }

  private var sessionCompletionPayload: SessionCompletionPayload? {
    switch self {
    case let .sessionCompleted(_, payload):
      payload
    case .sessionStarted, .stepStarted, .backendEvent, .silenceWarning, .loopStall, .budgetExceeded, .stepCompleted:
      nil
    }
  }

  var loopStallPayload: LoopStallPayload? {
    switch self {
    case let .loopStall(_, _, payload):
      payload
    case .sessionStarted, .stepStarted, .backendEvent, .silenceWarning, .budgetExceeded, .stepCompleted, .sessionCompleted:
      nil
    }
  }

  var loopBudgetPayload: LoopBudgetExceededPayload? {
    switch self {
    case let .budgetExceeded(_, _, payload):
      payload
    case .sessionStarted, .stepStarted, .backendEvent, .silenceWarning, .loopStall, .stepCompleted, .sessionCompleted:
      nil
    }
  }

  var silentForMs: Int? {
    silenceWarningPayload?.silentForMs
  }

  var silenceThresholdMs: Int? {
    silenceWarningPayload?.silenceThresholdMs
  }

  private var silenceWarningPayload: SilenceWarningPayload? {
    switch self {
    case let .silenceWarning(_, _, payload):
      payload
    case .sessionStarted, .stepStarted, .backendEvent, .loopStall, .budgetExceeded, .stepCompleted, .sessionCompleted:
      nil
    }
  }
}

extension WorkflowRunEvent: Codable {
  private enum CodingKeys: String, CodingKey {
    case type
    case workflowId
    case sessionId
    case status
    case currentStepId
    case stepId
    case nodeId
    case executionId
    case backendEventType
    case backendSessionId
    case backendEventChannel
    case backendEventContent
    case backendEventIsDelta
    case backendEventSequence
    case backendToolName
    case backendEventUsage
    case backendEventMetadata
    case silentForMs
    case silenceThresholdMs
    case loopStallGateId
    case loopStallViolationKind
    case loopStallAction
    case loopStallGateVisits
    case loopStallRepeatedRounds
    case loopStallFingerprints
    case loopStallPolicySource
    case loopBudgetDiagnostic
    case loopBudgetAction
    case loopBudgetConsumedTokens
    case loopBudgetMaxTotalTokens
    case loopBudgetElapsedMs
    case loopBudgetMaxWallClockMs
    case exitCode
    case nodeExecutions
    case transitions
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      type: try container.decode(WorkflowRunEventType.self, forKey: .type),
      workflowId: try container.decode(String.self, forKey: .workflowId),
      sessionId: try container.decode(String.self, forKey: .sessionId),
      status: try container.decodeIfPresent(WorkflowSessionStatus.self, forKey: .status),
      currentStepId: try container.decodeIfPresent(String.self, forKey: .currentStepId),
      stepId: try container.decodeIfPresent(String.self, forKey: .stepId),
      nodeId: try container.decodeIfPresent(String.self, forKey: .nodeId),
      executionId: try container.decodeIfPresent(String.self, forKey: .executionId),
      backendEventType: try container.decodeIfPresent(String.self, forKey: .backendEventType),
      backendSessionId: try container.decodeIfPresent(String.self, forKey: .backendSessionId),
      backendEventChannel: try container.decodeIfPresent(String.self, forKey: .backendEventChannel),
      backendEventContent: try container.decodeIfPresent(String.self, forKey: .backendEventContent),
      backendEventIsDelta: try container.decodeIfPresent(Bool.self, forKey: .backendEventIsDelta),
      backendEventSequence: try container.decodeIfPresent(Int.self, forKey: .backendEventSequence),
      backendToolName: try container.decodeIfPresent(String.self, forKey: .backendToolName),
      backendEventUsage: try container.decodeIfPresent(JSONObject.self, forKey: .backendEventUsage),
      backendEventMetadata: try container.decodeIfPresent(JSONObject.self, forKey: .backendEventMetadata),
      silentForMs: try container.decodeIfPresent(Int.self, forKey: .silentForMs),
      silenceThresholdMs: try container.decodeIfPresent(Int.self, forKey: .silenceThresholdMs),
      loopStallGateId: try container.decodeIfPresent(String.self, forKey: .loopStallGateId),
      loopStallViolationKind: try container.decodeIfPresent(String.self, forKey: .loopStallViolationKind),
      loopStallAction: try container.decodeIfPresent(String.self, forKey: .loopStallAction),
      loopStallGateVisits: try container.decodeIfPresent(Int.self, forKey: .loopStallGateVisits),
      loopStallRepeatedRounds: try container.decodeIfPresent(Int.self, forKey: .loopStallRepeatedRounds),
      loopStallFingerprints: try container.decodeIfPresent([String].self, forKey: .loopStallFingerprints),
      loopStallPolicySource: try container.decodeIfPresent(String.self, forKey: .loopStallPolicySource),
      loopBudgetDiagnostic: try container.decodeIfPresent(String.self, forKey: .loopBudgetDiagnostic),
      loopBudgetAction: try container.decodeIfPresent(String.self, forKey: .loopBudgetAction),
      loopBudgetConsumedTokens: try container.decodeIfPresent(Int.self, forKey: .loopBudgetConsumedTokens),
      loopBudgetMaxTotalTokens: try container.decodeIfPresent(Int.self, forKey: .loopBudgetMaxTotalTokens),
      loopBudgetElapsedMs: try container.decodeIfPresent(Int.self, forKey: .loopBudgetElapsedMs),
      loopBudgetMaxWallClockMs: try container.decodeIfPresent(Int.self, forKey: .loopBudgetMaxWallClockMs),
      exitCode: try container.decodeIfPresent(Int32.self, forKey: .exitCode),
      nodeExecutions: try container.decodeIfPresent(Int.self, forKey: .nodeExecutions),
      transitions: try container.decodeIfPresent(Int.self, forKey: .transitions)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type, forKey: .type)
    try container.encode(workflowId, forKey: .workflowId)
    try container.encode(sessionId, forKey: .sessionId)
    try container.encodeIfPresent(status, forKey: .status)
    try container.encodeIfPresent(currentStepId, forKey: .currentStepId)
    try container.encodeIfPresent(stepId, forKey: .stepId)
    try container.encodeIfPresent(nodeId, forKey: .nodeId)
    try container.encodeIfPresent(executionId, forKey: .executionId)
    try container.encodeIfPresent(backendEventType, forKey: .backendEventType)
    try container.encodeIfPresent(backendSessionId, forKey: .backendSessionId)
    try container.encodeIfPresent(backendEventChannel, forKey: .backendEventChannel)
    try container.encodeIfPresent(backendEventContent, forKey: .backendEventContent)
    try container.encodeIfPresent(backendEventIsDelta, forKey: .backendEventIsDelta)
    try container.encodeIfPresent(backendEventSequence, forKey: .backendEventSequence)
    try container.encodeIfPresent(backendToolName, forKey: .backendToolName)
    try container.encodeIfPresent(backendEventUsage, forKey: .backendEventUsage)
    try container.encodeIfPresent(backendEventMetadata, forKey: .backendEventMetadata)
    try container.encodeIfPresent(silentForMs, forKey: .silentForMs)
    try container.encodeIfPresent(silenceThresholdMs, forKey: .silenceThresholdMs)
    try container.encodeIfPresent(loopStallPayload?.gateId, forKey: .loopStallGateId)
    try container.encodeIfPresent(loopStallPayload?.violationKind, forKey: .loopStallViolationKind)
    try container.encodeIfPresent(loopStallPayload?.action, forKey: .loopStallAction)
    try container.encodeIfPresent(loopStallPayload?.gateVisits, forKey: .loopStallGateVisits)
    try container.encodeIfPresent(loopStallPayload?.repeatedRounds, forKey: .loopStallRepeatedRounds)
    try container.encodeIfPresent(loopStallPayload?.fingerprints, forKey: .loopStallFingerprints)
    try container.encodeIfPresent(loopStallPayload?.policySource, forKey: .loopStallPolicySource)
    try container.encodeIfPresent(loopBudgetPayload?.diagnostic, forKey: .loopBudgetDiagnostic)
    try container.encodeIfPresent(loopBudgetPayload?.action, forKey: .loopBudgetAction)
    try container.encodeIfPresent(loopBudgetPayload?.consumedTokens, forKey: .loopBudgetConsumedTokens)
    try container.encodeIfPresent(loopBudgetPayload?.maxTotalTokens, forKey: .loopBudgetMaxTotalTokens)
    try container.encodeIfPresent(loopBudgetPayload?.elapsedMs, forKey: .loopBudgetElapsedMs)
    try container.encodeIfPresent(loopBudgetPayload?.maxWallClockMs, forKey: .loopBudgetMaxWallClockMs)
    try container.encodeIfPresent(exitCode, forKey: .exitCode)
    try container.encodeIfPresent(nodeExecutions, forKey: .nodeExecutions)
    try container.encodeIfPresent(transitions, forKey: .transitions)
  }
}

public typealias WorkflowRunEventHandler = @Sendable (WorkflowRunEvent) async -> Void
