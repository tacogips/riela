import AgentGateway
import Foundation
import Testing
@testable import RielaAdapters
@testable import RielaCore

@Test func gatewayAdapterSelectsVendorAndStreamsJSONLEvents() async throws {
  let notification = GatewayRPCNotification(event: GatewayStreamEvent(
    requestId: "worker",
    sequence: 1,
    vendor: .openRouter,
    type: "assistant.delta",
    channel: .assistant,
    textDelta: "hello",
    vendorPayload: #"{"choices":[]}"#
  ))
  let response = GatewayRPCResponse(
    id: "worker",
    result: GatewayExecuteResult(
      vendor: .openRouter,
      model: "openai/gpt-5",
      text: "hello",
      usage: GatewayUsage(inputTokens: 2, outputTokens: 1, totalTokens: 3)
    )
  )
  let runner = GatewayStubRunner(lines: [try encodeLine(notification), try encodeLine(response)])
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
  #expect(output.usage?.totalTokens == 3)
  let streamed = await events.values
  #expect(streamed.count == 1)
  #expect(streamed.first?.contentDelta == "hello")
  let request = try #require(runner.request())
  #expect(request.params.vendor == .openRouter)
  #expect(request.params.apiKeyEnvironment == "OPENROUTER_API_KEY")
  #expect(request.params.baseURL == "https://openrouter.ai/api/v1")
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
    let response = GatewayRPCResponse(
      id: "worker",
      result: GatewayExecuteResult(vendor: vendor, model: "model", text: "ok")
    )
    let runner = GatewayStubRunner(lines: [try encodeLine(response)])
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
    #expect(runner.request()?.params.vendor == vendor)
  }
}

@Test func cliVendorKeepsOpenRouterAsProviderRoutingInsteadOfChangingHarness() async throws {
  let response = GatewayRPCResponse(
    id: "worker",
    result: GatewayExecuteResult(vendor: .codex, model: "model", text: "ok")
  )
  let runner = GatewayStubRunner(lines: [try encodeLine(response)])
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
  #expect(runner.request()?.params.vendor == .codex)
  #expect(runner.request()?.params.providerName == "openrouter")
  #expect(runner.request()?.params.apiKeyEnvironment == "OPENROUTER_API_KEY")
}

@Test func gatewayAdapterPreservesCLIExecutionControls() async throws {
  let response = GatewayRPCResponse(
    id: "worker",
    result: GatewayExecuteResult(vendor: .codex, model: "gpt-5", text: "ok")
  )
  let runner = GatewayStubRunner(lines: [try encodeLine(response)])
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
  let arguments = try #require(runner.request()?.params.arguments)
  #expect(arguments.contains(#"model_reasoning_effort="high""#))
  #expect(arguments.contains("--sandbox"))
  #expect(arguments.contains("workspace-write"))
  #expect(arguments.contains("--search"))
  #expect(arguments.contains("--ephemeral"))
}

@Test func gatewayAdapterReusesOnlyTheInheritedWorkflowSession() async throws {
  let store = AgentGatewaySessionStore()
  let firstResponse = GatewayRPCResponse(
    id: "producer",
    result: GatewayExecuteResult(
      vendor: .codex,
      model: "gpt-5",
      text: "first",
      sessionId: "backend-session-1"
    )
  )
  let firstRunner = GatewayStubRunner(lines: [try encodeLine(firstResponse)])
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

  let secondResponse = GatewayRPCResponse(
    id: "consumer",
    result: GatewayExecuteResult(vendor: .codex, model: "gpt-5", text: "second")
  )
  let secondRunner = GatewayStubRunner(lines: [try encodeLine(secondResponse)])
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
  #expect(secondRunner.request()?.params.sessionMode == .reuse)
  #expect(secondRunner.request()?.params.sessionId == "backend-session-1")

  let isolatedKey = AgentGatewaySessionKey(
    workflowRunId: "run-1",
    workflowSessionId: "workflow-session-2",
    stepId: "producer"
  )
  #expect(store.sessionId(for: isolatedKey) == nil)
}

private final class GatewayStubRunner: LocalProcessEventStreaming, @unchecked Sendable {
  private let lock = NSLock()
  private let lines: [String]
  private var capturedRequest: GatewayRPCRequest?

  init(lines: [String]) { self.lines = lines }

  func run(
    configuration: LocalProcessConfiguration,
    stdin: String,
    deadline: Date?
  ) async throws -> LocalProcessResult {
    try await run(configuration: configuration, stdin: stdin, deadline: deadline, outputEventHandler: nil)
  }

  func run(
    configuration _: LocalProcessConfiguration,
    stdin: String,
    deadline _: Date?,
    outputEventHandler: (@Sendable (LocalProcessOutputEvent) -> Void)?
  ) async throws -> LocalProcessResult {
    let request = try JSONDecoder().decode(GatewayRPCRequest.self, from: Data(stdin.utf8))
    lock.withLock { capturedRequest = request }
    for line in lines {
      outputEventHandler?(LocalProcessOutputEvent(stream: .stdout, line: line))
    }
    return LocalProcessResult(stdout: lines.joined(separator: "\n"), stderr: "", terminationStatus: 0)
  }

  func request() -> GatewayRPCRequest? { lock.withLock { capturedRequest } }
}

private actor GatewayEventStore {
  var values: [AdapterBackendEvent] = []
  func append(_ event: AdapterBackendEvent) { values.append(event) }
}

private func encodeLine<T: Encodable>(_ value: T) throws -> String {
  try #require(String(bytes: JSONEncoder().encode(value), encoding: .utf8))
}
