import ACP
import AgentGateway
import Foundation
import RielaCore

public struct AgentGatewayAdapterConfiguration: Equatable, Sendable {
  public var executableName: String
  public var environment: [String: String]

  public init(
    executableName: String = "agent-gateway",
    environment: [String: String] = [:]
  ) {
    self.executableName = executableName
    self.environment = environment
  }

  public init(processEnvironment environment: [String: String]) {
    self.init(
      executableName: environment["RIELA_AGENT_GATEWAY_EXECUTABLE"] ?? "agent-gateway",
      environment: environment
    )
  }

  public func makeAdapter() -> AgentGatewayNodeAdapter {
    AgentGatewayNodeAdapter(executableName: executableName, environment: environment)
  }
}

public struct AgentGatewayNodeAdapter: NodeAdapter {
  public var executableName: String
  public var runner: any LocalProcessRunning
  public var environment: [String: String]
  private let sessionStore: AgentGatewaySessionStore

  public init(
    executableName: String = "agent-gateway",
    runner: any LocalProcessRunning = FoundationLocalProcessRunner(),
    environment: [String: String] = [:],
    sessionStore: AgentGatewaySessionStore = AgentGatewaySessionStore()
  ) {
    self.executableName = executableName
    self.runner = runner
    self.environment = environment
    self.sessionStore = sessionStore
  }

  public func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    let vendor = try gatewayVendor(input.node)
    let outputSessionKey = gatewayOutputSessionKey(input)
    let inputSessionKey = gatewayInputSessionKey(input)
    let model = gatewayVendorModel(vendor, input: input)
    // The gateway is driven as an ACP client turn: `agent-gateway client`
    // owns the initialize/session/new/session/prompt handshake and echoes
    // the agent's raw ACP JSONL messages on stdout. The prompt travels as
    // ACP content blocks on stdin to stay clear of argv limits.
    var arguments = [
      executableName, "client",
      "--vendor", vendor.rawValue,
      "--model", model,
      "--prompt-blocks", "-"
    ]
    if let systemPrompt = input.systemPromptText {
      arguments += ["--system", systemPrompt]
    }
    if let workingDirectory = input.node.workingDirectory {
      arguments += ["--cwd", workingDirectory]
    }
    if let executable = gatewayVendorExecutable(vendor, input: input, environment: environment) {
      arguments += ["--executable", executable]
    }
    if let provider = input.node.provider {
      arguments += ["--provider-name", provider.name, "--base-url", provider.baseUrl]
      if let apiKeyEnv = provider.apiKeyEnv {
        arguments += ["--api-key-environment", apiKeyEnv]
      }
    }
    if let maxTokens = gatewayMaxTokens(input.node.variables) {
      arguments += ["--max-tokens", String(maxTokens)]
    }
    if input.sessionPolicy?.mode == .reuse,
       let sessionId = inputSessionKey.flatMap(sessionStore.sessionId(for:)) {
      arguments += ["--session-id", sessionId]
    }
    if let cursorAPI = gatewayCursorAPIOptions(vendor, input: input) {
      if let repositoryURL = cursorAPI.repositoryURL {
        arguments += ["--cursor-repository-url", repositoryURL]
      }
      if let startingRef = cursorAPI.startingRef {
        arguments += ["--cursor-starting-ref", startingRef]
      }
      if let workOnCurrentBranch = cursorAPI.workOnCurrentBranch {
        arguments += ["--cursor-work-on-current-branch", String(workOnCurrentBranch)]
      }
      if let autoCreatePR = cursorAPI.autoCreatePR {
        arguments += ["--cursor-auto-create-pr", String(autoCreatePR)]
      }
    }
    arguments += resolveAdapterImagePaths(input).flatMap { ["--image", $0] }
    let vendorArguments = gatewayVendorArguments(vendor, input: input)
    if !vendorArguments.isEmpty {
      arguments += ["--"] + vendorArguments
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let promptBlocksLine = String(
      bytes: try encoder.encode(gatewayPromptBlocks(input)),
      encoding: .utf8
    ) else {
      throw AdapterExecutionError(.invalidInput, "agent-gateway prompt is not valid UTF-8")
    }

    let collector = GatewayACPMessageCollector(vendor: vendor.rawValue)
    let (stream, continuation) = AsyncStream.makeStream(of: AdapterBackendEvent.self)
    let consumer = Task {
      for await event in stream {
        await context.backendEventHandler?(event)
      }
    }
    let configuration = LocalProcessConfiguration(
      executableURL: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: arguments,
      environment: environment.merging(input.agentEnvironment) { _, nodeValue in nodeValue },
      workingDirectoryURL: input.node.workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
    )
    let result: LocalProcessResult
    do {
      if let streamingRunner = runner as? any LocalProcessEventStreaming {
        result = try await streamingRunner.run(
          configuration: configuration,
          stdin: promptBlocksLine + "\n",
          deadline: context.deadline,
          outputEventHandler: { output in
            guard output.stream == .stdout else { return }
            if let event = collector.consume(output.line) {
              continuation.yield(event)
            }
          }
        )
      } else {
        result = try await runner.run(configuration: configuration, stdin: promptBlocksLine + "\n", deadline: context.deadline)
        for line in result.stdout.split(whereSeparator: \.isNewline) {
          if let event = collector.consume(String(line)) { continuation.yield(event) }
        }
      }
    } catch {
      continuation.finish()
      await consumer.value
      throw error
    }
    continuation.finish()
    await consumer.value
    if let error = collector.protocolError() {
      throw AdapterExecutionError(.providerError, "agent-gateway error \(error.code): \(error.message)")
    }
    guard result.terminationStatus == 0 else {
      throw AdapterExecutionError(
        .providerError,
        "agent-gateway failed with exit code \(result.terminationStatus): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
      )
    }
    let turn = try collector.terminalTurn()
    guard turn.stopReason == .endTurn else {
      throw AdapterExecutionError(.providerError, "agent-gateway turn ended with stop reason '\(turn.stopReason.rawValue)'")
    }
    if let sessionId = turn.vendorSessionId, let outputSessionKey {
      sessionStore.setSessionId(sessionId, for: outputSessionKey)
    }
    let normalized = try normalizeGatewayOutput(
      turn.text,
      source: "agent-gateway/\(vendor.rawValue)",
      requiresOutputContract: input.node.output != nil
    )
    return AdapterExecutionOutput(
      provider: vendor.rawValue,
      model: turn.model ?? model,
      promptText: input.promptText,
      completionPassed: normalized.completionPassed,
      when: normalized.when,
      payload: normalized.payload,
      usage: turn.usage
    )
  }

  public func workflowRunDidEnd(_ context: WorkflowRunLifecycleContext) async {
    sessionStore.removeSessions(forWorkflowRunId: context.workflowRunId)
  }
}

/// Backend event types the gateway adapter emits, mirroring the ACP
/// `sessionUpdate` discriminators. `AdapterBackendEvent.eventType` is
/// riela-core's open wire contract, so this enum defines the values the
/// gateway adapter writes into it.
public enum GatewayBackendEventType: String, Equatable, Sendable {
  case agentMessageChunk = "agent_message_chunk"
  case agentThoughtChunk = "agent_thought_chunk"
  case toolCall = "tool_call"
  case toolCallUpdate = "tool_call_update"
}

/// Typed schema for the metadata attached to `tool_call` and
/// `tool_call_update` backend events. `AdapterBackendEvent.metadata` itself
/// is riela-core's open `JSONObject` wire contract, so this struct defines
/// exactly which keys the gateway adapter writes into it.
public struct GatewayToolCallEventMetadata: Equatable, Sendable {
  public var toolCallId: ACPToolCallID
  public var title: String?
  public var kind: ACPToolKind?
  public var status: ACPToolCallStatus?

  public init(
    toolCallId: ACPToolCallID,
    title: String? = nil,
    kind: ACPToolKind? = nil,
    status: ACPToolCallStatus? = nil
  ) {
    self.toolCallId = toolCallId
    self.title = title
    self.kind = kind
    self.status = status
  }

  var jsonObject: JSONObject {
    var object: JSONObject = ["toolCallId": .string(toolCallId)]
    if let title { object["title"] = .string(title) }
    if let kind { object["kind"] = .string(kind.rawValue) }
    if let status { object["status"] = .string(status.rawValue) }
    return object
  }
}

struct GatewayACPTurn {
  var stopReason: ACPStopReason
  var text: String
  var model: String?
  var vendorSessionId: String?
  var usage: AdapterUsage?
}

/// Parses the raw ACP JSON-RPC lines echoed by `agent-gateway client`:
/// `session/update` notifications become backend events, and the
/// `session/prompt` response (the only response carrying `stopReason`)
/// terminates the turn. Vendor identity, usage, and the authoritative final
/// text arrive in the response `_meta.agentGateway` extension.
private final class GatewayACPMessageCollector: @unchecked Sendable {
  private struct NotificationLine: Decodable {
    var method: String
    var params: ACPSessionNotification
  }

  private struct PromptResponseLine: Decodable {
    var result: ACPPromptResponse
  }

  private struct ErrorLine: Decodable {
    var error: ACPError
  }

  private let lock = NSLock()
  private let vendor: String
  private var sequence = 0
  private var accumulatedText = ""
  private var response: ACPPromptResponse?
  private var error: ACPError?

  init(vendor: String) {
    self.vendor = vendor
  }

  func consume(_ line: String) -> AdapterBackendEvent? {
    lock.withLock {
      let data = Data(line.utf8)
      let decoder = JSONDecoder()
      if let notification = try? decoder.decode(NotificationLine.self, from: data),
         notification.method == "session/update" {
        return backendEvent(notification.params.update)
      }
      if let decoded = try? decoder.decode(ErrorLine.self, from: data) {
        error = decoded.error
        return nil
      }
      if let decoded = try? decoder.decode(PromptResponseLine.self, from: data) {
        response = decoded.result
      }
      return nil
    }
  }

  private func backendEvent(_ update: ACPSessionUpdate) -> AdapterBackendEvent? {
    switch update {
    case .agentMessageChunk(let content):
      guard case .text(let text) = content else { return nil }
      accumulatedText += text.text
      return chunkEvent(.agentMessageChunk, channel: .assistant, text: text.text)
    case .agentThoughtChunk(let content):
      guard case .text(let text) = content else { return nil }
      return chunkEvent(.agentThoughtChunk, channel: .thinking, text: text.text)
    case .toolCall(let toolCall):
      return chunkEvent(
        .toolCall,
        channel: .tool,
        text: nil,
        toolCall: GatewayToolCallEventMetadata(
          toolCallId: toolCall.toolCallId,
          title: toolCall.title,
          kind: toolCall.kind,
          status: toolCall.status
        )
      )
    case .toolCallUpdate(let update):
      return chunkEvent(
        .toolCallUpdate,
        channel: .tool,
        text: nil,
        toolCall: GatewayToolCallEventMetadata(
          toolCallId: update.toolCallId,
          title: update.title,
          kind: update.kind,
          status: update.status
        )
      )
    case .userMessageChunk, .plan:
      return nil
    }
  }

  private func chunkEvent(
    _ eventType: GatewayBackendEventType,
    channel: AdapterBackendEventChannel,
    text: String?,
    toolCall: GatewayToolCallEventMetadata? = nil
  ) -> AdapterBackendEvent {
    sequence += 1
    return AdapterBackendEvent(
      provider: vendor,
      eventType: eventType.rawValue,
      channel: channel,
      contentDelta: text,
      contentSnapshot: nil,
      isDelta: text != nil,
      metadata: toolCall?.jsonObject,
      sequence: sequence
    )
  }

  func protocolError() -> ACPError? {
    lock.withLock { error }
  }

  func terminalTurn() throws -> GatewayACPTurn {
    try lock.withLock {
      guard let response else {
        throw AdapterExecutionError(.invalidOutput, "agent-gateway stream ended without a session/prompt response")
      }
      let meta = response.meta?["agentGateway"]
      let usage = meta?["usage"].map { value in
        AdapterUsage(
          inputTokens: value["inputTokens"]?.integerValue,
          outputTokens: value["outputTokens"]?.integerValue,
          totalTokens: value["totalTokens"]?.integerValue
        )
      }
      return GatewayACPTurn(
        stopReason: response.stopReason,
        text: meta?["resultText"]?.stringValue ?? accumulatedText,
        model: meta?["model"]?.stringValue,
        vendorSessionId: meta?["vendorSessionId"]?.stringValue,
        usage: usage
      )
    }
  }
}

public struct AgentGatewaySessionKey: Hashable, Sendable {
  public var workflowRunId: String
  public var workflowSessionId: String
  public var stepId: String

  public init(workflowRunId: String, workflowSessionId: String, stepId: String) {
    self.workflowRunId = workflowRunId
    self.workflowSessionId = workflowSessionId
    self.stepId = stepId
  }
}

public final class AgentGatewaySessionStore: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [AgentGatewaySessionKey: String] = [:]

  public init() {}

  public func sessionId(for key: AgentGatewaySessionKey) -> String? {
    lock.withLock { values[key] }
  }

  public func setSessionId(_ sessionId: String, for key: AgentGatewaySessionKey) {
    lock.withLock { values[key] = sessionId }
  }

  public func removeSessions(forWorkflowRunId workflowRunId: String) {
    lock.withLock { values = values.filter { $0.key.workflowRunId != workflowRunId } }
  }
}

private func gatewayOutputSessionKey(_ input: AdapterExecutionInput) -> AgentGatewaySessionKey? {
  guard let identity = input.executionIdentity else { return nil }
  return AgentGatewaySessionKey(
    workflowRunId: identity.workflowRunId,
    workflowSessionId: identity.workflowSessionId,
    stepId: identity.stepId
  )
}

private func gatewayInputSessionKey(_ input: AdapterExecutionInput) -> AgentGatewaySessionKey? {
  guard let identity = input.executionIdentity else { return nil }
  return AgentGatewaySessionKey(
    workflowRunId: identity.workflowRunId,
    workflowSessionId: identity.workflowSessionId,
    stepId: input.sessionPolicy?.inheritFromStepId ?? identity.stepId
  )
}

private func gatewayVendor(_ node: AgentNodePayload) throws -> GatewayVendor {
  switch node.executionBackend {
  case .codexAgent: return .codex
  case .claudeCodeAgent: return .claudeCode
  case .cursorCliAgent: return .cursor
  case .officialOpenAISDK:
    return node.provider?.name == GatewayVendor.openRouter.rawValue ? .openRouter : .openAI
  case .officialAnthropicSDK: return .anthropic
  case .officialGeminiSDK: return .gemini
  case .officialCursorSDK: return .cursorAPI
  case nil:
    throw AdapterExecutionError(.invalidInput, "agent-gateway requires an explicit execution backend")
  }
}

private func gatewayPrompt(_ input: AdapterExecutionInput) -> String {
  input.sessionPolicy?.mode == .reuse ? input.resolvedResumedPromptText : input.resolvedFreshPromptText
}

private func gatewayVendorExecutable(
  _ vendor: GatewayVendor,
  input: AdapterExecutionInput,
  environment: [String: String]
) -> String? {
  guard vendor.isCLI else { return nil }
  let keys: (variable: String, environment: String) = switch vendor {
  case .codex: ("codexExecutable", "RIELA_CODEX_AGENT_EXECUTABLE")
  case .claudeCode: ("claudeExecutable", "RIELA_CLAUDE_CODE_AGENT_EXECUTABLE")
  case .cursor: ("cursorExecutable", "RIELA_CURSOR_CLI_AGENT_EXECUTABLE")
  case .openAI, .anthropic, .gemini, .openRouter, .cursorAPI: ("", "")
  }
  if case let .string(value)? = input.node.variables[keys.variable] { return value }
  return environment[keys.environment]
}

private func gatewayVendorArguments(_ vendor: GatewayVendor, input: AdapterExecutionInput) -> [String] {
  guard vendor.isCLI else { return [] }
  let images = resolveAdapterImagePaths(input)
  let (key, backend): (String, CliAgentBackend) = switch vendor {
  case .codex: ("codexAdditionalArgs", .codexAgent)
  case .claudeCode: ("claudeAdditionalArgs", .claudeCodeAgent)
  case .cursor: ("cursorAdditionalArgs", .cursorCliAgent)
  case .openAI, .anthropic, .gemini, .openRouter, .cursorAPI: ("", .codexAgent)
  }
  let configured: [String]
  if case let .array(values)? = input.node.variables[key] {
    configured = values.compactMap { value in
      guard case let .string(text) = value else { return nil }
      return text
    }
  } else {
    configured = []
  }
  var arguments: [String] = switch vendor {
  case .codex:
    (input.node.effort.map { ["-c", #"model_reasoning_effort="\#($0.rawValue)""#] } ?? [])
      + (input.node.agentSandbox.map { ["--sandbox", $0.rawValue] } ?? [])
      + images.flatMap { ["--image", $0] }
  case .claudeCode:
    (input.node.effort.map { ["--effort", $0.rawValue] } ?? [])
      + (claudePermissionMode(for: input.node.agentSandbox).map { ["--permission-mode", $0] } ?? [])
      + uniqueImageDirectories(images).flatMap { ["--add-dir", $0] }
  case .cursor:
    (input.node.agentSandbox.map { ["--sandbox", $0.rawValue] } ?? [])
      + images.flatMap { ["--image", $0] }
  case .openAI, .anthropic, .gemini, .openRouter, .cursorAPI:
    []
  }
  arguments.append(contentsOf: agentToolPolicyArguments(input.node.agentToolPolicy, backend: backend))
  arguments.append(contentsOf: configured)
  return arguments
}

private func gatewayVendorModel(_ vendor: GatewayVendor, input: AdapterExecutionInput) -> String {
  guard vendor == .cursor,
        let effort = input.node.effort,
        !input.node.model.hasPrefix("composer-"),
        input.node.model.contains("-") else { return input.node.model }
  let fastSuffix = input.node.model.hasSuffix("-fast") ? "-fast" : ""
  let base = fastSuffix.isEmpty ? input.node.model : String(input.node.model.dropLast(5))
  let usesExtraHigh = base == "gpt-5.5" || base.hasPrefix("gpt-5.5-")
  let requested = effort == .xhigh && usesExtraHigh ? "extra-high" : effort.rawValue
  if base.hasSuffix("-extra-high") {
    return String(base.dropLast("-extra-high".count)) + "-\(requested)\(fastSuffix)"
  }
  let effortTokens: Set<String> = ["none", "low", "medium", "high", "xhigh", "max"]
  var tokens = base.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
  if let last = tokens.last, effortTokens.contains(last) {
    tokens[tokens.count - 1] = requested
    return tokens.joined(separator: "-") + fastSuffix
  }
  if effort == .medium, !usesExtraHigh { return input.node.model }
  return "\(base)-\(requested)\(fastSuffix)"
}

private func claudePermissionMode(for sandbox: AgentSandboxMode?) -> String? {
  switch sandbox {
  case .readOnly: "plan"
  case .workspaceWrite: "acceptEdits"
  case .dangerFullAccess: "bypassPermissions"
  case nil: nil
  }
}

private func uniqueImageDirectories(_ paths: [String]) -> [String] {
  var seen = Set<String>()
  return paths.compactMap { path in
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
    guard seen.insert(directory).inserted else { return nil }
    return directory
  }.sorted()
}

private func gatewayMaxTokens(_ variables: JSONObject) -> Int? {
  guard case let .integer(value)? = variables["maxTokens"], value > 0, value <= Int64(Int.max) else { return nil }
  return Int(value)
}

private func gatewayCursorAPIOptions(
  _ vendor: GatewayVendor,
  input: AdapterExecutionInput
) -> GatewayCursorAPIOptions? {
  guard vendor == .cursorAPI else { return nil }
  return GatewayCursorAPIOptions(
    repositoryURL: input.agentEnvironment["CURSOR_REPOSITORY_URL"],
    startingRef: input.agentEnvironment["CURSOR_STARTING_REF"],
    workOnCurrentBranch: input.agentEnvironment["CURSOR_WORK_ON_CURRENT_BRANCH"].flatMap(Bool.init),
    autoCreatePR: input.agentEnvironment["CURSOR_AUTO_CREATE_PR"].flatMap(Bool.init)
  )
}

/// The ACP prompt for one turn: the resolved prompt text plus any inline
/// base64 image parts. File-based images travel as `--image` flags instead
/// so the gateway client owns file loading and validation.
private func gatewayPromptBlocks(_ input: AdapterExecutionInput) -> [ACPContentBlock] {
  var blocks: [ACPContentBlock] = [.text(gatewayPrompt(input))]
  guard case let .array(parts)? = input.mergedVariables["geminiInlineDataParts"] else {
    return blocks
  }
  blocks += parts.compactMap { part in
    guard case let .object(object) = part,
          case let .string(mimeType)? = object["mimeType"],
          case let .string(dataBase64)? = object["dataBase64"] else { return nil }
    return .image(ACPImageContent(data: dataBase64, mimeType: mimeType))
  }
  return blocks
}

private func normalizeGatewayOutput(
  _ text: String,
  source: String,
  requiresOutputContract: Bool
) throws -> OutputContractEnvelopeNormalization {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  if requiresOutputContract {
    return try normalizeOutputContractEnvelope(try parseJSONObjectCandidate(trimmed, source: source), source: source)
  }
  if trimmed.hasPrefix("{"),
     let object = try? parseJSONObjectCandidate(trimmed, source: source),
     let normalized = try? normalizeOutputContractEnvelope(object, source: source) {
    return normalized
  }
  return OutputContractEnvelopeNormalization(
    completionPassed: true,
    when: ["always": true],
    payload: normalizeTextBusinessPayload(text),
    usedEnvelope: false
  )
}
