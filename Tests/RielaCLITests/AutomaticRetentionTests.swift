import Foundation
import RielaCore
import RielaSQLite
import XCTest
@testable import RielaCLI

final class AutomaticRetentionTests: XCTestCase {
  private struct TestRoots {
    var root: URL
    var home: URL
    var project: URL
    var store: URL
  }

  func testAppliesOnlySupportedSuccessfulCommands() {
    XCTAssertTrue(AutomaticRetentionHook.applies(arguments: ["workflow", "run", "demo"], exitCode: .success, cancelled: false))
    XCTAssertTrue(AutomaticRetentionHook.applies(arguments: ["session", "continue", "id"], exitCode: .failure, cancelled: false))
    XCTAssertFalse(AutomaticRetentionHook.applies(arguments: ["gc"], exitCode: .success, cancelled: false))
    XCTAssertFalse(AutomaticRetentionHook.applies(arguments: ["workflow", "run", "demo", "--help"], exitCode: .success, cancelled: false))
    XCTAssertFalse(AutomaticRetentionHook.applies(arguments: ["session", "resume", "id"], exitCode: .usage, cancelled: false))
    XCTAssertFalse(AutomaticRetentionHook.applies(arguments: ["session", "rerun", "id"], exitCode: .success, cancelled: true))
  }

  func testRequestParsesWorkingDirectoryAndSessionStore() {
    let retentionRequest = AutomaticRetentionHook.request(
      arguments: ["workflow", "run", "demo", "--working-dir=/a/b", "--session-store", "relative-store"],
      environment: ["HOME": "/home/test"],
      currentDirectory: "/c"
    )
    XCTAssertEqual(retentionRequest.trigger, .automatic)
    XCTAssertEqual(retentionRequest.scope, .all)
    XCTAssertEqual(retentionRequest.homeDirectory.path, "/home/test")
    XCTAssertEqual(retentionRequest.projectDirectory?.path, "/a/b")
    XCTAssertEqual(retentionRequest.explicitSessionStore, "relative-store")
    XCTAssertFalse(retentionRequest.dryRun)
    XCTAssertTrue(retentionRequest.overrides.isEmpty)
  }

  func testWorkflowRunHookPrunesOldSessionWithoutChangingRunOutput() async throws {
    let roots = try makeRoots()
    defer { try? FileManager.default.removeItem(at: roots.root) }
    try writeConfig(#"{"retention":{"results":{"maxAgeDays":1}}}"#, home: roots.home)
    let workflowRoot = URL(fileURLWithPath: repositoryRoot()).appendingPathComponent("examples", isDirectory: true)
    let mockScenario = workflowRoot.appendingPathComponent("worker-only-single-step/mock-scenario.json")
    let firstResult = await runWorkflow(roots: roots, workflowRoot: workflowRoot, mockScenario: mockScenario)
    let secondResult = await runWorkflow(roots: roots, workflowRoot: workflowRoot, mockScenario: mockScenario)
    XCTAssertEqual(firstResult.exitCode, .success, firstResult.stderr)
    XCTAssertEqual(secondResult.exitCode, .success, secondResult.stderr)
    let first = try decodeJSON(WorkflowRunResult.self, from: firstResult.stdout)
    let second = try decodeJSON(WorkflowRunResult.self, from: secondResult.stdout)

    let fixedNow = Date()
    let databasePath = CLIWorkflowSessionStore.defaultDatabasePath(
      rootDirectory: roots.store.path
    )
    let database = try SQLiteDatabase.open(path: databasePath)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let oldTimestamp = formatter.string(from: fixedNow.addingTimeInterval(-3 * 86_400))
    let recentTimestamp = formatter.string(from: fixedNow.addingTimeInterval(-3_600))
    for (sessionId, timestamp) in [(first.session.sessionId, oldTimestamp), (second.session.sessionId, recentTimestamp)] {
      try database.execute(
        "UPDATE workflow_runtime_snapshots SET updated_at = ? WHERE workflow_execution_id = ?",
        bindings: [.text(timestamp), .text(sessionId)]
      )
      try database.execute(
        "UPDATE cli_workflow_sessions SET updated_at = ? WHERE session_id = ?",
        bindings: [.text(timestamp), .text(sessionId)]
      )
    }

    let originalExitCode = firstResult.exitCode
    let originalStdout = firstResult.stdout
    let warnings = AutomaticRetentionHook.runIfApplicable(
      arguments: ["workflow", "run", "worker-only-single-step", "--workflow-definition-dir", workflowRoot.path,
                  "--mock-scenario", mockScenario.path, "--session-store", roots.store.path,
                  "--working-dir", roots.project.path, "--output", "json"],
      exitCode: originalExitCode,
      cancelled: false,
      environment: ["HOME": roots.home.path],
      service: RielaRetentionService(clock: { fixedNow })
    )

    XCTAssertTrue(warnings.isEmpty)
    XCTAssertEqual(firstResult.exitCode, originalExitCode)
    XCTAssertEqual(firstResult.stdout, originalStdout)
    let remainingIds = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: roots.store.path)
    ).loadAll().map(\.session.sessionId)
    XCTAssertFalse(remainingIds.contains(first.session.sessionId))
    XCTAssertTrue(remainingIds.contains(second.session.sessionId))
  }

  func testHookKeepsRunningSessionUnderByteCapWhilePruningTerminalSession() async throws {
    let roots = try makeRoots()
    defer { try? FileManager.default.removeItem(at: roots.root) }
    try writeConfig(#"{"retention":{"results":{"maxTotalBytes":1}}}"#, home: roots.home)
    let workflowRoot = URL(fileURLWithPath: repositoryRoot()).appendingPathComponent("examples", isDirectory: true)
    let mockScenario = workflowRoot.appendingPathComponent("worker-only-single-step/mock-scenario.json")
    let firstResult = await runWorkflow(roots: roots, workflowRoot: workflowRoot, mockScenario: mockScenario)
    let secondResult = await runWorkflow(roots: roots, workflowRoot: workflowRoot, mockScenario: mockScenario)
    XCTAssertEqual(firstResult.exitCode, .success, firstResult.stderr)
    XCTAssertEqual(secondResult.exitCode, .success, secondResult.stderr)
    let completed = try decodeJSON(WorkflowRunResult.self, from: firstResult.stdout).session.sessionId
    let running = try decodeJSON(WorkflowRunResult.self, from: secondResult.stdout).session.sessionId
    XCTAssertNotEqual(completed, running)

    let fixedNow = Date()
    let database = try SQLiteDatabase.open(
      path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: roots.store.path)
    )
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let oldTimestamp = formatter.string(from: fixedNow.addingTimeInterval(-3 * 86_400))
    for sessionId in [completed, running] {
      try database.execute(
        "UPDATE workflow_runtime_snapshots SET updated_at = ? WHERE workflow_execution_id = ?",
        bindings: [.text(oldTimestamp), .text(sessionId)]
      )
      try database.execute(
        "UPDATE cli_workflow_sessions SET updated_at = ? WHERE session_id = ?",
        bindings: [.text(oldTimestamp), .text(sessionId)]
      )
    }
    try markSessionRunning(running, in: database)
    // Guard against a setup that silently has no effect: both tables must report the intended statuses
    // and the two sessions must be separate root families before the hook runs.
    XCTAssertEqual(try sessionStatuses(completed, in: database), ["completed", "completed"])
    XCTAssertEqual(try sessionStatuses(running, in: database), ["running", "running"])
    let rootIds = try database.query(
      "SELECT root_session_id FROM workflow_runtime_snapshots WHERE workflow_execution_id IN (?, ?)",
      bindings: [.text(completed), .text(running)]
    ).map { $0.string("root_session_id") }
    XCTAssertEqual(Set(rootIds), [completed, running])

    let warnings = AutomaticRetentionHook.runIfApplicable(
      arguments: ["workflow", "run", "worker-only-single-step", "--session-store", roots.store.path,
                  "--working-dir", roots.project.path],
      exitCode: .success,
      cancelled: false,
      environment: ["HOME": roots.home.path],
      service: RielaRetentionService(clock: { fixedNow })
    )

    XCTAssertTrue(warnings.isEmpty, "\(warnings)")
    let remainingIds = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: roots.store.path)
    ).loadAll().map(\.session.sessionId)
    XCTAssertFalse(remainingIds.contains(completed), "terminal session must be pruned under the byte cap")
    XCTAssertTrue(remainingIds.contains(running), "running session must survive the byte cap")
  }

  func testNoConfigDoesNotDeleteOrCreateRetentionState() throws {
    let roots = try makeRoots()
    defer { try? FileManager.default.removeItem(at: roots.root) }
    let warnings = AutomaticRetentionHook.runIfApplicable(
      arguments: ["workflow", "run", "demo", "--working-dir", roots.project.path, "--session-store", roots.store.path],
      exitCode: .success,
      cancelled: false,
      environment: ["HOME": roots.home.path]
    )
    XCTAssertTrue(warnings.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: roots.home.appendingPathComponent(".riela/retention").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: roots.store.appendingPathComponent("retention").path))
  }

  func testCorruptConfigWarnsAndDoesNotCreateRetentionState() throws {
    let roots = try makeRoots()
    defer { try? FileManager.default.removeItem(at: roots.root) }
    try writeConfig(#"{"retention":{"results":{"bogus":1}}}"#, home: roots.home)
    let warnings = AutomaticRetentionHook.runIfApplicable(
      arguments: ["session", "continue", "session-id", "--working-dir", roots.project.path,
                  "--session-store", roots.store.path],
      exitCode: .success,
      cancelled: false,
      environment: ["HOME": roots.home.path]
    )
    XCTAssertEqual(warnings.count, 1)
    XCTAssertTrue(warnings[0].hasPrefix("riela retention warning: "))
    XCTAssertFalse(FileManager.default.fileExists(atPath: roots.store.appendingPathComponent("retention").path))
  }

  func testAutomaticFalseSkipsPolicyPass() throws {
    let roots = try makeRoots()
    defer { try? FileManager.default.removeItem(at: roots.root) }
    try writeConfig(#"{"retention":{"automatic":false,"results":{"maxAgeDays":1}}}"#, home: roots.home)
    let warnings = AutomaticRetentionHook.runIfApplicable(
      arguments: ["workflow", "run", "demo", "--working-dir", roots.project.path],
      exitCode: .success,
      cancelled: false,
      environment: ["HOME": roots.home.path]
    )
    XCTAssertTrue(warnings.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: roots.home.appendingPathComponent(".riela/retention").path))
  }

  /// Flips the session status to `running` in both stores. The status columns are generated from the JSON
  /// documents, so the JSON must be rewritten rather than the columns.
  private func markSessionRunning(_ sessionId: String, in database: SQLiteDatabase) throws {
    try database.execute(
      "UPDATE workflow_runtime_snapshots SET session_json = jsonb_set(session_json, '$.status', 'running') "
        + "WHERE workflow_execution_id = ?",
      bindings: [.text(sessionId)]
    )
    try database.execute(
      "UPDATE cli_workflow_sessions SET record_json = jsonb_set(record_json, '$.session.status', 'running') "
        + "WHERE session_id = ?",
      bindings: [.text(sessionId)]
    )
  }

  private func sessionStatuses(_ sessionId: String, in database: SQLiteDatabase) throws -> [String] {
    let snapshot = try database.query(
      "SELECT session_status AS status FROM workflow_runtime_snapshots WHERE workflow_execution_id = ?",
      bindings: [.text(sessionId)]
    )
    let record = try database.query(
      "SELECT status FROM cli_workflow_sessions WHERE session_id = ?",
      bindings: [.text(sessionId)]
    )
    return (snapshot + record).map { $0.string("status") }
  }

  private func makeRoots() throws -> TestRoots {
    let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let root = repository.appendingPathComponent("tmp/automatic-retention-test-\(UUID().uuidString)", isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    let home = root.appendingPathComponent("home", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    let store = root.appendingPathComponent("sessions", isDirectory: true)
    for directory in [home, project, store] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    return TestRoots(root: root, home: home, project: project, store: store)
  }

  private func writeConfig(_ contents: String, home: URL) throws {
    let configDirectory = home.appendingPathComponent(".riela", isDirectory: true)
    try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    try contents.write(to: configDirectory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
  }

  private func runWorkflow(roots: TestRoots, workflowRoot: URL,
                           mockScenario: URL) async -> CLICommandResult {
    await RielaCLIApplication().run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", workflowRoot.path,
      "--mock-scenario", mockScenario.path,
      "--session-store", roots.store.path,
      "--working-dir", roots.project.path,
      "--output", "json"
    ], environment: ["HOME": roots.home.path])
  }

  private func decodeJSON<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(output.utf8))
  }

  private func repositoryRoot() -> String {
    FileManager.default.currentDirectoryPath
  }
}
