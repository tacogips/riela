import Foundation
import RielaCore

public struct ClaudeCodeProcessOptions: Equatable, Sendable {
  public var model: String?
  public var cwd: String?
  public var sandbox: String?
  public var approvalMode: String?
  public var fullAuto: Bool
  public var images: [String]
  public var configOverrides: [String]
  public var additionalArguments: [String]
  public var environmentVariables: [String: String]
  public var systemPrompt: String?
  public var claudeCodeHome: String?
  public var includeExistingOnResume: Bool
  public var streamGranularity: String?
  public var forwardApprovalMode: Bool

  public init(
    model: String? = nil,
    cwd: String? = nil,
    sandbox: String? = nil,
    approvalMode: String? = nil,
    fullAuto: Bool = false,
    images: [String] = [],
    configOverrides: [String] = [],
    additionalArguments: [String] = [],
    environmentVariables: [String: String] = [:],
    systemPrompt: String? = nil,
    claudeCodeHome: String? = nil,
    includeExistingOnResume: Bool = false,
    streamGranularity: String? = nil,
    forwardApprovalMode: Bool = true
  ) {
    self.model = model
    self.cwd = cwd
    self.sandbox = sandbox
    self.approvalMode = approvalMode
    self.fullAuto = fullAuto
    self.images = images
    self.configOverrides = configOverrides
    self.additionalArguments = additionalArguments
    self.environmentVariables = environmentVariables
    self.systemPrompt = systemPrompt
    self.claudeCodeHome = claudeCodeHome
    self.includeExistingOnResume = includeExistingOnResume
    self.streamGranularity = streamGranularity
    self.forwardApprovalMode = forwardApprovalMode
  }
}

public enum ClaudeCodeProcessCommandBuilder {
  public static func buildExecArguments(
    prompt: String,
    options: ClaudeCodeProcessOptions = ClaudeCodeProcessOptions(),
    terminatePromptWithDoubleDash: Bool = true
  ) -> [String] {
    var arguments = ["-p", "--output-format", "stream-json"]
    arguments.append(contentsOf: buildCommonArguments(options))
    appendImages(options.images, to: &arguments)
    arguments.append(prompt)
    return arguments
  }

  public static func buildResumeArguments(
    sessionId: String,
    prompt: String? = nil,
    options: ClaudeCodeProcessOptions = ClaudeCodeProcessOptions(),
    terminatePromptWithDoubleDash: Bool = true
  ) -> [String] {
    var arguments = ["-p", "--output-format", "stream-json", "--resume", sessionId]
    arguments.append(contentsOf: buildResumeCommonArguments(options))
    appendImages(options.images, to: &arguments)
    if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      arguments.append(prompt)
    }
    return arguments
  }

  public static func buildForkArguments(
    sessionId: String,
    nthMessage: Int? = nil,
    options: ClaudeCodeProcessOptions = ClaudeCodeProcessOptions()
  ) -> [String] {
    var arguments = ["--resume", sessionId]
    if let nthMessage {
      arguments.append(contentsOf: ["--replay-up-to-message", String(nthMessage)])
    }
    arguments.append(contentsOf: buildCommonArguments(options))
    return arguments
  }

  public static func buildEnvironment(
    base: [String: String] = ProcessInfo.processInfo.environment,
    options: ClaudeCodeProcessOptions = ClaudeCodeProcessOptions()
  ) -> [String: String] {
    var environment = base.merging(options.environmentVariables) { _, new in new }
    if let claudeCodeHome = options.claudeCodeHome {
      environment["CLAUDE_CONFIG_DIR"] = claudeCodeHome
    }
    return environment
  }

  public static func buildPromptWithSystemPrompt(prompt: String, systemPrompt: String?) -> String {
    guard let systemPrompt, !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return prompt
    }
    return "\(systemPrompt)\n\n\(prompt)"
  }

  private static func buildCommonArguments(_ options: ClaudeCodeProcessOptions) -> [String] {
    var arguments: [String] = []
    if let model = options.model {
      arguments.append(contentsOf: ["--model", model])
    }
    if options.fullAuto {
      arguments.append("--dangerously-skip-permissions")
    }
    if let approvalMode = options.approvalMode {
      arguments.append(contentsOf: ["--permission-mode", approvalMode])
    }
    if let systemPrompt = options.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !systemPrompt.isEmpty {
      arguments.append(contentsOf: ["--system-prompt", systemPrompt])
    }
    for configOverride in options.configOverrides {
      arguments.append(contentsOf: ["--config", configOverride])
    }
    arguments.append(contentsOf: sanitizedAdditionalArguments(options.additionalArguments))
    return arguments
  }

  private static func buildResumeCommonArguments(_ options: ClaudeCodeProcessOptions) -> [String] {
    var resumeOptions = options
    resumeOptions.sandbox = nil
    return buildCommonArguments(resumeOptions)
  }

  private static func appendImages(_ images: [String], to arguments: inout [String]) {
    let directories = Set(images.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
    for directory in directories.sorted() {
      arguments.append(contentsOf: ["--add-dir", directory])
    }
  }

  public static func sanitizedAdditionalArguments(_ arguments: [String]) -> [String] {
    var sanitized: [String] = []
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if argument == "-p" || argument == "--print" {
        index += 1
        continue
      }
      if argument == "--output-format" || argument == "--input-format" {
        index += 2
        continue
      }
      if argument.hasPrefix("--output-format=") || argument.hasPrefix("--input-format=") {
        index += 1
        continue
      }
      sanitized.append(argument)
      index += 1
    }
    return sanitized
  }
}

public struct ClaudeCodeAgentNormalizedEvent: Equatable, Sendable {
  public var type: String
  public var sessionId: String
  public var payload: JSONObject

  public init(type: String, sessionId: String, payload: JSONObject = [:]) {
    self.type = type
    self.sessionId = sessionId
    self.payload = payload
  }
}

public struct ClaudeCodeAgentEventNormalizer: Sendable {
  public private(set) var startedSessionIds: Set<String>
  public private(set) var assistantSnapshots: [String: String]
  public private(set) var toolNamesByCallId: [String: String]

  public init(
    startedSessionIds: Set<String> = [],
    assistantSnapshots: [String: String] = [:],
    toolNamesByCallId: [String: String] = [:]
  ) {
    self.startedSessionIds = startedSessionIds
    self.assistantSnapshots = assistantSnapshots
    self.toolNamesByCallId = toolNamesByCallId
  }

  public mutating func normalize(
    _ chunk: JSONObject,
    fallbackSessionId: String = "unknown-session",
    includeSessionStarted: Bool = false
  ) -> [ClaudeCodeAgentNormalizedEvent] {
    let sessionId = resolveSessionId(fallback: fallbackSessionId, chunk: chunk)
    guard let type = stringValue(chunk["type"]) else {
      return []
    }

    if type == "session_meta" {
      guard includeSessionStarted, !startedSessionIds.contains(sessionId) else {
        return []
      }
      startedSessionIds.insert(sessionId)
      return [ClaudeCodeAgentNormalizedEvent(type: "session.started", sessionId: sessionId, payload: ["resumed": .bool(false)])]
    }

    if type == "event_msg", let payload = objectValue(chunk["payload"]) {
      return normalizeRolloutPayload(payload, sessionId: sessionId)
    }

    if type == "response_item", let payload = objectValue(chunk["payload"]) {
      return normalizeResponseItem(payload, sessionId: sessionId)
    }

    if type == "assistant.snapshot", let content = stringValue(chunk["content"]) {
      assistantSnapshots[sessionId] = content
      return [ClaudeCodeAgentNormalizedEvent(type: "assistant.snapshot", sessionId: sessionId, payload: ["content": .string(content)])]
    }

    let deltaPayload = objectValue(chunk["payload"])
    if type == "assistant.delta", let text = stringValue(chunk["text"]) ?? stringValue(chunk["char"]) ?? stringValue(deltaPayload?["text"]) ?? stringValue(deltaPayload?["char"]) {
      return assistantTextEvents(sessionId: sessionId, text: text)
    }

    return []
  }

  private mutating func normalizeRolloutPayload(_ payload: JSONObject, sessionId: String) -> [ClaudeCodeAgentNormalizedEvent] {
    switch stringValue(payload["type"]) {
    case "AgentMessage":
      guard let message = stringValue(payload["message"]) else {
        return []
      }
      return assistantTextEvents(sessionId: sessionId, text: message)
    case "AgentReasoning":
      var eventPayload: JSONObject = [:]
      if let message = stringValue(payload["text"]) {
        eventPayload["message"] = .string(message)
      }
      return [ClaudeCodeAgentNormalizedEvent(type: "activity", sessionId: sessionId, payload: eventPayload)]
    case "ExecCommandBegin":
      return [
        ClaudeCodeAgentNormalizedEvent(
          type: "tool.call",
          sessionId: sessionId,
          payload: [
            "name": .string("local_shell"),
            "input": .object(shellPayload(from: payload))
          ]
        )
      ]
    case "ExecCommandEnd":
      let exitCode = numberValue(payload["exit_code"])
      return [
        ClaudeCodeAgentNormalizedEvent(
          type: "tool.result",
          sessionId: sessionId,
          payload: [
            "name": .string("local_shell"),
            "isError": .bool(exitCode.map { $0 != 0 } ?? false),
            "output": .object(shellPayload(from: payload))
          ]
        )
      ]
    case "Error":
      return [
        ClaudeCodeAgentNormalizedEvent(
          type: "session.error",
          sessionId: sessionId,
          payload: ["message": .string(stringValue(payload["message"]) ?? "Unknown rollout error")]
        )
      ]
    case let payloadType?:
      return [ClaudeCodeAgentNormalizedEvent(type: "activity", sessionId: sessionId, payload: ["message": .string(payloadType)])]
    case nil:
      return [ClaudeCodeAgentNormalizedEvent(type: "activity", sessionId: sessionId, payload: ["message": .string("event_msg")])]
    }
  }

  private mutating func normalizeResponseItem(_ payload: JSONObject, sessionId: String) -> [ClaudeCodeAgentNormalizedEvent] {
    switch stringValue(payload["type"]) {
    case "function_call":
      let name = stringValue(payload["name"]) ?? "unknown-tool"
      if let callId = stringValue(payload["call_id"]) {
        toolNamesByCallId[callId] = name
      }
      var input = parseMaybeJSONObject(stringValue(payload["arguments"])).map(JSONValue.object) ?? .null
      if case .null = input, let arguments = payload["arguments"] {
        input = arguments
      }
      return [
        ClaudeCodeAgentNormalizedEvent(
          type: "tool.call",
          sessionId: sessionId,
          payload: ["name": .string(name), "input": input]
        )
      ]
    case "function_call_output":
      let callId = stringValue(payload["call_id"])
      let name = callId.flatMap { toolNamesByCallId[$0] } ?? "unknown-tool"
      let output = payload["output"] ?? .null
      let outputObject = objectValue(output)
      let isError = boolValue(outputObject?["is_error"]) ?? (stringValue(outputObject?["status"]) == "error")
      return [
        ClaudeCodeAgentNormalizedEvent(
          type: "tool.result",
          sessionId: sessionId,
          payload: ["name": .string(name), "isError": .bool(isError), "output": output]
        )
      ]
    case "local_shell_call":
      let status = stringValue(payload["status"])
      let terminal = ["completed", "failed", "error"].contains(status)
      if terminal {
        return [
          ClaudeCodeAgentNormalizedEvent(
            type: "tool.result",
            sessionId: sessionId,
            payload: [
              "name": .string("local_shell"),
              "isError": .bool(status != "completed"),
              "output": .object([
                "callId": payload["call_id"] ?? .null,
                "status": payload["status"] ?? .null,
                "action": payload["action"] ?? .null,
                "output": payload["output"] ?? .null
              ])
            ]
          )
        ]
      }
      return [
        ClaudeCodeAgentNormalizedEvent(
          type: "tool.call",
          sessionId: sessionId,
          payload: [
            "name": .string("local_shell"),
            "input": .object([
              "callId": payload["call_id"] ?? .null,
              "status": payload["status"] ?? .null,
              "action": payload["action"] ?? .null
            ])
          ]
        )
      ]
    case "message":
      guard stringValue(payload["role"]) == "assistant", case let .array(content)? = payload["content"] else {
        return []
      }
      return content.flatMap { entry -> [ClaudeCodeAgentNormalizedEvent] in
        guard
          case let .object(item) = entry,
          ["output_text", "input_text"].contains(stringValue(item["type"])),
          let text = stringValue(item["text"]),
          !text.isEmpty
        else {
          return []
        }
        return assistantTextEvents(sessionId: sessionId, text: text)
      }
    default:
      return []
    }
  }

  private mutating func assistantTextEvents(sessionId: String, text: String) -> [ClaudeCodeAgentNormalizedEvent] {
    let content = (assistantSnapshots[sessionId] ?? "") + text
    assistantSnapshots[sessionId] = content
    return [
      ClaudeCodeAgentNormalizedEvent(type: "assistant.delta", sessionId: sessionId, payload: ["text": .string(text)]),
      ClaudeCodeAgentNormalizedEvent(type: "assistant.snapshot", sessionId: sessionId, payload: ["content": .string(content)])
    ]
  }
}

private func resolveSessionId(fallback: String, chunk: JSONObject) -> String {
  if
    stringValue(chunk["type"]) == "session_meta",
    let payload = objectValue(chunk["payload"]),
    let meta = objectValue(payload["meta"]),
    let id = stringValue(meta["id"]),
    !id.isEmpty {
    return id
  }
  if let sessionId = stringValue(chunk["sessionId"]), !sessionId.isEmpty {
    return sessionId
  }
  return fallback
}

private func shellPayload(from payload: JSONObject) -> JSONObject {
  var object: JSONObject = [:]
  object["callId"] = payload["call_id"] ?? .null
  object["turnId"] = payload["turn_id"] ?? .null
  object["cwd"] = payload["cwd"] ?? .null
  object["command"] = payload["command"] ?? .null
  if let exitCode = payload["exit_code"] {
    object["exitCode"] = exitCode
  }
  if let aggregatedOutput = payload["aggregated_output"] {
    object["aggregatedOutput"] = aggregatedOutput
  }
  return object
}

private func parseMaybeJSONObject(_ text: String?) -> JSONObject? {
  guard let text, let data = text.data(using: .utf8) else {
    return nil
  }
  guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: data), case let .object(object) = decoded else {
    return nil
  }
  return object
}

private func stringValue(_ value: JSONValue?) -> String? {
  guard case let .string(text) = value else {
    return nil
  }
  return text
}

private func objectValue(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object) = value else {
    return nil
  }
  return object
}

private func boolValue(_ value: JSONValue?) -> Bool? {
  guard case let .bool(value) = value else {
    return nil
  }
  return value
}

private func numberValue(_ value: JSONValue?) -> Double? {
  value?.asDouble
}
