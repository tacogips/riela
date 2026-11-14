import ACP
import AgentGateway
import Foundation
import Testing
@testable import RielaAdapters
@testable import RielaCore

@Test func gatewayAdapterSelectsVendorAndStreamsACPEvents() async throws {
  let notification = try acpLine(method: "session/update", params: ACPSessionNotification(
    sessionId: "sess-1",
    update: .agentMessageChunk(.text("hello"))
  ))
  let response = try acpResponseLine(id: 3, result: ACPPromptResponse(
    stopReason: .endTurn,
    meta: .object(["agentGateway": .object([
      "vendor": .string("openrouter"),
      "model": .string("openai/gpt-5"),
      "resultText": .string("hello"),
      "usage": .object([
        "inputTokens": .integer(2),
        "outputTokens": .integer(1),
        "totalTokens": .integer(3)
      ])
    ])])
  ))
  let runner = GatewayStubRunner(lines: [notification, response])
  let events = GatewayEventStore()
  let adapter = AgentGatewayNodeAdapter(executableName: "agent-gateway", runner: runner)
  let provider = try AgentProviderConfiguration(
    name: "openrouter",
    baseUrl: "https://openrouter.ai/api/v1",
    apiKeyEnv: "OPENROUTER_API_KEY"
  )
  let output = try await adapter.execute(
    AdapterExecutionInput(
      node: AgentNodePayload(
        id: "worker",
        executionBackend: .officialOpenAISDK,
        model: "openai/gpt-5",
        provider: provider
      ),
      promptText: "hello",
      executionIdentity: AdapterExecutionIdentity(
        workflowRunId: "run",
        workflowSessionId: "session",
        stepId: "worker"
      )
    ),
    context: AdapterExecutionContext { event in await events.append(event) }
  )

  #expect(output.provider == "openrouter")
  #expect(output.payload == ["text": .string("hello")])
  #expect(output.model == "openai/gpt-5")
  #expect(output.usage?.totalTokens == 3)
  let streamed = await events.values
  #expect(streamed.count == 1)
  #expect(streamed.first?.contentDelta == "hello")
  #expect(streamed.first?.channel == .assistant)
  let arguments = try #require(runner.arguments())
  #expect(arguments.contains("client"))
  #expect(pairedValue(arguments, "--vendor") == "openrouter")
  #expect(pairedValue(arguments, "--api-key-environment") == "OPENROUTER_API_KEY")
  #expect(pairedValue(arguments, "--base-url") == "https://openrouter.ai/api/v1")
  #expect(pairedValue(arguments, "--prompt-blocks") == "-")
  let blocks = try #require(runner.promptBlocks())
  #expect(blocks == [.text("hello")])
}

@Test func gatewayAdapterMapsEveryProductionBackendToAnExplicitVendor() async throws {
  let mappings: [(NodeExecutionBackend, GatewayVendor)] = [
    (.codexAgent, .codex),
    (.claudeCodeAgent, .claudeCode),
    (.cursorCliAgent, .cursor),
    (.officialOpenAISDK, .openAI),
    (.officialAnthropicSDK, .anthropic),
    (.officialGeminiSDK, .gemini),
    (.officialCursorSDK, .cursorAPI)
  ]
  for (backend, vendor) in mappings {
    let response = try acpResponseLine(id: 3, result: ACPPromptResponse(
      stopReason: .endTurn,
      meta: .object(["agentGateway": .object(["resultText": .string("ok")])])
    ))
    let runner = GatewayStubRunner(lines: [response])
    _ = try await AgentGatewayNodeAdapter(runner: runner).execute(
      AdapterExecutionInput(
        node: AgentNodePayload(id: "worker", executionBackend: backend, model: "model"),
        promptText: "prompt",
        executionIdentity: AdapterExecutionIdentity(
          workflowRunId: "run",
          workflowSessionId: "session",
          stepId: "worker"
        )
      ),
      context: AdapterExecutionContext()
    )
    #expect(pairedValue(runner.arguments() ?? [], "--vendor") == vendor.rawValue)
  }
}

@Test func cliVendorKeepsOpenRouterAsProviderRoutingInsteadOfChangingHarness() async throws {
  let response = try acpResponseLine(id: 3, result: ACPPromptResponse(
    stopReason: .endTurn,
    meta: .object(["agentGateway": .object(["resultText": .string("ok")])])
  ))
  let runner = GatewayStubRunner(lines: [response])
  let provider = try OpenRouterProvider.configuration(for: .codexAgent)
  _ = try await AgentGatewayNodeAdapter(runner: runner).execute(
    AdapterExecutionInput(
      node: AgentNodePayload(
        id: "worker",
        executionBackend: .codexAgent,
        model: "model",
        provider: provider
      ),
      promptText: "prompt",
      executionIdentity: AdapterExecutionIdentity(
        workflowRunId: "run",
        workflowSessionId: "session",
        stepId: "worker"
      )
    ),
    context: AdapterExecutionContext()
  )
  let arguments = try #require(runner.arguments())
  #expect(pairedValue(arguments, "--vendor") == "codex")
  #expect(pairedValue(arguments, "--provider-name") == "openrouter")
  #expect(pairedValue(arguments, "--api-key-environment") == "OPENROUTER_API_KEY")
}

@Test func cliVendorForwardsCustomBaseURLAndCredentialEnvironment() async throws {
  let response = try acpResponseLine(id: 3, result: ACPPromptResponse(
    stopReason: .endTurn,
    meta: .object(["agentGateway": .object(["resultText": .string("ok")])])
  ))
  let runner = GatewayStubRunner(lines: [response])
  _ = try await AgentGatewayNodeAdapter(runner: runner).execute(
    AdapterExecutionInput(
      node: AgentNodePayload(
        id: "worker",
        executionBackend: .claudeCodeAgent,
        model: "",
        baseURL: "https://api.kimi.example",
        apiKeyEnvironment: "KIMI_API_KEY"
      ),
      promptText: "prompt",
      executionIdentity: AdapterExecutionIdentity(
        workflowRunId: "run",
        workflowSessionId: "session",
        stepId: "worker"
      )
    ),
    context: AdapterExecutionContext()
  )
  let arguments = try #require(runner.arguments())
  #expect(pairedValue(arguments, "--vendor") == "claude-code")
  #expect(pairedValue(arguments, "--model") == "custom")
  #expect(pairedValue(arguments, "--base-url") == "https://api.kimi.example")
  #expect(pairedValue(arguments, "--api-key-environment") == "KIMI_API_KEY")
  #expect(pairedValue(arguments, "--provider-name") == nil)
}

@Test func gatewayAdapterPreservesCLIExecutionControls() async throws {
  let response = try acpResponseLine(id: 3, result: ACPPromptResponse(
    stopReason: .endTurn,
    meta: .object(["agentGateway": .object(["resultText": .string("ok")])])
  ))
  let runner = GatewayStubRunner(lines: [response])
  _ = try await AgentGatewayNodeAdapter(runner: runner).execute(
    AdapterExecutionInput(
      node: AgentNodePayload(
        id: "worker",
        executionBackend: .codexAgent,
        model: "gpt-5",
        effort: .high,
        agentSandbox: .workspaceWrite,
        agentToolPolicy: AgentToolPolicy(codexArguments: ["--search"]),
        variables: ["codexAdditionalArgs": .array([.string("--ephemeral")])]
      ),
      promptText: "prompt",
      executionIdentity: AdapterExecutionIdentity(
        workflowRunId: "run",
        workflowSessionId: "session",
        stepId: "worker"
      )
    ),
    context: AdapterExecutionContext()
  )
  let arguments = try #require(runner.arguments())
  let separator = try #require(arguments.firstIndex(of: "--"))
  let vendorArguments = Array(arguments[arguments.index(after: separator)...])
  #expect(vendorArguments.contains(#"model_reasoning_effort="high""#))
  #expect(vendorArguments.contains("--sandbox"))
  #expect(vendorArguments.contains("workspace-write"))
  #expect(vendorArguments.contains("--search"))
  #expect(vendorArguments.contains("--ephemeral"))
  #expect(pairedValue(vendorArguments, "--disable") == "multi_agent")
}

@Test func gatewayAdapterEnablesCodexSupervisorModeOnlyWhenRequested() async throws {
  let response = try acpResponseLine(id: 3, result: ACPPromptResponse(
    stopReason: .endTurn,
    meta: .object(["agentGateway": .object(["resultText": .string("ok")])])
  ))
  let runner = GatewayStubRunner(lines: [response])
  _ = try await AgentGatewayNodeAdapter(
    runner: runner,
    codexSupervisorModeEnabled: true
  ).execute(
    AdapterExecutionInput(
      node: AgentNodePayload(id: "worker", executionBackend: .codexAgent, model: "gpt-5"),
      promptText: "prompt"
    ),
    context: AdapterExecutionContext()
  )

  let arguments = try #require(runner.arguments())
  let separator = try #require(arguments.firstIndex(of: "--"))
  let vendorArguments = Array(arguments[arguments.index(after: separator)...])
  #expect(pairedValue(vendorArguments, "--enable") == "multi_agent")
  #expect(!vendorArguments.contains("--disable"))
}

@Test func gatewayAdapterReusesOnlyTheInheritedWorkflowSession() async throws {
  let store = AgentGatewaySessionStore()
  let firstResponse = try acpResponseLine(id: 3, result: ACPPromptResponse(
    stopReason: .endTurn,
    meta: .object(["agentGateway": .object([
      "resultText": .string("first"),
      "vendorSessionId": .string("backend-session-1")
    ])])
  ))
  let firstRunner = GatewayStubRunner(lines: [firstResponse])
  _ = try await AgentGatewayNodeAdapter(runner: firstRunner, sessionStore: store).execute(
    AdapterExecutionInput(
      node: AgentNodePayload(id: "producer", executionBackend: .codexAgent, model: "gpt-5"),
      promptText: "first",
      executionIdentity: AdapterExecutionIdentity(
        workflowRunId: "run-1",
        workflowSessionId: "workflow-session-1",
        stepId: "producer"
      )
    ),
    context: AdapterExecutionContext()
  )
  #expect(pairedValue(firstRunner.arguments() ?? [], "--session-id") == nil)

  let secondResponse = try acpResponseLine(id: 3, result: ACPPromptResponse(
    stopReason: .endTurn,
    meta: .object(["agentGateway": .object(["resultText": .string("second")])])
  ))
  let secondRunner = GatewayStubRunner(lines: [secondResponse])
  _ = try await AgentGatewayNodeAdapter(runner: secondRunner, sessionStore: store).execute(
    AdapterExecutionInput(
      node: AgentNodePayload(id: "consumer", executionBackend: .codexAgent, model: "gpt-5"),
      promptText: "second",
      sessionPolicy: WorkflowStepSessionPolicy(mode: .reuse, inheritFromStepId: "producer"),
      executionIdentity: AdapterExecutionIdentity(
        workflowRunId: "run-1",
        workflowSessionId: "workflow-session-1",
        stepId: "consumer"
      )
    ),
    context: AdapterExecutionContext()
  )
  #expect(pairedValue(secondRunner.arguments() ?? [], "--session-id") == "backend-session-1")

  let isolatedKey = AgentGatewaySessionKey(
    workflowRunId: "run-1",
    workflowSessionId: "workflow-session-2",
    stepId: "producer"
  )
  #expect(store.sessionId(for: isolatedKey) == nil)
}

@Test func gatewayAdapterSurfacesACPErrorResponses() async throws {
  let errorLine = #"{"jsonrpc":"2.0","id":3,"error":{"code":-32011,"message":"missing credential environment 'OPENAI_API_KEY'"}}"#
  let runner = GatewayStubRunner(lines: [errorLine], terminationStatus: 1)
  do {
    _ = try await AgentGatewayNodeAdapter(runner: runner).execute(
      AdapterExecutionInput(
        node: AgentNodePayload(id: "worker", executionBackend: .officialOpenAISDK, model: "gpt-5"),
        promptText: "prompt",
        executionIdentity: AdapterExecutionIdentity(
          workflowRunId: "run",
          workflowSessionId: "session",
          stepId: "worker"
        )
      ),
      context: AdapterExecutionContext()
    )
    Issue.record("expected a provider error")
  } catch let error as AdapterExecutionError {
    #expect(error.message.contains("-32011"))
    #expect(error.message.contains("missing credential"))
  }
}

@Test func gatewayAdapterFallsBackToAccumulatedChunksWithoutResultText() async throws {
  let chunks = [
    try acpLine(method: "session/update", params: ACPSessionNotification(
      sessionId: "sess-1", update: .agentMessageChunk(.text("hel"))
    )),
    try acpLine(method: "session/update", params: ACPSessionNotification(
      sessionId: "sess-1", update: .agentMessageChunk(.text("lo"))
    ))
  ]
  let response = try acpResponseLine(id: 3, result: ACPPromptResponse(stopReason: .endTurn))
  let runner = GatewayStubRunner(lines: [chunks[0], chunks[1], response])
  let output = try await AgentGatewayNodeAdapter(runner: runner).execute(
    AdapterExecutionInput(
      node: AgentNodePayload(id: "worker", executionBackend: .codexAgent, model: "gpt-5"),
      promptText: "prompt",
      executionIdentity: AdapterExecutionIdentity(
        workflowRunId: "run",
        workflowSessionId: "session",
        stepId: "worker"
      )
    ),
    context: AdapterExecutionContext()
  )
  #expect(output.payload == ["text": .string("hello")])
}

@Test func gatewayAdapterIgnoresForwardCompatibleUnknownACPUpdates() async throws {
  let unknownUpdate = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1","update":{"sessionUpdate":"available_commands_update","commands":[]}}}"#
  let response = try acpResponseLine(id: 3, result: ACPPromptResponse(
    stopReason: .endTurn,
    meta: .object(["agentGateway": .object(["resultText": .string("ok")])])
  ))
  let runner = GatewayStubRunner(lines: [unknownUpdate, response])
  let events = GatewayEventStore()

  let output = try await AgentGatewayNodeAdapter(runner: runner).execute(
    AdapterExecutionInput(
      node: AgentNodePayload(id: "worker", executionBackend: .codexAgent, model: "gpt-5"),
      promptText: "prompt",
      executionIdentity: AdapterExecutionIdentity(
        workflowRunId: "run",
        workflowSessionId: "session",
        stepId: "worker"
      )
    ),
    context: AdapterExecutionContext { event in await events.append(event) }
  )

  #expect(output.payload == ["text": .string("ok")])
  #expect(await events.values.isEmpty)
}

@Test func clientTurnRunsOneShotACPPromptAndParsesTypedResult() async throws {
  let chunk = try acpLine(method: "session/update", params: ACPSessionNotification(
    sessionId: "sess-1",
    update: .agentMessageChunk(.text("partial"))
  ))
  let response = try acpResponseLine(id: 3, result: ACPPromptResponse(
    stopReason: .endTurn,
    meta: .object(["agentGateway": .object([
      "model": .string("gemini-3.5-flash"),
      "resultText": .string("ocr text"),
      "usage": .object(["inputTokens": .integer(10), "outputTokens": .integer(4), "totalTokens": .integer(14)])
    ])])
  ))
  let runner = GatewayStubRunner(lines: [chunk, response])
  let turn = AgentGatewayClientTurn(runner: runner)

  let result = try await turn.run(AgentGatewayClientTurn.Request(
    vendor: .gemini,
    model: "gemini-3.5-flash",
    systemPrompt: "system",
    apiKeyEnvironment: "GOOGLE_API_KEY",
    workingDirectory: "/work",
    promptBlocks: [
      .text("read this"),
      .image(ACPImageContent(data: "cGRm", mimeType: "application/pdf"))
    ]
  ))

  #expect(result.stopReason == .endTurn)
  #expect(result.text == "ocr text")
  #expect(result.model == "gemini-3.5-flash")
  #expect(result.usage?.totalTokens == 14)
  let arguments = try #require(runner.arguments())
  #expect(arguments.contains("client"))
  #expect(pairedValue(arguments, "--vendor") == "gemini")
  #expect(pairedValue(arguments, "--model") == "gemini-3.5-flash")
  #expect(pairedValue(arguments, "--system") == "system")
  #expect(pairedValue(arguments, "--api-key-environment") == "GOOGLE_API_KEY")
  #expect(pairedValue(arguments, "--cwd") == "/work")
  #expect(pairedValue(arguments, "--prompt-blocks") == "-")
  let blocks = try #require(runner.promptBlocks())
  #expect(blocks == [
    .text("read this"),
    .image(ACPImageContent(data: "cGRm", mimeType: "application/pdf"))
  ])
}

@Test func clientTurnSurfacesACPProtocolErrors() async throws {
  let errorLine = #"{"jsonrpc":"2.0","id":3,"error":{"code":-32603,"message":"vendor exploded"}}"#
  let runner = GatewayStubRunner(lines: [errorLine])
  let turn = AgentGatewayClientTurn(runner: runner)

  await #expect(throws: AdapterExecutionError.self) {
    _ = try await turn.run(AgentGatewayClientTurn.Request(
      vendor: .gemini,
      model: "gemini-3.5-flash",
      promptBlocks: [.text("read this")]
    ))
  }
}

private final class GatewayStubRunner: LocalProcessEventStreaming, @unchecked Sendable {
  private let lock = NSLock()
  private let lines: [String]
  private let terminationStatus: Int32
  private var capturedArguments: [String]?
  private var capturedStdin: String?

  init(lines: [String], terminationStatus: Int32 = 0) {
    self.lines = lines
    self.terminationStatus = terminationStatus
  }

  func run(
    configuration: LocalProcessConfiguration,
    stdin: String,
    deadline: Date?
  ) async throws -> LocalProcessResult {
    try await run(configuration: configuration, stdin: stdin, deadline: deadline, outputEventHandler: nil)
  }

  func run(
    configuration: LocalProcessConfiguration,
    stdin: String,
    deadline _: Date?,
    outputEventHandler: (@Sendable (LocalProcessOutputEvent) -> Void)?
  ) async throws -> LocalProcessResult {
    lock.withLock {
      capturedArguments = configuration.arguments
      capturedStdin = stdin
    }
    for line in lines {
      outputEventHandler?(LocalProcessOutputEvent(stream: .stdout, line: line))
    }
    return LocalProcessResult(
      stdout: lines.joined(separator: "\n"),
      stderr: "",
      terminationStatus: terminationStatus
    )
  }

  func arguments() -> [String]? { lock.withLock { capturedArguments } }

  func promptBlocks() -> [ACPContentBlock]? {
    let stdin = lock.withLock { capturedStdin }
    guard let stdin else { return nil }
    return try? JSONDecoder().decode([ACPContentBlock].self, from: Data(stdin.utf8))
  }
}

private actor GatewayEventStore {
  var values: [AdapterBackendEvent] = []
  func append(_ event: AdapterBackendEvent) { values.append(event) }
}

private func pairedValue(_ arguments: [String], _ key: String) -> String? {
  guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else { return nil }
  return arguments[index + 1]
}

private struct ACPNotificationLine<T: Encodable>: Encodable {
  var jsonrpc = "2.0"
  var method: String
  var params: T
}

private struct ACPResponseEnvelopeLine<Value: Encodable>: Encodable {
  var jsonrpc = "2.0"
  var id: Int
  var result: Value
}

private func acpLine<Params: Encodable>(method: String, params: Params) throws -> String {
  let data = try JSONEncoder().encode(ACPNotificationLine(method: method, params: params))
  guard let line = String(bytes: data, encoding: .utf8) else {
    throw AdapterExecutionError(.invalidOutput, "not UTF-8")
  }
  return line
}

private func acpResponseLine<T: Encodable>(id: Int, result: T) throws -> String {
  let data = try JSONEncoder().encode(ACPResponseEnvelopeLine(id: id, result: result))
  guard let line = String(bytes: data, encoding: .utf8) else {
    throw AdapterExecutionError(.invalidOutput, "not UTF-8")
  }
  return line
}
