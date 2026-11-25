import Foundation
import RielaCore
import Testing
@testable import RielaCLI

struct AskTransportTests {
  @Test func selectsMCPOnlyForSupportedBackendsWithAnAbsoluteExecutable() {
    #expect(select(.codexAgent) == .mcp)
    #expect(select(.claudeCodeAgent) == .mcp)
    #expect(select(.codexAgent, environment: ["RIELA_ASK_TOOL_TRANSPORT": "rounds"]) == .rounds)
    #expect(select(.codexAgent, environment: [AskScriptedBackend.environmentKey: ""]) == .rounds)
    #expect(select(.codexAgent, path: nil) == .rounds)
    #expect(select(.codexAgent, path: "bin/riela") == .rounds)
    #expect(select(.officialOpenAISDK) == .rounds)
  }

  @Test(arguments: CaptureAdapter.Outcome.allCases)
  private func mcpPassesOneServerAndCleansValuesOnSettlement(_ outcome: CaptureAdapter.Outcome) async throws {
    let fixture = try AskEngineTestFixture()
    let adapter = CaptureAdapter(outcome: outcome)
    let service = makeService(fixture, adapter: adapter, deadline: outcome == .timeout ? 1 : 600)
    let started = try await service.send(.init(message: "What happened?"))
    let id = started.conversation.conversationId
    let turn = try #require(started.conversation.turn)
    #expect(turn.toolTransport == .mcp)
    // Wait until the adapter opens the handoff, before requesting cancellation.
    for await _ in adapter.entered.stream { break }
    if outcome == .cancelled {
      _ = try await service.cancel(conversationId: id)
    }
    await service.waitForTurn(conversationId: id)

    let seen = try #require(await adapter.capture)
    #expect(await adapter.calls == 1)
    #expect(seen.server.name == "riela-ask")
    #expect(seen.server.command == "/fixture/riela")
    #expect(seen.server.environment["HOME"] == fixture.root.path)
    #expect(seen.server.environment["RIELA_WORKFLOW_HOME"] == fixture.root.appendingPathComponent("profile").path)
    #expect(seen.server.environment["XDG_CONFIG_HOME"] == fixture.root.appendingPathComponent("config").path)
    #expect(seen.server.environment["RIELA_API_TOKEN"] == nil)
    #expect(seen.server.environment["RIELA_UNDER_ALIAS"] == nil)
    #expect(seen.server.environment["OPENAI_API_KEY"] == nil)
    #expect(!seen.server.arguments.contains("s3cr3t-value"))
    #expect(!seen.server.arguments.contains("sk-test-value"))
    #expect(seen.server.arguments == [
      "ask", "tool-server", "--session-store", fixture.sessions, "--working-dir", fixture.root.path,
      "--conversation", id, "--turn", turn.turnId, "--redaction-values", seen.path, "--scope", "project"
    ])
    #expect(seen.path == fixture.scratch + "/redaction/\(id)-\(turn.turnId).json")
    #expect(seen.permissions == 0o600)
    #expect(seen.directoryPermissions == 0o700)
    #expect(seen.values["s3cr3t-value"] == "RIELA_API_TOKEN")
    #expect(seen.values["sk-test-value"] == "OPENAI_API_KEY")
    #expect(!FileManager.default.fileExists(atPath: seen.path))
    #expect(seen.policy?.codexArguments.contains("mcp_servers={}") == false)
    #expect(seen.systemPrompt?.contains("MCP tools") == true)
    #expect(seen.systemPrompt?.contains("one JSON object per line") == false)

    let settled = try service.conversation(id: id)
    switch outcome {
    case .completed:
      #expect(settled.messages.last?.text == "Answer <redacted:OPENAI_API_KEY>")
      let page = try fixture.activity(for: id)
      #expect(page.events.contains { $0.kind == .message && $0.payload.values.contains(.string("Answer <redacted:OPENAI_API_KEY>")) })
      try fixture.expectSettlement(for: id, reason: .completed)
    case .providerError:
      #expect(settled.conversation.turn?.error?.code == "ask_provider_error")
      try fixture.expectSettlement(for: id, reason: .providerError)
    case .timeout:
      #expect(settled.conversation.turn?.error?.code == "ask_timeout")
      try fixture.expectSettlement(for: id, reason: .timeout)
    case .cancelled:
      #expect(settled.conversation.turn?.status == .cancelled)
      try fixture.expectSettlement(for: id, reason: .cancelled)
    }
  }

  @Test func staleMCPRecoveryRemovesValues() throws {
    let fixture = try AskEngineTestFixture()
    let service = makeService(fixture, adapter: CaptureAdapter(outcome: .completed))
    let started = try fixture.store.createAndBeginAskTurn(
      message: "Before host exit", context: .init(), selection: .init(), contextRef: nil,
      turn: AskTurn(backend: "codex-agent", providerInstanceId: "codex-agent", toolTransport: .mcp, runnerId: "dead-runner"),
      limits: .standard, now: fixture.at.addingTimeInterval(-31)
    )
    let id = started.conversationId
    let turnId = try #require(started.turn?.turnId)
    let scratch = try #require(service.host.turnDirectory(conversationId: id, turnId: turnId))
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let valuesPath = AskToolServerHandoff.redactionFile(for: scratch)
    try AskToolServerHandoff.writeRedactionValues(environment: service.host.environment, to: valuesPath)
    #expect(FileManager.default.fileExists(atPath: valuesPath.path))
    // A separate turn can reuse the private directory.
    let nextPath = valuesPath.deletingLastPathComponent().appendingPathComponent("second.json")
    try AskToolServerHandoff.writeRedactionValues(environment: [:], to: nextPath)

    let recovered = try service.conversation(id: id)
    #expect(recovered.conversation.turn?.error?.code == "ask_interrupted")
    #expect(!FileManager.default.fileExists(atPath: valuesPath.path))
    #expect(FileManager.default.fileExists(atPath: nextPath.path))
    try fixture.expectSettlement(for: id, reason: .processExit)
  }

  @Test func forcedRoundsCreatesNoRedactionFile() async throws {
    let fixture = try AskEngineTestFixture()
    let adapter = AskEngineTestAdapter([.text("Rounds answer")])
    let service = makeService(fixture, adapter: adapter, overrides: ["RIELA_ASK_TOOL_TRANSPORT": "rounds"])
    let started = try await service.send(.init(message: "What happened?"))
    await service.waitForTurn(conversationId: started.conversation.conversationId)
    #expect(started.conversation.turn?.toolTransport == .rounds)
    #expect(await adapter.inputs.first?.mcpServers.isEmpty == true)
    #expect(!FileManager.default.fileExists(atPath: fixture.scratch + "/redaction"))
  }

  private func select(
    _ backend: NodeExecutionBackend, path: String? = "/fixture/riela", environment: [String: String] = [:]
  ) -> AskToolTransport {
    AskToolTransportSelection.select(backend: backend, rielaExecutablePath: path, environment: environment)
  }

  private func makeService(
    _ fixture: AskEngineTestFixture, adapter: any NodeAdapter, deadline: Int = 600, overrides: [String: String] = [:]
  ) -> AskService {
    var limits = AskLimits()
    limits.turnDeadlineSeconds = deadline
    let environment = [
      "RIELA_API_TOKEN": "s3cr3t-value", "OPENAI_API_KEY": "sk-test-value", "RIELA_UNDER_ALIAS": "s3cr3t-value"
    ].merging(overrides) { _, override in override }
    let service = fixture.service(adapter: adapter, limits: limits, environmentOverrides: environment)
    var host = service.host
    host.rielaExecutablePath = "/fixture/riela"
    host.scope = .project
    return AskService(host: host, runtime: service.runtime)
  }
}

private actor CaptureAdapter: NodeAdapter {
  enum Outcome: CaseIterable, Sendable {
    case completed, cancelled, providerError, timeout
  }

  struct Capture {
    let server: AdapterMCPServer
    let path: String
    let permissions: Int?
    let directoryPermissions: Int?
    let values: [String: String]
    let policy: AgentToolPolicy?
    let systemPrompt: String?
  }

  let entered = AsyncStream<Void>.makeStream()
  private let outcome: Outcome
  private(set) var capture: Capture?
  private(set) var calls = 0

  init(outcome: Outcome) {
    self.outcome = outcome
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    calls += 1
    defer { entered.continuation.finish() }
    let server = try #require(input.mcpServers.first)
    #expect(input.mcpServers.count == 1)
    let flag = try #require(server.arguments.firstIndex(of: "--redaction-values"))
    let path = try #require(server.arguments.dropFirst(flag + 1).first)
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: path)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory)
    let values = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    capture = Capture(
      server: server, path: path, permissions: fileAttributes[.posixPermissions] as? Int,
      directoryPermissions: directoryAttributes[.posixPermissions] as? Int,
      values: values, policy: input.node.agentToolPolicy, systemPrompt: input.systemPromptText
    )
    entered.continuation.yield(())
    if outcome == .cancelled || outcome == .timeout {
      try await Task.sleep(for: .seconds(60))
    }
    if outcome == .providerError {
      throw AdapterExecutionError(.providerError, "Vendor failed")
    }
    let answer = "Answer sk-test-value"
    await context.backendEventHandler?(.init(
      provider: "fixture", eventType: "activity", activity: .message(messageId: "reply", text: answer, replace: false)
    ))
    return .init(provider: "fixture", model: "fixture", promptText: input.promptText, completionPassed: true, payload: ["text": .string(answer)])
  }
}
