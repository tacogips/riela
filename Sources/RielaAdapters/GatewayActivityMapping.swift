import ACP
import AgentGatewayAppCore
import Foundation
import RielaCore

enum GatewayActivityMapping {
  static func update(from update: ACPSessionUpdate) -> AdapterActivityUpdate {
    let kind = discriminator(update)
    switch update {
    case .agentMessageChunk(.text(let text)):
      return .message(messageId: nil, text: text.text, replace: false)
    case .agentThoughtChunk(.text(let text)):
      return .thought(text: text.text)
    case .toolCall(let call):
      return toolCall(call.toolCallId, call.title, call.kind?.rawValue, call.status?.rawValue, call.locations)
    case .toolCallUpdate(let call):
      return toolCall(call.toolCallId, call.title, call.kind?.rawValue, call.status?.rawValue, call.locations)
    case .plan(let entries):
      return .plan(planId: "default", entries: entries.map {
        .init(content: $0.content, status: $0.status.rawValue, priority: $0.priority.rawValue)
      })
    case .other(let raw):
      return v1RawUpdate(raw, kind: kind)
    case .userMessageChunk, .agentMessageChunk, .agentThoughtChunk:
      return .other(updateKind: kind)
    }
  }

  static func discriminator(_ update: ACPSessionUpdate) -> String {
    switch update {
    case .userMessageChunk: "user_message_chunk"
    case .agentMessageChunk: "agent_message_chunk"
    case .agentThoughtChunk: "agent_thought_chunk"
    case .toolCall: "tool_call"
    case .toolCallUpdate: "tool_call_update"
    case .plan: "plan"
    case .other(let raw): raw["sessionUpdate"]?.stringValue ?? "unknown"
    }
  }

  private static func v1RawUpdate(_ raw: ACPJSONValue, kind: String) -> AdapterActivityUpdate {
    switch kind {
    case "current_mode_update":
      if let mode = raw["currentModeId"]?.stringValue { return .mode(modeId: mode) }
    case "available_commands_update":
      if case .array(let commands)? = raw["availableCommands"] {
        return .commands(names: commands.compactMap { $0["name"]?.stringValue })
      }
    case "plan":
      // The pinned v1 decoder closes priority and status over their initial values.
      if case .array(let entries)? = raw["entries"] {
        return .plan(planId: "default", entries: entries.compactMap { entry in
          guard let content = entry["content"]?.stringValue, let status = entry["status"]?.stringValue,
                let priority = entry["priority"]?.stringValue else { return nil }
          return .init(content: content, status: status, priority: priority)
        })
      }
    case "tool_call", "tool_call_update":
      if let id = raw["toolCallId"]?.stringValue {
        let locations: [ACPToolCallLocation]?
        if case .array(let values)? = raw["locations"] {
          locations = values.compactMap { location in
            location["path"]?.stringValue.map { ACPToolCallLocation(path: $0, line: location["line"]?.integerValue) }
          }
        } else {
          locations = nil
        }
        return toolCall(id, raw["title"]?.stringValue, raw["kind"]?.stringValue, raw["status"]?.stringValue, locations)
      }
    default:
      break
    }
    return .other(updateKind: kind)
  }

  static func update(from update: ACPV2SessionUpdate) -> AdapterActivityUpdate {
    switch update {
    case .agentMessageChunk(let chunk):
      if case .text(let text) = chunk.content {
        return .message(messageId: chunk.messageId, text: text.text, replace: false)
      }
    case .agentMessage(let message):
      if let text = wholeText(message.content) {
        return .message(messageId: message.messageId, text: text, replace: true)
      }
    case .agentThoughtChunk(let chunk):
      if case .text(let text) = chunk.content { return .thought(text: text.text) }
    case .agentThought(let message):
      if let text = wholeText(message.content) { return .thought(text: text) }
    case .toolCallUpdate(let call):
      return toolCall(call.toolCallId, call.title.value, call.kind.value, call.status.value, call.locations.value)
    case .planUpdate(let plan):
      return planUpdate(plan)
    case .planRemoved(let id):
      return .planRemoved(planId: id)
    case .availableCommandsUpdate(let commands):
      return .commands(names: commands.compactMap {
        guard case .command(let command) = $0 else { return nil }
        return command.name
      })
    case .configOptionUpdate(let options):
      return .configOptions(options: options.map(configOption))
    case .sessionInfoUpdate(let info):
      return .sessionInfo(title: info.title.value)
    case .usageUpdate(let usage):
      return usageUpdate(usage)
    case .notice(let notice):
      return .notice(severity: notice.severity, title: notice.title, description: notice.description)
    case .subagentUpdate(let subagent):
      return .subagent(subSessionId: subagent.sessionId, title: subagent.title.value, state: subagent.state.value?.state.rawValue)
    case .userMessageChunk, .userMessage, .stateUpdate, .toolCallContentChunk,
         .terminalUpdate, .terminalOutputChunk, .replayComplete, .other:
      break
    }
    return .other(updateKind: update.kind)
  }

  static func mode(from update: ACPV2SessionUpdate) -> AdapterActivityUpdate? {
    guard case .configOptionUpdate(let options) = update else { return nil }
    for option in options where option.category == ACPSessionConfigOption.categoryMode {
      if case .select(let current, _) = option.kind { return .mode(modeId: current) }
    }
    return nil
  }

  static func stop(stopReason: String, meta: ACPJSONValue?, error: ACPError?) -> AdapterActivityUpdate {
    let limit = [gatewayACPMeta(meta)?["limit"], meta?["limit"], error?.data?["limit"]]
      .compactMap { $0 }
      .first { ["rate_limit", "usage_limit"].contains($0["kind"]?.stringValue ?? "") }
    let resetAt = limit?["resetAt"]?.stringValue.flatMap { value in
      (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
        ?? (try? Date.ISO8601FormatStyle().parse(value))
    }
    return .stop(stopReason: stopReason, limited: limit != nil, limitedResetAt: resetAt)
  }

  static func usage(meta: ACPJSONValue?) -> AdapterActivityUpdate? {
    guard let usage = (gatewayACPMeta(meta)?["usage"] ?? meta?["usage"])?.objectValue else { return nil }
    var payload: JSONObject = [:]
    for key in ["inputTokens", "outputTokens", "totalTokens", "contextUsed", "contextSize"] {
      payload[key] = usage[key]?.integerValue.map { .integer(Int64($0)) }
    }
    if let amount = usage["cost"]?["amount"], let currency = usage["cost"]?["currency"]?.stringValue {
      switch amount {
      case .number(let value): payload["cost"] = cost(value, currency: currency)
      case .integer(let value): payload["cost"] = cost(Double(value), currency: currency)
      default: break
      }
    }
    return .usage(payload)
  }

  static func reportedModel(meta: ACPJSONValue?) -> AdapterActivityUpdate? {
    guard let model = (gatewayACPMeta(meta)?["model"] ?? meta?["model"])?.stringValue, !model.isEmpty else { return nil }
    return .reportedModel(model)
  }

  private static func wholeText(_ patch: ACPPatch<[ACPContentBlock]>) -> String? {
    switch patch {
    case .unchanged: return nil
    case .clear: return ""
    case .set(let blocks):
      let text = blocks.compactMap { block -> String? in
        guard case .text(let text) = block else { return nil }
        return text.text
      }
      return text.isEmpty && !blocks.isEmpty ? nil : text.joined()
    }
  }

  private static func toolCall(
    _ id: String, _ title: String?, _ kind: String?, _ status: String?, _ locations: [ACPToolCallLocation]?
  ) -> AdapterActivityUpdate {
    .toolCall(.init(toolCallId: id, title: title, toolKind: kind, status: status, locations: locations?.map {
      .init(path: $0.path, line: $0.line)
    }))
  }

  private static func planUpdate(_ plan: ACPV2Plan) -> AdapterActivityUpdate {
    switch plan {
    case .items(let id, let entries):
      .plan(planId: id, entries: entries.map { .init(content: $0.content, status: $0.status, priority: $0.priority) })
    case .markdown(let id, let content, _):
      .plan(planId: id, entries: [.init(content: content, status: "", priority: "")])
    case .other:
      .other(updateKind: "plan_update")
    }
  }

  private static func configOption(_ option: ACPSessionConfigOption) -> JSONObject {
    var result: JSONObject = ["id": .string(option.configId)]
    result["category"] = option.category.map(JSONValue.string)
    switch option.kind {
    case .select(let current, let options):
      result["currentValue"] = .string(current)
      result["values"] = .array(options.all.map { .string($0.value) })
    case .boolean(let current):
      result["currentValue"] = .bool(current)
      result["values"] = .array([.bool(false), .bool(true)])
    case .other:
      break
    }
    return result
  }

  private static func usageUpdate(_ usage: ACPV2UsageUpdate) -> AdapterActivityUpdate {
    var payload: JSONObject = ["contextUsed": .integer(Int64(usage.used)), "contextSize": .integer(Int64(usage.size))]
    if let value = usage.cost.value { payload["cost"] = cost(value.amount, currency: value.currency) }
    return .usage(payload)
  }

  private static func cost(_ amount: Double, currency: String) -> JSONValue {
    .object(["amount": .number(amount), "currency": .string(currency)])
  }
}
