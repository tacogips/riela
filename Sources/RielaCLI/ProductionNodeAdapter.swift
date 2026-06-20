import ClaudeCodeAgent
import CodexAgent
import CursorCLIAgent
import Foundation
import RielaAdapters
import RielaCore

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

typealias GeminiAddonAdapterFactory = @Sendable (OfficialSDKAdapterConfiguration) async throws -> any NodeAdapter

struct BuiltinWorkflowAddonResolver: WorkflowAddonResolving {
  var environment: [String: String]
  var geminiAdapterFactory: GeminiAddonAdapterFactory

  init(
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment(),
    geminiAdapterFactory: @escaping GeminiAddonAdapterFactory = { configuration in
      GeminiSDKAdapter(configuration: configuration)
    }
  ) {
    self.environment = environment
    self.geminiAdapterFactory = geminiAdapterFactory
  }

  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    guard input.addon.name.hasPrefix("riela/") else {
      throw AdapterExecutionError(.providerError, "missing add-on resolver for '\(input.addon.name)'")
    }
    if input.addon.name == "riela/gemini-sdk-worker" {
      return try await executeGeminiSDKWorker(input, context: context)
    }
    if input.addon.name == "riela/chat-persona-router" {
      return executeChatPersonaRouter(input)
    }
    if input.addon.name == "riela/chat-reply-worker" {
      return try executeChatReplyWorker(input)
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

    var variables = input.variables
    for (key, value) in input.resolvedInputPayload {
      variables[key] = value
    }
    variables["input"] = .object(input.resolvedInputPayload)
    variables["inbox"] = .object([
      "latest": .object([
        "output": .object([
          "payload": .object(input.resolvedInputPayload)
        ])
      ])
    ])
    variables["workflowId"] = .string(input.workflowId)
    variables["stepId"] = .string(input.stepId)
    variables["nodeId"] = .string(input.nodeId)
    variables["addonName"] = .string(input.addon.name)
    for (key, value) in renderAddonInputs(input.addon.inputs, variables: variables) {
      variables[key] = value
    }

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

private func objectValue(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object) = value else {
    return nil
  }
  return object
}
