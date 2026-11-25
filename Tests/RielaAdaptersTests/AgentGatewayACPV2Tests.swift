import ACP
import AgentGateway
import AgentGatewayAppCore
import Foundation
import Testing
@testable import RielaAdapters
@testable import RielaCore

// The gateway adapter can drive its in-process agent over ACP protocol
// version 2, selected with RIELA_AGENT_GATEWAY_ACP_VERSION=2. These tests
// run the same turns through v2 and assert that riela observes the same
// outcomes as over v1, even though completion arrives as an idle
// `state_update` instead of the `session/prompt` response.

private actor V2EventStore {
  private(set) var values: [AdapterBackendEvent] = []

  func append(_ event: AdapterBackendEvent) {
    values.append(event)
  }
}

private final class V2StubExecutor: GatewayExecuting, @unchecked Sendable {
  enum Behavior: Sendable {
    case reply(deltas: [String], thoughts: [String], resultText: String)
    case fail(GatewayRPCError)
    case waitForCancellation
  }

  private let lock = NSLock()
  private let behavior: Behavior
  private var captured: GatewayExecuteParams?

  init(_ behavior: Behavior) {
    self.behavior = behavior
  }

  var params: GatewayExecuteParams? {
    lock.withLock { captured }
  }

  func execute(
    _ params: GatewayExecuteParams, emit: @escaping GatewayEventEmitter
  ) async throws -> GatewayExecuteResult {
    lock.withLock { captured = params }
    switch behavior {
    case .reply(let deltas, let thoughts, let resultText):
      for text in thoughts {
        emit(GatewayEvent(type: "thinking.delta", channel: .thinking, textDelta: text))
      }
      for text in deltas {
        emit(GatewayEvent(type: "assistant.delta", channel: .assistant, textDelta: text))
      }
      return GatewayExecuteResult(
        vendor: params.vendor, model: params.model, text: resultText,
        usage: GatewayUsage(inputTokens: 2, outputTokens: 1, totalTokens: 3), sessionId: "vendor-thread-1"
      )
    case .fail(let error):
      throw error
    case .waitForCancellation:
      try await Task.sleep(for: .seconds(60))
      throw CancellationError()
    }
  }
}

private let v2Environment = [gatewayACPVersionEnvironmentKey: "2"]

private func v2Input(backend: NodeExecutionBackend = .codexAgent) -> AdapterExecutionInput {
  AdapterExecutionInput(
    node: AgentNodePayload(id: "worker", executionBackend: backend, model: "fixture"),
    promptText: "prompt",
    executionIdentity: AdapterExecutionIdentity(workflowRunId: "run", workflowSessionId: "session", stepId: "worker")
  )
}

@Test func gatewayACPVersionDefaultsToV1AndAcceptsOnlyKnownVersions() {
  #expect(gatewayACPVersion(environment: [:]) == 1)
  #expect(gatewayACPVersion(environment: [gatewayACPVersionEnvironmentKey: "2"]) == 2)
  #expect(gatewayACPVersion(environment: [gatewayACPVersionEnvironmentKey: "1"]) == 1)
  for invalid in ["3", "0", "v2", ""] {
    #expect(gatewayACPVersion(environment: [gatewayACPVersionEnvironmentKey: invalid]) == 1)
  }
}

@Test func gatewayAdapterCompletesATurnOverACPV2() async throws {
  let executor = V2StubExecutor(.reply(deltas: ["hel", "lo"], thoughts: ["hmm"], resultText: "hello"))
  let events = V2EventStore()
  let output = try await AgentGatewayNodeAdapter(environment: v2Environment, executorFactory: { _ in executor })
    .execute(v2Input(), context: AdapterExecutionContext { event in await events.append(event) })

  #expect(output.payload == ["text": .string("hello")])
  #expect(output.model == "fixture")
  #expect(output.usage?.totalTokens == 3)
  let allEvents = await events.values
  let streamed = allEvents.filter { $0.channel == .assistant || $0.channel == .thinking }
  #expect(allEvents.suffix(3).map(\.eventType) == ["usage_update", "reported_model", "stop"])
  #expect(streamed.map(\.eventType) == ["agent_thought_chunk", "agent_message_chunk", "agent_message_chunk"])
  #expect(streamed.map(\.contentDelta) == ["hmm", "hel", "lo"])
  #expect(streamed.map(\.channel) == [.thinking, .assistant, .assistant])
  #expect(executor.params?.prompt == "prompt")
}

@Test func gatewayAdapterReusesVendorSessionsOverACPV2() async throws {
  let store = AgentGatewaySessionStore()
  let first = V2StubExecutor(.reply(deltas: ["a"], thoughts: [], resultText: "a"))
  var input = v2Input()
  input.sessionPolicy = WorkflowStepSessionPolicy(mode: .reuse)
  _ = try await AgentGatewayNodeAdapter(
    environment: v2Environment, executorFactory: { _ in first }, sessionStore: store
  ).execute(input, context: AdapterExecutionContext())
  #expect(first.params?.sessionMode == .new)

  // The vendor session id reported on the idle update is stored and handed
  // back through the v2 `_meta` key on the next turn.
  let second = V2StubExecutor(.reply(deltas: ["b"], thoughts: [], resultText: "b"))
  _ = try await AgentGatewayNodeAdapter(
    environment: v2Environment, executorFactory: { _ in second }, sessionStore: store
  ).execute(input, context: AdapterExecutionContext())
  #expect(second.params?.sessionMode == .reuse)
  #expect(second.params?.sessionId == "vendor-thread-1")
}

@Test func gatewayAdapterSurfacesVendorFailuresOverACPV2() async throws {
  // In v2 a failure after the prompt is accepted is an idle state with the
  // `error` stop reason; riela reports it exactly like a v1 error response.
  let executor = V2StubExecutor(.fail(
    GatewayRPCError(code: -32011, message: "missing credential environment 'OPENAI_API_KEY'")
  ))
  do {
    _ = try await AgentGatewayNodeAdapter(environment: v2Environment, executorFactory: { _ in executor })
      .execute(v2Input(backend: .officialOpenAISDK), context: AdapterExecutionContext())
    Issue.record("expected a provider error")
  } catch let error as AdapterExecutionError {
    #expect(error.code == .providerError)
    #expect(error.message == "agent-gateway error -32011: missing credential environment 'OPENAI_API_KEY'")
  }
}

@Test func gatewayAdapterDeadlineOverACPV2StillReturnsTimeout() async {
  let executor = V2StubExecutor(.waitForCancellation)
  do {
    _ = try await AgentGatewayNodeAdapter(environment: v2Environment, executorFactory: { _ in executor })
      .execute(v2Input(), context: AdapterExecutionContext(deadline: Date().addingTimeInterval(0.05)))
    Issue.record("expected watchdog timeout")
  } catch let error as AdapterExecutionError {
    #expect(error.code == .timeout)
  } catch {
    Issue.record("expected timeout, got \(error)")
  }
}

@Test func gatewayAdapterHostCancellationOverACPV2ThrowsCancellation() async {
  let executor = V2StubExecutor(.waitForCancellation)
  let adapter = AgentGatewayNodeAdapter(environment: v2Environment, executorFactory: { _ in executor })
  let task = Task { try await adapter.execute(v2Input(), context: AdapterExecutionContext()) }
  try? await Task.sleep(for: .milliseconds(100))
  task.cancel()
  do {
    _ = try await task.value
    Issue.record("expected task cancellation")
  } catch is CancellationError {
    #expect(true)
  } catch {
    Issue.record("expected CancellationError, got \(error)")
  }
}

@Test func clientTurnRunsOverACPV2() async throws {
  let executor = V2StubExecutor(.reply(deltas: [], thoughts: [], resultText: "unstreamed"))
  let result = try await AgentGatewayClientTurn(environment: v2Environment, executorFactory: { _ in executor })
    .run(.init(vendor: .openAI, model: "gpt-5", promptBlocks: [.text("hi")]))
  #expect(result.stopReason == .endTurn)
  #expect(result.text == "unstreamed")
  #expect(result.usage?.totalTokens == 3)
}
