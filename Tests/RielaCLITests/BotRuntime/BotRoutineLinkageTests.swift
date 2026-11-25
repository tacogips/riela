import Foundation
import RielaCore
import RielaGraphQL
import RielaWorkflowRegistry
import XCTest
@testable import RielaCLI

final class BotRoutineLinkageTests: XCTestCase {
  func testRoutineCLIValidatesAndRendersBotId() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let app = RielaCLIApplication()
    let create = [
      "routine", "create", "--name", "bot routine", "--task", "do work", "--every", "30m",
      "--workflow", "worker-only-single-step", "--event-root", fixture.eventRoot.path
    ] + fixture.routineCLIOptions

    let rejected = await app.run(create + ["--bot", "missing"], environment: fixture.environment)
    XCTAssertNotEqual(rejected.exitCode, .success)
    XCTAssertTrue(rejected.stderr.contains("bot_not_found: missing"), rejected.stderr)
    XCTAssertEqual(try fixture.routineStore.list(), [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.eventRoot.path))

    try fixture.createBot()
    let created = await app.run(create + ["--bot", "b1"], environment: fixture.environment)
    XCTAssertEqual(created.exitCode, .success, created.stderr)
    let record = try XCTUnwrap(fixture.routineStore.list().first)
    XCTAssertEqual(record.botId, "b1")

    let listed = await app.run(["routine", "list"] + fixture.routineCLIOptions, environment: fixture.environment)
    let inspected = await app.run(
      ["routine", "inspect", record.routineId] + fixture.routineCLIOptions, environment: fixture.environment
    )
    XCTAssertEqual(listed.exitCode, .success, listed.stderr)
    XCTAssertTrue(listed.stdout.contains("botId=b1"), listed.stdout)
    XCTAssertEqual(inspected.exitCode, .success, inspected.stderr)
    XCTAssertTrue(inspected.stdout.contains("botId=b1"), inspected.stdout)
  }

  func testCronDispatchSkipsPausedBotAndLinksResumedBotSession() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try await CLIRuntimeEnvironment.$overrides.withValue(fixture.environment) {
      try await assertCronLinkage(fixture)
    }
  }

  private func assertCronLinkage(_ fixture: Fixture) async throws {
    try fixture.createBot(paused: true)
    let service = RoutineService(workingDirectory: fixture.root.path, environment: fixture.environment)
    let record = try service.create(RoutineCreateRequest(
      name: "bot routine", task: "do work", schedule: "* * * * * *",
      workflowName: "worker-only-single-step", eventRoot: fixture.eventRoot.path,
      routineStoreRoot: fixture.routineStore.rootDirectory, botId: "b1"
    )).routine
    let examples = Fixture.repositoryRoot.appendingPathComponent("examples")
    let parsed = try ParsedParityOptions([
      "--working-dir", fixture.root.path, "--session-store", fixture.sessionStoreRoot,
      "--artifact-root", fixture.root.appendingPathComponent("artifacts").path,
      "--workflow-definition-dir", examples.path,
      "--mock-scenario", examples.appendingPathComponent("worker-only-single-step/mock-scenario.json").path
    ])
    let config = try EventLiveConfig.load(eventRoot: fixture.eventRoot)
    let source = try XCTUnwrap(config.cronSources(eventRoot: fixture.eventRoot).first)
    let server = DefaultEventLiveServer()
    let dispatcher = CronOverlapDispatcher(
      server: server, eventRoot: fixture.eventRoot, parsed: parsed, policies: [:],
      clock: SystemEventServeClock(), cancelSettleTimeout: .seconds(30)
    )

    let pausedTick = Date(timeIntervalSince1970: 1_790_000_000)
    let skipped = try await server.dispatchCronTick(
      source: source, scheduledAt: pausedTick, firedAt: pausedTick, config: config,
      eventRoot: fixture.eventRoot, parsed: parsed, dispatcher: dispatcher
    )
    XCTAssertEqual(skipped, 0)
    let receiptStore = EventReceiptStore(eventRoot: fixture.eventRoot)
    let skippedReceipt = try receiptStore.load(cronOverlapReceiptId(
      sourceId: source.id, eventId: "\(source.id)-1790000000", bindingId: record.bindingId
    ))
    XCTAssertEqual(skippedReceipt?.reason, "bot_paused:b1")
    XCTAssertEqual(try fixture.botStore.links(botId: "b1"), [])

    try fixture.botStore.setPaused(botId: "b1", paused: false)
    let resumedTick = pausedTick.addingTimeInterval(1)
    let dispatched = try await server.dispatchCronTick(
      source: source, scheduledAt: resumedTick, firedAt: resumedTick, config: config,
      eventRoot: fixture.eventRoot, parsed: parsed, dispatcher: dispatcher
    )
    XCTAssertEqual(dispatched, 1)
    await dispatcher.drain()

    let receipt = try XCTUnwrap(receiptStore.load(cronOverlapReceiptId(
      sourceId: source.id, eventId: "\(source.id)-1790000001", bindingId: record.bindingId
    )))
    XCTAssertEqual(receipt.status, "completed", receipt.reason ?? "")
    let links = try fixture.botStore.links(botId: "b1")
    XCTAssertEqual(links.count, 1)
    let link = try XCTUnwrap(links.first)
    XCTAssertEqual(link.sessionId, receipt.workflowExecutionId)
    XCTAssertEqual(link.source, "routine")
    XCTAssertEqual(link.sourceRef, record.routineId)
    XCTAssertEqual(try fixture.routineStore.load(routineId: record.routineId)?.runCount, 1)
  }

  func testGraphQLRoutineProviderValidatesBotAndExposesLink() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let provider = FileRoutineGraphQLProvider(
      workingDirectory: fixture.root.path, environment: fixture.environment, botExists: { $0 == "b1" }
    )
    let executor = RoutineGraphQLDocumentExecutor(provider: provider)
    let created = await executor.execute(fixture.graphQLRequest(botId: "b1"))
    XCTAssertEqual(created.body["data"], .object([
      "createRoutine": .object(["accepted": .bool(true), "routine": .object(["botId": .string("b1")])])
    ]))

    let rejected = await executor.execute(fixture.graphQLRequest(botId: "missing"))
    XCTAssertNotNil(rejected.body["errors"])
    XCTAssertTrue(String(describing: rejected.body["errors"]).contains("bot_not_found: missing"))
    XCTAssertEqual(try fixture.routineStore.list().map(\.botId), ["b1"])

    let noLookup = FileRoutineGraphQLProvider(
      workingDirectory: fixture.root.path, environment: fixture.environment,
      botExists: { _ in
        XCTFail("Unlinked routine creation must never consult the bot store")
        return false
      }
    )
    let unlinked = try await noLookup.createRoutine(input: GraphQLCreateRoutineInput(
      name: "unlinked routine", task: "do work", every: "30m", workflowName: "worker-only-single-step",
      eventRoot: fixture.eventRoot.path, routineStoreRoot: fixture.routineStore.rootDirectory
    ))
    XCTAssertTrue(unlinked.accepted)
    XCTAssertNotNil(unlinked.routine)
    XCTAssertNil(unlinked.routine?.botId)
  }

  func testGraphQLDocumentCLIUsesSelectedSessionStore() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let app = RielaCLIApplication()
    let arguments = [
      "graphql", "document", "--query", Fixture.createMutation, "--working-dir", fixture.root.path,
      "--session-store", fixture.sessionStoreRoot, "--output", "json"
    ]
    var environment = fixture.environment
    environment["RIELA_SESSION_STORE"] = fixture.root.appendingPathComponent("unused-sessions").path

    let missing = try jsonString(fixture.graphQLRequest(botId: "missing").variables)
    let rejected = await app.run(arguments + ["--variables", missing], environment: environment)
    XCTAssertEqual(rejected.exitCode, .success, rejected.stderr)
    XCTAssertTrue(rejected.stdout.contains("bot_not_found: missing"), rejected.stdout)
    XCTAssertEqual(try fixture.routineStore.list(), [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.eventRoot.path))

    try fixture.createBot()
    let valid = try jsonString(fixture.graphQLRequest(botId: "b1").variables)
    let created = await app.run(arguments + ["--variables", valid], environment: environment)
    XCTAssertEqual(created.exitCode, .success, created.stderr)
    XCTAssertFalse(created.stdout.contains("bot_not_found"), created.stdout)
    XCTAssertEqual(try fixture.routineStore.list().map(\.botId), ["b1"])
  }

  private struct Fixture {
    static let createMutation = """
      mutation CreateBotRoutine($input: CreateRoutineInput!) {
        createRoutine(input: $input) { accepted routine { botId } }
      }
      """

    static let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()

    let root: URL

    init() throws {
      root = Self.repositoryRoot.appendingPathComponent("tmp/bots-overview/bots-09-run-linkage", isDirectory: true)
        .appendingPathComponent("routine-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var eventRoot: URL { root.appendingPathComponent("events", isDirectory: true) }
    var sessionStoreRoot: String { root.appendingPathComponent("sessions", isDirectory: true).path }
    var routineStore: RoutineStore {
      RoutineStore(rootDirectory: root.appendingPathComponent("routines", isDirectory: true).path)
    }
    var botStore: BotStore {
      BotStore(sessionStoreRoot: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot))
    }
    var routineCLIOptions: [String] {
      ["--working-dir", root.path, "--routine-store", routineStore.rootDirectory, "--output", "text"]
    }
    var environment: [String: String] {
      [
        "HOME": root.path,
        "RIELA_WORKFLOW_HOME": root.appendingPathComponent(".riela", isDirectory: true).path,
        "RIELA_SESSION_STORE": sessionStoreRoot,
        "RIELA_EVENTS_READ_ONLY": "false",
        "RIEL_EVENTS_READ_ONLY": "false"
      ]
    }

    func createBot(paused: Bool = false) throws {
      let timestamp = RoutineStore.timestamp(Date(timeIntervalSince1970: 1_790_000_000))
      try botStore.create(BotRecord(
        botId: "b1", name: "Bot One", paused: paused, createdAt: timestamp, updatedAt: timestamp
      ))
    }

    func graphQLRequest(botId: String) -> GraphQLDocumentRequest {
      GraphQLDocumentRequest(
        query: Self.createMutation,
        variables: ["input": .object([
          "name": .string("bot routine"), "task": .string("do work"), "every": .string("30m"),
          "workflowName": .string("worker-only-single-step"), "eventRoot": .string(eventRoot.path),
          "routineStoreRoot": .string(routineStore.rootDirectory), "botId": .string(botId)
        ])],
        environment: environment, isLocallyTrusted: true, localWorkingDirectory: root.path
      )
    }

    func remove() {
      try? FileManager.default.removeItem(at: root)
    }
  }
}
