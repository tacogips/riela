import ACP
import AgentGateway
import AgentGatewayAppCore
import Foundation
import RielaCore
import RielaVersion

/// Builds a gateway executor for one turn. The default hosts the production
/// executor with a turn-scoped environment; tests substitute a stub so no
/// vendor process is spawned.
public typealias AgentGatewayExecutorFactory = @Sendable (_ environment: [String: String]) -> any GatewayExecuting

public struct AgentGatewayAdapterConfiguration: Sendable {
  public var environment: [String: String]
  public var codexSupervisorModeEnabled: Bool
  public var executorFactory: AgentGatewayExecutorFactory

  public init(
    environment: [String: String] = [:],
    codexSupervisorModeEnabled: Bool = false,
    executorFactory: @escaping AgentGatewayExecutorFactory = defaultAgentGatewayExecutorFactory
  ) {
    self.environment = environment
    self.codexSupervisorModeEnabled = codexSupervisorModeEnabled
    self.executorFactory = executorFactory
  }

  public init(processEnvironment environment: [String: String]) {
    self.init(environment: environment)
  }

  public func makeAdapter() -> AgentGatewayNodeAdapter {
    AgentGatewayNodeAdapter(
      environment: environment,
      codexSupervisorModeEnabled: codexSupervisorModeEnabled,
      executorFactory: executorFactory
    )
  }
}

public let defaultAgentGatewayExecutorFactory: AgentGatewayExecutorFactory = { environment in
  ProductionGatewayExecutor(environment: environment)
}

/// Runs agent steps through the gateway hosted **inside this process**: the
/// ACP agent (`GatewayACPAgent`) and the ACP client are linked as libraries
/// and connected over an in-memory transport, so the only child process riela
/// creates is the vendor CLI itself (`claude`, `codex`, `cursor-agent`). The
/// `agent-gateway` executable is not required at runtime.
public struct AgentGatewayNodeAdapter: NodeAdapter {
  public var environment: [String: String]
  public var codexSupervisorModeEnabled: Bool
  public var executorFactory: AgentGatewayExecutorFactory
  private let sessionStore: AgentGatewaySessionStore

  public init(
    environment: [String: String] = [:],
    codexSupervisorModeEnabled: Bool = false,
    executorFactory: @escaping AgentGatewayExecutorFactory = defaultAgentGatewayExecutorFactory,
    sessionStore: AgentGatewaySessionStore = AgentGatewaySessionStore()
  ) {
    self.environment = environment
    self.codexSupervisorModeEnabled = codexSupervisorModeEnabled
    self.executorFactory = executorFactory
    self.sessionStore = sessionStore
  }

  public func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    let vendor = try gatewayVendor(input.node)
    let outputSessionKey = gatewayOutputSessionKey(input)
    let inputSessionKey = gatewayInputSessionKey(input)
    let providerName = input.node.provider?.name
    let baseURL = input.node.provider?.baseUrl ?? input.node.baseURL
    let model = gatewayResolvedModel(
      gatewayVendorModel(vendor, input: input),
      vendor: vendor,
      providerName: providerName,
      baseURL: baseURL
    )
    let defaults = GatewayAgentDefaults(
      vendor: vendor,
      model: model,
      systemPrompt: input.systemPromptText,
      executable: gatewayVendorExecutable(vendor, input: input, environment: environment),
      arguments: gatewayVendorArguments(
        vendor,
        input: input,
        codexSupervisorModeEnabled: codexSupervisorModeEnabled
      ),
      providerName: providerName,
      apiKeyEnvironment: input.node.provider?.apiKeyEnv ?? input.node.apiKeyEnvironment,
      baseURL: baseURL,
      maxTokens: gatewayMaxTokens(input.node.variables),
      cursorAPI: gatewayCursorAPIOptions(vendor, input: input)
    )
    // The node's own environment wins over riela's so per-step credentials and
    // credential directories reach the vendor. Nothing is written back into
    // riela's process environment, so concurrent steps cannot collide.
    let turnEnvironment = environment.merging(input.agentEnvironment) { _, nodeValue in nodeValue }
    let reusedSessionId = input.sessionPolicy?.mode == .reuse
      ? inputSessionKey.flatMap(sessionStore.sessionId(for:))
      : nil

    let turn = try await runGatewayTurn(
      GatewayTurnRequest(
        defaults: defaults,
        environment: turnEnvironment,
        workingDirectory: input.node.workingDirectory,
        promptBlocks: try gatewayPromptBlocks(input),
        vendorSessionId: reusedSessionId,
        deadline: context.deadline
      ),
      executorFactory: executorFactory,
      backendEventHandler: context.backendEventHandler
    )
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

/// One gateway ACP prompt turn outside the workflow node path, for callers
/// (e.g. builtin add-ons) that need a single vendor completion. Shares the
/// adapter's in-process host, so these callers do not need the
/// `agent-gateway` executable either.
public struct AgentGatewayClientTurn: Sendable {
  public struct Request: Sendable {
    public var vendor: GatewayVendor
    public var model: String
    public var systemPrompt: String?
    public var apiKeyEnvironment: String?
    public var workingDirectory: String?
    public var promptBlocks: [ACPContentBlock]

    public init(
      vendor: GatewayVendor,
      model: String,
      systemPrompt: String? = nil,
      apiKeyEnvironment: String? = nil,
      workingDirectory: String? = nil,
      promptBlocks: [ACPContentBlock]
    ) {
      self.vendor = vendor
      self.model = model
      self.systemPrompt = systemPrompt
      self.apiKeyEnvironment = apiKeyEnvironment
      self.workingDirectory = workingDirectory
      self.promptBlocks = promptBlocks
    }
  }

  public struct Result: Sendable {
    public var stopReason: ACPStopReason
    public var text: String
    public var model: String?
    public var usage: AdapterUsage?
  }

  public var environment: [String: String]
  public var executorFactory: AgentGatewayExecutorFactory

  public init(
    environment: [String: String] = [:],
    executorFactory: @escaping AgentGatewayExecutorFactory = defaultAgentGatewayExecutorFactory
  ) {
    self.environment = environment
    self.executorFactory = executorFactory
  }

  public func run(_ request: Request, deadline: Date? = nil) async throws -> Result {
    let turn = try await runGatewayTurn(
      GatewayTurnRequest(
        defaults: GatewayAgentDefaults(
          vendor: request.vendor,
          model: request.model,
          systemPrompt: request.systemPrompt,
          apiKeyEnvironment: request.apiKeyEnvironment
        ),
        environment: environment,
        workingDirectory: request.workingDirectory,
        promptBlocks: request.promptBlocks,
        vendorSessionId: nil,
        deadline: deadline
      ),
      executorFactory: executorFactory,
      backendEventHandler: nil
    )
    return Result(stopReason: turn.stopReason, text: turn.text, model: turn.model, usage: turn.usage)
  }
}

struct GatewayTurnRequest: Sendable {
  var defaults: GatewayAgentDefaults
  var environment: [String: String]
  var workingDirectory: String?
  var promptBlocks: [ACPContentBlock]
  var vendorSessionId: String?
  var deadline: Date?
}

/// Hosts `GatewayACPAgent` on an in-memory ACP transport and drives exactly
/// one prompt turn against it. Streaming `session/update` notifications become
/// riela backend events; the `session/prompt` response carries the final text,
/// usage, and resumable vendor session id in `_meta.agentGateway`.
func runGatewayTurn(
  _ request: GatewayTurnRequest,
  executorFactory: AgentGatewayExecutorFactory,
  backendEventHandler: AdapterBackendEventHandler?
) async throws -> GatewayACPTurn {
  guard let vendor = request.defaults.vendor else {
    throw AdapterExecutionError(.invalidInput, "agent-gateway requires an explicit execution backend")
  }
  let agent = GatewayACPAgent(
    defaults: request.defaults,
    executor: executorFactory(request.environment)
  )
  let (client, server) = await ACPClientConnection.inProcess(agent: agent)
  let collector = GatewayACPUpdateCollector(vendor: vendor.rawValue)
  defer {
    let server = server
    Task { await server.connection.stop() }
  }

  do {
    _ = try await client.initialize(
      ACPInitializeRequest(
        clientInfo: ACPImplementation(name: "riela", version: String(cString: rielaEmbeddedVersion))
      )
    )
    let session = try await client.newSession(
      ACPNewSessionRequest(
        cwd: request.workingDirectory ?? FileManager.default.currentDirectoryPath,
        mcpServers: [],
        meta: request.vendorSessionId.map {
          .object(["agentGateway": .object(["vendorSessionId": .string($0)])])
        }
      )
    )
    let watchdog = GatewayDeadlineWatchdog(
      deadline: request.deadline,
      client: client,
      sessionId: session.sessionId
    )
    defer { watchdog.cancel() }

    var response: ACPPromptResponse?
    let stream = client.promptStream(ACPPromptRequest(sessionId: session.sessionId, prompt: request.promptBlocks))
    try await withTaskCancellationHandler {
      for try await event in stream {
        switch event {
        case .update(let update):
          if let backendEvent = collector.consume(update) {
            await backendEventHandler?(backendEvent)
          }
        case .response(let value):
          response = value
        }
      }
    } onCancel: {
      watchdog.cancelTurn()
    }
    guard let response else {
      throw AdapterExecutionError(.invalidOutput, "agent-gateway stream ended without a session/prompt response")
    }
    if response.stopReason == .cancelled, watchdog.deadlineExpired {
      throw AdapterExecutionError(.timeout, "local agent process exceeded deadline and was terminated")
    }
    await client.stop()
    return collector.turn(response: response)
  } catch let error as ACPError {
    await client.stop()
    throw AdapterExecutionError(.providerError, "agent-gateway error \(error.code): \(error.message)")
  } catch {
    await client.stop()
    throw error
  }
}

/// Cancels the in-flight ACP turn when the step deadline passes. The gateway
/// agent forwards the cancellation to the vendor process group, which is what
/// terminating the `agent-gateway` child used to accomplish.
private final class GatewayDeadlineWatchdog: @unchecked Sendable {
  private let lock = NSLock()
  private var expired = false
  private var task: Task<Void, Never>?
  private let client: ACPClientConnection
  private let sessionId: ACPSessionID

  init(deadline: Date?, client: ACPClientConnection, sessionId: ACPSessionID) {
    self.client = client
    self.sessionId = sessionId
    guard let deadline else { return }
    let interval = deadline.timeIntervalSinceNow
    task = Task { [weak self] in
      if interval > 0 {
        try? await Task.sleep(for: .seconds(interval))
      }
      guard !Task.isCancelled, let self else { return }
      self.lock.withLock { self.expired = true }
      try? await client.cancel(sessionId: sessionId)
    }
  }

  var deadlineExpired: Bool {
    lock.withLock { expired }
  }

  func cancel() {
    lock.withLock { task }?.cancel()
  }

  /// Propagates surrounding-task cancellation into the ACP turn so the vendor
  /// process is terminated instead of being orphaned.
  func cancelTurn() {
    let client = client
    let sessionId = sessionId
    Task { try? await client.cancel(sessionId: sessionId) }
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

/// Turns the ACP `session/update` notifications of one turn into riela backend
/// events, and the `session/prompt` response into the turn result. Vendor
/// identity, usage, and the authoritative final text arrive in the response's
/// `_meta.agentGateway` extension; the accumulated chunk text is the fallback.
private final class GatewayACPUpdateCollector: @unchecked Sendable {
  private let lock = NSLock()
  private let vendor: String
  private var sequence = 0
  private var accumulatedText = ""

  init(vendor: String) {
    self.vendor = vendor
  }

  func consume(_ update: ACPSessionUpdate) -> AdapterBackendEvent? {
    lock.withLock {
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
      case .userMessageChunk, .plan, .other:
        return nil
      }
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

  func turn(response: ACPPromptResponse) -> GatewayACPTurn {
    lock.withLock {
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
        // An empty authoritative result falls back to the streamed chunks
        // rather than reporting no text at all.
        text: meta?["resultText"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? accumulatedText,
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

private func gatewayVendorArguments(
  _ vendor: GatewayVendor,
  input: AdapterExecutionInput,
  codexSupervisorModeEnabled: Bool
) -> [String] {
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
  if vendor == .codex {
    arguments += [codexSupervisorModeEnabled ? "--enable" : "--disable", "multi_agent"]
  }
  return arguments
}

/// A bare `baseURL` on Codex or Claude Code selects the gateway's implicit
/// custom provider, whose model name is fixed. `agent-gateway client` applied
/// this before spawning its agent; hosting the agent in-process keeps it so a
/// step's reported model stays `custom` rather than the node's empty model.
private func gatewayResolvedModel(
  _ model: String,
  vendor: GatewayVendor,
  providerName: String?,
  baseURL: String?
) -> String {
  guard baseURL != nil, providerName == nil, [.codex, .claudeCode].contains(vendor) else { return model }
  return CustomProvider.modelName
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

/// The ACP prompt for one turn: the resolved prompt text, any inline base64
/// image parts, and any file-backed images. File loading and validation is
/// the gateway's own `gatewayImageContentBlocks`, the code path
/// `agent-gateway client --image` uses, so hosting it in-process does not
/// change how images are read.
private func gatewayPromptBlocks(_ input: AdapterExecutionInput) throws -> [ACPContentBlock] {
  var blocks: [ACPContentBlock] = [.text(gatewayPrompt(input))]
  if case let .array(parts)? = input.mergedVariables["geminiInlineDataParts"] {
    blocks += parts.compactMap { part in
      guard case let .object(object) = part,
            case let .string(mimeType)? = object["mimeType"],
            case let .string(dataBase64)? = object["dataBase64"] else { return nil }
      return .image(ACPImageContent(data: dataBase64, mimeType: mimeType))
    }
  }
  do {
    blocks += try gatewayImageContentBlocks(resolveAdapterImagePaths(input).map { .filePath($0) })
  } catch let error as GatewayRPCError {
    throw AdapterExecutionError(.invalidInput, error.message)
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
