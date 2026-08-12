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
    (.officialCursorSDK, .cursor)
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

private final class GatewayStubRunner: LocalAgentProcessEventStreaming, @unchecked Sendable {
  private let lock = NSLock()
  private let lines: [String]
  private var capturedRequest: GatewayRPCRequest?

  init(lines: [String]) { self.lines = lines }

  func run(
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    deadline: Date?
  ) async throws -> LocalAgentProcessResult {
    try await run(configuration: configuration, stdin: stdin, deadline: deadline, outputEventHandler: nil)
  }

  func run(
    configuration _: LocalAgentProcessConfiguration,
    stdin: String,
    deadline _: Date?,
    outputEventHandler: (@Sendable (LocalAgentProcessOutputEvent) -> Void)?
  ) async throws -> LocalAgentProcessResult {
    let request = try JSONDecoder().decode(GatewayRPCRequest.self, from: Data(stdin.utf8))
    lock.withLock { capturedRequest = request }
    for line in lines {
      outputEventHandler?(LocalAgentProcessOutputEvent(stream: .stdout, line: line))
    }
    return LocalAgentProcessResult(stdout: lines.joined(separator: "\n"), stderr: "", terminationStatus: 0)
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
