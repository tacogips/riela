import Foundation
import RielaCore
import Testing
@testable import RielaCLI

@Suite(.timeLimit(.minutes(1)))
struct AskTurnEngineTests {
  @Test(arguments: [
    NodeExecutionBackend.codexAgent, .claudeCodeAgent, .cursorCliAgent, .officialOpenAISDK, .officialAnthropicSDK
  ])
  func streamsAndPersistsGroundedAnswer(backend: NodeExecutionBackend) async throws {
    let fixture = try AskEngineTestFixture()
    try fixture.seedSession()
    let session = AskEngineTestFixture.sessionId
    let tool = AskEngineTestFixture.tool("session_status", arguments: #"{"sessionId":"\#(session)"}"#)
    let answer = "Active [[session:\(session)]]. Unknown [[session:not-read]]."
    let adapter = AskEngineTestAdapter([.text(tool), .text(answer)], activity: [
      .message(messageId: "raw", text: "raw vendor text", replace: false),
      .thought(text: "Checking records"), .plan(planId: "check", entries: []), .usage(["inputTokens": .integer(3)])
    ])
    let service = fixture.service(adapter: adapter)
    let started = try await service.send(.init(
      message: "What happened?", selection: .init(providerInstanceId: backend.rawValue)
    ))
    let id = started.conversation.conversationId

    await service.waitForTurn(conversationId: id)

    let snapshot = try service.conversation(id: id)
    #expect(snapshot.conversation.turn?.status == .completed)
    #expect(snapshot.conversation.turn?.toolTransport == .rounds)
    #expect(snapshot.conversation.usage.toolCalls == 1)
    #expect(snapshot.messages.map(\.role) == [.user, .assistant])
    #expect(snapshot.messages.last?.text == answer)
    #expect(snapshot.messages.last?.citations == [AskRef(kind: .session, id: session)])
    let inputs = await adapter.inputs
    #expect(inputs.count == 2)
    #expect(inputs.allSatisfy { $0.node.executionBackend == backend })
    let directory = try #require(await adapter.workingDirectory)
    #expect(directory.path.hasPrefix(fixture.scratch + "/"))
    #expect(directory.permissions == 0o700)
    #expect(directory.entries.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    let systemPrompt = try #require(inputs.first?.systemPromptText)
    #expect(inputs.allSatisfy { $0.systemPromptText == systemPrompt })
    #expect(!systemPrompt.contains(session))
    let prompt = try #require(inputs.last?.promptText)
    #expect(prompt.contains("session_status"))
    #expect(prompt.contains(session))
    #expect(prompt.contains("running"))

    let page = try fixture.activity(for: id)
    let coreEvents = page.events.filter { event in
      [.stepStarted, .toolCall, .message, .stop, .stepFinished, .settled].contains(event.kind)
        && (event.kind != .message || event.payload["text"] != .string(""))
    }
    #expect(coreEvents.map(\.kind) == [.stepStarted, .toolCall, .toolCall, .message, .stop, .stepFinished, .settled])
    #expect(coreEvents.filter { $0.kind == .toolCall }.map { $0.payload["status"] } == [.string("inProgress"), .string("completed")])
    #expect(coreEvents.filter { $0.kind == .message }.map { $0.payload["text"] } == [.string(answer)])
    #expect(page.events.contains { $0.kind == .thought && $0.payload["text"] == .string("Checking records") })
    #expect(page.events.contains { $0.kind == .plan && $0.payload["planId"] == .string("check") })
    #expect(page.events.contains { $0.kind == .usage && $0.payload["inputTokens"] == .integer(3) })
    try fixture.expectSettlement(for: id, reason: .completed)
    let first = try await service.activity(conversationId: id, limit: 1)
    #expect(first.page.events.map(\.kind) == [.stepStarted])
    #expect(first.page.lastSequence == first.page.events.last?.seq)
    let second = try await service.activity(conversationId: id, afterSequence: first.page.lastSequence, limit: 1)
    #expect(second.page.events.first?.seq == first.page.lastSequence + 1)

    let unchanged = try await service.cancel(conversationId: id)
    #expect(unchanged.conversation == snapshot.conversation)
    try fixture.expectSettlement(for: id, reason: .completed)
  }

  @Test
  func retainsUnusedToolReferencesForLaterTurnsAndEnforcesTurnBudget() async throws {
    let fixture = try AskEngineTestFixture()
    try fixture.seedSession()
    let session = AskEngineTestFixture.sessionId
    let tool = AskEngineTestFixture.tool("session_status", arguments: #"{"sessionId":"\#(session)"}"#)
    let adapter = AskEngineTestAdapter([.text(tool), .text("I checked."), .text("See [[session:\(session)]].")])
    var limits = AskLimits()
    limits.turnsPerConversation = 2
    let service = fixture.service(adapter: adapter, limits: limits)

    let started = try await service.send(.init(message: "Check the run"))
    let id = started.conversation.conversationId
    await service.waitForTurn(conversationId: id)
    #expect(try service.conversation(id: id).messages.last?.citations == [])

    _ = try await service.send(.init(conversationId: id, message: "Cite the result"))
    await service.waitForTurn(conversationId: id)
    let snapshot = try service.conversation(id: id)
    #expect(snapshot.messages.last?.citations == [AskRef(kind: .session, id: session)])
    #expect(snapshot.conversation.usage.turns == 2)
    #expect(snapshot.conversation.usage.toolCalls == 1)

    await expectEngineError("ask_budget_exceeded") {
      _ = try await service.send(.init(conversationId: id, message: "Another question"))
    }
    #expect(try service.conversation(id: id).messages.count == 4)
    #expect(await adapter.inputs.count == 3)
  }

  @Test(arguments: AskEngineBudget.allCases)
  func budgetsReachTheNextRoundAsAnError(budget: AskEngineBudget) async throws {
    let fixture = try AskEngineTestFixture()
    try fixture.seedSession()
    let tool = AskEngineTestFixture.tool("session_status", arguments: #"{"sessionId":"\#(AskEngineTestFixture.sessionId)"}"#)
    var limits = AskLimits()
    switch budget {
    case .turnCalls: limits.toolCallsPerTurn = 1
    case .conversationCalls: limits.toolCallsPerConversation = 1
    case .turnBytes: limits.toolBytesPerTurn = 1
    case .conversationBytes: limits.toolBytesPerConversation = 1
    }
    let adapter = AskEngineTestAdapter([.text("\(tool)\n\(tool)"), .text("Budget reached.")])
    let service = fixture.service(adapter: adapter, limits: limits)

    let started = try await service.send(.init(message: "Check records"))
    let id = started.conversation.conversationId
    await service.waitForTurn(conversationId: id)
    let snapshot = try service.conversation(id: id)

    #expect(snapshot.conversation.turn?.status == .completed)
    let inputs = await adapter.inputs
    #expect(inputs.last?.promptText.contains("budget_exceeded") == true)
    switch budget {
    case .turnCalls, .conversationCalls:
      #expect(snapshot.conversation.usage.toolCalls == 1)
      #expect(snapshot.conversation.usage.toolBytes > 0)
    case .turnBytes, .conversationBytes:
      #expect(snapshot.conversation.usage.toolBytes == 0)
    }
    try fixture.expectSettlement(for: id, reason: .completed)
  }

  @Test
  func stopsAtRoundLimitAndKeepsLastAnswer() async throws {
    let fixture = try AskEngineTestFixture()
    let tool = AskEngineTestFixture.tool("session_list")
    let adapter = AskEngineTestAdapter([.text("\(tool)\nEarly answer"), .text("\(tool)\nLast answer")])
    var limits = AskLimits()
    limits.roundsPerTurn = 2
    let service = fixture.service(adapter: adapter, limits: limits)
    let started = try await service.send(.init(message: "Check again"))
    let id = started.conversation.conversationId
    await service.waitForTurn(conversationId: id)

    #expect(await adapter.inputs.count == 2)
    let snapshot = try service.conversation(id: id)
    #expect(snapshot.conversation.turn?.status == .completed)
    #expect(snapshot.messages.last?.text == "Last answer")
    let page = try fixture.activity(for: id)
    #expect(page.events.filter { $0.kind == .notice }.map { $0.payload["title"] } == [.string("round_limit")])
    try fixture.expectSettlement(for: id, reason: .completed)
  }

  @Test
  func cancelsBlockedToolAndWakesLongPollWithOneSettlement() async throws {
    let fixture = try AskEngineTestFixture()
    let console = AskEngineBlockingConsole()
    defer { console.blocked.continuation.finish() }
    let adapter = AskEngineTestAdapter([.text(AskEngineTestFixture.tool("ops_overview"))])
    let service = fixture.service(adapter: adapter, console: console)
    let started = try await service.send(.init(message: "Check the overview"))
    let id = started.conversation.conversationId
    let toolEntered: Void? = await console.entered.stream.first { _ in true }
    try #require(toolEntered != nil)

    let running = try await service.activity(conversationId: id, waitMs: 1_000)
    #expect(running.turnStatus == .running)
    #expect(running.page.events.contains { $0.kind == .toolCall && $0.payload["status"] == .string("inProgress") })
    let otherRunner = fixture.service(adapter: adapter)
    await expectEngineError("ask_turn_running") {
      _ = try await otherRunner.send(.init(conversationId: id, message: "Concurrent message"))
    }

    async let pending = service.activity(conversationId: id, afterSequence: running.page.lastSequence, waitMs: 1_000)
    let cancelled = try await service.cancel(conversationId: id)
    let wake = try await pending
    #expect(!wake.page.events.isEmpty)
    let terminalPage = if wake.page.events.contains(where: { $0.kind == .settled }) {
      wake
    } else {
      try await service.activity(conversationId: id, afterSequence: wake.page.events.last?.seq ?? running.page.lastSequence)
    }
    #expect(cancelled.conversation.turn?.status == .cancelled)
    #expect(cancelled.messages.map(\.role) == [.user])
    #expect(terminalPage.turnStatus == .cancelled)
    #expect(terminalPage.page.events.contains { $0.kind == .settled })
    #expect(terminalPage.page.state?.toolCalls.map(\.status) == ["interrupted"])
    try fixture.expectSettlement(for: id, reason: .cancelled)

    let settled = try await service.activity(conversationId: id, afterSequence: terminalPage.page.lastSequence, waitMs: 1_000)
    #expect(settled.page.events.isEmpty)
    #expect(settled.turnStatus == .cancelled)
    #expect(await adapter.inputs.count == 1)
  }

  @Test
  func checksActivityAuthorizationOnEachWake() async throws {
    let fixture = try AskEngineTestFixture()
    let console = AskEngineBlockingConsole()
    defer { console.blocked.continuation.finish() }
    let adapter = AskEngineTestAdapter([.text(AskEngineTestFixture.tool("ops_overview"))])
    let service = fixture.service(adapter: adapter, console: console)
    let started = try await service.send(.init(message: "Check the overview"))
    let id = started.conversation.conversationId
    let toolEntered: Void? = await console.entered.stream.first { _ in true }
    try #require(toolEntered != nil)
    let cursor = try fixture.activity(for: id).lastSequence
    let authorization = AskEnginePollAuthorization()

    do {
      _ = try await service.activity(conversationId: id, afterSequence: cursor, waitMs: 1_000) {
        await authorization.isAllowed()
      }
      Issue.record("Expected activity access to be revoked")
    } catch {
      #expect(String(describing: error).contains("activity_wait_revoked"))
    }
    #expect(await authorization.checks == 2)
    _ = try await service.cancel(conversationId: id)
  }

  @Test
  func redactsProviderFailureAndDoesNotStoreAssistantMessage() async throws {
    let fixture = try AskEngineTestFixture()
    let adapter = AskEngineTestAdapter([.error(.init(code: "fixture", message: "Rejected \(AskEngineTestFixture.secret)"))])
    let service = fixture.service(adapter: adapter)

    let started = try await service.send(.init(message: "Check records"))
    let id = started.conversation.conversationId
    await service.waitForTurn(conversationId: id)

    let snapshot = try service.conversation(id: id)
    #expect(snapshot.conversation.turn?.status == .failed)
    #expect(snapshot.conversation.turn?.error?.code == "ask_provider_error")
    let message = try #require(snapshot.conversation.turn?.error?.message)
    #expect(message.contains("Rejected"))
    #expect(!message.contains(AskEngineTestFixture.secret))
    #expect(snapshot.messages.map(\.role) == [.user])
    try fixture.expectSettlement(for: id, reason: .providerError)
  }

  @Test
  func rejectsExpiredDeadlineBeforeCallingAdapter() async throws {
    let fixture = try AskEngineTestFixture()
    let adapter = AskEngineTestAdapter([.text("late reply")])
    var limits = AskLimits()
    limits.turnDeadlineSeconds = -1
    let service = fixture.service(adapter: adapter, limits: limits)

    let started = try await service.send(.init(message: "Check records"))
    let id = started.conversation.conversationId
    await service.waitForTurn(conversationId: id)

    let snapshot = try service.conversation(id: id)
    #expect(snapshot.conversation.turn?.status == .failed)
    #expect(snapshot.conversation.turn?.error?.code == "ask_timeout")
    #expect(snapshot.messages.map(\.role) == [.user])
    #expect(await adapter.inputs.isEmpty)
    try fixture.expectSettlement(for: id, reason: .timeout)
  }

  @Test
  func recoversAnotherRunnersStaleTurnOnce() async throws {
    let fixture = try AskEngineTestFixture()
    let service = fixture.service(adapter: AskEngineTestAdapter([.text("unused")]))
    let stale = fixture.at.addingTimeInterval(-31)
    let conversation = try fixture.store.createAskConversation(
      context: AskContext(), selection: AskSelection(), firstMessage: "Before host exit", now: stale
    )
    let id = conversation.conversationId
    let running = try fixture.store.beginAskTurn(
      conversationId: id, message: "Before host exit",
      turn: AskTurn(backend: "codex-agent", providerInstanceId: "codex-agent", toolTransport: .rounds, runnerId: "dead-runner"),
      now: stale
    )
    let turnId = try #require(running.turn?.turnId)
    let scratch = try #require(service.host.turnDirectory(conversationId: id, turnId: turnId))
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let recorder = SQLiteWorkflowActivityRecorder(sessionStoreRoot: fixture.store.sessionStoreRoot)
    await recorder.stepStarted(
      sessionId: AskActivityKey.sessionId(id), executionId: turnId, stepId: "ask", nodeId: "ask",
      backend: "codex-agent", requestedModel: nil, at: stale
    )
    await recorder.record(
      sessionId: AskActivityKey.sessionId(id), executionId: turnId,
      update: .toolCall(.init(toolCallId: "open", status: "inProgress")), at: stale
    )

    let recovered = try service.conversation(id: id)
    #expect(recovered.conversation.turn?.status == .failed)
    #expect(recovered.conversation.turn?.error?.code == "ask_interrupted")
    #expect(recovered.messages.map(\.role) == [.user])
    #expect(!FileManager.default.fileExists(atPath: scratch.path))
    #expect(try fixture.activity(for: id).state?.toolCalls.map(\.status) == ["interrupted"])
    #expect(try service.conversation(id: id).conversation == recovered.conversation)
    try fixture.expectSettlement(for: id, reason: .processExit)
  }

  @Test
  func readableScriptRunsWithoutVendorAvailability() async throws {
    let fixture = try AskEngineTestFixture()
    let script = "script.json"
    try #"{"rounds":["Scripted answer."]}"#.write(
      to: fixture.root.appendingPathComponent(script), atomically: true, encoding: .utf8
    )
    let fallback = AskEngineTestAdapter([.text("Unexpected production fallback.")])
    let service = fixture.service(
      adapter: fallback, environmentOverrides: [
        AskScriptedBackend.environmentKey: script, "PATH": fixture.root.appendingPathComponent("absent-vendor-bin").path
      ], requiresVendorAvailability: true
    )

    let started = try await service.send(.init(message: "Check records"))
    let id = started.conversation.conversationId
    await service.waitForTurn(conversationId: id)

    let snapshot = try service.conversation(id: id)
    #expect(snapshot.conversation.turn?.status == .completed)
    #expect(snapshot.messages.last?.text == "Scripted answer.")
    #expect(await fallback.inputs.isEmpty)
    try fixture.expectSettlement(for: id, reason: .completed)
  }

  @Test
  func invalidContextCreatesNoConversationAndCallsNoAdapter() async throws {
    let fixture = try AskEngineTestFixture()
    try fixture.seedSession()
    let adapter = AskEngineTestAdapter([.text("unused")])
    let service = fixture.service(adapter: adapter)

    await expectEngineError("ask_context_not_found") {
      _ = try await service.send(.init(message: "What happened?", context: .init(kind: .session, id: "absent")))
    }
    #expect(await adapter.inputs.isEmpty)
    #expect(try fixture.store.askConversations().isEmpty)
  }
}

enum AskEngineBudget: CaseIterable, Sendable {
  case turnCalls, conversationCalls, turnBytes, conversationBytes
}

private actor AskEnginePollAuthorization {
  private(set) var checks = 0

  func isAllowed() -> Bool {
    checks += 1
    return checks == 1
  }
}

private func expectEngineError(_ code: String, performing operation: () async throws -> Void) async {
  do {
    try await operation()
    Issue.record("Expected \(code)")
  } catch let error as AskError {
    #expect(error.code == code)
  } catch {
    Issue.record("Expected \(code), got \(error)")
  }
}
