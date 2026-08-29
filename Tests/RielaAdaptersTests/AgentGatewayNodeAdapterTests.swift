import ACP
import AgentGateway
import AgentGatewayAppCore
import Foundation
import Testing
@testable import RielaAdapters
@testable import RielaCore

/// Riela no longer spawns `agent-gateway`; it hosts the gateway ACP agent in
/// its own process. These tests therefore assert on the `GatewayExecuteParams`
/// the gateway hands to its vendor executor — the contract that used to be
/// observed as `agent-gateway client` argv — and drive streaming through the
/// executor's event emitter.
private final class GatewayStubExecutor: GatewayExecuting, @unchecked Sendable {
  enum Step: Sendable {
    case delta(String)
    case thought(String)
  }

  private let lock = NSLock()
  private let steps: [Step]
  private let resultText: String
  private let vendorSessionId: String?
  private let usage: GatewayUsage?
  private let failure: GatewayRPCError?
  private var capturedParams: GatewayExecuteParams?
  private var capturedEnvironment: [String: String] = [:]

  init(
    steps: [Step] = [],
    resultText: String = "ok",
    vendorSessionId: String? = nil,
    usage: GatewayUsage? = nil,
    failure: GatewayRPCError? = nil
  ) {
    self.steps = steps
    self.resultText = resultText
    self.vendorSessionId = vendorSessionId
    self.usage = usage
    self.failure = failure
  }

  /// Factory that records the turn environment the adapter resolved.
  var factory: AgentGatewayExecutorFactory {
    { [self] environment in
      lock.withLock { capturedEnvironment = environment }
      return self
    }
  }

  func execute(
    _ params: GatewayExecuteParams, emit: @escaping GatewayEventEmitter
  ) async throws -> GatewayExecuteResult {
    lock.withLock { capturedParams = params }
    if let failure { throw failure }
    for step in steps {
      switch step {
      case .delta(let text):
        emit(GatewayEvent(type: "assistant.delta", channel: .assistant, textDelta: text))
      case .thought(let text):
        emit(GatewayEvent(type: "thinking.delta", channel: .thinking, textDelta: text))
      }
    }
    return GatewayExecuteResult(
      vendor: params.vendor,
      model: params.model,
      text: resultText,
      usage: usage,
      sessionId: vendorSessionId
    )
  }

  func params() -> GatewayExecuteParams? { lock.withLock { capturedParams } }
  func environment() -> [String: String] { lock.withLock { capturedEnvironment } }
}

private func vendorArguments(_ params: GatewayExecuteParams) -> [String] { params.arguments }

@Test func gatewayAdapterSelectsVendorAndStreamsACPEvents() async throws {
  let executor = GatewayStubExecutor(
    steps: [.delta("hello")],
    resultText: "hello",
    usage: GatewayUsage(inputTokens: 2, outputTokens: 1, totalTokens: 3)
  )
  let events = GatewayEventStore()
  let adapter = AgentGatewayNodeAdapter(executorFactory: executor.factory)
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
  let params = try #require(executor.params())
  #expect(params.vendor == .openRouter)
  #expect(params.apiKeyEnvironment == "OPENROUTER_API_KEY")
  #expect(params.baseURL == "https://openrouter.ai/api/v1")
  #expect(params.prompt == "hello")
  #expect(params.images.isEmpty)
}

@Test func gatewayAdapterRunsInProcessWithoutTheGatewayExecutable() async throws {
  // The gateway agent and ACP client are linked libraries, so no `PATH`
  // lookup of `agent-gateway` can happen: an empty PATH still completes a turn.
  let executor = GatewayStubExecutor(resultText: "in-process")
  let output = try await AgentGatewayNodeAdapter(
    environment: ["PATH": ""],
    executorFactory: executor.factory
  ).execute(
    AdapterExecutionInput(
      node: AgentNodePayload(id: "worker", executionBackend: .codexAgent, model: "gpt-5"),
      promptText: "prompt"
    ),
    context: AdapterExecutionContext()
  )
  #expect(output.payload == ["text": .string("in-process")])
}

@Test func gatewayAdapterScopesNodeEnvironmentToTheTurn() async throws {
  let executor = GatewayStubExecutor()
  _ = try await AgentGatewayNodeAdapter(
    environment: ["PATH": "/usr/bin", "SHARED": "riela"],
    executorFactory: executor.factory
  ).execute(
    AdapterExecutionInput(
      node: AgentNodePayload(id: "worker", executionBackend: .codexAgent, model: "gpt-5"),
      promptText: "prompt",
      agentEnvironment: ["SHARED": "node", "NODE_ONLY": "value"]
    ),
    context: AdapterExecutionContext()
  )
  let environment = executor.environment()
  #expect(environment["PATH"] == "/usr/bin")
  // The node's binding wins over riela's, and nothing is written back into
  // riela's own environment.
  #expect(environment["SHARED"] == "node")
  #expect(environment["NODE_ONLY"] == "value")
  #expect(ProcessInfo.processInfo.environment["NODE_ONLY"] == nil)
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
    let executor = GatewayStubExecutor()
    _ = try await AgentGatewayNodeAdapter(executorFactory: executor.factory).execute(
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
    #expect(executor.params()?.vendor == vendor)
  }
}

@Test func cliVendorKeepsOpenRouterAsProviderRoutingInsteadOfChangingHarness() async throws {
  let executor = GatewayStubExecutor()
  let provider = try OpenRouterProvider.configuration(for: .codexAgent)
  _ = try await AgentGatewayNodeAdapter(executorFactory: executor.factory).execute(
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
  let params = try #require(executor.params())
  #expect(params.vendor == .codex)
  #expect(params.providerName == "openrouter")
  #expect(params.apiKeyEnvironment == "OPENROUTER_API_KEY")
}

@Test func cliVendorForwardsCustomBaseURLAndCredentialEnvironment() async throws {
  let executor = GatewayStubExecutor()
  _ = try await AgentGatewayNodeAdapter(executorFactory: executor.factory).execute(
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
  let params = try #require(executor.params())
  #expect(params.vendor == .claudeCode)
  #expect(params.model == "custom")
  #expect(params.baseURL == "https://api.kimi.example")
  #expect(params.apiKeyEnvironment == "KIMI_API_KEY")
  #expect(params.providerName == nil)
}

@Test func gatewayAdapterPreservesCLIExecutionControls() async throws {
  let executor = GatewayStubExecutor()
  _ = try await AgentGatewayNodeAdapter(executorFactory: executor.factory).execute(
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
  let arguments = vendorArguments(try #require(executor.params()))
  #expect(arguments.contains(#"model_reasoning_effort="high""#))
  #expect(arguments.contains("--sandbox"))
  #expect(arguments.contains("workspace-write"))
  #expect(arguments.contains("--search"))
  #expect(arguments.contains("--ephemeral"))
  #expect(pairedValue(arguments, "--disable") == "multi_agent")
}

@Test func gatewayAdapterEnablesCodexSupervisorModeOnlyWhenRequested() async throws {
  let executor = GatewayStubExecutor()
  _ = try await AgentGatewayNodeAdapter(
    codexSupervisorModeEnabled: true,
    executorFactory: executor.factory
  ).execute(
    AdapterExecutionInput(
      node: AgentNodePayload(id: "worker", executionBackend: .codexAgent, model: "gpt-5"),
      promptText: "prompt"
    ),
    context: AdapterExecutionContext()
  )

  let arguments = vendorArguments(try #require(executor.params()))
  #expect(pairedValue(arguments, "--enable") == "multi_agent")
  #expect(!arguments.contains("--disable"))
}

@Test func gatewayAdapterReusesOnlyTheInheritedWorkflowSession() async throws {
  let store = AgentGatewaySessionStore()
  let first = GatewayStubExecutor(resultText: "first", vendorSessionId: "backend-session-1")
  _ = try await AgentGatewayNodeAdapter(executorFactory: first.factory, sessionStore: store).execute(
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
  #expect(first.params()?.sessionId == nil)
  #expect(first.params()?.sessionMode == .new)

  let second = GatewayStubExecutor(resultText: "second")
  _ = try await AgentGatewayNodeAdapter(executorFactory: second.factory, sessionStore: store).execute(
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
  #expect(second.params()?.sessionId == "backend-session-1")
  #expect(second.params()?.sessionMode == .reuse)

  let isolatedKey = AgentGatewaySessionKey(
    workflowRunId: "run-1",
    workflowSessionId: "workflow-session-2",
    stepId: "producer"
  )
  #expect(store.sessionId(for: isolatedKey) == nil)
}

@Test func gatewayAdapterSurfacesACPErrorResponses() async throws {
  let executor = GatewayStubExecutor(
    failure: GatewayRPCError(code: -32011, message: "missing credential environment 'OPENAI_API_KEY'")
  )
  do {
    _ = try await AgentGatewayNodeAdapter(executorFactory: executor.factory).execute(
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
  let executor = GatewayStubExecutor(steps: [.delta("hel"), .delta("lo")], resultText: "")
  let output = try await AgentGatewayNodeAdapter(executorFactory: executor.factory).execute(
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

@Test func gatewayAdapterStreamsThoughtChunksOnTheThinkingChannel() async throws {
  let executor = GatewayStubExecutor(steps: [.thought("planning"), .delta("done")], resultText: "done")
  let events = GatewayEventStore()
  _ = try await AgentGatewayNodeAdapter(executorFactory: executor.factory).execute(
    AdapterExecutionInput(
      node: AgentNodePayload(id: "worker", executionBackend: .codexAgent, model: "gpt-5"),
      promptText: "prompt"
    ),
    context: AdapterExecutionContext { event in await events.append(event) }
  )
  let streamed = await events.values
  #expect(streamed.map(\.channel) == [.thinking, .assistant])
  #expect(streamed.map(\.eventType) == ["agent_thought_chunk", "agent_message_chunk"])
}

@Test func clientTurnRunsOneShotACPPromptAndParsesTypedResult() async throws {
  let executor = GatewayStubExecutor(
    steps: [.delta("partial")],
    resultText: "ocr text",
    usage: GatewayUsage(inputTokens: 10, outputTokens: 4, totalTokens: 14)
  )
  let turn = AgentGatewayClientTurn(executorFactory: executor.factory)

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
  let params = try #require(executor.params())
  #expect(params.vendor == .gemini)
  #expect(params.model == "gemini-3.5-flash")
  #expect(params.systemPrompt == "system")
  #expect(params.apiKeyEnvironment == "GOOGLE_API_KEY")
  #expect(params.workingDirectory == "/work")
  #expect(params.prompt == "read this")
  #expect(params.images == [GatewayImageInput(dataBase64: "cGRm", mimeType: "application/pdf")])
}

@Test func clientTurnSurfacesACPProtocolErrors() async throws {
  let executor = GatewayStubExecutor(failure: GatewayRPCError(code: -32603, message: "vendor exploded"))
  let turn = AgentGatewayClientTurn(executorFactory: executor.factory)

  await #expect(throws: AdapterExecutionError.self) {
    _ = try await turn.run(AgentGatewayClientTurn.Request(
      vendor: .gemini,
      model: "gemini-3.5-flash",
      promptBlocks: [.text("read this")]
    ))
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
