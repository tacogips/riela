import Foundation
import RielaCore
import RielaSQLite
import XCTest
@testable import RielaCLI

final class SessionMessageRetentionAdmissionTests: XCTestCase {
  func testMessageRetiredSessionCannotResumeOrRerun() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/automatic-retention-admission-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let canonicalRoot = root.resolvingSymlinksInPath()
    let repository = FileManager.default.currentDirectoryPath
    let workflowRoot = URL(fileURLWithPath: repository).appendingPathComponent("examples", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("worker-only-single-step", isDirectory: true)
    let scenario = workflowDirectory.appendingPathComponent("mock-scenario.json")
    let store = canonicalRoot.appendingPathComponent("sessions", isDirectory: true)
    let run = await RielaCLIApplication().run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", workflowRoot.path,
      "--mock-scenario", scenario.path,
      "--working-dir", canonicalRoot.path,
      "--session-store", store.path,
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .success, run.stderr + run.stdout)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let sessionId = try decoder.decode(WorkflowRunResult.self, from: Data(run.stdout.utf8)).session.sessionId

    let databasePath = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: store.path)
    let db = try SQLiteDatabase.open(path: databasePath)
    try db.execute("CREATE TABLE session_message_retention_tombstones(session_id TEXT PRIMARY KEY, workflow_id TEXT NOT NULL, pruned_at TEXT NOT NULL, message_bytes INTEGER NOT NULL)")
    try db.execute("INSERT INTO session_message_retention_tombstones VALUES(?,?,?,?)",
      bindings: [.text(sessionId), .text("worker-only-single-step"), .text("2026-10-19T00:00:00Z"), .int(4)])
    let sessionCountBefore = try CLIWorkflowSessionStore(rootDirectory: store.path).loadAll().count

    let rerun = await RielaCLIApplication().run([
      "session", "rerun", sessionId, "main-worker",
      "--workflow-definition-dir", workflowRoot.path,
      "--working-dir", canonicalRoot.path,
      "--session-store", store.path,
      "--output", "json"
    ])
    XCTAssertEqual(rerun.exitCode, .failure)
    XCTAssertTrue(rerun.stdout.contains("workflow messages expired under retention"), rerun.stdout)

    let resume = await RielaCLIApplication().run([
      "session", "resume", sessionId,
      "--workflow-definition-dir", workflowRoot.path,
      "--mock-scenario", scenario.path,
      "--working-dir", canonicalRoot.path,
      "--session-store", store.path,
      "--output", "json"
    ])
    XCTAssertEqual(resume.exitCode, .failure)
    XCTAssertTrue(resume.stdout.contains("workflow messages expired under retention"), resume.stdout)
    XCTAssertEqual(try CLIWorkflowSessionStore(rootDirectory: store.path).loadAll().count, sessionCountBefore)
  }
}
