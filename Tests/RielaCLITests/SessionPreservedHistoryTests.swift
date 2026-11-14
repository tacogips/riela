import Foundation
import XCTest
import RielaCore
@testable import RielaCLI

final class SessionPreservedHistoryTests: XCTestCase {
  func testActualCLIFailedRunAndPreservedRerunReload() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/cli-history-\(UUID().uuidString)")
    let bundle = root.appendingPathComponent("history-cli")
    let sessions = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try """
    {"workflowId":"history-cli","defaults":{"nodeTimeoutMs":120000,"maxLoopIterations":2},"entryStepId":"first",
     "nodes":[{"id":"first","nodeFile":"first.json"},{"id":"final","nodeFile":"final.json"}],
     "steps":[{"id":"first","nodeId":"first","transitions":[{"toStepId":"final"}]},{"id":"final","nodeId":"final"}]}
    """.write(to: bundle.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    for id in ["first", "final"] {
      try """
      {"id":"\(id)","executionBackend":"codex-agent","model":"fixture","variables":{},
       "output":{"jsonSchema":{"type":"object","required":["answer"]},"maxValidationAttempts":2}}
      """.write(to: bundle.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8)
    }
    let failure = root.appendingPathComponent("deterministic-failure.json")
    let repair = root.appendingPathComponent("deterministic-repair.json")
    try """
    {"first":{"provider":"scenario-mock","model":"fixture","payload":{"answer":"accepted discussion"}},
     "final":{"provider":"scenario-mock","model":"fixture","payload":{}}}
    """.write(to: failure, atomically: true, encoding: .utf8)
    // No prefix scenario: invoking first again must fail rather than silently pass.
    try """
    {"final":{"provider":"scenario-mock","model":"fixture","payload":{"answer":"repaired decision"}}}
    """.write(to: repair, atomically: true, encoding: .utf8)
    let common = ["--workflow-definition-dir", root.path, "--working-directory", root.path,
      "--session-store", sessions.path, "--output", "json"]
    let first = await RielaCLIApplication().run(["workflow", "run", "history-cli", "--mock-scenario", failure.path] + common)
    XCTAssertNotEqual(first.exitCode, .success)
    let store = CLIWorkflowSessionStore(rootDirectory: sessions.path)
    let source = try store.load(sessionId: "history-cli-session-1")
    XCTAssertEqual(source.session.status, .failed)
    let rerun = await RielaCLIApplication().run(["session", "rerun", source.session.sessionId, "final",
      "--preserve-history", "--mock-scenario", repair.path] + common)
    XCTAssertEqual(rerun.exitCode, .success, rerun.stderr + rerun.stdout)
    let result = try JSONDecoder().decode(SessionRerunCommandResult.self, from: Data(rerun.stdout.utf8))
    let recovered = try store.load(sessionId: result.sessionId)
    XCTAssertEqual(recovered.session.status, .completed)
    XCTAssertEqual(recovered.session.newExecutionCount, 1)
    XCTAssertEqual(recovered.session.executions.count, 2)
    XCTAssertEqual(recovered.session.executions.first?.importedFrom?.sessionId, source.session.sessionId)
    XCTAssertEqual(try store.load(sessionId: source.session.sessionId), source)
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessions.path))
    let snapshot = try persistence.load(sessionId: result.sessionId)
    XCTAssertEqual(snapshot.session.executions.first?.importedFrom, recovered.session.executions.first?.importedFrom)
    XCTAssertEqual(snapshot.workflowMessages.first?.payload, ["answer": .string("accepted discussion")])
  }
}
