import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class ReviewFindingInspectionTests: XCTestCase {
  func testSessionStatusReportsPersistedReviewFindings() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-review-finding-session-\(UUID().uuidString)", isDirectory: true)
    let workflowRoot = tempDir.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("review-finding-command", isDirectory: true)
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
    let script = try createExecutable(
      directory: tempDir,
      name: "review-finding-command.sh",
      body: """
      cat <<'JSON' | tr -d '\\n'
      {
        "status": "needs-work",
        "findings": [
          {
            "severity": "high",
            "targetStepId": "implement",
            "file": "Sources/App.swift",
            "line": 42,
            "message": "Persist this review finding.",
            "requiredChange": "Replay it on rerun."
          }
        ]
      }
      JSON
      printf '\\n'
      """
    )
    try writeSingleCommandWorkflow(
      workflowDirectory: workflowDirectory,
      script: script
    )

    let run = await RielaCLIApplication().run([
      "workflow", "run", "review-finding-command",
      "--workflow-definition-dir", workflowRoot.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .success, run.stderr + run.stdout)
    let runResult = try decodeJSON(WorkflowRunResult.self, from: run.stdout)

    let status = await RielaCLIApplication().run([
      "session", "status", runResult.session.sessionId,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(status.exitCode, .success, status.stderr + status.stdout)
    let inspection = try decodeJSON(SessionInspectionCommandResult.self, from: status.stdout)
    XCTAssertEqual(inspection.reviewFindingCount, 1)
    XCTAssertEqual(inspection.reviewFindings.first?.severity, .high)
    XCTAssertEqual(inspection.reviewFindings.first?.targetStepId, "implement")
    XCTAssertEqual(inspection.reviewFindings.first?.message, "Persist this review finding.")

    let textStatus = await RielaCLIApplication().run([
      "session", "status", runResult.session.sessionId,
      "--session-store", sessionStore.path,
      "--output", "text"
    ])
    XCTAssertEqual(textStatus.exitCode, .success, textStatus.stderr + textStatus.stdout)
    XCTAssertTrue(textStatus.stdout.contains("reviewFindingCount: 1"))
  }

  private func writeSingleCommandWorkflow(workflowDirectory: URL, script: URL) throws {
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
    try """
    {
      "workflowId": "review-finding-command",
      "defaults": { "maxLoopIterations": 1, "nodeTimeoutMs": 10000 },
      "entryStepId": "run-command",
      "nodes": [{ "id": "run-command", "nodeFile": "nodes/node-run-command.json" }],
      "steps": [
        {
          "id": "run-command",
          "nodeId": "run-command",
          "role": "worker"
        }
      ]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "review-command",
      "nodeType": "command",
      "modelFreeze": false,
      "command": { "executable": "\(script.path)" }
    }
    """.write(to: nodesDirectory.appendingPathComponent("node-run-command.json"), atomically: true, encoding: .utf8)
  }

  private func createExecutable(directory: URL, name: String, body: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try """
    #!/bin/sh
    \(body)
    """.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  private func decodeJSON<T: Decodable>(_ type: T.Type, from stdout: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(stdout.utf8))
  }
}
