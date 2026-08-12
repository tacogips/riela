import AgentGateway
import Foundation
import RielaCore

public struct AgentGatewayNodeAdapter: NodeAdapter {
  public var executableName: String
  public var runner: any LocalAgentProcessRunning
  public var environment: [String: String]

  public init(
    executableName: String = "agent-gateway",
    runner: any LocalAgentProcessRunning = FoundationLocalAgentProcessRunner(),
    environment: [String: String] = [:]
  ) {
    self.executableName = executableName
    self.runner = runner
    self.environment = environment
  }

  public func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    let vendor = try gatewayVendor(input.node)
    let request = GatewayRPCRequest(
      id: input.executionIdentity?.stepId ?? UUID().uuidString,
      params: GatewayExecuteParams(
        vendor: vendor,
        model: gatewayVendorModel(vendor, input: input),
        prompt: input.promptText,
        systemPrompt: input.systemPromptText,
        workingDirectory: input.node.workingDirectory,
        executable: gatewayVendorExecutable(vendor, input: input, environment: environment),
        arguments: gatewayVendorArguments(vendor, input: input),
        providerName: input.node.provider?.name,
        apiKeyEnvironment: input.node.provider?.apiKeyEnv,
        baseURL: input.node.provider?.baseUrl,
        maxTokens: gatewayMaxTokens(input.node.variables)
      )
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let requestLine = String(bytes: try encoder.encode(request), encoding: .utf8) else {
      throw AdapterExecutionError(.invalidInput, "agent-gateway request is not valid UTF-8")
    }
    let collector = GatewayClientResponseCollector(requestId: request.id)
    let (stream, continuation) = AsyncStream.makeStream(of: AdapterBackendEvent.self)
    let consumer = Task {
      for await event in stream {
        await context.backendEventHandler?(event)
      }
    }
    let configuration = LocalAgentProcessConfiguration(
      executableURL: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: [executableName, "server"],
      environment: environment.merging(input.agentEnvironment) { _, nodeValue in nodeValue },
      workingDirectoryURL: input.node.workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
    )
    let result: LocalAgentProcessResult
    do {
      if let streamingRunner = runner as? any LocalAgentProcessEventStreaming {
        result = try await streamingRunner.run(
          configuration: configuration,
          stdin: requestLine + "\n",
          deadline: context.deadline,
          outputEventHandler: { output in
            guard output.stream == .stdout else { return }
            if let event = collector.consume(output.line) {
              continuation.yield(event)
            }
          }
        )
      } else {
        result = try await runner.run(configuration: configuration, stdin: requestLine + "\n", deadline: context.deadline)
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
    guard result.terminationStatus == 0 else {
      throw AdapterExecutionError(
        .providerError,
        "agent-gateway failed with exit code \(result.terminationStatus): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
      )
    }
    let response = try collector.terminalResponse()
    if let error = response.error {
      throw AdapterExecutionError(.providerError, "agent-gateway error \(error.code): \(error.message)")
    }
    guard let gatewayResult = response.result else {
      throw AdapterExecutionError(.invalidOutput, "agent-gateway returned no terminal result")
    }
    let normalized = try normalizeGatewayOutput(
      gatewayResult.text,
      source: "agent-gateway/\(vendor.rawValue)",
      requiresOutputContract: input.node.output != nil
    )
    return AdapterExecutionOutput(
      provider: vendor.rawValue,
      model: gatewayResult.model,
      promptText: input.promptText,
      completionPassed: normalized.completionPassed,
      when: normalized.when,
      payload: normalized.payload,
      usage: gatewayResult.usage.map {
        AdapterUsage(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens, totalTokens: $0.totalTokens)
      }
    )
  }
}

private final class GatewayClientResponseCollector: @unchecked Sendable {
  private let lock = NSLock()
  private let requestId: String
  private var response: GatewayRPCResponse?

  init(requestId: String) {
    self.requestId = requestId
  }

  func consume(_ line: String) -> AdapterBackendEvent? {
    lock.withLock {
      let data = Data(line.utf8)
      if let notification = try? JSONDecoder().decode(GatewayRPCNotification.self, from: data),
         notification.method == "agent/event",
         notification.params.requestId == requestId {
        let event = notification.params
        return AdapterBackendEvent(
          provider: event.vendor.rawValue,
          eventType: event.type,
          channel: AdapterBackendEventChannel(rawValue: event.channel.rawValue),
          contentDelta: event.textDelta,
          contentSnapshot: event.textSnapshot,
          isDelta: event.textDelta != nil,
          metadata: event.vendorPayload.map { ["vendorPayload": .string($0)] },
          sequence: event.sequence
        )
      }
      if let decoded = try? JSONDecoder().decode(GatewayRPCResponse.self, from: data), decoded.id == requestId {
        response = decoded
      }
      return nil
    }
  }

  func terminalResponse() throws -> GatewayRPCResponse {
    try lock.withLock {
      guard let response else {
        throw AdapterExecutionError(.invalidOutput, "agent-gateway stream ended without a terminal response")
      }
      return response
    }
  }
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
  case .officialCursorSDK: return .cursor
  case nil:
    throw AdapterExecutionError(.invalidInput, "agent-gateway requires an explicit execution backend")
  }
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
  case .openAI, .anthropic, .gemini, .openRouter: ("", "")
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
  case .openAI, .anthropic, .gemini, .openRouter: ("", .codexAgent)
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
  case .openAI, .anthropic, .gemini, .openRouter:
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
