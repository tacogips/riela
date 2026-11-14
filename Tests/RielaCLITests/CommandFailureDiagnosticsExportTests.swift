import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

/// #163: a failed command's non-authoritative diagnostics receipt travels
/// runner -> runtime store -> CLI SQLite persistence -> `session export`.
final class CommandFailureDiagnosticsExportTests: XCTestCase {
  func testFailureDiagnosticsReceiptSurvivesPersistenceAndSessionExport() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("command-failure-diagnostics-export")
    defer { try? FileManager.default.removeItem(at: root) }
    let workflowRoot = root.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("diagnostics-export", isDirectory: true)
    let sessionStore = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    let workflow: [String: Any] = [
      "workflowId": "diagnostics-export",
      "defaults": ["maxLoopIterations": 1, "nodeTimeoutMs": 30_000],
      "entryStepId": "probe",
      "nodes": [["id": "probe", "nodeFile": "nodes/probe.json"]],
      "steps": [["id": "probe", "nodeId": "probe"]]
    ]
    try JSONSerialization.data(withJSONObject: workflow).write(to: workflowDirectory.appendingPathComponent("workflow.json"))
    let schema: [String: Any] = [
      "type": "object", "additionalProperties": false, "required": ["status"],
      "properties": ["status": ["type": "string", "enum": ["quota_exhausted"]]]
    ]
    let node: [String: Any] = [
      "id": "probe", "nodeType": "command", "modelFreeze": false,
      "command": [
        "executable": "/bin/sh",
        "arguments": ["-c", "printf '{\"private\":\"DO_NOT_RETAIN\",\"report\":{\"status\":\"quota_exhausted\"}}'; exit 4"],
        "failureDiagnostics": ["schema": schema, "path": ["report"]]
      ]
    ]
    try JSONSerialization.data(withJSONObject: node).write(to: workflowDirectory.appendingPathComponent("nodes/probe.json"))

    let app = RielaCLIApplication()
    let run = await app.run([
      "workflow", "run", "diagnostics-export",
      "--workflow-definition-dir", workflowRoot.path,
      "--working-dir", root.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .failure, run.stderr + run.stdout)
    let sessionId = try XCTUnwrap(try JSONDecoder().decode(WorkflowRunFailureResult.self, from: Data(run.stdout.utf8)).sessionId)

    let expected = WorkflowFailureDiagnostics.eventMetadata(
      exitCode: 4, diagnostics: ["status": .string("quota_exhausted")]
    )
    let persisted = try CLIWorkflowSessionStore(rootDirectory: sessionStore.path).load(sessionId: sessionId)
    let probe = try XCTUnwrap(persisted.session.executions.last { $0.stepId == "probe" })
    XCTAssertEqual(probe.status, .failed)
    XCTAssertNil(probe.acceptedOutput)
    let receipt = try XCTUnwrap(probe.recentBackendEvents?.last { $0.eventType == WorkflowFailureDiagnostics.eventType })
    XCTAssertEqual(receipt.metadata, expected)

    let export = await app.run([
      "session", "export", sessionId,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(export.exitCode, .success, export.stderr + export.stdout)
    XCTAssertTrue(export.stdout.contains(WorkflowFailureDiagnostics.eventType), export.stdout)
    XCTAssertTrue(export.stdout.contains("quota_exhausted"), export.stdout)
    XCTAssertFalse(export.stdout.contains("DO_NOT_RETAIN"), export.stdout)
  }
}
