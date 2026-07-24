import Foundation
import RielaAdapters
import RielaCore

private let defaultCodexAuthPreflightTimeout: TimeInterval = 5
private let codexJSONEventTypes: Set<String> = [
  "session_meta",
  "thread.started",
  "turn.started",
  "turn.completed",
  "item.started",
  "item.updated",
  "item.completed",
  "event_msg",
  "response_item",
  "assistant.snapshot",
  "session.started",
  "session.error"
]
private let codexItemEventTypes: Set<String> = ["item.started", "item.updated", "item.completed"]

public struct CodexAgentCommandBuilder: LocalAgentCommandBuilding {
  public var executableName: String
  public var environment: [String: String]
  public var additionalArguments: [String]

  public var provider: String { CliAgentBackend.codexAgent.rawValue }

  public init(
    executableName: String = "codex",
    environment: [String: String] = [:],
    additionalArguments: [String] = []
  ) {
    self.executableName = executableName
    self.environment = environment
    self.additionalArguments = additionalArguments
  }

  public func buildCommand(for input: AdapterExecutionInput) throws -> LocalAgentCommand {
    try validateAgentProviderRoutingForAdapter(input.node)
    let imagePaths = resolveAdapterImagePaths(input)
    var configOverrides = input.node.effort.map { [#"model_reasoning_effort="\#($0.rawValue)""#] } ?? []
    if let provider = input.node.provider {
      configOverrides.append(contentsOf: [
        "model_provider=\(provider.name)",
        "model_providers.\(provider.name).name=\(provider.name)",
        "model_providers.\(provider.name).base_url=\(provider.baseUrl)"
      ])
      if let apiKeyEnv = provider.apiKeyEnv {
        configOverrides.append("model_providers.\(provider.name).env_key=\(apiKeyEnv)")
      }
    }
    let promptText = buildCombinedPromptText(promptText: input.promptText, systemPromptText: input.systemPromptText)
    let processOptions = CodexProcessOptions(
      model: input.node.model,
      sandbox: input.node.agentSandbox?.rawValue,
      images: imagePaths,
      configOverrides: configOverrides,
      additionalArguments: additionalArguments
        + agentToolPolicyArguments(input.node.agentToolPolicy, backend: .codexAgent)
        + codexUnifiedExecArguments(input.node.variables["codexUnifiedExec"])
        + stringArray(input.node.variables["codexAdditionalArgs"])
    )
    let arguments = [executableName] + CodexProcessCommandBuilder.buildExecArguments(
      prompt: "-",
      options: processOptions
    )
    try CodexProcessCommandBuilder.validatePipedStdinExecPromptTransport(arguments: arguments)

    let environment = mergedAgentProcessEnvironment(
      baseEnvironment: environment,
      input: input,
      provider: provider
    )
    let recoveryPolicy = codexToolChildRecoveryPolicy(input.node.variables)
    return LocalAgentCommand(
      provider: provider,
      metadata: providerMetadata(input.node.provider),
      additionalSensitiveValues: providerCredentialSensitiveValues(
        input.node.provider,
        processEnvironment: environment
      ),
      configuration: LocalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: arguments,
        environment: environment,
        workingDirectoryURL: input.node.workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
      ),
      stdin: promptText,
      normalizeStdout: normalizeCodexExecJSONStdout,
      backendEventType: codexBackendEventType,
      classifyBackendEvent: classifyCodexBackendEvent,
      toolChildMonitor: recoveryPolicy.mode == .off ? nil : CodexToolChildRecoveryMonitor(
        policy: recoveryPolicy,
        workflowExecutionId: "codex-agent",
        stepExecutionId: input.node.id,
        attempt: input.executionIndex
      )
    )
  }
}

private func providerMetadata(_ configuration: AgentProviderConfiguration?) -> JSONObject {
  configuration.map { ["provider_name": .string($0.name)] } ?? [:]
}

public struct CodexAgentAdapter: NodeAdapter {
  private let adapter: LocalAgentCommandAdapter
  private let executableName: String
  private let runner: any LocalAgentProcessRunning
  private let environment: [String: String]
  private let authPreflight: Bool
  private let checkAuthPreflight: (@Sendable (AdapterExecutionInput) async throws -> Void)?

  public init(
    executableName: String = "codex",
    runner: any LocalAgentProcessRunning = FoundationLocalAgentProcessRunner(),
    environment: [String: String] = [:],
    additionalArguments: [String] = [],
    authPreflight: Bool = true,
    checkAuthPreflight: (@Sendable (AdapterExecutionInput) async throws -> Void)? = nil
  ) {
    self.executableName = executableName
    self.runner = runner
    self.environment = environment
    self.authPreflight = authPreflight
    self.adapter = LocalAgentCommandAdapter(
      commandBuilder: CodexAgentCommandBuilder(
        executableName: executableName,
        environment: environment,
        additionalArguments: additionalArguments
      ),
      runner: runner
    )
    self.checkAuthPreflight = checkAuthPreflight
  }

  public func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    if authPreflight {
      if let checkAuthPreflight {
        let sensitiveValues = codexPreflightSensitiveValues(input: input, baseEnvironment: environment)
        do {
          try await checkAuthPreflight(input)
        } catch let error as CancellationError {
          throw error
        } catch let error as AdapterExecutionError {
          throw AdapterExecutionError(
            error.code,
            redactAdapterSensitiveText(error.message, additionalSensitiveValues: sensitiveValues),
            isRetryable: error.isRetryable,
            retryAfter: error.retryAfter
          )
        } catch {
          throw AdapterExecutionError(
            .policyBlocked,
            "codex-agent authentication is unavailable: \(redactAdapterSensitiveText(error.localizedDescription, additionalSensitiveValues: sensitiveValues))"
          )
        }
      } else {
        try await runCodexDefaultAuthPreflight(
          input: input,
          executableName: executableName,
          environment: environment,
          runner: runner,
          deadline: context.deadline
        )
      }
    }
    return try await adapter.execute(input, context: context)
  }
}

private func runCodexDefaultAuthPreflight(
  input: AdapterExecutionInput,
  executableName: String,
  environment: [String: String],
  runner: any LocalAgentProcessRunning,
  deadline: Date?
) async throws {
  let preflightEnvironment = mergedAgentProcessEnvironment(
    baseEnvironment: environment,
    input: input,
    provider: CliAgentBackend.codexAgent.rawValue
  )
  let sensitiveValues = sensitiveAdapterEnvironmentValues(preflightEnvironment)
    + providerCredentialSensitiveValues(input.node.provider, processEnvironment: preflightEnvironment)
  let preflightDeadline = defaultAgentPreflightDeadline(existingDeadline: deadline, timeout: defaultCodexAuthPreflightTimeout)
  let version: LocalAgentProcessResult
  do {
    version = try await runner.run(
      configuration: LocalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [executableName, "--version"],
        environment: preflightEnvironment,
        workingDirectoryURL: input.node.workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
      ),
      stdin: "",
      deadline: preflightDeadline
    )
  } catch let error as CancellationError {
    throw error
  } catch {
    throw AdapterExecutionError(
      .policyBlocked,
      "codex-agent CLI is unavailable: \(agentPreflightErrorDetail(error, fallback: "codex command timed out", additionalSensitiveValues: sensitiveValues))"
    )
  }
  if version.terminationStatus != 0 {
    throw AdapterExecutionError(
      .policyBlocked,
      "codex-agent CLI is unavailable: \(compactAgentReadinessMessage([version.stderr, version.stdout].joined(separator: "\n"), fallback: "codex command is unavailable", additionalSensitiveValues: sensitiveValues))"
    )
  }
  // Alternate providers authenticate through their configured runtime
  // environment. The default Codex account login state is unrelated and must
  // not block an otherwise valid provider-backed execution.
  if input.node.provider != nil {
    return
  }
  let result: LocalAgentProcessResult
  do {
    result = try await runner.run(
      configuration: LocalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [executableName, "login", "status"],
        environment: preflightEnvironment,
        workingDirectoryURL: input.node.workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
      ),
      stdin: "",
      deadline: preflightDeadline
    )
  } catch let error as CancellationError {
    throw error
  } catch {
    throw AdapterExecutionError(
      .policyBlocked,
      "codex-agent authentication is unavailable: \(agentPreflightErrorDetail(error, fallback: "login status timed out", additionalSensitiveValues: sensitiveValues))"
    )
  }
  let combined = [result.stderr, result.stdout].joined(separator: "\n")
  if result.terminationStatus != 0 || hasAuthFailureText(combined) {
    throw AdapterExecutionError(
      .policyBlocked,
      "codex-agent authentication is unavailable: \(compactAgentReadinessMessage(combined, fallback: "login status failed", additionalSensitiveValues: sensitiveValues))"
    )
  }
}

private func codexPreflightSensitiveValues(
  input: AdapterExecutionInput,
  baseEnvironment: [String: String]
) -> [String] {
  let processEnvironment = mergedAgentProcessEnvironment(
    baseEnvironment: baseEnvironment,
    input: input,
    provider: CliAgentBackend.codexAgent.rawValue
  )
  return sensitiveAdapterEnvironmentValues(processEnvironment)
    + providerCredentialSensitiveValues(input.node.provider, processEnvironment: processEnvironment)
}

private func hasAuthFailureText(_ text: String) -> Bool {
  text.range(of: #"not logged|login required|unauthorized|credential|expired|permission denied"#, options: [.regularExpression, .caseInsensitive]) != nil
}

private func stringArray(_ value: JSONValue?) -> [String] {
  guard case let .array(entries) = value else {
    return []
  }
  return entries.compactMap { entry in
    guard case let .string(text) = entry else {
      return nil
    }
    return text
  }
}

private func boolValue(_ value: JSONValue?) -> Bool? {
  guard case let .bool(value) = value else {
    return nil
  }
  return value
}

private func codexUnifiedExecArguments(_ value: JSONValue?) -> [String] {
  guard boolValue(value) == true else {
    return ["--disable", "unified_exec"]
  }
  return []
}

public func normalizeCodexExecJSONStdout(_ text: String) -> String {
  let lines = text
    .split(whereSeparator: \.isNewline)
    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }
  guard !lines.isEmpty else {
    return text
  }

  var parsedObjects: [JSONObject] = []
  var containsCodexEvent = false
  for line in lines {
    guard
      let data = line.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
      case let .object(object) = decoded
    else {
      return text
    }
    if isCodexJSONEvent(object) {
      containsCodexEvent = true
    }
    parsedObjects.append(object)
  }
  guard containsCodexEvent else {
    return text
  }

  var finalAssistantContent: String?
  for object in parsedObjects {
    if let content = codexAssistantContent(from: object) {
      finalAssistantContent = content
    }
  }

  return finalAssistantContent ?? ""
}

private func isCodexJSONEvent(_ object: JSONObject) -> Bool {
  guard let type = stringValue(object["type"]) else {
    return false
  }
  return codexJSONEventTypes.contains(type)
}

private func codexBackendEventType(_ line: String) -> String? {
  guard
    let data = line.data(using: .utf8),
    let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
    case let .object(object) = decoded,
    isCodexJSONEvent(object)
  else {
    return nil
  }
  return stringValue(object["type"]) ?? "json-event"
}

private func classifyCodexBackendEvent(_ line: String) -> AdapterBackendEvent? {
  guard
    let data = line.data(using: .utf8),
    let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
    case let .object(object) = decoded,
    isCodexJSONEvent(object)
  else {
    return nil
  }
  let eventType = stringValue(object["type"]) ?? "json-event"
  if eventType == "turn.completed", let usage = objectValue(object["usage"]) {
    return AdapterBackendEvent(provider: CliAgentBackend.codexAgent.rawValue, eventType: eventType, channel: .usage, usage: usage)
  }
  if let classified = classifyCodexContentEvent(object: object, eventType: eventType) {
    return classified
  }
  return AdapterBackendEvent(provider: CliAgentBackend.codexAgent.rawValue, eventType: eventType, channel: .lifecycle)
}

private func classifyCodexContentEvent(object: JSONObject, eventType: String) -> AdapterBackendEvent? {
  if eventType == "assistant.snapshot", let content = stringValue(object["content"]) {
    return AdapterBackendEvent(
      provider: CliAgentBackend.codexAgent.rawValue,
      eventType: eventType,
      channel: .assistant,
      contentSnapshot: content
    )
  }
  if isCodexItemEvent(eventType), let item = objectValue(object["item"]) {
    switch stringValue(item["type"]) {
    case "agent_message":
      guard eventType == "item.completed" else {
        return nil
      }
      return AdapterBackendEvent(
        provider: CliAgentBackend.codexAgent.rawValue,
        eventType: eventType,
        channel: .assistant,
        contentSnapshot: stringValue(item["text"])
      )
    case "reasoning":
      guard eventType == "item.completed" else {
        return nil
      }
      return AdapterBackendEvent(
        provider: CliAgentBackend.codexAgent.rawValue,
        eventType: eventType,
        channel: .thinking,
        contentSnapshot: stringValue(item["text"]) ?? outputText(from: item["content"])
      )
    case "command_execution", "tool_call":
      return AdapterBackendEvent(
        provider: CliAgentBackend.codexAgent.rawValue,
        eventType: eventType,
        channel: .tool,
        contentSnapshot: codexToolContentSnapshot(from: item),
        toolName: codexToolName(from: item)
      )
    default:
      return nil
    }
  }
  if let content = codexAssistantContent(from: object) {
    return AdapterBackendEvent(
      provider: CliAgentBackend.codexAgent.rawValue,
      eventType: eventType,
      channel: .assistant,
      contentSnapshot: content
    )
  }
  return nil
}

private func isCodexItemEvent(_ eventType: String) -> Bool {
  codexItemEventTypes.contains(eventType)
}

private func codexToolContentSnapshot(from item: JSONObject) -> String? {
  stringValue(item["command"])
    ?? stringValue(item["text"])
    ?? outputText(from: item["content"])
    ?? stringValue(item["status"])
}

private func codexToolName(from item: JSONObject) -> String? {
  stringValue(item["name"])
    ?? stringValue(item["tool_name"])
    ?? stringValue(item["type"])
}

private func codexAssistantContent(from object: JSONObject) -> String? {
  if stringValue(object["type"]) == "assistant.snapshot", let content = stringValue(object["content"]) {
    return content
  }

  if ["AgentMessage", "agent_message"].contains(stringValue(object["type"])), let message = stringValue(object["message"]) {
    return message
  }

  if ["AgentMessage", "agent_message"].contains(stringValue(object["type"])), let text = stringValue(object["text"]) {
    return text
  }

  if ["TurnComplete", "task_complete"].contains(stringValue(object["type"])) {
    return stringValue(object["last_agent_message"]) ?? stringValue(object["lastAgentMessage"])
  }

  if stringValue(object["role"]) == "assistant", let content = outputText(from: object["content"]) {
    return content
  }

  for key in ["payload", "item", "message"] {
    if let nested = objectValue(object[key]), let content = codexAssistantContent(from: nested) {
      return content
    }
  }

  return nil
}

private func outputText(from value: JSONValue?) -> String? {
  guard let value else {
    return nil
  }
  switch value {
  case let .string(text):
    return text
  case let .array(entries):
    let text = entries.compactMap { entry -> String? in
      guard case let .object(object) = entry else {
        return nil
      }
      let type = stringValue(object["type"])
      if type == "output_text" || type == "text", let text = stringValue(object["text"]) {
        return text
      }
      return outputText(from: object["content"])
    }.joined()
    return text.isEmpty ? nil : text
  case let .object(object):
    return outputText(from: object["content"])
  case .null, .bool, .integer, .number:
    return nil
  }
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
