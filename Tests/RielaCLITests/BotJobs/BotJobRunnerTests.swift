import Foundation
import RielaCore
import RielaGraphQL
import XCTest
@testable import RielaCLI

final class BotJobRunnerTests: XCTestCase {
  func testScheduledUpkeepConsolidatesNotesAndRecordsLinkedAudit() async throws {
    let fixture = try BotJobFixture()
    defer { fixture.remove() }
    let original = "## Instructions\n## Notes\n- First note\n- Second note\n"
    try fixture.writeMemory(original)
    let recordId = try XCTUnwrap(fixture.entries().first?.recordId)
    try fixture.recordActivity()
    let proposal = "## Instructions\n## Notes\n- Combined note <!-- id:\(recordId) -->\n"
    let first = try await fixture.run(.upkeep, output: ["memoryMarkdown": .string(proposal)])
    XCTAssertEqual(first.status, .succeeded, first.detail ?? "")
    XCTAssertEqual(first.periodKey, "2026-11-24")
    XCTAssertEqual(try fixture.entries().map(\.text), ["Combined note"])
    let session = try XCTUnwrap(first.sessionId)
    let change = try XCTUnwrap(fixture.service.memoryWriter().history(botId: fixture.botId).first)
    XCTAssertEqual(change.actor, .upkeep)
    XCTAssertEqual(change.evidenceRefs, ["session:\(session)"])
    XCTAssertEqual(try fixture.store.link(forSession: session)?.source, "job")
    let row = try XCTUnwrap(fixture.store.jobRuns(botId: fixture.botId, job: .upkeep, limit: 1).first)
    XCTAssertEqual(row.sessionId, session)
    XCTAssertEqual(row.status, .succeeded)
    let second = try await fixture.run(.upkeep, output: [:])
    XCTAssertEqual(second.status, .notDue)
    XCTAssertEqual(second.detail, "done")
    var nextDay = fixture.service
    let tomorrow = fixture.instant.addingTimeInterval(86_400)
    nextDay.now = { tomorrow }
    let subsequent = try await BotJobRunner(service: nextDay, mockScenarioPath: fixture.scenario.path)
      .run(botId: fixture.botId, job: .upkeep, force: false)
    XCTAssertEqual(subsequent.status, .skipped)
    XCTAssertEqual(subsequent.detail, "no_activity")
    XCTAssertNil(subsequent.sessionId)
  }

  func testUpkeepCannotChangeInstructions() async throws {
    let fixture = try BotJobFixture()
    defer { fixture.remove() }
    try fixture.writeMemory("## Instructions\n- Keep this instruction\n## Notes\n")
    let id = try XCTUnwrap(fixture.entries().first?.recordId)
    let proposal = "## Instructions\n- Replace this instruction <!-- id:\(id) -->\n## Notes\n"
    let result = try await fixture.run(.upkeep, output: ["memoryMarkdown": .string(proposal)], force: true)
    XCTAssertEqual(result.status, .succeeded, result.detail ?? "")
    XCTAssertEqual(result.changeSet?.ignoredInstructionChanges, 1)
    XCTAssertEqual(try fixture.entries().map(\.text), ["Keep this instruction"])
  }

  func testInvalidMarkdownAndExcessiveRemovalLeaveMemoryUnchanged() async throws {
    let fixture = try BotJobFixture()
    defer { fixture.remove() }
    try fixture.writeMemory("## Notes\n" + (1...6).map { "- Note \($0)\n" }.joined())
    let initial = try fixture.entries()
    let keep = try XCTUnwrap(initial.first?.recordId)
    let invalid = try await fixture.run(.upkeep, output: ["memoryMarkdown": .string("invalid")], force: true)
    XCTAssertEqual(invalid.status, .failed)
    XCTAssertEqual(invalid.detail, "memory_markdown_invalid")
    let purge = "## Notes\n- Note 1 <!-- id:\(keep) -->\n"
    let rejected = try await fixture.run(.upkeep, output: ["memoryMarkdown": .string(purge)], force: true)
    XCTAssertEqual(rejected.status, .failed)
    XCTAssertEqual(rejected.detail, "upkeep_removes_too_much")
    XCTAssertEqual(try fixture.entries(), initial)
  }

  func testScheduledSkipAndManualRunsUseSeparatePeriodKeys() async throws {
    let fixture = try BotJobFixture()
    defer { fixture.remove() }
    let skipped = try await fixture.run(.upkeep, output: [:])
    XCTAssertEqual(skipped.status, .skipped)
    XCTAssertEqual(skipped.detail, "no_activity")
    XCTAssertNil(skipped.sessionId)
    let output: JSONObject = ["memoryMarkdown": .string("## Instructions\n## Notes\n")]
    let first = try await fixture.run(.upkeep, output: output, force: true)
    let second = try await fixture.run(.upkeep, output: output, force: true)
    XCTAssertEqual(first.status, .succeeded, first.detail ?? "")
    XCTAssertEqual(second.status, .succeeded, second.detail ?? "")
    XCTAssertNotEqual(first.sessionId, second.sessionId)
    XCTAssertNotEqual(first.periodKey, second.periodKey)
    let ledger = try fixture.store.jobRuns(botId: fixture.botId, job: .upkeep, limit: 10)
    XCTAssertEqual(ledger.filter { $0.status == .skipped }.map(\.periodKey), ["2026-11-24"])
    XCTAssertFalse(ledger.contains { $0.periodKey == "2026-11-25" })
  }

  func testCLIForceRunsIdleJobAndSkipsBusyBot() async throws {
    let fixture = try BotJobFixture()
    defer { fixture.remove() }
    try fixture.writeScenario(.lookAround, output: ["suggestions": .array([])])
    let args = [
      "bot", "job", "run", fixture.botId, "look-around", "--force", "--output", "json",
      "--mock-scenario", fixture.scenario.path, "--working-dir", fixture.root.path,
      "--session-store", fixture.service.sessionStoreRoot
    ]
    let app = RielaCLIApplication()
    let first = await app.run(args, environment: fixture.service.environment)
    XCTAssertEqual(first.exitCode, .success, first.stderr + first.stdout)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let successful = try decoder.decode(BotJobPayload.self, from: Data(first.stdout.utf8))
    XCTAssertEqual(successful.status, .succeeded)
    XCTAssertNotNil(successful.sessionId)

    try fixture.recordActivity(status: .running)
    let second = await app.run(args, environment: fixture.service.environment)
    XCTAssertEqual(second.exitCode, .success, second.stderr + second.stdout)
    let skipped = try decoder.decode(BotJobPayload.self, from: Data(second.stdout.utf8))
    XCTAssertEqual(skipped.status, .notDue)
    XCTAssertEqual(skipped.detail, "busy")
    XCTAssertNil(skipped.sessionId)
    XCTAssertEqual(try fixture.store.jobRuns(botId: fixture.botId, job: .lookAround, limit: 10).count, 1)
  }

  func testPausedAndMissingBackendNeverClaimManualRun() async throws {
    let fixture = try BotJobFixture()
    defer { fixture.remove() }
    try fixture.store.update(botId: fixture.botId) { $0.paused = true }
    do {
      _ = try await fixture.run(.upkeep, output: [:], force: true)
      XCTFail("Expected paused rejection")
    } catch let error as BotStoreError { XCTAssertEqual(error.code, "bot_paused") }
    try fixture.store.update(botId: fixture.botId) { bot in
      bot.paused = false
      bot.defaultBackend = nil
    }
    do {
      _ = try await fixture.run(.upkeep, output: [:], force: true)
      XCTFail("Expected missing backend rejection")
    } catch let error as BotStoreError { XCTAssertEqual(error.code, "bot_job_backend_missing") }
    XCTAssertTrue(try fixture.store.jobRuns(botId: fixture.botId, job: .upkeep, limit: 10).isEmpty)
  }

  func testLookAroundStoresOpenSuggestionsAndTheyRequireAcceptanceToRun() async throws {
    let fixture = try BotJobFixture()
    defer { fixture.remove() }
    try fixture.writeMemory("## Notes\n- Leave alone\n")
    let memory = try fixture.entries()
    let workflow = "worker-only-single-step"
    let bundle = try fixture.installExample(workflow)
    let suggestions: [JSONValue] = [
      .object(["title": .string("Review queue"), "action": .object(["workflowName": .string(workflow)])]),
      .object(["title": .string("Review notes")])
    ]
    let result = try await fixture.run(.lookAround, output: ["suggestions": .array(suggestions)], force: true)
    XCTAssertEqual(result.status, .succeeded, result.detail ?? "")
    let open = try fixture.service.suggestions(botId: fixture.botId, status: .open)
    XCTAssertEqual(open.count, 2)
    XCTAssertEqual(Set(open.compactMap(\.sourceSessionId)), Set([try XCTUnwrap(result.sessionId)]))
    XCTAssertEqual(try fixture.entries(), memory)
    XCTAssertEqual(try fixture.store.links(botId: fixture.botId).count, 1)
    let suggestion = try XCTUnwrap(open.first { $0.action != nil })
    let response = await RielaCLIApplication().run([
      "bot", "suggestion", "accept", suggestion.suggestionId, "--run", "--output", "json",
      "--mock-scenario", bundle.appendingPathComponent("mock-scenario.json").path,
      "--working-dir", fixture.root.path, "--session-store", fixture.service.sessionStoreRoot
    ], environment: fixture.service.environment)
    XCTAssertEqual(response.exitCode, .success, response.stderr + response.stdout)
    let started = try JSONDecoder().decode(BotSuggestion.self, from: Data(response.stdout.utf8))
    XCTAssertEqual(started.status, .started)
    let startedId = try XCTUnwrap(started.startedSessionId)
    XCTAssertEqual(try fixture.store.link(forSession: startedId)?.botId, fixture.botId)
    do {
      _ = try await fixture.service.decideSuggestion(.init(suggestionId: suggestion.suggestionId, decision: .accept), actor: "cli")
      XCTFail("Expected repeated acceptance to fail")
    } catch let error as BotStoreError { XCTAssertEqual(error.code, "suggestion_already_decided") }
  }

  func testLookAroundRejectsMissingSuggestions() async throws {
    let fixture = try BotJobFixture()
    defer { fixture.remove() }
    let result = try await fixture.run(.lookAround, output: [:], force: true)
    XCTAssertEqual(result.status, .failed)
    XCTAssertEqual(result.detail, "look_around_output_invalid")
    XCTAssertTrue(try fixture.service.suggestions(botId: fixture.botId, status: nil).isEmpty)
  }
}

private struct BotJobFixture {
  let root: URL
  let service: BotsService
  let botId = "jobs"
  let instant = Date(timeIntervalSince1970: 1_795_608_000)
  var store: BotStore { service.store }

  init() throws {
    root = Self.repository.appendingPathComponent("tmp/bots-overview/bots-16-jobs-surfaces/test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = instant
    service = BotsService(
      workingDirectory: root.path, sessionStoreRoot: root.appendingPathComponent("sessions").path,
      environment: ["HOME": root.path, "XDG_STATE_HOME": root.path, "RIELA_WORKFLOW_HOME": root.path], now: { now }
    )
    let at = RoutineStore.timestamp(instant)
    var bot = BotRecord(botId: botId, name: "Jobs", createdAt: at, updatedAt: at)
    bot.defaultBackend = NodeExecutionBackend.codexAgent.rawValue
    try store.create(bot)
  }

  private static var repository: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  func writeMemory(_ markdown: String) throws {
    try service.memoryWriter().applyMarkdown(botId: botId, markdown: markdown, source: .user, actor: "cli", reason: "fixture")
  }

  func entries() throws -> [BotMemoryEntry] { try service.memoryWriter().entries(botId: botId) }

  func recordActivity(status: WorkflowSessionStatus = .completed) throws {
    let at = instant.addingTimeInterval(-86_400)
    let session = WorkflowSession(
      workflowId: "example", sessionId: "prior", status: status, entryStepId: "main",
      createdAt: at, updatedAt: at
    )
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.sessionStoreRoot).save(.init(session: session))
    try store.linkSession(sessionId: session.sessionId, botId: botId, source: "run", at: at)
  }

  var scenario: URL { root.appendingPathComponent("scenario.json") }

  func writeScenario(_ job: BotJobKind, output: JSONObject) throws {
    let document: JSONObject = [job.rawValue: .object(["payload": .object(output)])]
    try JSONEncoder().encode(document).write(to: scenario)
  }

  func run(_ job: BotJobKind, output: JSONObject, force: Bool = false) async throws -> BotJobPayload {
    try writeScenario(job, output: output)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    return try await BotJobRunner(service: service, calendar: calendar, mockScenarioPath: scenario.path)
      .run(botId: botId, job: job, force: force)
  }

  func installExample(_ name: String) throws -> URL {
    let workflows = root.appendingPathComponent(".riela/workflows")
    try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
    let destination = workflows.appendingPathComponent(name)
    try FileManager.default.copyItem(at: Self.repository.appendingPathComponent("examples/\(name)"), to: destination)
    return destination
  }
}
