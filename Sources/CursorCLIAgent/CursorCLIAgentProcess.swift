import Foundation
import RielaCore

public struct CursorCLIProcessOptions: Equatable, Sendable {
  public var model: String?
  public var cwd: String?
  public var sandbox: String?
  public var approvalMode: String?
  public var mode: CursorCLIMode?
  public var fullAuto: Bool
  public var trust: Bool
  public var force: Bool
  public var yolo: Bool
  public var streamPartialOutput: Bool
  public var approveMcps: Bool
  public var worktree: String?
  public var worktreeBase: String?
  public var skipWorktreeSetup: Bool
  public var images: [String]
  public var configOverrides: [String]
  public var additionalArguments: [String]
  public var environmentVariables: [String: String]
  public var systemPrompt: String?
  public var cursorCLIHome: String?
  public var includeExistingOnResume: Bool
  public var streamGranularity: String?
  public var forwardApprovalMode: Bool

  public init(
    model: String? = nil,
    cwd: String? = nil,
    sandbox: String? = nil,
    approvalMode: String? = nil,
    mode: CursorCLIMode? = nil,
    fullAuto: Bool = false,
    trust: Bool = false,
    force: Bool = false,
    yolo: Bool = false,
    streamPartialOutput: Bool = false,
    approveMcps: Bool = false,
    worktree: String? = nil,
    worktreeBase: String? = nil,
    skipWorktreeSetup: Bool = false,
    images: [String] = [],
    configOverrides: [String] = [],
    additionalArguments: [String] = [],
    environmentVariables: [String: String] = [:],
    systemPrompt: String? = nil,
    cursorCLIHome: String? = nil,
    includeExistingOnResume: Bool = false,
    streamGranularity: String? = nil,
    forwardApprovalMode: Bool = true
  ) {
    self.model = model
    self.cwd = cwd
    self.sandbox = sandbox
    self.approvalMode = approvalMode
    self.mode = mode
    self.fullAuto = fullAuto
    self.trust = trust
    self.force = force
    self.yolo = yolo
    self.streamPartialOutput = streamPartialOutput
    self.approveMcps = approveMcps
    self.worktree = worktree
    self.worktreeBase = worktreeBase
    self.skipWorktreeSetup = skipWorktreeSetup
    self.images = images
    self.configOverrides = configOverrides
    self.additionalArguments = additionalArguments
    self.environmentVariables = environmentVariables
    self.systemPrompt = systemPrompt
    self.cursorCLIHome = cursorCLIHome
    self.includeExistingOnResume = includeExistingOnResume
    self.streamGranularity = streamGranularity
    self.forwardApprovalMode = forwardApprovalMode
  }
}

public enum CursorCLIProcessCommandBuilder {
  public static func buildExecArguments(
    prompt: String,
    options: CursorCLIProcessOptions = CursorCLIProcessOptions(),
    terminatePromptWithDoubleDash: Bool = true
  ) -> [String] {
    var arguments = ["--print", "--output-format", "stream-json"]
    arguments.append(contentsOf: buildCommonArguments(options))
    appendImages(options.images, to: &arguments)
    appendWorktree(options, to: &arguments)
    arguments.append("--")
    arguments.append(prompt)
    return arguments
  }

  public static func buildResumeArguments(
    sessionId: String,
    prompt: String? = nil,
    options: CursorCLIProcessOptions = CursorCLIProcessOptions(),
    terminatePromptWithDoubleDash: Bool = true
  ) -> [String] {
    var arguments = ["--print", "--output-format", "stream-json", "--resume", sessionId]
    arguments.append(contentsOf: buildResumeCommonArguments(options))
    appendImages(options.images, to: &arguments)
    appendWorktree(options, to: &arguments)
    if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      arguments.append("--")
      arguments.append(prompt)
    }
    return arguments
  }

  public static func buildForkArguments(
    sessionId: String,
    nthMessage: Int? = nil,
    options: CursorCLIProcessOptions = CursorCLIProcessOptions()
  ) -> [String] {
    var arguments = ["--print", "--output-format", "stream-json", "--resume", sessionId]
    if let nthMessage {
      arguments.append(contentsOf: ["--replay-up-to-message", String(nthMessage)])
    }
    arguments.append(contentsOf: buildCommonArguments(options))
    return arguments
  }

  public static func buildEnvironment(
    base: [String: String] = ProcessInfo.processInfo.environment,
    options: CursorCLIProcessOptions = CursorCLIProcessOptions()
  ) -> [String: String] {
    var environment = base.merging(options.environmentVariables) { _, new in new }
    if let cursorCLIHome = options.cursorCLIHome {
      environment["CURSOR_CLI_AGENT_CURSOR_HOME"] = cursorCLIHome
    }
    return environment
  }

  public static func buildPromptWithSystemPrompt(prompt: String, systemPrompt: String?) -> String {
    guard let systemPrompt, !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return prompt
    }
    return "\(systemPrompt)\n\n\(prompt)"
  }

  private static func buildCommonArguments(_ options: CursorCLIProcessOptions) -> [String] {
    var arguments: [String] = []
    if let model = options.model {
      arguments.append(contentsOf: ["--model", model])
    }
    if let mode = options.mode, mode != .default {
      arguments.append(contentsOf: ["--mode", mode.rawValue])
    }
    if options.trust {
      arguments.append("--trust")
    }
    if options.force {
      arguments.append("--force")
    }
    if options.yolo || options.fullAuto {
      arguments.append("--yolo")
    }
    if options.streamPartialOutput {
      arguments.append("--stream-partial-output")
    }
    if let sandbox = options.sandbox {
      arguments.append(contentsOf: ["--sandbox", sandbox])
    }
    if options.approveMcps {
      arguments.append("--approve-mcps")
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

  private static func buildResumeCommonArguments(_ options: CursorCLIProcessOptions) -> [String] {
    var resumeOptions = options
    resumeOptions.sandbox = nil
    return buildCommonArguments(resumeOptions)
  }

  private static func appendImages(_ images: [String], to arguments: inout [String]) {
    for image in images where !image.isEmpty {
      arguments.append(contentsOf: ["--image", image])
    }
  }

  private static func appendWorktree(_ options: CursorCLIProcessOptions, to arguments: inout [String]) {
    if let worktree = options.worktree {
      if worktree.isEmpty || worktree == "true" {
        arguments.append("--worktree")
      } else {
        arguments.append(contentsOf: ["--worktree", worktree])
      }
    }
    if let worktreeBase = options.worktreeBase, !worktreeBase.isEmpty {
      arguments.append(contentsOf: ["--worktree-base", worktreeBase])
    }
    if options.skipWorktreeSetup {
      arguments.append("--skip-worktree-setup")
    }
  }

  public static func sanitizedAdditionalArguments(_ arguments: [String]) -> [String] {
    var sanitized: [String] = []
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if argument == "--print" || argument == "-p" {
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

public struct CursorCLIAgentNormalizedEvent: Equatable, Sendable {
  public var type: String
  public var sessionId: String
  public var payload: JSONObject

  public init(type: String, sessionId: String, payload: JSONObject = [:]) {
    self.type = type
    self.sessionId = sessionId
    self.payload = payload
  }
}

public struct CursorCLIAgentEventNormalizer: Sendable {
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
  ) -> [CursorCLIAgentNormalizedEvent] {
    let sessionId = resolveSessionId(fallback: fallbackSessionId, chunk: chunk)
    guard let type = stringValue(chunk["type"]) else {
      return []
    }

    if type == "session_meta" {
      guard includeSessionStarted, !startedSessionIds.contains(sessionId) else {
        return []
      }
      startedSessionIds.insert(sessionId)
      return [CursorCLIAgentNormalizedEvent(type: "session.started", sessionId: sessionId, payload: ["resumed": .bool(false)])]
    }

    if type == "event_msg", let payload = objectValue(chunk["payload"]) {
      return normalizeRolloutPayload(payload, sessionId: sessionId)
    }

    if type == "response_item", let payload = objectValue(chunk["payload"]) {
      return normalizeResponseItem(payload, sessionId: sessionId)
    }

    if type == "assistant.snapshot", let content = stringValue(chunk["content"]) {
      assistantSnapshots[sessionId] = content
      return [CursorCLIAgentNormalizedEvent(type: "assistant.snapshot", sessionId: sessionId, payload: ["content": .string(content)])]
    }

    let deltaPayload = objectValue(chunk["payload"])
    if type == "assistant.delta", let text = stringValue(chunk["text"]) ?? stringValue(chunk["char"]) ?? stringValue(deltaPayload?["text"]) ?? stringValue(deltaPayload?["char"]) {
      return assistantTextEvents(sessionId: sessionId, text: text)
    }

    return []
  }

  private mutating func normalizeRolloutPayload(_ payload: JSONObject, sessionId: String) -> [CursorCLIAgentNormalizedEvent] {
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
      return [CursorCLIAgentNormalizedEvent(type: "activity", sessionId: sessionId, payload: eventPayload)]
    case "ExecCommandBegin":
      return [
        CursorCLIAgentNormalizedEvent(
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
        CursorCLIAgentNormalizedEvent(
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
        CursorCLIAgentNormalizedEvent(
          type: "session.error",
          sessionId: sessionId,
          payload: ["message": .string(stringValue(payload["message"]) ?? "Unknown rollout error")]
        )
      ]
    case let payloadType?:
      return [CursorCLIAgentNormalizedEvent(type: "activity", sessionId: sessionId, payload: ["message": .string(payloadType)])]
    case nil:
      return [CursorCLIAgentNormalizedEvent(type: "activity", sessionId: sessionId, payload: ["message": .string("event_msg")])]
    }
  }

  private mutating func normalizeResponseItem(_ payload: JSONObject, sessionId: String) -> [CursorCLIAgentNormalizedEvent] {
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
        CursorCLIAgentNormalizedEvent(
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
        CursorCLIAgentNormalizedEvent(
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
          CursorCLIAgentNormalizedEvent(
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
        CursorCLIAgentNormalizedEvent(
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
      return content.flatMap { entry -> [CursorCLIAgentNormalizedEvent] in
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

  private mutating func assistantTextEvents(sessionId: String, text: String) -> [CursorCLIAgentNormalizedEvent] {
    let content = (assistantSnapshots[sessionId] ?? "") + text
    assistantSnapshots[sessionId] = content
    return [
      CursorCLIAgentNormalizedEvent(type: "assistant.delta", sessionId: sessionId, payload: ["text": .string(text)]),
      CursorCLIAgentNormalizedEvent(type: "assistant.snapshot", sessionId: sessionId, payload: ["content": .string(content)])
    ]
  }
}

private func resolveSessionId(fallback: String, chunk: JSONObject) -> String {
  if
    stringValue(chunk["type"]) == "session_meta",
    let payload = objectValue(chunk["payload"]),
    let meta = objectValue(payload["meta"]),
    let id = stringValue(meta["id"]),
    !id.isEmpty
  {
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
  guard case let .number(value) = value else {
    return nil
  }
  return value
}
