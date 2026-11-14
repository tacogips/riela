import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class SessionAddonRecoveryTests: XCTestCase {
  func testSessionResumeAndRerunProvideBuiltinAddonResolver() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("session-addon-recovery")
    defer { try? FileManager.default.removeItem(at: root) }
    let workflowRoot = root.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("two-time-signals", isDirectory: true)
    let sessionStore = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    try writeWorkflow(to: workflowDirectory.appendingPathComponent("workflow.json"))

    let app = RielaCLIApplication()
    let initialRun = await app.run([
      "workflow", "run", "two-time-signals",
      "--workflow-definition-dir", workflowRoot.path,
      "--working-dir", root.path,
      "--session-store", sessionStore.path,
      "--max-steps", "1",
      "--output", "json"
    ])
    XCTAssertEqual(initialRun.exitCode, .failure, initialRun.stderr + initialRun.stdout)
    let initialFailure = try decode(WorkflowRunFailureResult.self, from: initialRun.stdout)
    XCTAssertEqual(initialFailure.failureKind, .maxStepsExceeded)
    let sessionId = try XCTUnwrap(initialFailure.sessionId)

    let resume = await app.run([
      "session", "resume", sessionId,
      "--workflow-definition-dir", workflowRoot.path,
      "--working-dir", root.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(resume.exitCode, .success, resume.stderr + resume.stdout)
    let resumed = try decode(SessionResumeCommandResult.self, from: resume.stdout)
    XCTAssertEqual(resumed.status, .completed)

    let rerun = await app.run([
      "session", "rerun", sessionId, "first-signal",
      "--workflow-definition-dir", workflowRoot.path,
      "--working-dir", root.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(rerun.exitCode, .success, rerun.stderr + rerun.stdout)
    let rerunResult = try decode(SessionRerunCommandResult.self, from: rerun.stdout)
    XCTAssertEqual(rerunResult.status, .completed)
    XCTAssertEqual(rerunResult.rerunFromStepId, "first-signal")
  }

  private func writeWorkflow(to url: URL) throws {
    try """
    {
      "workflowId": "two-time-signals",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 30000 },
      "entryStepId": "first-signal",
      "nodes": [
        {
          "id": "first-signal",
          "addon": {
            "name": "riela/time-signal",
            "version": "1",
            "config": { "intervalMinutes": 5 },
            "inputs": {
              "scheduledAt": "2026-08-06T01:00:00.000Z",
              "timezone": "Asia/Tokyo"
            }
          }
        },
        {
          "id": "second-signal",
          "addon": {
            "name": "riela/time-signal",
            "version": "1",
            "config": { "intervalMinutes": 5 },
            "inputs": {
              "scheduledAt": "{{inbox.latest.output.payload.scheduledAt}}",
              "timezone": "{{inbox.latest.output.payload.timezone}}"
            }
          }
        }
      ],
      "steps": [
        {
          "id": "first-signal",
          "nodeId": "first-signal",
          "role": "worker",
          "transitions": [
            { "toStepId": "second-signal", "label": "should_announce" }
          ]
        },
        { "id": "second-signal", "nodeId": "second-signal", "role": "worker" }
      ]
    }
    """.write(to: url, atomically: true, encoding: .utf8)
  }

  private func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(value.utf8))
  }
}
