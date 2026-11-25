import Foundation
import RielaCore
import RielaGraphQL
import RielaWorkflowRegistry
import XCTest
@testable import RielaCLI

final class BotExampleWalkthroughTests: XCTestCase {
  func testRoutineOverviewAndMemoryUpkeepWalkthrough() async throws {
    let fixture = try WalkthroughFixture()
    addTeardownBlock { try FileManager.default.removeItem(at: fixture.root) }

    try await fixture.run(["bot", "create", "--name", "Triage Bot", "--backend", "codex-agent"])
    try await fixture.run([
      "routine", "create", "--name", "nightly-triage", "--task", WalkthroughFixture.task,
      "--schedule", "0 0 0 * * *", "--timezone", "UTC", "--workflow", WalkthroughFixture.workflowName,
      "--bot", WalkthroughFixture.botId, "--routine-store", fixture.path("routines"), "--event-root", fixture.path("events")
    ])
    try await assertOverview(fixture)
    try await assertMemoryUpkeep(fixture)
  }

  private func assertOverview(_ fixture: WalkthroughFixture) async throws {
    let run: WorkflowRunResult = try await fixture.json([
      "workflow", "run", WalkthroughFixture.workflowName, "--workflow-definition-dir", fixture.examples.path,
      "--mock-scenario", fixture.bundlePath("mock-scenario.json"), "--bot", WalkthroughFixture.botId,
      "--variables", #"{"workflowInput":{"task":"\#(WalkthroughFixture.task)"}}"#,
      "--artifact-root", fixture.path("artifacts")
    ])
    XCTAssertEqual(run.status, .completed)
    XCTAssertEqual(run.rootOutput?["conditionMet"], .bool(false))
    XCTAssertEqual(run.rootOutput?["summary"], .string("Flagged two reports for the next review."))

    let store = BotStore(sessionStoreRoot: canonicalRuntimeStoreRoot(sessionStoreRoot: fixture.path("sessions")))
    let link = try XCTUnwrap(try store.link(forSession: run.session.sessionId))
    XCTAssertEqual(link.botId, WalkthroughFixture.botId)
    XCTAssertEqual(link.source, "run")

    let list: BotListPayload = try await fixture.json(["bot", "list"])
    XCTAssertEqual(list.bots.map(\.bot.botId), [WalkthroughFixture.botId])
    XCTAssertNotNil(list.bots.first?.lastActivityAt)
    XCTAssertEqual(list.bots.first?.lastResult, "completed at step triage")

    let detail: BotDetailPayload = try await fixture.json(["bot", "show", WalkthroughFixture.botId])
    XCTAssertEqual(detail.board.closed.map(\.itemId), [run.session.sessionId])
    XCTAssertEqual(detail.board.closed.first?.activitySource, "session")
    let routine = try XCTUnwrap(detail.routines.first)
    XCTAssertEqual(detail.routines.map(\.name), ["nightly-triage"])
    XCTAssertNotNil(routine.nextRunAt)
    XCTAssertEqual(detail.board.planned.map(\.itemId), [routine.routineId])
  }

  private func assertMemoryUpkeep(_ fixture: WalkthroughFixture) async throws {
    let botId = WalkthroughFixture.botId
    try await fixture.run(["bot", "memory", "edit", botId, "--file", fixture.bundlePath("memory-seed.md")])
    let seed = try await fixture.memory()
    XCTAssertEqual(seed.map(\.recordId), [1, 2, 3])
    XCTAssertEqual(seed.map(\.kind), [.instruction, .note, .note])

    let job: BotJobPayload = try await fixture.json([
      "bot", "job", "run", botId, "upkeep", "--force", "--mock-scenario", fixture.bundlePath("upkeep-mock-scenario.json")
    ])
    XCTAssertEqual(job.status, .succeeded, job.detail ?? "")
    let history: [BotMemoryChangeSet] = try await fixture.json(["bot", "memory", "history", botId])
    XCTAssertEqual(history.map(\.actor), [.upkeep, .cli])
    XCTAssertEqual(history.first?.changeId, job.changeSet?.changeId)
    let consolidated = try await fixture.memory()
    XCTAssertEqual(consolidated.map(\.kind), [.instruction, .note])
    XCTAssertEqual(consolidated.first, seed.first)
    XCTAssertEqual(consolidated.last?.text, "Two reports from the same queue need review.")

    try await fixture.run(["bot", "memory", "undo", botId])
    let restored = try await fixture.memory()
    XCTAssertEqual(restored, seed)
  }
}

private struct WalkthroughFixture {
  static let botId = "triage-bot"
  static let workflowName = "bot-routine-memory-upkeep"
  static let task = "Summarize reports for the next review."

  let root: URL
  let examples: URL

  init() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    examples = repository.appendingPathComponent("examples")
    root = repository.appendingPathComponent("tmp/bots-overview/bots-17-example-docs/test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func path(_ name: String) -> String {
    root.appendingPathComponent(name).path
  }

  func bundlePath(_ name: String) -> String {
    examples.appendingPathComponent(Self.workflowName).appendingPathComponent(name).path
  }

  @discardableResult
  func run(_ arguments: [String]) async throws -> String {
    let environment = [
      "HOME": path("home"), "XDG_STATE_HOME": path("state"), "XDG_CONFIG_HOME": path("config"),
      "RIELA_WORKFLOW_HOME": path("workflows"), "RIELA_SESSION_STORE": path("sessions"),
      "RIELA_ROUTINE_STORE": path("routines"), "RIELA_MEMORY_ROOT": path("memory")
    ]
    let result = await CLIRuntimeEnvironment.$captured.withValue(environment) {
      await RielaCLIApplication().run(arguments + ["--working-dir", root.path, "--output", "json"])
    }
    return try XCTUnwrap(
      result.exitCode == .success ? result.stdout : nil,
      "\(arguments.joined(separator: " ")): \(result.stderr) \(result.stdout)"
    )
  }

  func json<T: Decodable>(_ arguments: [String]) async throws -> T {
    let stdout = try await run(arguments)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: Data(stdout.utf8))
  }

  func memory() async throws -> [BotMemoryMarkdownItem] {
    let shown: MemoryOutput = try await json(["bot", "memory", "show", Self.botId])
    return try BotMemoryMarkdown.parse(shown.markdown)
  }

  private struct MemoryOutput: Decodable {
    let markdown: String
  }
}
