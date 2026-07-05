import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

extension WorkflowCommandLivePersistenceTests {
  func testSessionProgressReportsActiveBackendHeartbeatFields() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-progress-backend-heartbeat-\(UUID().uuidString)", isDirectory: true)
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let heartbeatAt = Date(timeIntervalSince1970: 1_700_000_010)
    let session = WorkflowSession(
      workflowId: "heartbeat-workflow",
      sessionId: "heartbeat-session",
      status: .running,
      entryStepId: "agent-step",
      currentStepId: "agent-step",
      createdAt: now,
      updatedAt: now,
      executions: [
        WorkflowStepExecution(
          executionId: "agent-step-attempt-1-exec-1",
          stepId: "agent-step",
          nodeId: "agent-node",
          attempt: 1,
          backend: .codexAgent,
          status: .running,
          lastBackendEventAt: heartbeatAt,
          lastBackendEventType: "turn.started",
          createdAt: now,
          updatedAt: now
        )
      ]
    )
    let resolution = WorkflowResolutionOptions(workflowName: "heartbeat-workflow", workingDirectory: tempDir.path)
    try CLIWorkflowSessionStore(rootDirectory: sessionStore.path).save(
      PersistedCLIWorkflowSession(workflowName: "heartbeat-workflow", session: session, resolution: resolution),
      runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(session: session)
    )

    let jsonResult = await RielaCLIApplication().run([
      "session", "progress", "heartbeat-session",
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(jsonResult.exitCode, .success, jsonResult.stderr + jsonResult.stdout)
    let progress = try decodeProgressJSON(from: jsonResult.stdout)
    XCTAssertEqual(progress.activeBackend, NodeExecutionBackend.codexAgent)
    XCTAssertEqual(progress.activeBackendEventAt, heartbeatAt)
    XCTAssertEqual(progress.activeBackendEventType, "turn.started")
    XCTAssertNotNil(progress.backendSilentForMs)
    XCTAssertNotNil(progress.activeSilentForMs)
    XCTAssertEqual(progress.executions.first?.lastBackendEventAt, heartbeatAt)

    let textResult = await RielaCLIApplication().run([
      "session", "progress", "heartbeat-session",
      "--session-store", sessionStore.path,
      "--output", "text"
    ])
    XCTAssertEqual(textResult.exitCode, .success, textResult.stderr + textResult.stdout)
    XCTAssertTrue(textResult.stdout.contains("activeBackendEventType: turn.started"))
    XCTAssertTrue(textResult.stdout.contains("activeBackendEventAt: 2023-11-14T22:13:30Z"))
    XCTAssertTrue(textResult.stdout.contains("backendSilentForMs: "))
    XCTAssertTrue(textResult.stdout.contains("activeSilentForMs: "))
  }

  private func decodeProgressJSON(from stdout: String) throws -> SessionInspectionCommandResult {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(SessionInspectionCommandResult.self, from: Data(stdout.utf8))
  }
}
