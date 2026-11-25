import Foundation
import RielaCore
import RielaGraphQL
import RielaServer
import XCTest
@testable import RielaCLI

@MainActor
final class RemoteForwardingTests: XCTestCase {
  func testExplicitAllAndActiveListsPreserveOriginsAndOrder() async throws {
    let pair = try ForwardingPair(test: self)
    try pair.client.createBot("local-bot")
    try await pair.pairRemote()

    let targeted = try await pair.list(["--remote", "srv"])
    XCTAssertEqual(targeted.bots.map(\.bot.botId), ["remote-bot"])
    XCTAssertEqual(targeted.bots.first?.origin.remote, "srv")
    XCTAssertEqual(targeted.bots.first?.origin.serverId, pair.pairing.identity.serverId)
    XCTAssertEqual(targeted.bots.first?.origin.verified, true)

    let all = try await pair.list(["--all-remotes"])
    XCTAssertEqual(all.bots.map(\.bot.botId), ["local-bot", "remote-bot"])
    XCTAssertEqual(all.bots.map(\.origin.remote), ["local", "srv"])
    let use = await pair.client.run(["remote", "use", "srv"], transport: pair.transport)
    XCTAssertEqual(use.exitCode, .success, use.stderr)
    let active = try await pair.list([])
    XCTAssertEqual(active.bots.map(\.bot.botId), ["remote-bot"])
    let explicitLocal = try await pair.list(["--remote", "local"])
    XCTAssertEqual(explicitLocal.bots.map(\.bot.botId), ["local-bot"])
  }

  func testReplacementServerIdentityIsUnverified() async throws {
    let pair = try ForwardingPair(test: self)
    try await pair.pairRemote()
    let replacement = try RemoteTestFixture(test: self)
    try replacement.createBot("replacement-bot")
    let server = try replacement.serve(name: "Replacement")
    let key = try server.pairing.store.issue(name: "test bridge", scope: .read)
    let replacementTransport = RemoteTestFixture.transport(to: server.host)
    let result = try await pair.list(["--remote", "srv"]) { request in
      // Keep both real stores isolated and let the second composite authenticate its own fixture key.
      var request = request
      request.setValue("Bearer " + key.token, forHTTPHeaderField: "Authorization")
      return try await replacementTransport(request)
    }
    XCTAssertEqual(result.bots.map(\.bot.botId), ["replacement-bot"])
    XCTAssertEqual(result.bots.first?.origin.serverId, server.pairing.identity.serverId)
    XCTAssertEqual(result.bots.first?.origin.remote, "unverified")
    XCTAssertEqual(result.bots.first?.origin.verified, false)
  }

  func testResponseWithoutOriginIsUnverifiedAndDoesNotSeedCache() async throws {
    let pair = try ForwardingPair(test: self)
    try await pair.pairRemote()
    let transport = pair.transport
    let result = try await pair.list(["--remote", "srv"]) { request in
      let (body, status) = try await transport(request)
      var response = try JSONDecoder().decode(JSONObject.self, from: body)
      var data = try XCTUnwrap(response["data"]?.pairingObject)
      var list = try XCTUnwrap(data["bots"]?.pairingObject)
      var row = try XCTUnwrap(list["bots"]?.pairingArray?.first?.pairingObject)
      row["origin"] = nil
      list["bots"] = .array([.object(row)])
      data["bots"] = .object(list)
      response["data"] = .object(data)
      return (try JSONEncoder().encode(response), status)
    }
    let row = try XCTUnwrap(result.bots.first)
    XCTAssertEqual(row.bot.botId, "remote-bot")
    XCTAssertEqual(row.origin.remote, "unverified")
    XCTAssertFalse(row.origin.verified)
    XCTAssertNil(row.origin.serverId)
    XCTAssertNil(try pair.client.registry.record(name: "srv").lastKnown)
  }

  func testDisconnectedListUsesLastKnownAndAnEmptyRemoteGetsPlaceholder() async throws {
    let pair = try ForwardingPair(test: self)
    try pair.client.createBot("local-bot")
    try await pair.pairRemote()
    try await pair.pairRemote(name: "unseen")
    let connected = try await pair.list(["--remote", "srv"])
    let seen = try XCTUnwrap(connected.bots.first)
    let unavailable: RemoteHTTP.Transport = { _ in throw URLError(.notConnectedToInternet) }

    let disconnected = try await pair.list(["--remote", "srv"], using: unavailable)
    let cached = try XCTUnwrap(disconnected.bots.first)
    XCTAssertEqual(cached.bot.botId, seen.bot.botId)
    XCTAssertEqual(cached.origin.remote, "srv")
    XCTAssertEqual(cached.origin.connection, "disconnected")
    let lastKnown = try XCTUnwrap(pair.client.registry.record(name: "srv").lastKnown)
    XCTAssertEqual(Int(cached.origin.observedAt.timeIntervalSince1970), Int(lastKnown.observedAt.timeIntervalSince1970))
    XCTAssertEqual(cached.section.rawValue, "disconnected")
    XCTAssertEqual(cached.counts, seen.counts)
    XCTAssertTrue(cached.inProgress.isEmpty)
    XCTAssertNil(cached.lastResult)

    let all = try await pair.list(["--all-remotes"], using: unavailable)
    XCTAssertEqual(all.bots.map(\.origin.remote), ["local", "srv", "unseen"])
    XCTAssertEqual(all.bots.last?.section.rawValue, "disconnected")
    let details = await pair.bot(["show", "remote-bot", "--remote", "srv"], using: unavailable)
    XCTAssertNotEqual(details.exitCode, .success)
    XCTAssertTrue(details.stderr.contains("remote_unreachable"))
    let text = await pair.bot(["list", "--remote", "srv"], using: unavailable)
    XCTAssertEqual(text.exitCode, .success)
    XCTAssertTrue(text.stdout.contains("disconnected (last seen"))
    XCTAssertFalse(text.stdout.contains("working:0"))
  }

  func testScopesAndRevocationEnforceServerAuthorityWithoutLocalWrites() async throws {
    let pair = try ForwardingPair(test: self)
    try pair.client.createBot("remote-bot")
    try await pair.pairRemote(name: "reader")
    try await pair.pairRemote(scope: .operate)

    let denied = await pair.bot(["pause", "remote-bot", "--remote", "reader"])
    XCTAssertNotEqual(denied.exitCode, .success)
    XCTAssertTrue(denied.stderr.contains("scope_insufficient"))
    XCTAssertEqual(try pair.server.botStore.load(botId: "remote-bot")?.paused, false)

    let paused = await pair.bot(["pause", "remote-bot", "--remote", "srv"])
    XCTAssertEqual(paused.exitCode, .success, paused.stderr)
    XCTAssertEqual(try pair.server.botStore.load(botId: "remote-bot")?.paused, true)
    XCTAssertEqual(try pair.client.botStore.load(botId: "remote-bot")?.paused, false)

    let wildcard = await pair.bot(["resume", "remote-bot", "--all-remotes"])
    XCTAssertNotEqual(wildcard.exitCode, .success)
    XCTAssertTrue(wildcard.stderr.contains("remote_selector_invalid"))
    let grant = try pair.client.registry.record(name: "srv").grantId
    _ = try pair.pairing.revoke(grantId: grant)
    let revoked = await pair.bot(["list", "--remote", "srv"])
    XCTAssertNotEqual(revoked.exitCode, .success)
    XCTAssertTrue(revoked.stderr.contains("remote_unauthorized"))
  }

  func testAnswersAndActivityUseTheServerRuntime() async throws {
    let pair = try ForwardingPair(test: self)
    try await pair.pairRemote(scope: .operate)
    try pair.server.startSession()
    let store = pair.server.botStore
    let recorder = SQLiteWorkflowActivityRecorder(sessionStoreRoot: store.sessionStoreRoot)
    await recorder.stepStarted(
      sessionId: "session", executionId: "execution", stepId: "step", nodeId: "worker",
      backend: nil, requestedModel: nil, at: Date()
    )
    let pending = Task {
      await recorder.requestPermission(
        sessionId: "session", executionId: "execution",
        request: .init(title: "Continue?", options: [.init(optionId: "allow-1", name: "Allow", kind: "allow_once")]),
        waitMs: 10_000, deadline: nil
      )
    }
    defer { pending.cancel() }
    let requestId = try await pendingRequest(in: store)
    let answer = await pair.bot(["answer", requestId, "--option", "allow-1", "--remote", "srv"])
    XCTAssertEqual(answer.exitCode, .success, answer.stderr)
    let outcome = await pending.value
    XCTAssertEqual(outcome, .selected(optionId: "allow-1"))

    let activity = await pair.bot(["activity", "--session", "session", "--remote", "srv", "--output", "json"])
    let page = try pair.client.decode(BotActivityPage.self, activity)
    XCTAssertEqual(page.origin.remote, "srv")
    XCTAssertEqual(page.events.map(\.kind), [.stepStarted, .permissionRequested, .permissionResolved])
    XCTAssertTrue(page.events.allSatisfy { $0.sessionId == "session" })
  }

  func testModelCatalogAndMemoryReadThroughTheServer() async throws {
    let pair = try ForwardingPair(test: self)
    try await pair.pairRemote()
    let model = await pair.client.run(["model", "list", "--remote", "srv", "--output", "json"], transport: pair.transport)
    let catalog = try pair.client.decode(ModelCatalogPayload.self, model)
    XCTAssertFalse(catalog.providers.isEmpty)
    XCTAssertTrue(catalog.providers.allSatisfy { $0.origin.remote == "srv" && $0.origin.verified })

    let memory = await pair.bot(["memory", "show", "remote-bot", "--remote", "srv", "--output", "json"])
    let payload = try pair.client.decode(JSONObject.self, memory)
    XCTAssertEqual(payload["botId"], .string("remote-bot"))
    XCTAssertNotNil(payload["markdown"])
    XCTAssertNil(try pair.client.botStore.load(botId: "remote-bot"))
  }

  private func pendingRequest(in store: BotStore) async throws -> String {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    repeat {
      if let request = try store.pendingActivityRequests(sessionIds: ["session"]).first {
        return request.requestId
      }
      try await Task.sleep(for: .milliseconds(10))
    } while ContinuousClock.now < deadline
    throw BotStoreError(code: "fixture_request_missing", message: "The recorder did not persist a permission request")
  }
}

@MainActor
private struct ForwardingPair {
  let server: RemoteTestFixture
  let client: RemoteTestFixture
  let pairing: PairingService
  let transport: RemoteHTTP.Transport

  init(test: XCTestCase) throws {
    server = try RemoteTestFixture(test: test)
    client = try RemoteTestFixture(test: test)
    try server.createBot("remote-bot")
    let served = try server.serve()
    pairing = served.pairing
    transport = RemoteTestFixture.transport(to: served.host)
  }

  func pairRemote(name: String = "srv", scope: RielaAPIKeyStore.Scope = .read) async throws {
    let minted = try pairing.mint(address: "https://riela.example", scope: scope)
    let added = await client.run(["remote", "add", "--name", name, "--code", minted.code], transport: transport)
    XCTAssertEqual(added.exitCode, .success)
  }

  func bot(_ arguments: [String], using override: RemoteHTTP.Transport? = nil) async -> CLICommandResult {
    await client.run(client.botArguments(arguments), transport: override ?? transport)
  }

  func list(_ arguments: [String], using override: RemoteHTTP.Transport? = nil) async throws -> BotListPayload {
    let result = await bot(["list", "--output", "json"] + arguments, using: override)
    return try client.decode(BotListPayload.self, result)
  }
}
