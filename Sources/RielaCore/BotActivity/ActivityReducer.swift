import Foundation

public struct ActivityEventDraft: Equatable, Sendable {
  public var kind: ActivityEventKind
  public var payload: JSONObject

  public init(kind: ActivityEventKind, payload: JSONObject) {
    self.kind = kind
    self.payload = payload
  }
}

public enum ActivityReducer {
  public static func apply(
    _ update: AdapterActivityUpdate, to state: inout ActivityState, executionId: String, at: Date
  ) -> [ActivityEventDraft] {
    if let currentExecutionId = state.currentExecutionId, currentExecutionId != executionId { return [] }
    state.source = "acp"
    switch update {
    case let .message(_, text, _):
      state.lastMessageLine = String(text.prefix(while: { !$0.isNewline }).prefix(200))
      return []
    case .thought:
      return []
    case let .toolCall(update):
      guard let event = upsertToolCall(update, in: &state, at: at) else { return [] }
      return [event]
    case let .plan(planId, entries):
      let entries = entries.map {
        AdapterActivityPlanEntry(content: $0.content, status: normalized($0.status), priority: $0.priority)
      }
      let plan = ActivityPlan(planId: planId, entries: entries)
      if let index = state.plans.firstIndex(where: { $0.planId == planId }) {
        state.plans[index] = plan
      } else {
        state.plans.append(plan)
      }
      return [.init(kind: .plan, payload: [
        "planId": .string(planId),
        "entries": .array(entries.map { .object([
          "content": .string($0.content), "status": .string($0.status), "priority": .string($0.priority)
        ]) })
      ])]
    case let .planRemoved(planId):
      state.plans.removeAll { $0.planId == planId }
      return [.init(kind: .planRemoved, payload: ["planId": .string(planId)])]
    case let .mode(modeId):
      state.mode = modeId
      return [.init(kind: .mode, payload: ["modeId": .string(modeId)])]
    case let .commands(names):
      state.commands = names
      return [.init(kind: .commands, payload: ["names": .array(names.map(JSONValue.string))])]
    case let .configOptions(options):
      state.configOptions = options
      return [.init(kind: .configOptions, payload: ["options": .array(options.map(JSONValue.object))])]
    case let .sessionInfo(title):
      return [.init(kind: .sessionInfo, payload: title.map { ["title": .string($0)] } ?? [:])]
    case let .usage(usage):
      state.usage = usage
      return [.init(kind: .usage, payload: usage)]
    case let .notice(severity, title, description):
      var payload: JSONObject = ["severity": .string(severity), "title": .string(title)]
      payload["description"] = description.map(JSONValue.string)
      return [.init(kind: .notice, payload: payload)]
    case let .subagent(id, title, status):
      return [upsertSubagent(id: id, title: title, status: status, in: &state)]
    case let .stop(reason, limited, resetAt):
      state.lastStop = ActivityStop(stopReason: reason, limited: limited, limitedResetAt: resetAt)
      var payload: JSONObject = ["stopReason": .string(reason)]
      if limited {
        payload["limited"] = .object(resetAt.map { ["resetAt": .string(RoutineStore.timestamp($0))] } ?? [:])
      }
      return [.init(kind: .stop, payload: payload)]
    case let .reportedModel(model):
      state.reportedModel = model
      return []
    case let .other(kind):
      return [.init(kind: .other, payload: ["updateKind": .string(kind)])]
    }
  }

  public static func stepStarted(
    state: inout ActivityState, executionId: String, stepId: String, nodeId: String,
    backend: String?, requestedModel: String?, at: Date
  ) -> [ActivityEventDraft] {
    let source = state.source
    let lastMessageLine = state.lastMessageLine
    state = ActivityState()
    state.source = source
    state.lastMessageLine = lastMessageLine
    state.currentExecutionId = executionId
    state.currentStepId = stepId
    state.currentNodeId = nodeId
    state.backend = backend
    state.requestedModel = requestedModel
    state.lastEventAt = at
    var payload: JSONObject = ["stepId": .string(stepId), "nodeId": .string(nodeId)]
    payload["backend"] = backend.map(JSONValue.string)
    payload["requestedModel"] = requestedModel.map(JSONValue.string)
    return [.init(kind: .stepStarted, payload: payload)]
  }

  public static func settle(
    state: inout ActivityState, reason: ActivitySettleReason, stepStatus: String, at: Date
  ) -> [ActivityEventDraft] {
    guard state.currentExecutionId != nil else { return [] }
    var closed: [String: Int64] = ["toolCalls": 0, "planEntries": 0, "subagents": 0]
    closed["permissionRequests"] = Int64(state.pendingRequestIds.count)
    for index in state.toolCalls.indices where !isTerminalToolCall(state.toolCalls[index].status) {
      state.toolCalls[index].status = "interrupted"
      state.toolCalls[index].updatedAt = at
      closed["toolCalls", default: 0] += 1
    }
    for plan in state.plans.indices {
      for entry in state.plans[plan].entries.indices where state.plans[plan].entries[entry].status != "completed" {
        state.plans[plan].entries[entry].status = "abandoned"
        closed["planEntries", default: 0] += 1
      }
    }
    for index in state.subagents.indices where !isTerminalSubagent(state.subagents[index].state) {
      state.subagents[index].state = "interrupted"
      closed["subagents", default: 0] += 1
    }
    var finished: JSONObject = ["status": .string(stepStatus)]
    finished["stepId"] = state.currentStepId.map(JSONValue.string)
    state.currentExecutionId = nil
    state.currentStepId = nil
    state.currentNodeId = nil
    state.pendingRequestIds = []
    state.lastEventAt = at
    trimToolCalls(in: &state)
    return [
      .init(kind: .stepFinished, payload: finished),
      .init(kind: .settled, payload: ["reason": .string(reason.rawValue), "closed": .object(closed.mapValues(JSONValue.integer))])
    ]
  }

  private static func normalized(_ status: String) -> String {
    status == "in_progress" ? "inProgress" : status
  }

  private static func isTerminalToolCall(_ status: String?) -> Bool {
    status == "completed" || status == "failed" || status == "interrupted"
  }

  private static func isTerminalSubagent(_ status: String?) -> Bool {
    status == "completed" || status == "failed" || status == "cancelled" || status == "interrupted"
  }

  private static func upsertToolCall(
    _ patch: AdapterActivityToolCall, in state: inout ActivityState, at: Date
  ) -> ActivityEventDraft? {
    let index = state.toolCalls.firstIndex { $0.toolCallId == patch.toolCallId }
    let existing = index.map { state.toolCalls[$0] }
    var call = existing ?? ActivityToolCall(toolCallId: patch.toolCallId, updatedAt: at)
    call.title = patch.title ?? call.title
    call.toolKind = patch.toolKind ?? call.toolKind
    call.locations = patch.locations ?? call.locations
    if let status = patch.status.map(normalized), !isTerminalToolCall(call.status) || isTerminalToolCall(status) {
      call.status = status
    }
    guard call != existing else { return nil }
    call.updatedAt = at
    if let index {
      state.toolCalls[index] = call
    } else {
      state.toolCalls.append(call)
    }
    trimToolCalls(in: &state)
    var payload: JSONObject = ["toolCallId": .string(call.toolCallId)]
    payload["title"] = call.title.map(JSONValue.string)
    payload["toolKind"] = call.toolKind.map(JSONValue.string)
    payload["status"] = call.status.map(JSONValue.string)
    payload["locations"] = call.locations.map { .array($0.map { location in
      var value: JSONObject = ["path": .string(location.path)]
      value["line"] = location.line.map { .integer(Int64($0)) }
      return .object(value)
    }) }
    return .init(kind: .toolCall, payload: payload)
  }

  private static func trimToolCalls(in state: inout ActivityState) {
    let excess = state.toolCalls.count - 200
    guard excess > 0 else { return }
    let oldest = state.toolCalls.filter { isTerminalToolCall($0.status) }.sorted {
      ($0.updatedAt, $0.toolCallId) < ($1.updatedAt, $1.toolCallId)
    }
    let removed = Set(oldest.prefix(excess).map(\.toolCallId))
    state.toolCalls.removeAll { removed.contains($0.toolCallId) }
  }

  private static func upsertSubagent(
    id: String, title: String?, status: String?, in state: inout ActivityState
  ) -> ActivityEventDraft {
    let index = state.subagents.firstIndex { $0.subSessionId == id }
    var subagent = index.map { state.subagents[$0] } ?? ActivitySubagent(subSessionId: id, title: nil, state: nil)
    subagent.title = title ?? subagent.title
    subagent.state = status ?? subagent.state
    if let index {
      state.subagents[index] = subagent
    } else {
      state.subagents.append(subagent)
    }
    var payload: JSONObject = ["subSessionId": .string(id)]
    payload["title"] = subagent.title.map(JSONValue.string)
    payload["state"] = subagent.state.map(JSONValue.string)
    return .init(kind: .subagent, payload: payload)
  }
}
