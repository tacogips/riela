import XCTest
@testable import ClaudeCodeAgent
@testable import CodexAgent
@testable import RielaAdapters
@testable import RielaCore

extension AgentAdapterTests {
  func testProviderNameAppearsInAdapterOutputAndBackendEventMetadataOnlyWhenActive() async throws {
    let configuration = try AgentProviderConfiguration(name: "openrouter", baseUrl: "https://provider.example/v1")
    let recorder = BackendEventRecorder()
    let output = try await CodexAgentAdapter(
      runner: StreamingRecordingRunner(output: #"{"type":"turn.started"}"# + "\n" + "done"),
      authPreflight: false
    ).execute(
      providerRoutingInput(backend: .codexAgent, provider: configuration),
      context: AdapterExecutionContext { event in await recorder.append(event) }
    )

    XCTAssertEqual(output.provider, "codex-agent")
    XCTAssertEqual(output.payload["provider_name"], .string("openrouter"))
    let providerEvents = await recorder.recordedEvents()
    XCTAssertEqual(providerEvents.first?.metadata?["provider_name"], .string("openrouter"))

    let defaultOutput = try await CodexAgentAdapter(
      runner: CapturingRunner(output: "done"),
      authPreflight: false
    ).execute(providerRoutingInput(backend: .codexAgent), context: AdapterExecutionContext())
    XCTAssertNil(defaultOutput.payload["provider_name"])
  }

  func testProviderCredentialIsRedactedFromFailureAndBackendEventContent() async throws {
    let secret = "provider-secret-value"
    let configuration = try AgentProviderConfiguration(
      name: "openrouter",
      baseUrl: "https://provider.example/v1",
      apiKeyEnv: "CUSTOM_PROVIDER_CREDENTIAL"
    )
    let recorder = BackendEventRecorder()
    let adapter = LocalAgentCommandAdapter(
      commandBuilder: ProviderSecretEventCommandBuilder(secret: secret),
      runner: StreamingRecordingRunner(output: secret)
    )

    _ = try await adapter.execute(
      providerRoutingInput(backend: .claudeCodeAgent, provider: configuration),
      context: AdapterExecutionContext { event in await recorder.append(event) }
    )
    let eventText = (await recorder.recordedEvents()).compactMap { $0.contentSnapshot ?? $0.contentDelta }.joined()
    XCTAssertFalse(eventText.contains(secret))
    XCTAssertTrue(eventText.contains("<redacted>"))

    let failingAdapter = ClaudeCodeAgentAdapter(
      runner: CapturingRunner(output: "", error: "gateway rejected \(secret)", status: 1),
      authPreflight: false
    )
    do {
      _ = try await failingAdapter.execute(
        providerRoutingInput(
          backend: .claudeCodeAgent,
          agentEnvironment: ["CUSTOM_PROVIDER_CREDENTIAL": secret],
          provider: configuration
        ),
        context: AdapterExecutionContext()
      )
      XCTFail("expected provider failure")
    } catch let error as AdapterExecutionError {
      XCTAssertFalse(error.message.contains(secret))
      XCTAssertTrue(error.message.contains("<redacted>"))
    }
  }

  func testProviderCredentialIsRedactedFromPlainAndContractOutput() async throws {
    let secret = "provider-secret-value"
    let plainOutput = try await LocalAgentCommandAdapter(
      commandBuilder: ProviderSensitiveCommandBuilder(secret: secret),
      runner: CapturingRunner(output: "model echoed \(secret)")
    ).execute(
      providerRoutingInput(backend: .claudeCodeAgent),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(plainOutput.payload["text"], .string("model echoed <redacted>"))

    let contractOutput = try await LocalAgentCommandAdapter(
      commandBuilder: ProviderSensitiveCommandBuilder(secret: secret),
      runner: CapturingRunner(
        output: #"{"when":{"always":true},"payload":{"token":"provider-secret-value"}}"#
      )
    ).execute(
      providerRoutingInput(
        backend: .claudeCodeAgent,
        output: NodeOutputContract(description: "provider response")
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(contractOutput.payload["token"], .string("<redacted>"))

    let escapedSecret = "q\"\\\n"
    let escapedContract = JSONValue.object([
      "when": .object(["always": .bool(true)]),
      "payload": .object([
        "nested": .array([.object(["credential": .string(escapedSecret)])])
      ])
    ])
    let escapedData = try JSONEncoder().encode(escapedContract)
    let escapedOutput = try XCTUnwrap(String(data: escapedData, encoding: .utf8))
    let escapedResult = try await LocalAgentCommandAdapter(
      commandBuilder: ProviderSensitiveCommandBuilder(secret: escapedSecret),
      runner: CapturingRunner(output: escapedOutput)
    ).execute(
      providerRoutingInput(
        backend: .claudeCodeAgent,
        output: NodeOutputContract(description: "escaped provider response")
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(
      escapedResult.payload["nested"],
      .array([.object(["credential": .string("<redacted>")])])
    )
  }

  func testProviderCredentialIsRedactedFromStreamingAndNonStreamingRunnerErrors() async throws {
    let secret = "abc"
    let sourceError = AdapterExecutionError(
      .timeout,
      "runner exposed \(secret)",
      isRetryable: true,
      retryAfter: .seconds(3)
    )
    let adapters = [
      LocalAgentCommandAdapter(
        commandBuilder: ProviderSensitiveCommandBuilder(secret: secret),
        runner: ProviderThrowingRunner(error: sourceError)
      ),
      LocalAgentCommandAdapter(
        commandBuilder: ProviderSensitiveCommandBuilder(secret: secret),
        runner: ProviderStreamingThrowingRunner(error: sourceError)
      )
    ]

    for adapter in adapters {
      do {
        _ = try await adapter.execute(
          providerRoutingInput(backend: .claudeCodeAgent),
          context: AdapterExecutionContext()
        )
        XCTFail("expected runner error")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .timeout)
        XCTAssertEqual(error.message, "runner exposed <redacted>")
        XCTAssertEqual(error.isRetryable, true)
        XCTAssertEqual(error.retryAfter, .seconds(3))
      }
    }
  }

  func testProviderCredentialIsRedactedFromEveryBackendEventField() async throws {
    let secret = "abc"
    for streamContent in [false, true] {
      let recorder = BackendEventRecorder()
      _ = try await LocalAgentCommandAdapter(
        commandBuilder: SensitiveEventCommandBuilder(secret: secret),
        runner: StreamingRecordingRunner(output: "event")
      ).execute(
        providerRoutingInput(
          backend: .claudeCodeAgent,
          variables: ["streamBackendContent": .bool(streamContent)]
        ),
        context: AdapterExecutionContext { event in await recorder.append(event) }
      )
      let events = await recorder.recordedEvents()
      XCTAssertEqual(events.count, 2)
      XCTAssertFalse(String(describing: events).contains(secret))
      XCTAssertTrue(events.allSatisfy { $0.metadata?["provider_name"] == .string("openrouter") })
    }
  }

  func testArbitraryProviderCredentialNameIsRedactedForCodex() async throws {
    let secret = "provider-secret-value"
    let provider = try AgentProviderConfiguration(
      name: "openrouter",
      baseUrl: "https://provider.example/v1",
      apiKeyEnv: "FOO"
    )
    let adapter = CodexAgentAdapter(
      runner: CapturingRunner(output: "", error: "gateway rejected \(secret)", status: 1),
      authPreflight: false
    )

    do {
      _ = try await adapter.execute(
        providerRoutingInput(backend: .codexAgent, agentEnvironment: ["FOO": secret], provider: provider),
        context: AdapterExecutionContext()
      )
      XCTFail("expected provider failure")
    } catch let error as AdapterExecutionError {
      XCTAssertFalse(error.message.contains(secret))
      XCTAssertTrue(error.message.contains("<redacted>"))
    }
  }

  func testCodexPreflightRedactsArbitraryProviderCredentialName() async throws {
    let secret = "provider-secret-value"
    let provider = try AgentProviderConfiguration(
      name: "openrouter",
      baseUrl: "https://provider.example/v1",
      apiKeyEnv: "FOO"
    )
    let adapterInput = providerRoutingInput(
      backend: .codexAgent,
      agentEnvironment: ["FOO": secret],
      provider: provider
    )

    for adapter in [
      CodexAgentAdapter(runner: CapturingRunner(output: "", error: "echo \(secret)", status: 1)),
      CodexAgentAdapter(
        runner: CapturingRunner(output: "done"),
        checkAuthPreflight: { _ in
          throw AdapterExecutionError(.policyBlocked, "custom preflight echoed \(secret)")
        }
      )
    ] {
      do {
        _ = try await adapter.execute(adapterInput, context: AdapterExecutionContext())
        XCTFail("expected preflight failure")
      } catch let error as AdapterExecutionError {
        XCTAssertFalse(error.message.contains(secret))
        XCTAssertTrue(error.message.contains("<redacted>"))
      }
    }
  }

  func testConfiguredCodexProviderSkipsDefaultLoginPreflight() async throws {
    let provider = try AgentProviderConfiguration(
      name: "openrouter",
      baseUrl: "https://provider.example/v1",
      apiKeyEnv: "FOO"
    )
    let runner = SequencedRunner([
      LocalAgentProcessResult(stdout: "codex-cli 1.0", stderr: "", terminationStatus: 0),
      LocalAgentProcessResult(stdout: "done", stderr: "", terminationStatus: 0),
      LocalAgentProcessResult(stdout: "", stderr: "not logged in", terminationStatus: 1)
    ])
    _ = try await CodexAgentAdapter(runner: runner).execute(
      providerRoutingInput(
        backend: .codexAgent,
        agentEnvironment: ["FOO": "provider-secret-value"],
        provider: provider
      ),
      context: AdapterExecutionContext()
    )

    let runs = await runner.runs()
    XCTAssertEqual(runs.count, 2)
    XCTAssertEqual(runs[0].configuration.arguments, ["codex", "--version"])
    XCTAssertTrue(runs[1].configuration.arguments.contains("exec"))
    XCTAssertFalse(runs.contains { $0.configuration.arguments == ["codex", "login", "status"] })
  }

  func testUnsetProviderClassifiedFallbackAndInjectedEventsKeepNilMetadata() async throws {
    let classifiedRecorder = BackendEventRecorder()
    _ = try await CodexAgentAdapter(
      runner: StreamingRecordingRunner(output: #"{"type":"turn.started"}"# + "\n" + "done"),
      authPreflight: false
    ).execute(
      providerRoutingInput(backend: .codexAgent),
      context: AdapterExecutionContext { event in await classifiedRecorder.append(event) }
    )
    let classifiedEvents = await classifiedRecorder.recordedEvents()
    XCTAssertTrue(classifiedEvents.allSatisfy { $0.metadata == nil })

    let secret = "provider-secret-value"
    let fallbackAndInjectedRecorder = BackendEventRecorder()
    _ = try await LocalAgentCommandAdapter(
      commandBuilder: UnsetProviderMetadataCommandBuilder(secret: secret),
      runner: StreamingRecordingRunner(output: "fallback")
    ).execute(
      providerRoutingInput(backend: .codexAgent),
      context: AdapterExecutionContext { event in await fallbackAndInjectedRecorder.append(event) }
    )
    let events = await fallbackAndInjectedRecorder.recordedEvents()
    XCTAssertEqual(Set(events.map(\.eventType)), ["fallback", "injected"])
    XCTAssertTrue(events.allSatisfy { $0.metadata == nil })
    let injectedContent = events.first { $0.eventType == "injected" }?.contentSnapshot
    XCTAssertEqual(injectedContent, "monitor emitted <redacted>")
    XCTAssertFalse(injectedContent?.contains(secret) == true)
  }
}

private func providerRoutingInput(
  backend: NodeExecutionBackend,
  agentEnvironment: [String: String] = [:],
  provider: AgentProviderConfiguration? = nil,
  output: NodeOutputContract? = nil,
  variables: JSONObject = [:]
) -> AdapterExecutionInput {
  AdapterExecutionInput(
    node: AgentNodePayload(
      id: "worker",
      executionBackend: backend,
      model: "model",
      provider: provider,
      variables: variables,
      output: output
    ),
    promptText: "hello",
    agentEnvironment: agentEnvironment
  )
}

private struct SensitiveEventCommandBuilder: LocalAgentCommandBuilding {
  var secret: String
  var provider: String { "claude-code-agent" }

  func buildCommand(for input: AdapterExecutionInput) throws -> LocalAgentCommand {
    LocalAgentCommand(
      provider: provider,
      metadata: [
        "provider_name": .string("openrouter"),
        "nested": .object(["credential": .string(secret)])
      ],
      additionalSensitiveValues: [secret],
      configuration: LocalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["true"],
        environment: ["RIELA_AGENT_BACKEND": provider]
      ),
      stdin: "",
      backendEventType: { _ in "fallback-\(secret)" },
      classifyBackendEvent: { _ in sensitiveEvent(secret: secret, eventType: "classified-\(secret)") },
      toolChildMonitor: ProviderSensitiveEventMonitor(secret: secret)
    )
  }
}

private struct ProviderSensitiveEventMonitor: LocalAgentToolChildMonitoring {
  var secret: String

  func start(emitBackendEvent: @escaping @Sendable (AdapterBackendEvent) -> Void) {
    emitBackendEvent(sensitiveEvent(secret: secret, eventType: "injected-\(secret)"))
  }

  func processSpawned(_ processId: Int32) {}
  func observeStdoutLine(_ line: String) {}
  func stop() async {}
}

private func sensitiveEvent(secret: String, eventType: String) -> AdapterBackendEvent {
  AdapterBackendEvent(
    provider: "provider-\(secret)",
    eventType: eventType,
    contentDelta: "delta-\(secret)",
    contentSnapshot: "snapshot-\(secret)",
    toolName: "tool-\(secret)",
    usage: ["nested": .array([.object(["credential": .string(secret)])])],
    metadata: ["nested": .object([secret: .string(secret)])]
  )
}

private struct ProviderSensitiveCommandBuilder: LocalAgentCommandBuilding {
  var secret: String
  var provider: String { "claude-code-agent" }

  func buildCommand(for input: AdapterExecutionInput) throws -> LocalAgentCommand {
    LocalAgentCommand(
      provider: provider,
      additionalSensitiveValues: [secret],
      configuration: LocalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["true"],
        environment: ["RIELA_AGENT_BACKEND": provider]
      ),
      stdin: ""
    )
  }
}

private struct ProviderThrowingRunner: LocalAgentProcessRunning {
  var error: AdapterExecutionError

  func run(
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    deadline: Date?
  ) async throws -> LocalAgentProcessResult {
    throw error
  }
}

private struct ProviderStreamingThrowingRunner: LocalAgentProcessRunning, LocalAgentProcessEventStreaming {
  var error: AdapterExecutionError

  func run(
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    deadline: Date?
  ) async throws -> LocalAgentProcessResult {
    throw error
  }

  func run(
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    deadline: Date?,
    outputEventHandler: (@Sendable (LocalAgentProcessOutputEvent) -> Void)?
  ) async throws -> LocalAgentProcessResult {
    throw error
  }
}

private struct UnsetProviderMetadataCommandBuilder: LocalAgentCommandBuilding {
  var secret: String
  var provider: String { "codex-agent" }

  func buildCommand(for input: AdapterExecutionInput) throws -> LocalAgentCommand {
    LocalAgentCommand(
      provider: provider,
      additionalSensitiveValues: [secret],
      configuration: LocalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["true"]
      ),
      stdin: "",
      backendEventType: { _ in "fallback" },
      toolChildMonitor: UnsetProviderMetadataMonitor(secret: secret)
    )
  }
}

private struct UnsetProviderMetadataMonitor: LocalAgentToolChildMonitoring {
  var secret: String

  func start(emitBackendEvent: @escaping @Sendable (AdapterBackendEvent) -> Void) {
    emitBackendEvent(AdapterBackendEvent(
      provider: "codex-agent",
      eventType: "injected",
      contentSnapshot: "monitor emitted \(secret)"
    ))
  }

  func processSpawned(_ processId: Int32) {}
  func observeStdoutLine(_ line: String) {}
  func stop() async {}
}

private struct ProviderSecretEventCommandBuilder: LocalAgentCommandBuilding {
  var secret: String
  var provider: String { "claude-code-agent" }

  func buildCommand(for input: AdapterExecutionInput) throws -> LocalAgentCommand {
    LocalAgentCommand(
      provider: provider,
      metadata: input.node.provider.map { ["provider_name": .string($0.name)] } ?? [:],
      configuration: LocalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["true"],
        environment: ["ANTHROPIC_AUTH_TOKEN": secret]
      ),
      stdin: "",
      classifyBackendEvent: { line in
        AdapterBackendEvent(
          provider: "claude-code-agent",
          eventType: "assistant",
          channel: .assistant,
          contentSnapshot: line
        )
      }
    )
  }
}
