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
  public var defaultWorkingDirectory: String?
  public var executorFactory: AgentGatewayExecutorFactory

  public init(
    environment: [String: String] = [:],
    codexSupervisorModeEnabled: Bool = false,
    defaultWorkingDirectory: String? = nil,
    executorFactory: @escaping AgentGatewayExecutorFactory = defaultAgentGatewayExecutorFactory
  ) {
    self.environment = environment
    self.codexSupervisorModeEnabled = codexSupervisorModeEnabled
    self.defaultWorkingDirectory = defaultWorkingDirectory
    self.executorFactory = executorFactory
  }

  public init(processEnvironment environment: [String: String]) {
    self.init(environment: environment)
  }

  public func makeAdapter() -> AgentGatewayNodeAdapter {
    AgentGatewayNodeAdapter(
      environment: environment,
      codexSupervisorModeEnabled: codexSupervisorModeEnabled,
      defaultWorkingDirectory: defaultWorkingDirectory,
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
  public var defaultWorkingDirectory: String?
  public var executorFactory: AgentGatewayExecutorFactory
  private let sessionStore: AgentGatewaySessionStore

  public init(
    environment: [String: String] = [:],
    codexSupervisorModeEnabled: Bool = false,
    defaultWorkingDirectory: String? = nil,
    executorFactory: @escaping AgentGatewayExecutorFactory = defaultAgentGatewayExecutorFactory,
    sessionStore: AgentGatewaySessionStore = AgentGatewaySessionStore()
  ) {
    self.environment = environment
    self.codexSupervisorModeEnabled = codexSupervisorModeEnabled
    self.defaultWorkingDirectory = defaultWorkingDirectory
    self.executorFactory = executorFactory
    self.sessionStore = sessionStore
  }

  public func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    guard input.node.sandbox == nil else {
      throw AdapterExecutionError(.policyBlocked, "OS-sandboxed nodes must use the isolated Riela worker adapter")
    }
    let vendor = try gatewayVendor(input.node)
    if vendor.isCLI, input.node.agentToolPolicy?.preset != nil {
      throw AdapterExecutionError(
        .invalidInput,
        "agent tool policy preset must be expanded by the host runtime before CLI dispatch"
      )
    }
    let webSearch = !vendor.isCLI && input.node.agentToolPolicy?.preset == .webSearch
    let outputSessionKey = gatewayOutputSessionKey(input)
    let inputSessionKey = gatewayInputSessionKey(input)
    let providerName = input.node.provider?.name
    let baseURL = input.node.provider?.baseUrl ?? input.node.baseURL
    let model = input.node.model == ModelSentinel.defaultModel ? "" : gatewayResolvedModel(
      gatewayVendorModel(vendor, input: input),
      vendor: vendor,
      providerName: providerName,
      baseURL: baseURL
    )
    let vendorArguments = gatewayVendorArguments(vendor, input: input,
      codexSupervisorModeEnabled: codexSupervisorModeEnabled)
    let structuredOutput = try NativeStructuredOutputFile(input: input, vendor: vendor, arguments: vendorArguments)
    defer { structuredOutput?.remove() }
    let defaults = GatewayAgentDefaults(
      vendor: vendor,
      model: model,
      systemPrompt: input.systemPromptText,
      executable: gatewayVendorExecutable(vendor, input: input, environment: environment),
      arguments: vendorArguments + (structuredOutput?.arguments ?? []),
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
        workingDirectory: input.node.workingDirectory ?? defaultWorkingDirectory,
        promptBlocks: try gatewayPromptBlocks(input),
        vendorSessionId: reusedSessionId,
        deadline: context.deadline,
        webSearch: webSearch,
        acpVersion: gatewayACPVersion(environment: turnEnvironment),
        mcpServers: input.mcpServers
      ),
      executorFactory: executorFactory,
      backendEventHandler: context.backendEventHandler,
      permissionRequestHandler: context.permissionRequestHandler
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
      model: turn.model.flatMap { $0.isEmpty ? nil : $0 } ?? (model.isEmpty ? ModelSentinel.defaultModel : model),
      promptText: input.promptText,
      completionPassed: normalized.completionPassed,
      when: normalized.when,
      payload: normalized.payload,
      usage: turn.usage,
      routingDiagnostics: normalized.routingDiagnostics
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
        deadline: deadline,
        acpVersion: gatewayACPVersion(environment: environment)
      ),
      executorFactory: executorFactory,
      backendEventHandler: nil,
      permissionRequestHandler: nil
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
  var webSearch: Bool = false
  /// ACP protocol version to request from the in-process gateway agent.
  var acpVersion: Int = ACPProtocol.versionV1
  var mcpServers: [AdapterMCPServer] = []
}

typealias GatewayACPAgentFactory = @Sendable (GatewayAgentDefaults, any GatewayExecuting) -> any ACPAgent & ACPV2Agent

/// Hosts `GatewayACPAgent` on an in-memory ACP transport and drives exactly
/// one prompt turn against it. Streaming `session/update` notifications become
/// riela backend events. The agent serves ACP protocol versions 1 and 2; the
/// request picks one. In v1 the `session/prompt` response ends the turn and
/// carries the final text, usage, and resumable vendor session id in the
/// gateway's `_meta` extension; in v2 the idle `state_update` does.
func runGatewayTurn(
  _ request: GatewayTurnRequest,
  executorFactory: AgentGatewayExecutorFactory,
  backendEventHandler: AdapterBackendEventHandler?,
  permissionRequestHandler: AdapterPermissionRequestHandler? = nil,
  agentFactory: GatewayACPAgentFactory = { GatewayACPAgent(defaults: $0, executor: $1) }
) async throws -> GatewayACPTurn {
  guard let vendor = request.defaults.vendor else {
    throw AdapterExecutionError(.invalidInput, "agent-gateway requires an explicit execution backend")
  }
  try validateGatewayMCPServers(request.mcpServers, vendor: vendor)
  var defaults = request.defaults
  if vendor.isCLI {
    defaults.systemPrompt = [defaults.systemPrompt, gatewayForegroundExecutionInstructions].compactMap { $0 }.joined(separator: "\n\n")
  }
  let executor = GatewayTurnExecutor(base: executorFactory(request.environment), webSearch: request.webSearch)
  let agent = agentFactory(defaults, executor)
  let delegate = GatewayPermissionDelegate(handler: permissionRequestHandler)
  let permissions = GatewayPermissionLifetime()
  let (client, server) = await ACPClientConnection.inProcess(v1: agent, v2: agent, delegate: delegate)
  await permissions.install(on: client.connection, delegate: delegate)
  let collector = GatewayACPUpdateCollector(vendor: vendor.rawValue)
  return try await withGatewayTurnLifetime(cleanup: {
    permissions.cancel()
    await permissions.waitForReplies()
    await executor.finish()
    await client.stop()
    // Drain responses already queued for the peer before closing its side.
    await server.connection.waitUntilClosed()
    await server.connection.stop()
    await client.connection.waitUntilClosed()
  }, operation: {
    do {
      return try await consumeGatewayTurn(
        request, client: client, collector: collector, permissions: permissions, backendEventHandler: backendEventHandler
      )
    } catch let failure as GatewayTurnFailure {
      await collector.emitTurnEnd(
        reason: failure.reason, meta: failure.meta, error: failure.acpError, handler: backendEventHandler
      )
      throw failure.error
    } catch let error as ACPError {
      if Task.isCancelled {
        await collector.emitTurnEnd(reason: ACPStopReason.cancelled.rawValue, handler: backendEventHandler)
        throw CancellationError()
      }
      let failure = gatewayProviderError(error)
      await collector.emitTurnEnd(reason: failure.message, error: error, handler: backendEventHandler)
      throw failure
    } catch {
      let reason = if error is CancellationError {
        ACPStopReason.cancelled.rawValue
      } else {
        (error as? AdapterExecutionError)?.message ?? String(describing: error)
      }
      await collector.emitTurnEnd(reason: reason, handler: backendEventHandler)
      throw error
    }
  })
}

struct GatewayTurnFailure: Error {
  let error: AdapterExecutionError
  let reason: String
  var meta: ACPJSONValue?
  var acpError: ACPError?
}

func gatewayProviderError(_ error: ACPError) -> AdapterExecutionError {
  AdapterExecutionError(.providerError, "agent-gateway error \(error.code): \(error.message)")
}

func gatewayStopReason(_ rawValue: String?, meta: ACPJSONValue?, error: ACPError? = nil) throws -> ACPStopReason {
  if let rawValue, let reason = ACPStopReason(rawValue: rawValue) { return reason }
  let reason = rawValue ?? "unknown"
  throw GatewayTurnFailure(
    error: AdapterExecutionError(.providerError, "agent-gateway turn ended with stop reason '\(reason)'"),
    reason: reason, meta: meta, acpError: error
  )
}

private func consumeGatewayTurn(
  _ request: GatewayTurnRequest,
  client: ACPClientConnection,
  collector: GatewayACPUpdateCollector,
  permissions: GatewayPermissionLifetime,
  backendEventHandler: AdapterBackendEventHandler?
) async throws -> GatewayACPTurn {
  let clientInfo = ACPImplementation(name: "riela", version: String(cString: rielaEmbeddedVersion))
  if request.acpVersion >= ACPProtocol.versionV2 {
    let negotiated = try await client.negotiate(
      ACPV2InitializeRequest(info: clientInfo), v1Fallback: ACPInitializeRequest(clientInfo: clientInfo)
    )
    if case .v2 = negotiated {
      return try await consumeGatewayTurnV2(
        request, client: client, collector: collector, permissions: permissions, backendEventHandler: backendEventHandler
      )
    }
  } else {
    _ = try await client.initialize(ACPInitializeRequest(clientInfo: clientInfo))
  }
  return try await consumeGatewayTurnV1(
    request, client: client, collector: collector, permissions: permissions, backendEventHandler: backendEventHandler
  )
}

private func consumeGatewayTurnV1(
  _ request: GatewayTurnRequest,
  client: ACPClientConnection,
  collector: GatewayACPUpdateCollector,
  permissions: GatewayPermissionLifetime,
  backendEventHandler: AdapterBackendEventHandler?
) async throws -> GatewayACPTurn {
  let session = try await client.newSession(
    ACPNewSessionRequest(
      cwd: request.workingDirectory ?? FileManager.default.currentDirectoryPath,
      mcpServers: request.mcpServers.map {
        ACPMCPServer(name: $0.name, command: $0.command, args: $0.arguments, env: gatewayMCPEnvironment($0))
      },
      meta: request.vendorSessionId.map {
        .object([GatewayACPMetaKey.v1: .object(["vendorSessionId": .string($0)])])
      }
    )
  )
  let watchdog = GatewayDeadlineWatchdog(
    deadline: request.deadline, client: client, sessionId: session.sessionId, permissions: permissions
  )
  defer { watchdog.cancel() }

  // The ACP v1 types close tool/plan vocabularies. Decode known updates
  // normally and keep open fields as raw JSON when typed decoding fails.
  let (updates, continuation) = AsyncStream<ACPSessionUpdate>.makeStream()
  await client.connection.setNotificationHandler { method, params, _ in
    guard method == ACPMethod.sessionUpdate,
          let note = try? ACPConnection.decodeParams(GatewayOpenV1Notification.self, from: params),
          note.sessionId == session.sessionId else { return }
    continuation.yield(note.update)
  }
  async let updateDrain: Void = forwardV1Updates(updates, collector: collector, handler: backendEventHandler)
  let prompt = ACPPromptRequest(sessionId: session.sessionId, prompt: request.promptBlocks)
  let response: GatewayOpenV1PromptResponse?
  do {
    response = try await withTaskCancellationHandler {
      var responses = gatewayV1PromptResponses(prompt, connection: client.connection).makeAsyncIterator()
      return try await responses.next()
    } onCancel: {
      watchdog.cancelTurnUntilSettled()
    }
  } catch {
    continuation.finish()
    await updateDrain
    throw error
  }
  continuation.finish()
  await updateDrain
  if Task.isCancelled, !watchdog.deadlineExpired { throw CancellationError() }
  guard let response else {
    throw AdapterExecutionError(.invalidOutput, "agent-gateway stream ended without a session/prompt response")
  }
  let stopReason = try gatewayStopReason(response.stopReason, meta: response.meta)
  if stopReason == .cancelled, watchdog.deadlineExpired {
    throw GatewayTurnFailure(
      error: AdapterExecutionError(.timeout, "local agent process exceeded deadline and was terminated"),
      reason: stopReason.rawValue, meta: response.meta
    )
  }
  await collector.emitTurnEnd(reason: stopReason.rawValue, meta: response.meta, handler: backendEventHandler)
  return collector.lock.withLock { collector.turn(stopReason: stopReason, meta: response.meta) }
}

private func gatewayV1PromptResponses(
  _ request: ACPPromptRequest, connection: ACPConnection
) -> AsyncThrowingStream<GatewayOpenV1PromptResponse, Error> {
  AsyncThrowingStream { continuation in
    let requestTask = Task {
      do {
        let response: GatewayOpenV1PromptResponse = try await connection.sendRequest(method: ACPMethod.sessionPrompt, params: request)
        continuation.yield(response)
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    // ACP sendRequest keeps waiting for the peer after it sends cancellation.
    // The stream restores local cancellation and connection cleanup ends the RPC.
    continuation.onTermination = { termination in
      if case .cancelled = termination { requestTask.cancel() }
    }
  }
}

struct GatewayOpenV1PromptResponse: Decodable, Sendable {
  let stopReason: String?
  let meta: ACPJSONValue?

  private enum CodingKeys: String, CodingKey {
    case stopReason
    case meta = "_meta"
  }
}

private func forwardV1Updates(
  _ updates: AsyncStream<ACPSessionUpdate>, collector: GatewayACPUpdateCollector, handler: AdapterBackendEventHandler?
) async {
  for await update in updates {
    let backendEvent = collector.consume(update)
    await handler?(backendEvent)
  }
}

private struct GatewayOpenV1Notification: Decodable {
  let sessionId: String
  let update: ACPSessionUpdate

  private enum CodingKeys: String, CodingKey { case sessionId, update }

  init(from decoder: Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    sessionId = try fields.decode(String.self, forKey: .sessionId)
    let updateDecoder = try fields.superDecoder(forKey: .update)
    if let typed = try? ACPSessionUpdate(from: updateDecoder) {
      update = typed
    } else {
      update = .other(try ACPJSONValue(from: updateDecoder))
    }
  }
}

/// Cancels the in-flight ACP turn when the step deadline passes. The gateway
/// agent forwards the cancellation to the vendor process group, which is what
/// terminating the `agent-gateway` child used to accomplish.
final class GatewayDeadlineWatchdog: @unchecked Sendable {
  private let lock = NSLock()
  private var expired = false
  private var task: Task<Void, Never>?
  private var hostCancelTask: Task<Void, Never>?
  private let client: ACPClientConnection
  private let sessionId: ACPSessionID
  private let permissions: GatewayPermissionLifetime

  init(deadline: Date?, client: ACPClientConnection, sessionId: ACPSessionID, permissions: GatewayPermissionLifetime) {
    self.client = client
    self.sessionId = sessionId
    self.permissions = permissions
    guard let deadline else { return }
    task = Task { [weak self] in
      try? await wallClockSleep(until: deadline)
      guard !Task.isCancelled, let self else { return }
      self.lock.withLock { self.expired = true }
      await self.repeatCancel()
    }
  }

  var deadlineExpired: Bool {
    lock.withLock { expired }
  }

  func cancel() {
    let tasks = lock.withLock { [task, hostCancelTask] }
    for task in tasks { task?.cancel() }
  }

  /// A cancel that reaches the agent before the prompt is in flight is
  /// ignored, so repeat it until the turn settles and `cancel()` stops us.
  private func repeatCancel() async {
    while !Task.isCancelled {
      cancelTurn()
      try? await Task.sleep(for: .milliseconds(200))
    }
  }

  /// Host cancellation (the surrounding task was cancelled): same race as the
  /// deadline, without marking the deadline as expired.
  func cancelTurnUntilSettled() {
    lock.withLock {
      guard hostCancelTask == nil else { return }
      hostCancelTask = Task { [weak self] in await self?.repeatCancel() }
    }
  }

  /// Propagates surrounding-task cancellation into the ACP turn so the vendor
  /// process is terminated instead of being orphaned.
  func cancelTurn() {
    permissions.cancel()
    try? client.connection.notify(method: ACPMethod.sessionCancel, params: ACPCancelNotification(sessionId: sessionId))
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
/// events, and the turn's completion signal into the turn result. Vendor
/// identity, usage, and the authoritative final text arrive in the gateway's
/// `_meta` extension object; the accumulated chunk text is the fallback.
final class GatewayACPUpdateCollector: @unchecked Sendable {
  let lock = NSLock()
  private let vendor: String
  private var sequence = 0
  var accumulatedText = ""
  /// v2 bookkeeping: agent message text by message id, and the tool calls
  /// already announced.
  var messages = ACPV2MessageTextAccumulator()
  var seenToolCalls: Set<ACPToolCallID> = []

  init(vendor: String) {
    self.vendor = vendor
  }

  func consume(_ update: ACPSessionUpdate) -> AdapterBackendEvent {
    lock.withLock {
      let activity = GatewayActivityMapping.update(from: update)
      let discriminator = GatewayActivityMapping.discriminator(update)
      switch update {
      case .agentMessageChunk(let content):
        guard case .text(let text) = content else { return activityEvent(discriminator, activity: activity) }
        accumulatedText += text.text
        return chunkEvent(.agentMessageChunk, channel: .assistant, text: text.text, activity: activity)
      case .agentThoughtChunk(let content):
        guard case .text(let text) = content else { return activityEvent(discriminator, activity: activity) }
        return chunkEvent(.agentThoughtChunk, channel: .thinking, text: text.text, activity: activity)
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
          ),
          activity: activity
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
          ),
          activity: activity
        )
      case .userMessageChunk, .plan, .other:
        if case .usage = activity { return activityEvent(discriminator, channel: .usage, activity: activity) }
        return activityEvent(discriminator, channel: activity.isGatewayToolCall ? .tool : .lifecycle, activity: activity)
      }
    }
  }

  func chunkEvent(
    _ eventType: GatewayBackendEventType,
    channel: AdapterBackendEventChannel,
    text: String?,
    toolCall: GatewayToolCallEventMetadata? = nil,
    activity: AdapterActivityUpdate
  ) -> AdapterBackendEvent {
    activityEvent(eventType.rawValue, channel: channel, text: text, metadata: toolCall?.jsonObject, activity: activity)
  }

  func activityEvent(
    _ eventType: String,
    channel: AdapterBackendEventChannel = .lifecycle,
    text: String? = nil,
    metadata: JSONObject? = nil,
    activity: AdapterActivityUpdate
  ) -> AdapterBackendEvent {
    sequence += 1
    return AdapterBackendEvent(
      provider: vendor,
      eventType: eventType,
      channel: channel,
      contentDelta: text,
      contentSnapshot: nil,
      isDelta: text != nil,
      metadata: metadata,
      sequence: sequence,
      activity: activity
    )
  }

  func emitTurnEnd(
    reason: String, meta: ACPJSONValue? = nil, error: ACPError? = nil, handler: AdapterBackendEventHandler?
  ) async {
    guard let handler else { return }
    let events = lock.withLock {
      var events: [AdapterBackendEvent] = []
      if let usage = GatewayActivityMapping.usage(meta: meta) {
        events.append(activityEvent("usage_update", channel: .usage, activity: usage))
      }
      if let model = GatewayActivityMapping.reportedModel(meta: meta) {
        events.append(activityEvent("reported_model", activity: model))
      }
      events.append(activityEvent("stop", activity: GatewayActivityMapping.stop(stopReason: reason, meta: meta, error: error)))
      return events
    }
    for event in events { await handler(event) }
  }

  /// Builds the turn result from the gateway's `_meta` extension object,
  /// which v1 attaches to the prompt response and v2 to the idle state.
  /// Call with the lock held.
  func turn(stopReason: ACPStopReason, meta: ACPJSONValue?) -> GatewayACPTurn {
    let meta = gatewayACPMeta(meta) ?? meta
    let usage = meta?["usage"].map { value in
      AdapterUsage(
        inputTokens: value["inputTokens"]?.integerValue,
        outputTokens: value["outputTokens"]?.integerValue,
        totalTokens: value["totalTokens"]?.integerValue
      )
    }
    return GatewayACPTurn(
      stopReason: stopReason,
      // An empty authoritative result falls back to the streamed chunks
      // rather than reporting no text at all.
      text: meta?["resultText"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? accumulatedText,
      model: meta?["model"]?.stringValue,
      vendorSessionId: meta?["vendorSessionId"]?.stringValue,
      usage: usage
    )
  }
}

private extension AdapterActivityUpdate {
  var isGatewayToolCall: Bool {
    if case .toolCall = self { return true }
    return false
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
      // `codex exec resume` accepts config overrides but not the top-level
      // `--sandbox` spelling. Use the equivalent config form for both fresh
      // and resumed turns so one reusable argument set is valid in both modes.
      + (input.node.agentSandbox.map { ["-c", #"sandbox_mode="\#($0.rawValue)""#] } ?? [])
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
    do {
      return try normalizeOutputContractEnvelope(try parseJSONObjectCandidate(trimmed, source: source), source: source)
    } catch let failure as AdapterExecutionError {
      throw WorkflowPublicationError.validationRejected(failure.message)
    }
  }
  return OutputContractEnvelopeNormalization(
    completionPassed: true,
    when: ["always": true],
    payload: normalizeTextBusinessPayload(text),
    usedEnvelope: false
  )
}
