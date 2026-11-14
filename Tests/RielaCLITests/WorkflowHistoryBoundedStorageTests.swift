import Foundation
import RielaCore
import RielaSQLite
import XCTest
@testable import RielaCLI

final class WorkflowHistoryBoundedStorageTests: XCTestCase {
  func testOneTimeRunsDoNotWriteDefinitionHistoryOrProposals() async throws {
    for form in ["named", "inline", "path", "loop"] {
      let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("tmp/workflow-history-unification/whu-08-rollback-service/q7-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      let workflowDirectory = root.appendingPathComponent(".riela/workflows/bounded-flow")
      let nodes = workflowDirectory.appendingPathComponent("nodes")
      let sessions = root.appendingPathComponent("sessions")
      try FileManager.default.createDirectory(at: nodes, withIntermediateDirectories: true)
      let workflow = #"""
        {"workflowId":"bounded-flow","entryStepId":"work","defaults":{"nodeTimeoutMs":30000,"maxLoopIterations":1},
        "nodes":[{"id":"worker","nodeFile":"nodes/worker.json"}],"steps":[{"id":"work","nodeId":"worker","role":"worker"}],
        "loop":{"regressionRollback":{"policy":"automatic"}}}
        """#
      let node = #"{"id":"worker","executionBackend":"codex-agent","agentSandbox":"read-only","model":"test-model","modelFreeze":false,"variables":{}}"#
      try workflow.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
      try node.write(to: nodes.appendingPathComponent("worker.json"), atomically: true, encoding: .utf8)
      let temporary = #"{"workflow":\#(workflow),"nodePayloads":{"nodes/worker.json":\#(node)}}"#
      let temporaryPath = root.appendingPathComponent("temp-workflow.json")
      try temporary.write(to: temporaryPath, atomically: true, encoding: .utf8)
      let scenario = root.appendingPathComponent("scenario.json")
      try #"{"worker":{"provider":"scenario-mock","when":{"always":true},"payload":{"ok":true}}}"#
        .write(to: scenario, atomically: true, encoding: .utf8)
      let options = ["--working-dir", root.path, "--mock-scenario", scenario.path,
                     "--session-store", sessions.path, "--output", "json"]
      let app = RielaCLIApplication()
      let baselineRun = await app.run(["workflow", "run", "bounded-flow"] + options)
      XCTAssertEqual(baselineRun.exitCode, .success, "\(form): \(baselineRun.stderr)")
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let baseline = try decoder.decode(WorkflowRunResult.self, from: Data(baselineRun.stdout.utf8))
      let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessions.path))
      try runtime.setLoopBaseline(.init(workflowId: "bounded-flow", sessionId: baseline.session.sessionId, setAt: Date()))
      XCTAssertEqual(try runtime.loadLoopBaseline(workflowId: "bounded-flow")?.sessionId, baseline.session.sessionId)
      let command: [String]
      switch form {
      case "inline": command = ["workflow", "run", temporary]
      case "path": command = ["workflow", "run", temporaryPath.path]
      case "loop": command = ["loop", "start", "bounded-flow"]
      default: command = ["workflow", "run", "bounded-flow"]
      }
      let result = await app.run(command + options)
      XCTAssertEqual(result.exitCode, .success, "\(form): \(result.stderr)\n\(result.stdout)")
      let db = try SQLiteDatabase.open(path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(
        rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessions.path)), mode: .strictReadOnly, options: .readOnlyDefault)
      for table in ["definition_heads", "definition_versions", "definition_change_audit", "definition_rollback_proposals"] {
        let count = try XCTUnwrap(db.query("SELECT COUNT(*) AS count FROM \(table)").first?["count"])
        XCTAssertEqual(count, "0", "\(form): \(table)")
      }
    }
  }
}
