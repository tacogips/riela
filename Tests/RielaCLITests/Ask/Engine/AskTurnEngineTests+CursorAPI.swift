import RielaCore
import Testing
@testable import RielaCLI

extension AskTurnEngineTests {
  @Test
  func rejectsPinnedCursorCloudAgentWithoutDispatching() async throws {
    let fixture = try AskEngineTestFixture()
    let adapter = AskEngineTestAdapter([.text("unused")])
    let service = fixture.service(
      adapter: adapter, environmentOverrides: ["CURSOR_API_KEY": "fixture-placeholder"], requiresVendorAvailability: true
    )

    await expectCursorAPIRefusal(service, .init(message: "Check records", selection: .init(vendor: "cursor-api")))
    #expect(await adapter.inputs.isEmpty)
    #expect(try fixture.store.askConversations().isEmpty)
  }

  @Test(arguments: [false, true])
  func rejectsCursorAPIOverrideWithoutChangingExistingConversation(staleTurn: Bool) async throws {
    let fixture = try AskEngineTestFixture()
    let adapter = AskEngineTestAdapter([.text("unused")])
    let service = fixture.service(
      adapter: adapter, environmentOverrides: ["CURSOR_API_KEY": "fixture-placeholder"], requiresVendorAvailability: true
    )
    let backend = NodeExecutionBackend.codexAgent.rawValue
    let at = fixture.at.addingTimeInterval(-60)
    let running = try fixture.store.createAndBeginAskTurn(
      message: "Original question", context: AskContext(), selection: AskSelection(), contextRef: nil,
      turn: AskTurn(backend: backend, providerInstanceId: backend, toolTransport: .rounds, runnerId: "previous-runner"),
      now: at
    )
    let id = running.conversationId
    if !staleTurn {
      let turnId = try #require(running.turn?.turnId)
      let settled = try fixture.store.finishAskTurn(
        conversationId: id, turnId: turnId, status: .completed, assistantText: "Original answer", now: at,
        activityReason: .completed
      )
      try #require(settled)
    }
    let stored = try fixture.store.askConversation(id: id)
    let conversation = try #require(stored)
    let messages = try fixture.store.askMessages(conversationId: id)
    let activity = try fixture.activity(for: id)

    await expectCursorAPIRefusal(service, .init(
      conversationId: id, message: "Check again", selection: .init(providerInstanceId: "official/cursor-sdk")
    ))

    #expect(await adapter.inputs.isEmpty)
    #expect(try fixture.store.askConversations() == [conversation])
    #expect(try fixture.store.askMessages(conversationId: id) == messages)
    #expect(try fixture.activity(for: id) == activity)
  }

  @Test
  func rejectsAutomaticWithOnlyCursorAPIAvailable() async throws {
    let fixture = try AskEngineTestFixture()
    let adapter = AskEngineTestAdapter([.text("unused")])
    let service = fixture.service(
      adapter: adapter,
      environmentOverrides: [
        "CURSOR_API_KEY": "fixture-placeholder", "PATH": fixture.root.appendingPathComponent("absent-vendor-bin").path
      ],
      requiresVendorAvailability: true, vendor: .automatic
    )

    await expectCursorAPIRefusal(service, .init(message: "Check records"))
    #expect(await adapter.inputs.isEmpty)
    #expect(try fixture.store.askConversations().isEmpty)
  }

  private func expectCursorAPIRefusal(_ service: AskService, _ request: AskSendRequest) async {
    do {
      _ = try await service.send(request)
      Issue.record("Expected the Cursor cloud-agent backend to fail closed")
    } catch let error as AskError {
      #expect(error.code == "ask_provider_unsupported")
      #expect(error.message.contains("official/cursor-sdk"))
    } catch {
      Issue.record("Expected an Ask error, got \(error)")
    }
  }
}
