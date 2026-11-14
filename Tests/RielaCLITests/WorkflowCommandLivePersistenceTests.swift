import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class WorkflowCommandLivePersistenceTests: XCTestCase {
  func testWorkflowRunJSONPersistsLiveSessionBeforeCommandNodeCompletes() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-json-live-session-\(UUID().uuidString)", isDirectory: true)
    let workflowRoot = tempDir.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("slow-command", isDirectory: true)
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
    let script = try createExecutable(
      directory: tempDir,
      name: "slow-command.sh",
      body: """
      sleep 1
      printf '%s\\n' '{"status":"done"}'
      """
    )
    try writeSingleCommandWorkflow(
      workflowDirectory: workflowDirectory,
      nodeJSON: """
      {
        "id": "run-command",
        "nodeType": "command",
        "command": { "executable": "\(script.path)" }
      }
      """
    )

    let app = RielaCLIApplication()
    let task = Task {
      await app.run([
        "workflow", "run", "slow-command",
        "--workflow-definition-dir", workflowRoot.path,
        "--session-store", sessionStore.path,
        "--output", "json"
      ])
    }

    var liveRecord: PersistedCLIWorkflowSession?
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      liveRecord = try? CLIWorkflowSessionStore(rootDirectory: sessionStore.path).loadAll().first
      if liveRecord != nil {
        break
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }

    XCTAssertEqual(liveRecord?.workflowName, "slow-command")
    let snapshot = try liveRecord.map {
      try SQLiteWorkflowRuntimePersistenceStore(
        rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
      ).load(sessionId: $0.session.sessionId)
    }
    XCTAssertNotNil(snapshot)

    let result = await task.value
    XCTAssertEqual(result.exitCode, .success)
    XCTAssertTrue(result.stderr.isEmpty)
    let runResult = try decodeJSON(WorkflowRunResult.self, from: result.stdout)
    XCTAssertEqual(runResult.status, .completed)
    XCTAssertEqual(runResult.rootOutput?["status"], .string("done"))
  }

  func testWorkflowRunJSONSignalFailureIncludesPersistedSessionDiagnostic() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-json-signal-failure-\(UUID().uuidString)", isDirectory: true)
    let workflowRoot = tempDir.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("signal-command", isDirectory: true)
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try writeSingleCommandWorkflow(
      workflowDirectory: workflowDirectory,
      workflowId: "signal-command",
      nodeJSON: """
      {
        "id": "run-command",
        "nodeType": "command",
        "command": { "executable": "/bin/sh", "arguments": ["-c", "kill -13 $$"] }
      }
      """
    )

    let result = await RielaCLIApplication().run([
      "workflow", "run", "signal-command",
      "--workflow-definition-dir", workflowRoot.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowRunFailureResult.self, from: result.stdout)
    XCTAssertEqual(failure.target, "signal-command")
    XCTAssertEqual(failure.sessionStore, sessionStore.path)
    XCTAssertEqual(failure.persistedSession, true)
    XCTAssertNotNil(failure.sessionId)
    XCTAssertTrue(failure.error.contains("exit code -13"), failure.error)
    XCTAssertEqual(failure.childExitCode, -13)
    XCTAssertEqual(failure.terminationSignal, 13)
    let sessionId = try XCTUnwrap(failure.sessionId)
    XCTAssertNotNil(try CLIWorkflowSessionStore(rootDirectory: sessionStore.path).load(sessionId: sessionId))
  }

  func testWorkflowRunJSONFailureErrorIsBounded() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-json-bounded-failure-\(UUID().uuidString)", isDirectory: true)
    let workflowRoot = tempDir.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("noisy-command", isDirectory: true)
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try writeSingleCommandWorkflow(
      workflowDirectory: workflowDirectory,
      workflowId: "noisy-command",
      nodeJSON: """
      {
        "id": "run-command",
        "nodeType": "command",
        "command": {
          "executable": "/bin/sh",
          "arguments": ["-c", "i=0; while [ $i -lt 9000 ]; do printf x >&2; i=$((i + 1)); done; exit 1"]
        }
      }
      """
    )

    let result = await RielaCLIApplication().run([
      "workflow", "run", "noisy-command",
      "--workflow-definition-dir", workflowRoot.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .failure)
    let failure = try decodeJSON(WorkflowRunFailureResult.self, from: result.stdout)
    XCTAssertLessThanOrEqual(failure.error.count, 8_100)
    XCTAssertTrue(failure.error.contains("...(truncated)"), failure.error)
    XCTAssertEqual(failure.persistedSession, true)
  }

  private func writeSingleCommandWorkflow(
    workflowDirectory: URL,
    workflowId: String = "slow-command",
    nodeJSON: String
  ) throws {
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
    try """
    {
      "workflowId": "\(workflowId)",
      "defaults": { "maxLoopIterations": 1, "nodeTimeoutMs": 10000 },
      "entryStepId": "run-command",
      "nodes": [{ "id": "run-command", "nodeFile": "nodes/node-run-command.json" }],
      "steps": [{ "id": "run-command", "nodeId": "run-command", "role": "worker" }]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try nodeJSON.write(to: nodesDirectory.appendingPathComponent("node-run-command.json"), atomically: true, encoding: .utf8)
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
