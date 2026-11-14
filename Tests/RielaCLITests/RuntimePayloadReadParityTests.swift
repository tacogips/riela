import Foundation
import RielaSQLite
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class RuntimePayloadReadParityTests: XCTestCase {
  func testReadParityAcrossRepresentations() async throws {
    let environment = try RielaCLIIsolatedEnvironment.make("runtime-payload-parity")
    defer { environment.remove() }
    for status: WorkflowSessionStatus in [.running, .completed] {
      let date = Date(timeIntervalSince1970: 1_700_000_000)
      let execution = WorkflowStepExecution(executionId: "execution", stepId: "step", nodeId: "worker", attempt: 1,
        inputSnapshot: ["shared": .string(String(repeating: "x", count: 2048))],
        status: .completed, createdAt: date, updatedAt: date)
      let session = WorkflowSession(workflowId: "workflow", sessionId: "session", status: status,
        entryStepId: "step", currentStepId: "step", createdAt: date, updatedAt: date, executions: [execution])
      let record = PersistedCLIWorkflowSession(workflowName: "workflow", session: session,
        resolution: WorkflowResolutionOptions(workflowName: "workflow", scope: .project))
      var paths: [String] = []
      for representation in 0..<3 {
        let root = environment.root.appendingPathComponent("\(status.rawValue)-\(representation)").path
        paths.append(root)
        let cli = CLIWorkflowSessionStore(rootDirectory: root)
        let runtimeRoot = canonicalRuntimeStoreRoot(sessionStoreRoot: root)
        let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot)
        try SQLiteWorkflowRuntimePersistenceStore.$writesReducedExecutionPayloadsOverride.withValue(representation == 0) {
          try cli.save(record, runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(session: session))
          let child = WorkflowSession(workflowId: "child", sessionId: "child", status: .created,
            entryStepId: "step", createdAt: date, updatedAt: date, executions: [execution],
            parentSessionId: "session", rootSessionId: "session")
          let reservation = WorkflowNestedInvocationReservation(parentSessionId: "session", parentStepId: "step",
            resumeStepId: "resume", sourceStepExecutionId: "execution", branchId: "branch",
            childSnapshot: WorkflowRuntimePersistenceSnapshot(session: child))
          _ = try runtime.reserveNestedInvocation(reservation)
          XCTAssertEqual(try runtime.nestedInvocationRecord(reservation)?.reservation, reservation)
        }
        let db = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root))
        if representation == 0 {
          XCTAssertNotEqual(try db.query("SELECT COUNT(*) AS count FROM workflow_runtime_payload_refs").first?["count"], "0")
        }
        if representation == 2 {
          let recordEncoder = JSONEncoder()
          recordEncoder.dateEncodingStrategy = .iso8601
          let recordJSON = try XCTUnwrap(String(data: recordEncoder.encode(record), encoding: .utf8))
          try db.execute("UPDATE cli_workflow_sessions SET record_json=jsonb(?) WHERE session_id=?",
            bindings: [.text(recordJSON), .text(session.sessionId)])
          let sessionEncoder = JSONEncoder()
          sessionEncoder.dateEncodingStrategy = RuntimeSnapshotDates.encoding
          let sessionJSON = try XCTUnwrap(String(data: sessionEncoder.encode(session), encoding: .utf8))
          try db.execute("UPDATE workflow_runtime_snapshots SET session_json=jsonb(?) WHERE workflow_execution_id=?",
            bindings: [.text(sessionJSON), .text(session.sessionId)])
        }
        XCTAssertEqual(try cli.load(sessionId: session.sessionId), record)
        XCTAssertEqual(try runtime.load(sessionId: session.sessionId).session, session)
        XCTAssertEqual(try runtime.loadWebSessionDetail(sessionId: session.sessionId, messageLimit: 10).session, session)
      }
      for command in ["status", "export", "logs", "progress"] {
        var outputs: [String] = []
        for path in paths {
          let result = await environment.run {
            await RielaCLIApplication().run(["session", command, session.sessionId,
              "--session-store", path, "--output", "json"])
          }
          XCTAssertEqual(result.exitCode, .success, "\(command): \(result.stderr)")
          outputs.append(result.stdout.replacingOccurrences(of: path, with: "<store>"))
        }
        XCTAssertEqual(outputs[0], outputs[1], command)
        XCTAssertEqual(outputs[0], outputs[2], command)
      }
    }
  }
}
