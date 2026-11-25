import Foundation

public enum ActivityEventKind: String, Codable, CaseIterable, Sendable {
  case stepStarted, stepFinished, message, thought, toolCall, plan, planRemoved
  case mode, commands, configOptions, sessionInfo, usage, notice, subagent
  case permissionRequested, permissionResolved, stop, settled, other
}

public struct ActivityEvent: Codable, Equatable, Sendable {
  public var sessionId: String
  public var seq: Int
  public var executionId: String?
  public var at: Date
  public var kind: ActivityEventKind
  public var payload: JSONObject

  public init(sessionId: String, seq: Int, executionId: String?, at: Date, kind: ActivityEventKind, payload: JSONObject) {
    self.sessionId = sessionId
    self.seq = seq
    self.executionId = executionId
    self.at = at
    self.kind = kind
    self.payload = payload
  }
}

public struct ActivityState: Codable, Equatable, Sendable {
  public var source = "session"
  public var currentExecutionId: String?
  public var currentStepId: String?
  public var currentNodeId: String?
  public var backend: String?
  public var requestedModel: String?
  public var reportedModel: String?
  public var toolCalls: [ActivityToolCall] = []
  public var plans: [ActivityPlan] = []
  public var mode: String?
  public var commands: [String] = []
  public var configOptions: [JSONObject] = []
  public var usage: JSONObject?
  public var subagents: [ActivitySubagent] = []
  public var pendingRequestIds: [String] = []
  public var lastStop: ActivityStop?
  public var lastMessageLine: String?
  public var lastEventAt: Date?

  public init() {}
}

public struct ActivityToolCall: Codable, Equatable, Sendable {
  public var toolCallId: String
  public var title: String?
  public var toolKind: String?
  public var status: String?
  public var locations: [AdapterActivityLocation]?
  public var updatedAt: Date

  public init(
    toolCallId: String, title: String? = nil, toolKind: String? = nil,
    status: String? = nil, locations: [AdapterActivityLocation]? = nil, updatedAt: Date
  ) {
    self.toolCallId = toolCallId
    self.title = title
    self.toolKind = toolKind
    self.status = status
    self.locations = locations
    self.updatedAt = updatedAt
  }
}

public struct ActivityPlan: Codable, Equatable, Sendable {
  public var planId: String
  public var entries: [AdapterActivityPlanEntry]

  public init(planId: String, entries: [AdapterActivityPlanEntry]) {
    self.planId = planId
    self.entries = entries
  }
}

public struct ActivitySubagent: Codable, Equatable, Sendable {
  public var subSessionId: String
  public var title: String?
  public var state: String?

  public init(subSessionId: String, title: String?, state: String?) {
    self.subSessionId = subSessionId
    self.title = title
    self.state = state
  }
}

public struct ActivityStop: Codable, Equatable, Sendable {
  public var stopReason: String
  public var limited: Bool
  public var limitedResetAt: Date?

  public init(stopReason: String, limited: Bool, limitedResetAt: Date?) {
    self.stopReason = stopReason
    self.limited = limited
    self.limitedResetAt = limitedResetAt
  }
}

public enum ActivitySettleReason: String, Codable, Sendable {
  case completed, cancelled, timeout, providerError, processExit
}

public protocol WorkflowActivityRecording: Sendable {
  func stepStarted(
    sessionId: String, executionId: String, stepId: String, nodeId: String,
    backend: String?, requestedModel: String?, at: Date
  ) async
  func record(sessionId: String, executionId: String, update: AdapterActivityUpdate, at: Date) async
  func requestPermission(
    sessionId: String, executionId: String, request: AdapterPermissionRequest, waitMs: Int, deadline: Date?
  ) async -> AdapterPermissionOutcome
  func settle(
    sessionId: String, executionId: String, reason: ActivitySettleReason, stepStatus: String, at: Date
  ) async
}
