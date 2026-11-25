import Foundation
import RielaCore
import RielaSQLite
import XCTest
@testable import RielaCLI

final class BotActivityRuntimeTests: XCTestCase {
  func testTwoStepMockRunRecordsOrderedActivityWithOrWithoutBot() async throws {
    let fixture = try makeFixture()
    try fixture.writeWorkflow()
    try fixture.createBot()
    for arguments in [[], ["--bot", fixture.botID]] {
      let result = await fixture.run(["workflow", "run", fixture.workflowID] + arguments)
      XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
      let session = try fixture.decode(WorkflowRunResult.self, from: result).session
      XCTAssertEqual(session.executions.map(\.stepId), ["start", "finish"])
      let page = try fixture.bots.activityPage(sessionId: session.sessionId)
      XCTAssertEqual(page.activitySource, "session")
      XCTAssertEqual(try XCTUnwrap(page.state).source, "session")
      XCTAssertEqual(page.events.map(\.seq), Array(1...6))
      XCTAssertEqual(page.events.map(\.kind), [
        .stepStarted, .stepFinished, .settled, .stepStarted, .stepFinished, .settled
      ])
      XCTAssertEqual(page.events.map(\.executionId), session.executions.flatMap { execution in
        Array(repeating: Optional(execution.executionId), count: 3)
      })
      XCTAssertEqual(try fixture.bots.link(forSession: session.sessionId)?.botId, arguments.isEmpty ? nil : fixture.botID)
    }
  }

  func testResumeOfSuspendedLinkedSessionAppendsActivityToTheSameSession() async throws {
    let fixture = try makeFixture()
    try fixture.createBot()
    try fixture.writeWorkflow(suspends: true)
    let initial = await fixture.run(["workflow", "run", fixture.workflowID, "--bot", fixture.botID])
    XCTAssertEqual(initial.exitCode, .suspended, initial.stderr + initial.stdout)
    let session = try XCTUnwrap(try fixture.sessions.list().first?.session)
    XCTAssertEqual(session.status, .suspended)
    let link = try XCTUnwrap(try fixture.bots.link(forSession: session.sessionId))
    let prior = try fixture.bots.activityPage(sessionId: session.sessionId)
    XCTAssertEqual(prior.events.filter { $0.kind == .stepStarted }.count, 1)
    let waitMs = 42_000
    try fixture.bots.update(botId: fixture.botID) { bot in
      bot.paused = true
      bot.permissionWaitMs = waitMs
    }
    XCTAssertEqual(
      BotActivityRuntime.botContext(
        forExistingSession: session.sessionId, sessionStoreRoot: fixture.sessionRoot.path,
        workingDirectory: fixture.sessionRoot.path, environment: [:]
      ),
      BotRunContext(botId: fixture.botID, permissionWaitMs: waitMs)
    )

    let answer = #"{"handover":{"answer":{"option":"a"}}}"#
    let result = await fixture.run(["session", "resume", session.sessionId, "--variables", answer])
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let resumed = try fixture.decode(SessionResumeCommandResult.self, from: result)
    XCTAssertEqual(resumed.sessionId, session.sessionId)
    XCTAssertEqual(try fixture.bots.link(forSession: resumed.sessionId), link)
    let saved = try fixture.sessions.load(sessionId: resumed.sessionId).session
    let resumedEvents = try fixture.bots.activityPage(sessionId: resumed.sessionId, afterSequence: prior.lastSequence).events
    XCTAssertEqual(resumedEvents.first?.kind, .stepStarted)
    XCTAssertEqual(resumedEvents.last?.kind, .settled)
    XCTAssertEqual(resumedEvents.last?.executionId, try XCTUnwrap(saved.executions.last?.executionId))
  }

  func testRerunCreatesActivityAndLinksOnlyWhenSourceIsLinked() async throws {
    let fixture = try makeFixture()
    try fixture.writeWorkflow()
    try fixture.createBot()
    for arguments in [[], ["--bot", fixture.botID]] {
      let initial = await fixture.run(["workflow", "run", fixture.workflowID] + arguments)
      XCTAssertEqual(initial.exitCode, .success, initial.stderr + initial.stdout)
      let source = try fixture.decode(WorkflowRunResult.self, from: initial).session
      let originalPage = try fixture.bots.activityPage(sessionId: source.sessionId)
      let result = await fixture.run(["session", "rerun", source.sessionId, "finish"])
      XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
      let rerun = try fixture.decode(SessionRerunCommandResult.self, from: result)
      XCTAssertNotEqual(rerun.sessionId, source.sessionId)
      let link = try fixture.bots.link(forSession: rerun.sessionId)
      XCTAssertEqual(link?.botId, arguments.isEmpty ? nil : fixture.botID)
      XCTAssertEqual(link?.source, arguments.isEmpty ? nil : "run")
      XCTAssertEqual(link?.sourceRef, arguments.isEmpty ? nil : source.sessionId)
      let page = try fixture.bots.activityPage(sessionId: rerun.sessionId)
      XCTAssertEqual(page.events.map(\.kind), [.stepStarted, .stepFinished, .settled])
      XCTAssertEqual(try fixture.bots.activityPage(sessionId: source.sessionId), originalPage)
    }
  }

  func testOrphanReconcileSettlesActivityAndPermissionOnlyOnce() async throws {
    let fixture = try makeFixture()
    let sessionID = "orphan"
    try fixture.saveSession(sessionID, status: .running, at: fixture.timestamp)
    try await fixture.seedOpenActivity(sessionID, at: fixture.timestamp)
    XCTAssertEqual(try fixture.bots.pendingActivityRequests(sessionIds: [sessionID]).map(\.requestId), ["request-orphan"])

    let arguments = ["session", "reconcile", "--session-store", fixture.sessionRoot.path, "--apply"]
    let result = await RielaCLIApplication().run(arguments, environment: fixture.environment)
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let page = try fixture.bots.activityPage(sessionId: sessionID)
    XCTAssertEqual(page.state?.toolCalls.first?.status, "interrupted")
    XCTAssertNil(page.state?.currentExecutionId)
    let settlements = page.events.filter { $0.kind == .settled }
    XCTAssertEqual(settlements.map { $0.payload["reason"] }, [.string(ActivitySettleReason.processExit.rawValue)])
    let db = try fixture.openDatabase()
    let permission = try XCTUnwrap(try db.query(
      "SELECT status, resolved_by FROM activity_requests WHERE session_id = ?", bindings: [.text(sessionID)]
    ).first)
    XCTAssertEqual(permission["status"], "cancelled")
    XCTAssertEqual(permission["resolved_by"], "settlement")
    let repeated = await RielaCLIApplication().run(arguments, environment: fixture.environment)
    XCTAssertEqual(repeated.exitCode, .success, repeated.stderr + repeated.stdout)
    XCTAssertEqual(try fixture.bots.activityPage(sessionId: sessionID), page)
  }

  func testRetentionDeletesRowsForPrunedSessionAndPreservesOtherSession() async throws {
    let fixture = try makeFixture()
    try fixture.createBot()
    let oldDate = fixture.timestamp.addingTimeInterval(-90_000)
    for (id, date) in [("old", oldDate), ("new", fixture.timestamp)] {
      try fixture.saveSession(id, status: .completed, at: date)
      try await fixture.seedOpenActivity(id, at: date)
      try fixture.bots.linkSession(sessionId: id, botId: fixture.botID, source: "run", at: date)
    }
    let report = try fixture.prune()
    XCTAssertEqual(report.removedSessionCount, 1)
    let db = try fixture.openDatabase()
    for table in ActivityRuntimeFixture.activityTables {
      let ids = try db.query("SELECT DISTINCT session_id FROM \(table)").compactMap { $0["session_id"] }
      XCTAssertEqual(ids, ["new"], table)
    }
  }

  func testRetentionWorksWithoutGenerationThirteenTables() throws {
    let fixture = try makeFixture()
    try fixture.saveSession("legacy", status: .completed, at: fixture.timestamp.addingTimeInterval(-90_000))
    let db = try fixture.openDatabase()
    for table in ActivityRuntimeFixture.activityTables + ["bots", "bot_work_task_links", "bot_list_state"] {
      try db.execute("DROP TABLE IF EXISTS \(table)")
    }
    try db.execute("PRAGMA user_version = 12")
    let report = try fixture.prune()
    XCTAssertEqual(report.removedSessionCount, 1)
  }

  private func makeFixture() throws -> ActivityRuntimeFixture {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/bots-overview/bots-11-activity-runtime/fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return ActivityRuntimeFixture(root: root)
  }
}

private struct ActivityRuntimeFixture {
  static let activityTables = ["activity_events", "activity_state", "activity_requests", "bot_session_links"]
  let root: URL
  let workflowID = "activity-runtime"
  let botID = "bot-runtime"
  let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

  var sessionRoot: URL { root.appendingPathComponent("sessions") }
  var artifactRoot: URL { root.appendingPathComponent("artifacts") }
  var workflowRoot: URL { root.appendingPathComponent("workflows") }
  var bundle: URL { workflowRoot.appendingPathComponent(workflowID) }
  var runtimeRoot: String { canonicalRuntimeStoreRoot(sessionStoreRoot: sessionRoot.path) }
  var bots: BotStore { BotStore(sessionStoreRoot: runtimeRoot) }
  var sessions: CLIWorkflowSessionStore { CLIWorkflowSessionStore(rootDirectory: sessionRoot.path) }
  var environment: [String: String] {
    [
      "HOME": root.path,
      "RIELA_WORKFLOW_HOME": root.appendingPathComponent("user-riela").path,
      "XDG_STATE_HOME": root.appendingPathComponent("user-state").path,
      "RIELA_API_KEY": "",
      "RIELA_MANAGER_SESSION_ID": ""
    ]
  }

  func run(_ arguments: [String]) async -> CLICommandResult {
    await RielaCLIApplication().run(arguments + [
      "--workflow-definition-dir", workflowRoot.path,
      "--working-dir", root.path,
      "--session-store", sessionRoot.path,
      "--artifact-root", artifactRoot.path,
      "--mock-scenario", bundle.appendingPathComponent("scenario.json").path,
      "--output", "json"
    ], environment: environment)
  }

  func decode<T: Decodable>(_ type: T.Type, from result: CLICommandResult) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(result.stdout.utf8))
  }

  func writeWorkflow(suspends: Bool = false) throws {
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    try """
    {"workflowId":"\(workflowID)","defaults":{"maxLoopIterations":3,"nodeTimeoutMs":30000},"entryStepId":"start",
     "nodes":[{"id":"worker","nodeFile":"worker.json"}],
     "steps":[{"id":"start","nodeId":"worker","transitions":[{"toStepId":"finish"}]},{"id":"finish","nodeId":"worker"}]}
    """.write(to: bundle.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {"id":"worker","executionBackend":"codex-agent","agentSandbox":"read-only","model":"fixture","variables":{},
     "output":{"jsonSchema":{"type":"object","required":["answer"]}}}
    """.write(to: bundle.appendingPathComponent("worker.json"), atomically: true, encoding: .utf8)
    let handover = """
    {"payload":{"answer":"before","handover":{"reason":"userInputRequired","resumeStepId":"start",
    "question":{"id":"q1","text":"Choose an option","options":[{"id":"a","label":"Option A"}]}}}},
    """
    try """
    {"start":[\(suspends ? handover : ""){"payload":{"answer":"start"}}],"finish":{"payload":{"answer":"finish"}}}
    """.write(to: bundle.appendingPathComponent("scenario.json"), atomically: true, encoding: .utf8)
  }

  func createBot() throws {
    let at = RoutineStore.timestamp(timestamp)
    try bots.create(BotRecord(botId: botID, name: "Activity fixture", createdAt: at, updatedAt: at))
  }

  func saveSession(_ id: String, status: WorkflowSessionStatus, at: Date) throws {
    let execution = WorkflowStepExecution(
      executionId: "execution-\(id)", stepId: "start", nodeId: "worker", attempt: 1,
      status: status == .running ? .running : .completed, createdAt: at, updatedAt: at
    )
    let session = WorkflowSession(
      workflowId: workflowID, sessionId: id, status: status,
      entryStepId: "start", currentStepId: "start", createdAt: at, updatedAt: at,
      executions: [execution], rootSessionId: id
    )
    try sessions.save(PersistedCLIWorkflowSession(
      workflowName: workflowID, session: session, resolution: WorkflowResolutionOptions(workflowName: workflowID)
    ), runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: session))
  }

  func seedOpenActivity(_ id: String, at: Date) async throws {
    let executionID = "execution-\(id)"
    let recorder = SQLiteWorkflowActivityRecorder(sessionStoreRoot: runtimeRoot)
    await recorder.stepStarted(sessionId: id, executionId: executionID, stepId: "start", nodeId: "worker",
      backend: nil, requestedModel: nil, at: at)
    await recorder.record(sessionId: id, executionId: executionID,
      update: .toolCall(.init(toolCallId: "tool-\(id)", status: "in_progress")), at: at)
    let db = try openDatabase()
    try db.execute("""
      INSERT INTO activity_requests (
        request_id, session_id, execution_id, tool_call_id, options_json, status, created_at, expires_at
      ) VALUES (?, ?, ?, ?, jsonb('[]'), 'pending', ?, ?)
      """, bindings: [.text("request-\(id)"), .text(id), .text(executionID), .text("tool-\(id)"),
        .text(RoutineStore.timestamp(at)), .text(RoutineStore.timestamp(at.addingTimeInterval(60)))])
  }

  func openDatabase() throws -> SQLiteDatabase {
    try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: sessionRoot.path))
  }

  func prune() throws -> TerminalRetentionReport {
    let paths = try TerminalRetentionPaths(sessionRoot: sessionRoot.path,
      artifactRoot: artifactRoot.path, memoryRoot: root.appendingPathComponent("memory").path)
    return try TerminalRetentionExecutor(clock: { timestamp }).run(
      paths: paths, workflows: [workflowID], retentionHours: 24, maxPayloadBytes: 268_435_456, dryRun: false
    )
  }
}
