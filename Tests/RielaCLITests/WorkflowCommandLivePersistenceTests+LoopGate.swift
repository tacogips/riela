import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

extension WorkflowCommandLivePersistenceTests {
  func testWorkflowRunFailsRequiredLoopWhenEvidenceProjectionFails() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-loop-projection-failure-\(UUID().uuidString)", isDirectory: true)
    let workflowRoot = tempDir.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("loop-command", isDirectory: true)
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let script = try createExecutable(
      directory: tempDir,
      name: "loop-gate-command.sh",
      body: """
      tr -d '\\n' <<'JSON'
      {
        "loopGate": {
          "gateId": "implementation-review",
          "stepId": "run-command",
          "decision": "accepted",
          "severityCounts": { "high": 0, "medium": 0 },
          "evidenceRefs": ["review.json"],
          "diagnostics": ["ok"]
        }
      }
      JSON
      printf '\\n'
      """
    )
    try writeSingleCommandWorkflow(
      workflowDirectory: workflowDirectory,
      workflowId: "loop-command",
      workflowLoopJSON: """
      {
        "kind": "design-implement-review",
        "required": true,
        "gates": [
          {
            "id": "implementation-review",
            "stepId": "run-command",
            "required": true,
            "acceptWhen": { "decision": "accepted", "maxHighFindings": 0, "maxMediumFindings": 0 }
          }
        ]
      }
      """,
      stepLoopJSON: """
      {
        "role": "gate",
        "gateId": "implementation-review",
        "evidenceTags": ["review"],
        "recordsVerification": true
      }
      """,
      nodeJSON: """
      {
        "id": "run-command",
        "nodeType": "command",
        "modelFreeze": false,
        "command": {
          "executable": "\(script.path)"
        }
      }
      """
    )

    // The gate itself is accepted; only the evidence projector fails. A
    // `loop.required` workflow must not pass when its gates cannot be verified.
    var runCommand = WorkflowRunCommand()
    runCommand.loopEvidenceProjector = FailingLoopEvidenceProjector()
    let result = await RielaCLIApplication(runCommand: runCommand).run([
      "workflow", "run", "loop-command",
      "--workflow-definition-dir", workflowRoot.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .failure, result.stderr + result.stdout)
    XCTAssertTrue(result.stderr.contains("loop evidence projection failed"), result.stderr)
    XCTAssertTrue(result.stderr.contains("required loop gates could not be verified"), result.stderr)
    let runResult = try decodeJSON(WorkflowRunResult.self, from: result.stdout)
    XCTAssertEqual(runResult.exitCode, 1)
    XCTAssertEqual(runResult.status, .failed)
    XCTAssertEqual(runResult.session.status, .failed)
    XCTAssertNil(runResult.loopEvidence)
    let persisted = try XCTUnwrap(CLIWorkflowSessionStore(rootDirectory: sessionStore.path).loadAll().first)
    XCTAssertEqual(persisted.session.status, .failed)
  }
}

private struct FailingLoopEvidenceProjector: LoopEvidenceProjecting {
  struct Failure: Error, CustomStringConvertible {
    var description: String { "synthetic loop evidence projector failure" }
  }

  func project(_ input: LoopEvidenceProjectionInput) throws -> LoopEvidenceManifest? {
    throw Failure()
  }
}
