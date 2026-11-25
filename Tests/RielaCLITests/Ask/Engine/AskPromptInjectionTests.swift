import RielaCore
import Testing
@testable import RielaCLI

@Suite
struct AskPromptInjectionTests {
  @Test
  func logInstructionsCannotMutateSession() async throws {
    let fixture = try AskEngineTestFixture()
    let sessionId = AskEngineTestFixture.sessionId
    let instruction = AskEngineTestFixture.logInstruction
    let secret = AskEngineTestFixture.secret
    try fixture.seedSession(log: "\(instruction) Fixture token: \(secret)")
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: fixture.store.sessionStoreRoot)
    let initialSession = try runtime.loadStrictReadOnly(sessionId: sessionId).session
    let target = #"{"sessionId":"\#(sessionId)"}"#
    let readLog = AskEngineTestFixture.tool("session_logs", arguments: target)
    let rejected = AskEngineTestFixture.tool("stop_session", arguments: target)
    let proposed = AskEngineTestFixture.tool(
      "propose_action", arguments: #"{"kind":"stopSession","target":\#(target),"reason":"Untrusted log request"}"#
    )
    let adapter = AskEngineTestAdapter([.text(readLog), .text("\(rejected)\n\(proposed)"), .text("A proposal needs confirmation.")])
    let service = fixture.service(adapter: adapter)

    let started = try await service.send(.init(message: "Read the latest log"))
    let id = started.conversation.conversationId
    await service.waitForTurn(conversationId: id)

    let snapshot = try service.conversation(id: id)
    #expect(snapshot.conversation.turn?.status == .completed)
    #expect(try runtime.loadStrictReadOnly(sessionId: sessionId).session == initialSession)
    #expect(await fixture.mutations.calls == 0)
    #expect(snapshot.actions.map(\.kind) == [.stopSession])
    #expect(snapshot.actions.map(\.status) == [.proposed])
    #expect(snapshot.actions.first?.target["sessionId"] == .string(sessionId))

    let inputs = await adapter.inputs
    #expect(inputs.count == 3)
    #expect(inputs.dropFirst().first?.promptText.contains(instruction) == true)
    #expect(inputs.last?.promptText.contains("tool_unknown") == true)
    let prompts = inputs.flatMap { [$0.promptText, $0.resolvedFreshPromptText, $0.resolvedResumedPromptText, $0.systemPromptText ?? ""] }
    #expect(prompts.allSatisfy { !$0.contains(secret) })
    #expect(inputs.allSatisfy { $0.systemPromptText?.contains(instruction) == false })
    try fixture.expectSettlement(for: id, reason: .completed)
  }
}
