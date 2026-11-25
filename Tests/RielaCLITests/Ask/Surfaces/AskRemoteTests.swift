import Foundation
import RielaAppSupport
import RielaCore
import RielaGraphQL
import RielaServer
import Testing
@testable import RielaCLI

@MainActor
struct AskRemoteTests {
  @Test func followsOnlyTheRemoteStoreAndShowsVerifiedOrigin() async throws {
    let pair = try AskRemotePair()
    try pair.server.script(["Remote answer."])
    try await pair.addRemote(scope: .operate)
    let result = await pair.ask(["--remote", "srv", "--output", "json", "state?"])
    let payload = try pair.client.decode(AskConversationPayload.self, result)
    #expect(payload.origin.remote == "srv")
    #expect(payload.origin.verified)
    #expect(payload.messages.last?.text == "Remote answer.")
    #expect(try pair.server.store.askConversation(id: payload.conversation.conversationId)?.turn?.status == .completed)
    #expect(try pair.client.store.askConversations().isEmpty)
  }

  @Test(arguments: [false, true])
  func pairedServerOwnsNoFollowTurn(activeRemote: Bool) async throws {
    let pair = try AskRemotePair()
    try pair.server.script(["Remote answer."])
    try await pair.addRemote(scope: .operate)
    if activeRemote { try pair.client.registry.use(name: "srv") }
    let selector = activeRemote ? [] : ["--remote", "srv"]
    let result = await pair.ask(selector + ["--no-follow", "--output", "json", "state?"])
    let payload = try pair.client.decode(AskConversationPayload.self, result)
    let id = payload.conversation.conversationId
    #expect(payload.conversation.turn?.status == .running)
    #expect(payload.origin.remote == "srv")
    await AskRuntime.shared.wait(conversationId: id)
    #expect(try pair.server.store.askConversation(id: id)?.turn?.status == .completed)
    #expect(try pair.server.store.askMessages(conversationId: id).last?.text == "Remote answer.")
    #expect(try pair.client.store.askConversations().isEmpty)
  }

  @Test func readGrantCanListButCannotStartAndOfflineHasNoAnswer() async throws {
    let pair = try AskRemotePair()
    try pair.server.script(["Remote answer."])
    try await pair.addRemote(scope: .read)
    let denied = await pair.ask(["--remote", "srv", "state?"])
    #expect(denied.exitCode == .failure)
    #expect(denied.stderr.contains("scope_insufficient"))
    #expect(denied.stdout.isEmpty)
    let list = await pair.ask(["list", "--remote", "srv", "--output", "json"])
    #expect(try pair.client.decode(AskConversationListPayload.self, list).conversations.isEmpty)
    let offline = await pair.client.ask(["--remote", "srv", "state?"], transport: { _ in
      throw URLError(.notConnectedToInternet)
    })
    #expect(offline.exitCode == .failure)
    #expect(offline.stderr.contains("remote_unreachable"))
    #expect(offline.stdout.isEmpty)
    #expect(try pair.server.store.askConversations().isEmpty)
    #expect(try pair.client.store.askConversations().isEmpty)
  }

  @Test func confirmedActionUsesTheServerStoreAndPairingIdentity() async throws {
    let pair = try AskRemotePair()
    try pair.server.seedBot()
    try pair.client.seedBot()
    try pair.server.script([AskSurfaceFixture.pauseProposal, "Please confirm the pause."])
    try await pair.addRemote(scope: .operate)

    let result = await pair.ask(["--remote", "srv", "--output", "json", "pause?"])
    let payload = try pair.client.decode(AskConversationPayload.self, result)
    let action = try #require(payload.actions.first)
    let confirmation = await pair.ask([
      "confirm", payload.conversation.conversationId, action.actionId, "--remote", "srv", "--output", "json"
    ])
    let confirmed = try pair.client.decode(AskConversationPayload.self, confirmation)
    let grant = try pair.client.registry.record(name: "srv").grantId
    #expect(confirmed.actions.first?.status == .confirmed)
    #expect(confirmed.actions.first?.decidedBy == "\(grant)/Ask fixture")
    #expect(try pair.server.store.load(botId: "fixture-bot")?.paused == true)
    #expect(try pair.client.store.load(botId: "fixture-bot")?.paused == false)
  }
}

private struct AskRemotePair: Sendable {
  let client: AskSurfaceFixture
  let server: AskSurfaceFixture
  let pairing: PairingService
  let transport: RemoteHTTP.Transport

  @MainActor
  init() throws {
    client = try AskSurfaceFixture()
    server = try AskSurfaceFixture()
    let home = URL(fileURLWithPath: try #require(server.environment["HOME"]), isDirectory: true)
    pairing = try PairingService(store: serverAPIKeyStore(homeDirectory: home), serverName: "Ask fixture server")
    let parsed = try ParsedParityOptions(["--working-dir", server.root.path, "--session-store", server.sessionRoot])
    let adapter = serveMachineGraphQLAdapter(
      parsed: parsed, environment: server.environment, workingDirectory: server.root.path, pairing: pairing
    )
    let host = ServeWebHost(
      homeDirectory: home, workingDirectory: server.root, sessionStoreRoot: server.sessionRoot,
      host: "0.0.0.0", port: 8787, fallback: adapter,
      environment: server.environment.merging(["RIELA_WEB_ORIGIN": "https://riela.example"]) { _, value in value },
      pairing: pairing
    )
    transport = RemoteTestFixture.transport(to: host)
  }

  func addRemote(scope: RielaAPIKeyStore.Scope) async throws {
    let minted = try pairing.mint(address: "https://riela.example", scope: scope)
    let result = await client.run(
      ["remote", "add", "--name", "srv", "--code", minted.code, "--client-name", "Ask fixture"], transport: transport
    )
    try #require(result.exitCode == .success)
  }

  func ask(_ args: [String]) async -> CLICommandResult {
    await client.ask(args, transport: transport)
  }
}
