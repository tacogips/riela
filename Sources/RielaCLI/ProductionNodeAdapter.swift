import ClaudeCodeAgent
import CodexAgent
import CursorCLIAgent
import Foundation
import RielaAdapters
import RielaCore
import RielaMemory

func makeProductionNodeAdapter() -> any NodeAdapter {
  DispatchingNodeAdapter(
    configuration: DispatchingNodeAdapterConfiguration(
      registry: [
        .codexAgent: {
          CodexAgentAdapter(
            executableName: environmentValue("RIELA_CODEX_AGENT_EXECUTABLE") ?? "codex"
          )
        },
        .claudeCodeAgent: {
          ClaudeCodeAgentAdapter(
            executableName: environmentValue("RIELA_CLAUDE_CODE_AGENT_EXECUTABLE") ?? "claude"
          )
        },
        .cursorCliAgent: {
          CursorCLIAgentAdapter(
            executableName: environmentValue("RIELA_CURSOR_CLI_AGENT_EXECUTABLE") ?? "cursor-agent"
          )
        }
      ]
    )
  )
}

func makeScenarioBackedNodeAdapter(
  scenarioPath: String?,
  workingDirectory: String,
  autoImprove: Bool = false
) throws -> any NodeAdapter {
  guard let scenarioPath else {
    return makeProductionNodeAdapter()
  }
  let fallback = DeterministicLocalNodeAdapter()
  let scenario = try WorkflowMockScenarioLoader().loadScenario(at: absoluteURL(
    scenarioPath,
    relativeTo: URL(fileURLWithPath: workingDirectory)
  ).path)
  return autoImprove
    ? SupervisedScenarioNodeAdapter(scenario: scenario, fallback: fallback)
    : ScenarioNodeAdapter(scenario: scenario, fallback: fallback)
}

func makeScenarioBackedStdioNodeExecutor(
  scenarioPath: String?,
  workingDirectory: String
) throws -> any WorkflowStdioNodeExecuting {
  let fallback = LocalWorkflowStdioNodeExecutor()
  guard let scenarioPath else {
    return fallback
  }
  let scenario = try WorkflowMockScenarioLoader().loadScenario(at: absoluteURL(
    scenarioPath,
    relativeTo: URL(fileURLWithPath: workingDirectory)
  ).path)
  return ScenarioWorkflowStdioNodeExecutor(scenario: scenario, fallback: fallback)
}

func makeScenarioBackedAddonResolver(
  scenarioPath: String?,
  workingDirectory: String
) throws -> any WorkflowAddonResolving {
  let fallback = BuiltinWorkflowAddonResolver()
  guard let scenarioPath else {
    return fallback
  }
  let scenario = try WorkflowMockScenarioLoader().loadScenario(at: absoluteURL(
    scenarioPath,
    relativeTo: URL(fileURLWithPath: workingDirectory)
  ).path)
  return ScenarioWorkflowAddonResolver(scenario: scenario, fallback: fallback)
}

actor ScenarioWorkflowStdioNodeExecutor: WorkflowStdioNodeExecuting {
  private let scenario: WorkflowMockScenario
  private let fallback: any WorkflowStdioNodeExecuting
  private var counts: [String: Int] = [:]

  init(scenario: WorkflowMockScenario, fallback: any WorkflowStdioNodeExecuting) {
    self.scenario = scenario
    self.fallback = fallback
  }

  func execute(
    _ input: WorkflowStdioNodeExecutionInput,
    context: AdapterExecutionContext
  ) async throws -> WorkflowStdioNodeExecutionResult {
    guard let sequence = scenario.responses[input.nodeId] else {
      return try await fallback.execute(input, context: context)
    }
    let count = (counts[input.nodeId] ?? 0) + 1
    counts[input.nodeId] = count
    let response = sequence.isEmpty ? MockNodeResponse() : sequence[min(count - 1, sequence.count - 1)]
    if response.fail == true {
      throw AdapterExecutionError(.providerError, "scenario forced failure for stdio node '\(input.nodeId)'")
    }
    return WorkflowStdioNodeExecutionResult(payload: response.payload ?? [:])
  }
}

actor ScenarioWorkflowAddonResolver: WorkflowAddonResolving {
  private let scenario: WorkflowMockScenario
  private let fallback: any WorkflowAddonResolving
  private var counts: [String: Int] = [:]

  init(scenario: WorkflowMockScenario, fallback: any WorkflowAddonResolving) {
    self.scenario = scenario
    self.fallback = fallback
  }

  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    guard let sequence = scenario.responses[input.nodeId] else {
      return try await fallback.execute(input, context: context)
    }
    let count = (counts[input.nodeId] ?? 0) + 1
    counts[input.nodeId] = count
    let response = sequence.isEmpty ? MockNodeResponse() : sequence[min(count - 1, sequence.count - 1)]
    if response.fail == true {
      throw AdapterExecutionError(.providerError, "scenario forced failure for add-on node '\(input.nodeId)'")
    }
    return AdapterExecutionOutput(
      provider: response.provider ?? "scenario-mock",
      model: response.model ?? input.addon.name,
      promptText: response.promptText ?? "",
      completionPassed: response.completionPassed ?? true,
      when: response.when ?? ["always": true],
      payload: response.payload ?? [:]
    )
  }
}

typealias GeminiAddonAdapterFactory = @Sendable (OfficialSDKAdapterConfiguration) async throws -> any NodeAdapter
typealias OpenAIAddonAdapterFactory = @Sendable (OfficialSDKAdapterConfiguration) async throws -> any NodeAdapter
typealias AnthropicAddonAdapterFactory = @Sendable (AnthropicSDKAdapterConfiguration) async throws -> any NodeAdapter
typealias CursorAddonAdapterFactory = @Sendable ([String: String]) async throws -> any NodeAdapter

private enum BuiltinSDKWorker: String {
  case codex = "riela/codex-sdk-worker"
  case claude = "riela/claude-sdk-worker"
  case cursor = "riela/cursor-sdk-worker"

  var executionBackend: NodeExecutionBackend {
    switch self {
    case .codex:
      .officialOpenAISDK
    case .claude:
      .officialAnthropicSDK
    case .cursor:
      .officialCursorSDK
    }
  }

  var provider: String {
    switch self {
    case .codex:
      OpenAiSDKAdapter.provider
    case .claude:
      AnthropicSDKAdapter.provider
    case .cursor:
      "official-cursor-sdk"
    }
  }
}

struct BuiltinWorkflowAddonResolver: WorkflowAddonResolving {
  var environment: [String: String]
  var openAIAdapterFactory: OpenAIAddonAdapterFactory
  var anthropicAdapterFactory: AnthropicAddonAdapterFactory
  var cursorAdapterFactory: CursorAddonAdapterFactory
  var geminiAdapterFactory: GeminiAddonAdapterFactory

  init(
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment(),
    openAIAdapterFactory: @escaping OpenAIAddonAdapterFactory = { configuration in
      OpenAiSDKAdapter(configuration: configuration)
    },
    anthropicAdapterFactory: @escaping AnthropicAddonAdapterFactory = { configuration in
      AnthropicSDKAdapter(configuration: configuration)
    },
    cursorAdapterFactory: @escaping CursorAddonAdapterFactory = { environment in
      CursorCLIAgentAdapter(environment: environment)
    },
    geminiAdapterFactory: @escaping GeminiAddonAdapterFactory = { configuration in
      GeminiSDKAdapter(configuration: configuration)
    }
  ) {
    self.environment = environment
    self.openAIAdapterFactory = openAIAdapterFactory
    self.anthropicAdapterFactory = anthropicAdapterFactory
    self.cursorAdapterFactory = cursorAdapterFactory
    self.geminiAdapterFactory = geminiAdapterFactory
  }

  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    guard input.addon.name.hasPrefix("riela/") else {
      throw AdapterExecutionError(.providerError, "missing add-on resolver for '\(input.addon.name)'")
    }
    if input.addon.name == "riela/gemini-sdk-worker" {
      return try await executeGeminiSDKWorker(input, context: context)
    }
    if let sdkWorker = BuiltinSDKWorker(rawValue: input.addon.name) {
      return try await executeSDKWorker(input, sdkWorker: sdkWorker, context: context)
    }
    if input.addon.name == "riela/chat-persona-router" {
      return executeChatPersonaRouter(input)
    }
    if input.addon.name == "riela/chat-reply-worker" {
      return try executeChatReplyWorker(input)
    }
    if let memoryAddon = BuiltinMemoryAddon(rawValue: input.addon.name) {
      return try executeMemoryAddon(input, operation: memoryAddon)
    }
    return AdapterExecutionOutput(
      provider: "riela-builtin-addon",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      payload: [
        "status": .string("ok"),
        "addon": .string(input.addon.name),
        "stepId": .string(input.stepId)
      ]
    )
  }

  private func executeSDKWorker(
    _ input: WorkflowAddonExecutionInput,
    sdkWorker: BuiltinSDKWorker,
    context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    let config = input.addon.config ?? [:]
    guard let model = nonEmptyString(config["model"]) else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) config.model is required")
    }
    guard let promptTemplate = nonEmptyString(config["promptTemplate"]) else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) config.promptTemplate is required")
    }

    let variables = addonVariables(for: input)
    let promptText = renderPromptTemplate(promptTemplate, variables: variables)
    let systemPromptText = nonEmptyString(config["systemPromptTemplate"]).map {
      renderPromptTemplate($0, variables: variables)
    }
    let resolvedEnvironment = try resolveAddonEnvironmentOverlay(input.addon.env, runtimeEnvironment: environment)
    let adapterInput = AdapterExecutionInput(
      node: AgentNodePayload(
        id: input.nodeId,
        nodeType: .addon,
        executionBackend: sdkWorker.executionBackend,
        model: model,
        variables: objectValue(config["variables"]) ?? [:]
      ),
      promptText: promptText,
      systemPromptText: systemPromptText,
      arguments: input.variables,
      mergedVariables: variables
    )
    let adapter = try await sdkAdapter(for: sdkWorker, config: config, environment: resolvedEnvironment)
    let output = try await adapter.execute(adapterInput, context: context)
    let text = (nonEmptyString(output.payload["text"]) ?? nonEmptyString(output.payload["replyText"]) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      throw AdapterExecutionError(.invalidOutput, "\(input.addon.name) returned empty reply text")
    }

    var payload = output.payload
    payload["status"] = .string("ok")
    payload["addon"] = .string(input.addon.name)
    payload["stepId"] = .string(input.stepId)
    payload["executionBackend"] = .string(sdkWorker.executionBackend.rawValue)
    payload["text"] = .string(text)
    payload["replyText"] = .string(text)
    payload["liveExecution"] = .bool(true)
    payload.removeValue(forKey: "inputFilterSkipped")

    return AdapterExecutionOutput(
      provider: output.provider,
      model: output.model,
      promptText: output.promptText,
      completionPassed: output.completionPassed,
      when: output.when,
      payload: payload
    )
  }

  private func sdkAdapter(
    for sdkWorker: BuiltinSDKWorker,
    config: JSONObject,
    environment: [String: String]
  ) async throws -> any NodeAdapter {
    let officialConfiguration = OfficialSDKAdapterConfiguration(
      apiKeyEnv: nonEmptyString(config["apiKeyEnv"]),
      baseURL: nonEmptyString(config["baseURL"]).flatMap(URL.init(string:)),
      environment: environment
    )
    switch sdkWorker {
    case .codex:
      return try await openAIAdapterFactory(officialConfiguration)
    case .claude:
      let maxTokens = intValue(config["maxTokens"]) ?? 1024
      return try await anthropicAdapterFactory(AnthropicSDKAdapterConfiguration(
        officialSDK: officialConfiguration,
        maxTokens: maxTokens
      ))
    case .cursor:
      return try await cursorAdapterFactory(environment)
    }
  }

  private func executeChatPersonaRouter(_ input: WorkflowAddonExecutionInput) -> AdapterExecutionOutput {
    let personas = chatPersonas(from: input.addon.config ?? [:])
    let defaultPersonaId = nonEmptyString(input.addon.config?["defaultPersonaId"]) ?? personas.first?.id ?? "yui"
    let request = routerRequestText(input)
    let target = personas.first { persona in
      persona.matches(request)
    }?.id ?? defaultPersonaId
    let knownTargetIds = Set(personas.map(\.id) + ["yui", "mika", "rina"])
    var when = Dictionary(uniqueKeysWithValues: knownTargetIds.map { ("target_\($0)", $0 == target) })
    when["always"] = true
    var payload: JSONObject = [
      "status": .string("ok"),
      "addon": .string(input.addon.name),
      "target": .string(target),
      "reason": .string(target == defaultPersonaId ? "No persona alias matched, so the default persona was selected." : "Persona alias matched the incoming chat text.")
    ]
    for (key, value) in when {
      payload[key] = .bool(value)
    }
    return AdapterExecutionOutput(
      provider: "riela-builtin-addon",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: when,
      payload: payload
    )
  }

  private struct ChatPersona {
    var id: String
    var aliases: [String]

    func matches(_ request: String) -> Bool {
      let normalizedRequest = request.lowercased()
      return aliases.contains { alias in
        let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalizedAlias.isEmpty && normalizedRequest.contains(normalizedAlias)
      }
    }
  }

  private func chatPersonas(from config: JSONObject) -> [ChatPersona] {
    guard case let .array(personaValues)? = config["personas"] else {
      return [
        ChatPersona(id: "yui", aliases: ["yui", "codex"]),
        ChatPersona(id: "mika", aliases: ["mika", "maki", "claude"]),
        ChatPersona(id: "rina", aliases: ["rina", "cursor"])
      ]
    }
    return personaValues.compactMap { value in
      guard case let .object(persona) = value,
        let id = nonEmptyString(persona["id"])
      else {
        return nil
      }
      var aliases = [id]
      if let name = nonEmptyString(persona["name"]) {
        aliases.append(name)
      }
      if case let .array(aliasValues)? = persona["aliases"] {
        aliases.append(contentsOf: aliasValues.compactMap(nonEmptyString))
      }
      if id == "mika" {
        aliases.append("maki")
      }
      return ChatPersona(id: id, aliases: aliases)
    }
  }

  private func routerRequestText(_ input: WorkflowAddonExecutionInput) -> String {
    for object in [
      input.resolvedInputPayload,
      objectValue(input.variables["humanInput"]) ?? [:],
      objectValue(input.variables["workflowInput"]) ?? [:],
      objectValue(objectValue(input.variables["event"])?["input"]) ?? [:]
    ] {
      if let request = nonEmptyString(object["request"]) ?? nonEmptyString(object["text"]) {
        return request
      }
    }
    return ""
  }

  private func executeChatReplyWorker(_ input: WorkflowAddonExecutionInput) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported riela/chat-reply-worker version '\(input.addon.version ?? "")'")
    }
    let config = input.addon.config ?? [:]
    guard let textTemplate = nonEmptyString(config["textTemplate"]) else {
      throw AdapterExecutionError(.policyBlocked, "riela/chat-reply-worker config.textTemplate is required")
    }

    var variables = addonVariables(for: input)
    variables["inbox"] = .object([
      "latest": .object([
        "output": .object([
          "payload": .object(input.resolvedInputPayload)
        ])
      ])
    ])
    let text = renderPromptTemplate(textTemplate, variables: variables)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      throw AdapterExecutionError(.invalidOutput, "riela/chat-reply-worker rendered empty reply text")
    }

    let replyAs = nonEmptyString(config["replyAsTemplate"]).map {
      renderPromptTemplate($0, variables: variables)
    }?.trimmingCharacters(in: .whitespacesAndNewlines)

    var payload = input.resolvedInputPayload
    payload["status"] = .string("ok")
    payload["addon"] = .string(input.addon.name)
    payload["stepId"] = .string(input.stepId)
    payload["text"] = .string(text)
    payload["replyText"] = .string(text)
    payload["dispatchStatus"] = .string("intent-only")
    if let replyAs, !replyAs.isEmpty {
      payload["replyAs"] = .string(replyAs)
    }

    var when: [String: Bool] = ["always": true]
    for (key, value) in input.resolvedInputPayload {
      if case let .bool(flag) = value {
        when[key] = flag
      }
    }

    return AdapterExecutionOutput(
      provider: "riela-builtin-addon",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: when,
      payload: payload
    )
  }

  private func executeMemoryAddon(
    _ input: WorkflowAddonExecutionInput,
    operation: BuiltinMemoryAddon
  ) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }

    let config = input.addon.config ?? [:]
    let variables = addonVariables(for: input)
    let memoryId = nonEmptyString(config["memoryId"]) ?? nonEmptyString(variables["memoryId"]) ?? "chat-memory"
    let nodeId = nonEmptyString(config["nodeId"]) ?? nonEmptyString(variables["memoryNodeId"]) ?? input.nodeId
    let limit = intValue(config["limit"]) ?? intValue(variables["limit"]) ?? 30
    let memoryRoot = nonEmptyString(config["memoryRoot"]) ?? nonEmptyString(variables["memoryRoot"])
    let store = RielaMemoryStore(
      rootDirectory: memoryRoot ?? RielaMemoryStore.defaultRootDirectory()
    )

    switch operation {
    case .save:
      let payload = try memoryPayload(config: config, variables: variables, input: input)
      let record = try store.save(
        memoryId: memoryId,
        workflowId: input.workflowId,
        nodeId: nodeId,
        payload: payload
      )
      return memoryAddonOutput(
        input: input,
        operation: operation,
        memoryId: memoryId,
        databasePath: try store.databasePath(memoryId: memoryId),
        payload: [
          "saved": .bool(true),
          "record": memoryRecordJSON(record)
        ]
      )
    case .load:
      let records = try store.load(
        memoryId: memoryId,
        workflowId: input.workflowId,
        nodeId: optionalNodeScope(config: config, variables: variables),
        limit: limit
      )
      return memoryAddonOutput(
        input: input,
        operation: operation,
        memoryId: memoryId,
        databasePath: try store.databasePath(memoryId: memoryId),
        payload: [
          "records": .array(records.map(memoryRecordJSON)),
          "limit": .number(Double(limit))
        ]
      )
    case .search:
      let patterns = memoryMatchPatterns(config: config, variables: variables)
      let records = try store.search(
        memoryId: memoryId,
        options: MemorySearchOptions(
          workflowId: input.workflowId,
          nodeId: optionalNodeScope(config: config, variables: variables),
          matchPatterns: patterns,
          limit: limit
        )
      )
      return memoryAddonOutput(
        input: input,
        operation: operation,
        memoryId: memoryId,
        databasePath: try store.databasePath(memoryId: memoryId),
        payload: [
          "records": .array(records.map(memoryRecordJSON)),
          "matchPatterns": .array(patterns.map { .string($0) }),
          "limit": .number(Double(limit))
        ]
      )
    }
  }

  private func executeGeminiSDKWorker(
    _ input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported riela/gemini-sdk-worker version '\(input.addon.version ?? "")'")
    }
    let config = input.addon.config ?? [:]
    guard let model = nonEmptyString(config["model"]) else {
      throw AdapterExecutionError(.policyBlocked, "riela/gemini-sdk-worker config.model is required")
    }
    guard let promptTemplate = nonEmptyString(config["promptTemplate"]) else {
      throw AdapterExecutionError(.policyBlocked, "riela/gemini-sdk-worker config.promptTemplate is required")
    }

    let resolvedEnvironment = try resolveAddonEnvironment(input.addon.env, runtimeEnvironment: environment)
    let apiKeyEnv = resolvedEnvironment["GOOGLE_API_KEY"]?.isEmpty == false ? "GOOGLE_API_KEY" : "GEMINI_API_KEY"
    guard resolvedEnvironment[apiKeyEnv]?.isEmpty == false else {
      throw AdapterExecutionError(.policyBlocked, "riela/gemini-sdk-worker requires addon.env.GEMINI_API_KEY or addon.env.GOOGLE_API_KEY")
    }

    var variables = addonVariables(for: input)
    if let inlineDataParts = config["inlineDataParts"] {
      variables["geminiInlineDataParts"] = inlineDataParts
    }

    let adapter = try await geminiAdapterFactory(
      OfficialSDKAdapterConfiguration(
        apiKeyEnv: apiKeyEnv,
        environment: resolvedEnvironment
      )
    )
    let node = AgentNodePayload(
      id: input.nodeId,
      nodeType: .addon,
      executionBackend: .officialGeminiSDK,
      model: model
    )
    return try await adapter.execute(
      AdapterExecutionInput(
        node: node,
        promptText: renderPromptTemplate(promptTemplate, variables: variables),
        systemPromptText: nonEmptyString(config["systemPromptTemplate"]).map {
          renderPromptTemplate($0, variables: variables)
        },
        arguments: input.variables,
        mergedVariables: variables
      ),
      context: context
    )
  }
}

private enum BuiltinMemoryAddon: String {
  case save = "riela/memory-save"
  case load = "riela/memory-load"
  case search = "riela/memory-search"
}

private func addonVariables(for input: WorkflowAddonExecutionInput) -> JSONObject {
  var variables = input.variables
  for (key, value) in input.resolvedInputPayload {
    variables[key] = value
  }
  variables["input"] = .object(input.resolvedInputPayload)
  variables["workflowId"] = .string(input.workflowId)
  variables["stepId"] = .string(input.stepId)
  variables["nodeId"] = .string(input.nodeId)
  variables["addonName"] = .string(input.addon.name)
  for (key, value) in renderAddonInputs(input.addon.inputs, variables: variables) {
    variables[key] = value
  }
  return variables
}

private func environmentValue(_ key: String) -> String? {
  guard let value = CLIRuntimeEnvironment.mergedProcessEnvironment()[key], !value.isEmpty else {
    return nil
  }
  return value
}

private func resolveAddonEnvironment(
  _ env: JSONObject?,
  runtimeEnvironment: [String: String]
) throws -> [String: String] {
  guard let env else {
    return [:]
  }
  var resolved: [String: String] = [:]
  for (targetName, bindingValue) in env {
    guard case let .object(binding) = bindingValue else {
      throw AdapterExecutionError(.policyBlocked, "addon.env.\(targetName) must be an object")
    }
    guard let sourceName = nonEmptyString(binding["fromEnv"]) else {
      throw AdapterExecutionError(.policyBlocked, "addon.env.\(targetName).fromEnv is required")
    }
    let required = boolValue(binding["required"]) ?? true
    guard let value = runtimeEnvironment[sourceName], !value.isEmpty else {
      if required {
        throw AdapterExecutionError(.policyBlocked, "required environment variable '\(sourceName)' is unavailable for addon.env.\(targetName)")
      }
      continue
    }
    resolved[targetName] = value
  }
  return resolved
}

private func resolveAddonEnvironmentOverlay(
  _ env: JSONObject?,
  runtimeEnvironment: [String: String]
) throws -> [String: String] {
  var resolved = runtimeEnvironment
  guard let env else {
    return resolved
  }
  for (targetName, bindingValue) in env {
    guard case let .object(binding) = bindingValue else {
      throw AdapterExecutionError(.policyBlocked, "addon.env.\(targetName) must be an object")
    }
    guard let sourceName = nonEmptyString(binding["fromEnv"]) else {
      throw AdapterExecutionError(.policyBlocked, "addon.env.\(targetName).fromEnv is required")
    }
    let required = boolValue(binding["required"]) ?? true
    guard let value = runtimeEnvironment[sourceName], !value.isEmpty else {
      if required {
        throw AdapterExecutionError(.policyBlocked, "required environment variable '\(sourceName)' is unavailable for addon.env.\(targetName)")
      }
      resolved.removeValue(forKey: targetName)
      continue
    }
    resolved[targetName] = value
  }
  return resolved
}

private func renderAddonInputs(_ inputs: JSONObject?, variables: JSONObject) -> JSONObject {
  guard let inputs else {
    return [:]
  }
  var rendered: JSONObject = [:]
  for (key, value) in inputs {
    if case let .string(template) = value {
      rendered[key] = .string(renderPromptTemplate(template, variables: variables))
    } else {
      rendered[key] = value
    }
  }
  return rendered
}

private func nonEmptyString(_ value: JSONValue?) -> String? {
  guard case let .string(text) = value, !text.isEmpty else {
    return nil
  }
  return text
}

private func boolValue(_ value: JSONValue?) -> Bool? {
  guard case let .bool(value) = value else {
    return nil
  }
  return value
}

private func intValue(_ value: JSONValue?) -> Int? {
  guard case let .number(value) = value else {
    return nil
  }
  return Int(value)
}

private func optionalNodeScope(config: JSONObject, variables: JSONObject) -> String? {
  if boolValue(config["workflowScopeOnly"]) == true || boolValue(variables["workflowScopeOnly"]) == true {
    return nil
  }
  return nonEmptyString(config["nodeScope"]) ?? nonEmptyString(variables["nodeScope"])
}

private func memoryPayload(
  config: JSONObject,
  variables: JSONObject,
  input: WorkflowAddonExecutionInput
) throws -> MemoryJSONValue {
  if let payload = config["payload"] ?? variables["payload"] {
    return try memoryJSONValue(from: payload)
  }

  let payloadSource = nonEmptyString(config["payloadSource"]) ?? nonEmptyString(variables["payloadSource"]) ?? "input"
  switch payloadSource {
  case "event":
    if let event = variables["event"] {
      return try memoryJSONValue(from: event)
    }
    return .object([:])
  case "variables":
    return try memoryJSONValue(from: .object(variables))
  case "resolvedInput", "input":
    return try memoryJSONValue(from: .object(input.resolvedInputPayload))
  default:
    throw AdapterExecutionError(.policyBlocked, "unsupported memory payloadSource '\(payloadSource)'")
  }
}

private func memoryMatchPatterns(config: JSONObject, variables: JSONObject) -> [String] {
  if let configured = stringArrayValue(config["matchPatterns"]) {
    return configured
  }
  if let variablePatterns = stringArrayValue(variables["matchPatterns"]) {
    return variablePatterns
  }
  if let singlePattern = nonEmptyString(config["match"]) ?? nonEmptyString(variables["match"]) {
    return [singlePattern]
  }
  return []
}

private func stringArrayValue(_ value: JSONValue?) -> [String]? {
  guard case let .array(values) = value else {
    return nil
  }
  return values.compactMap(nonEmptyString)
}

private func memoryAddonOutput(
  input: WorkflowAddonExecutionInput,
  operation: BuiltinMemoryAddon,
  memoryId: String,
  databasePath: String,
  payload extraPayload: JSONObject
) -> AdapterExecutionOutput {
  var payload: JSONObject = [
    "status": .string("ok"),
    "addon": .string(input.addon.name),
    "operation": .string(operation.rawValue.replacingOccurrences(of: "riela/memory-", with: "")),
    "stepId": .string(input.stepId),
    "memoryId": .string(memoryId),
    "databasePath": .string(databasePath)
  ]
  for (key, value) in extraPayload {
    payload[key] = value
  }
  return AdapterExecutionOutput(
    provider: "riela-builtin-addon",
    model: input.addon.name,
    promptText: "",
    completionPassed: true,
    payload: payload
  )
}

private func memoryRecordJSON(_ record: MemoryRecord) -> JSONValue {
  .object([
    "recordId": .number(Double(record.recordId)),
    "memoryId": .string(record.memoryId),
    "workflowId": .string(record.workflowId),
    "nodeId": record.nodeId.map { .string($0) } ?? .null,
    "registeredAt": .string(record.registeredAt),
    "payload": jsonValue(from: record.payload)
  ])
}

private func memoryJSONValue(from value: JSONValue) throws -> MemoryJSONValue {
  switch value {
  case .null:
    return .null
  case let .bool(value):
    return .bool(value)
  case let .number(value):
    return .number(value)
  case let .string(value):
    return .string(value)
  case let .array(values):
    return .array(try values.map(memoryJSONValue))
  case let .object(values):
    return .object(try values.mapValues(memoryJSONValue))
  }
}

private func jsonValue(from value: MemoryJSONValue) -> JSONValue {
  switch value {
  case .null:
    return .null
  case let .bool(value):
    return .bool(value)
  case let .number(value):
    return .number(value)
  case let .string(value):
    return .string(value)
  case let .array(values):
    return .array(values.map(jsonValue))
  case let .object(values):
    return .object(values.mapValues(jsonValue))
  }
}

private func objectValue(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object) = value else {
    return nil
  }
  return object
}
