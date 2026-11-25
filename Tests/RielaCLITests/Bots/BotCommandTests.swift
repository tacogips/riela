import Foundation
import RielaCore
import RielaGraphQL
import RielaWork
import XCTest
@testable import RielaCLI

final class BotCommandTests: XCTestCase {
  func testEmptyStoreAndCreateUpdatePauseResume() async throws {
    let fixture = try fixture()
    let empty = await fixture.run(["list", "--output", "text"])
    XCTAssertEqual(empty.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "[]")
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.databasePath))

    let created: BotMutationPayload = try await fixture.json(["create", "--name", "Release Bot", "--purpose", "Ship"])
    XCTAssertEqual(created.bot.botId, "release-bot")
    let duplicate = await fixture.run(["create", "--name", "Release Bot"])
    XCTAssertNotEqual(duplicate.exitCode, .success)
    XCTAssertTrue(duplicate.stderr.contains("bot_exists"), duplicate.stderr)
    let listing: BotListPayload = try await fixture.json(["list"])
    XCTAssertEqual(listing.bots.map(\.bot.botId), ["release-bot"])
    XCTAssertEqual(listing.bots.first?.counts.working, 0)
    XCTAssertNil(listing.bots.first?.lastActivityAt)
    let updated: BotMutationPayload = try await fixture.json(["update", "release-bot", "--model", "default"])
    XCTAssertEqual(updated.bot.purpose, "Ship")
    XCTAssertEqual(updated.bot.defaultModel, "default")
    let paused: BotMutationPayload = try await fixture.json(["pause", "release-bot"])
    XCTAssertTrue(paused.bot.paused)
    let resumed: BotMutationPayload = try await fixture.json(["resume", "release-bot"])
    XCTAssertFalse(resumed.bot.paused)
  }

  func testBotListStateCommandsChangeServerOrderAndSections() async throws {
    let fixture = try fixture()
    try await fixture.assertSuccess(["create", "--name", "Alpha"])
    try await fixture.assertSuccess(["create", "--name", "Bravo"])
    try await fixture.assertSuccess(["pin", "bravo"])
    let pinned: BotListPayload = try await fixture.json(["list"])
    XCTAssertEqual(pinned.bots.map(\.bot.botId), ["bravo", "alpha"])
    try await fixture.assertSuccess(["unpin", "bravo"])
    try await fixture.assertSuccess(["move", "alpha", "--position", "2"])
    try await fixture.assertSuccess(["move", "bravo", "--position", "1"])
    let moved: BotListPayload = try await fixture.json(["list"])
    XCTAssertEqual(moved.bots.map(\.bot.botId), ["bravo", "alpha"])
    try await fixture.assertSuccess(["snooze", "bravo", "--for", "2h"])
    let snoozed: BotListPayload = try await fixture.json(["list"])
    XCTAssertEqual(snoozed.bots.first { $0.bot.botId == "bravo" }?.section, .snoozed)
    try await fixture.assertSuccess(["unsnooze", "bravo"])
    let awake: BotListPayload = try await fixture.json(["list"])
    XCTAssertEqual(awake.bots.first?.section, .active)
    try await fixture.assertSuccess(["settle", "bravo"])
    let settled: BotListPayload = try await fixture.json(["list"])
    XCTAssertEqual(settled.bots.first { $0.bot.botId == "bravo" }?.section, .settled)
    try await fixture.assertSuccess(["unsettle", "bravo"])
  }

  func testMockRunAppearsClosedAndCanSettleItsItem() async throws {
    let fixture = try fixture()
    try await fixture.assertSuccess(["create", "--name", "Release Bot"])
    let workflowName = "worker-only-single-step"
    let source = fixture.repository.appendingPathComponent("examples/\(workflowName)")
    let workflows = fixture.root.appendingPathComponent(".riela/workflows")
    try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
    let workflow = workflows.appendingPathComponent(workflowName)
    try FileManager.default.copyItem(at: source, to: workflow)
    let result = await RielaCLIApplication().run([
      "workflow", "run", workflowName, "--bot", "release-bot", "--mock-scenario",
      workflow.appendingPathComponent("mock-scenario.json").path, "--output", "json",
      "--working-dir", fixture.root.path, "--session-store", fixture.sessions,
      "--artifact-root", fixture.root.appendingPathComponent("artifacts").path
    ], environment: fixture.environment)
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let detail: BotDetailPayload = try await fixture.json(["show", "release-bot"])
    let closed = try XCTUnwrap(detail.board.closed.first)
    XCTAssertEqual(closed.workflowId, workflowName)
    XCTAssertEqual(closed.activitySource, "session")
    XCTAssertNotNil(closed.lastResult)
    XCTAssertEqual(detail.memory, .null)
    let listing: BotListPayload = try await fixture.json(["list"])
    XCTAssertNotNil(listing.bots.first?.lastActivityAt)
    try await fixture.assertSuccess(["settle", "release-bot", "--item", "session:\(closed.itemId)"])
    let key = BotListStateKey(itemKind: "session", itemId: closed.itemId)
    XCTAssertNotNil(try fixture.store.listState(botId: "release-bot")[key]?.settledAt)
  }

  func testRoutineAppearsPlannedAndRemoveDetachesIt() async throws {
    let fixture = try fixture()
    try await fixture.assertSuccess(["create", "--name", "Release Bot"])
    let routine = await RielaCLIApplication().run([
      "routine", "create", "--name", "Daily release", "--bot", "release-bot", "--task", "Ship",
      "--every", "30m", "--workflow", "worker-only-single-step", "--working-dir", fixture.root.path,
      "--event-root", fixture.root.appendingPathComponent("events").path
    ], environment: fixture.environment)
    XCTAssertEqual(routine.exitCode, .success, routine.stderr + routine.stdout)
    let detail: BotDetailPayload = try await fixture.json(["show", "release-bot"])
    let row = try XCTUnwrap(detail.routines.first)
    XCTAssertNotNil(row.nextRunAt)
    XCTAssertEqual(detail.board.planned.map(\.itemId), [row.routineId])
    try await fixture.assertSuccess(["remove", "release-bot"])
    XCTAssertNil(try fixture.store.load(botId: "release-bot"))
    let routines = RoutineStore(rootDirectory: RoutineStore.defaultRootDirectory(workingDirectory: fixture.root.path))
    let remaining = try XCTUnwrap(routines.load(routineId: row.routineId))
    XCTAssertNil(remaining.botId)
  }

  func testBusyBotCannotSettleAndPendingRequestPreventsRemoval() async throws {
    let fixture = try fixture()
    try await fixture.assertSuccess(["create", "--name", "Release Bot"])
    let instant = Date(timeIntervalSince1970: 1_790_000_000)
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: fixture.store.sessionStoreRoot)
    let running = WorkflowSession(
      workflowId: "flow", sessionId: "running", status: .running, entryStepId: "work",
      currentStepId: "work", createdAt: instant, updatedAt: instant
    )
    try runtime.save(.init(session: running))
    try fixture.store.linkSession(sessionId: running.sessionId, botId: "release-bot", source: "run", at: instant)
    let settled = await fixture.run(["settle", "release-bot"])
    XCTAssertTrue(settled.stderr.contains("list_item_busy"), settled.stderr)
    var completed = running
    completed.status = .completed
    try runtime.save(.init(session: completed))
    try fixture.store.write { database in
      try database.execute("""
        INSERT INTO activity_requests
          (request_id, session_id, execution_id, options_json, status, created_at, expires_at)
        VALUES ('request', 'running', 'execution', jsonb('[]'), 'pending', '2026-11-01T00:00:00Z', '2030-11-01T00:00:00Z')
        """)
    }
    let removed = await fixture.run(["remove", "release-bot"])
    XCTAssertTrue(removed.stderr.contains("bot_busy"), removed.stderr)
    XCTAssertNotNil(try fixture.store.load(botId: "release-bot"))
  }

  func testOwnedWorkTaskUsesPersistedUpdateTime() async throws {
    let fixture = try fixture()
    try await fixture.assertSuccess(["create", "--name", "Release Bot"])
    let work = WorkStore(rootDirectory: fixture.store.sessionStoreRoot)
    let owned = WorkTask(
      id: TaskID(rawValue: "task-owned"), intentId: IntentID(rawValue: "intent-example"),
      title: "Owned task", instruction: "Ship", owner: OwnerAssignment(identity: "bot:release-bot"), state: .ready
    )
    let other = WorkTask(
      id: TaskID(rawValue: "task-other"), intentId: owned.intentId,
      title: "Another task", instruction: "Ship", owner: OwnerAssignment(identity: "bot:other"), state: .ready
    )
    try work.saveTask(owned)
    try work.saveTask(other)
    let stamp = "2026-11-25T03:00:00Z"
    try fixture.store.write { database in
      try database.execute("UPDATE work_tasks SET updated_at = ? WHERE task_id = ?", bindings: [
        .text(stamp), .text(owned.id.rawValue)
      ])
    }
    let detail: BotDetailPayload = try await fixture.json(["show", "release-bot"])
    XCTAssertEqual(detail.board.planned.map(\.itemId), [owned.id.rawValue])
    let list: BotListPayload = try await fixture.json(["list"])
    XCTAssertEqual(list.bots.first?.lastActivityAt, ISO8601DateFormatter().date(from: stamp))
  }

  func testLibraryComposesBotAndRoutineOperationsOnSameStore() async throws {
    let fixture = try fixture()
    let library = RielaLibrary(workingDirectory: fixture.root.path, sessionStore: fixture.sessions)
    try await CLIRuntimeEnvironment.$overrides.withValue(fixture.environment) {
      let response = await library.executeGraphQLDocument("""
        mutation { createBot(input: { name: "Server Bot" }) { bot { botId } } }
        """)
      XCTAssertNil(response.body["errors"], "\(response.body)")
      let mixed = await library.executeGraphQLDocument("""
        { bots { bots { bot { botId } } } routines { routines { routineId } } }
        """)
      XCTAssertNil(mixed.body["errors"], "\(mixed.body)")
      XCTAssertEqual(try fixture.store.load(botId: "server-bot")?.name, "Server Bot")
      let update = await library.executeGraphQLDocument("""
        mutation {
          updateBot(input: {botId: "server-bot", purpose: "Ship"}) { bot { purpose } }
          setBotPaused(input: {botId: "server-bot", paused: true}) { bot { paused } }
          setBotListState(input: {botId: "server-bot", pinned: true}) { bot { botId } }
        }
        """)
      XCTAssertNil(update.body["errors"], "\(update.body)")
      let key = BotListStateKey.bot
      XCTAssertEqual(try fixture.store.listState(botId: "server-bot")[key]?.pinned, true)
      let detail: BotDetailPayload = try await fixture.json(["show", "server-bot"])
      XCTAssertEqual(detail.bot.name, "Server Bot")
      XCTAssertEqual(detail.bot.purpose, "Ship")
      XCTAssertTrue(detail.bot.paused)
      let read = await library.executeGraphQLDocument("""
        { bot(botId: "server-bot") { bot { botId paused } board { closedTotal } } }
        """)
      XCTAssertEqual(read.body["data"], .object([
        "bot": .object([
          "bot": .object(["botId": .string("server-bot"), "paused": .bool(true)]),
          "board": .object(["closedTotal": .integer(0)])
        ])
      ]))
      let remote = await library.executeGraphQLDocument(#"{ bots(filter: {remote: "other"}) { groups } }"#)
      XCTAssertTrue(String(describing: remote.body["errors"]).contains("remote_not_configured"))
      let removed = await library.executeGraphQLDocument("""
        mutation { removeBot(input: {botId: "server-bot"}) { bot { botId } } }
        """)
      XCTAssertNil(removed.body["errors"], "\(removed.body)")
      XCTAssertNil(try fixture.store.load(botId: "server-bot"))
    }
  }

  private func fixture() throws -> BotCommandFixture {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/bots-overview/bots-10-bot-surfaces/test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return BotCommandFixture(root: root, repository: repository)
  }
}

private struct BotCommandFixture {
  let root: URL
  let repository: URL

  var sessions: String { root.appendingPathComponent(".riela/sessions").path }
  var store: BotStore { BotStore(sessionStoreRoot: canonicalRuntimeStoreRoot(sessionStoreRoot: sessions)) }
  var environment: [String: String] {
    [
      "HOME": root.path,
      "RIELA_WORKFLOW_HOME": root.appendingPathComponent("user").path,
      "XDG_STATE_HOME": root.appendingPathComponent("state").path
    ]
  }

  func run(_ arguments: [String]) async -> CLICommandResult {
    await RielaCLIApplication().run(
      ["bot"] + arguments + ["--working-dir", root.path, "--session-store", sessions], environment: environment
    )
  }

  func assertSuccess(_ arguments: [String], file: StaticString = #filePath, line: UInt = #line) async throws {
    let result = await run(arguments)
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout, file: file, line: line)
  }

  func json<T: Decodable>(_ arguments: [String], file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let result = await run(arguments + ["--output", "json"])
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout, file: file, line: line)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: Data(result.stdout.utf8))
  }
}
