import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class WorkflowRunGatewayValidationWarningTests: XCTestCase {
  func testProductionOnlyGatewayIssueIsWarningOnStderrAndRunCompletes() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("workflow-run-gateway-warning")
    defer { try? FileManager.default.removeItem(at: root) }
    let workflows = root.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflows.appendingPathComponent("gateway-warning", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    try writeFixture(workflowDirectory: workflowDirectory, unknownArgument: true)

    let result = await run(root: root, workflowDirectory: workflowDirectory, workflows: workflows)
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    XCTAssertTrue(result.stderr.contains("warning: workflow.nodes[0].addon.config.arguments.unexpected"), result.stderr)
    XCTAssertFalse(result.stdout.contains("warning:"), result.stdout)
    XCTAssertEqual(try sessionStatus(in: result.stdout), "completed")

    try writeFixture(workflowDirectory: workflowDirectory, unknownArgument: false)
    let validResult = await run(root: root, workflowDirectory: workflowDirectory, workflows: workflows)
    XCTAssertEqual(validResult.exitCode, .success, validResult.stderr + validResult.stdout)
    XCTAssertFalse(validResult.stderr.contains("warning: workflow.nodes"), validResult.stderr)
    XCTAssertEqual(try sessionStatus(in: validResult.stdout), "completed")
  }

  private func run(root: URL, workflowDirectory: URL, workflows: URL) async -> CLICommandResult {
    await RielaCLIApplication().run([
      "workflow", "run", "gateway-warning",
      "--workflow-definition-dir", workflows.path,
      "--working-dir", root.path,
      "--mock-scenario", workflowDirectory.appendingPathComponent("mock-scenario.json").path,
      "--session-store", root.appendingPathComponent("sessions", isDirectory: true).path,
      "--output", "json"
    ])
  }

  private func writeFixture(workflowDirectory: URL, unknownArgument: Bool) throws {
    let arguments: [String: Any] = unknownArgument ? ["unexpected": "{{workflowInput.value}}"] : [:]
    let workflow: [String: Any] = [
      "workflowId": "gateway-warning",
      "defaults": ["nodeTimeoutMs": 30_000, "maxLoopIterations": 1],
      "entryStepId": "probe",
      "nodes": [[
        "id": "probe",
        "addon": [
          "name": "riela/wrike-gateway-read",
          "version": "1",
          "config": ["operation": "tasks", "arguments": arguments]
        ]
      ]],
      "steps": [["id": "probe", "nodeId": "probe", "role": "worker"]]
    ]
    let scenario: [String: Any] = [
      "probe": [
        "provider": "scenario-mock", "model": "gpt-5.4-mini", "when": ["always": true],
        "payload": ["status": "done"]
      ]
    ]
    try JSONSerialization.data(withJSONObject: workflow).write(to: workflowDirectory.appendingPathComponent("workflow.json"))
    try JSONSerialization.data(withJSONObject: scenario).write(to: workflowDirectory.appendingPathComponent("mock-scenario.json"))
  }

  private func sessionStatus(in stdout: String) throws -> String? {
    let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
    let session = try XCTUnwrap(result["session"] as? [String: Any])
    return session["status"] as? String
  }
}
