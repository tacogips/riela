import Foundation
import RielaCore
import RielaWork
import XCTest
@testable import RielaCLI

extension WorkflowCommandTests {
  func testRetiredWorkflowRunOptionsRejectBeforeExecution() async {
    let flags = [
      "--auto-improve", "--no-auto-improve", "--auto-improve=true", "--no-auto-improve=false",
      "--max-supervised-attempts=3", "--max-workflow-patches=2", "--monitor-interval-ms=1000",
      "--stall-timeout-ms=2000", "--workflow-mutation-mode=execution-copy",
      "--nested-superviser", "--nested-supervisor", "--nested-superviser=false"
    ]
    for flag in flags {
      let store = FileManager.default.temporaryDirectory
        .appendingPathComponent("riela-retired-option-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: store) }
      let result = await RielaCLIApplication().run([
        "workflow", "run", "worker-only-single-step",
        "--workflow-definition-dir", "examples",
        "--session-store", store.path,
        flag,
        "--output", "json"
      ])
      XCTAssertEqual(result.exitCode, .usage, flag)
      XCTAssertFalse(FileManager.default.fileExists(atPath: store.path), flag)
    }
  }

  func testOrdinaryWorkflowRunDoesNotCreateTaskStore() async throws {
    let store = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-plain-run-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: store) }
    let taskDatabase = WorkStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: store.path)).databasePath
    XCTAssertFalse(FileManager.default.fileExists(atPath: taskDatabase))
    let result = await RielaCLIApplication().run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "examples",
      "--mock-scenario", "examples/worker-only-single-step/mock-scenario.json",
      "--session-store", store.path,
      "--output", "json"
    ])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let run = try decodeJSON(WorkflowRunResult.self, from: result.stdout)
    XCTAssertEqual(run.status, .completed)
    XCTAssertTrue(try WorkStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: store.path)).listTasks().isEmpty)
  }

  func testCancellationWithoutAutoImprovePersistsTerminalFailure() async throws {
    let tempDir = URL(fileURLWithPath: repositoryRoot())
      .appendingPathComponent("tmp/cancellation-finalization/\(UUID().uuidString)", isDirectory: true)
    let workflowRoot = tempDir.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("cancelled-run", isDirectory: true)
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
    let script = try createExecutable(directory: tempDir, name: "wait.sh", body: "exec sleep 60")
    try writeCancellationWorkflow(
      workflowDirectory: workflowDirectory,
      nodesDirectory: nodesDirectory,
      executable: script,
      argument: tempDir.appendingPathComponent("unused.txt")
    )
    let task = Task {
      await RielaCLIApplication().run([
        "workflow", "run", "cancelled-run",
        "--workflow-definition-dir", workflowRoot.path,
        "--session-store", sessionStore.path,
        "--output", "json"
      ])
    }
    let live = try await waitForCancellationSession(sessionStore: sessionStore)
    task.cancel()
    let result = await task.value
    XCTAssertEqual(result.exitCode, .failure, result.stdout + result.stderr)
    let persistence = SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
    )
    let snapshot = try XCTUnwrap(persistence.load(sessionId: live.session.sessionId))
    XCTAssertEqual(snapshot.session.status, .failed)
    XCTAssertEqual(snapshot.session.failureKind, .cancelled)
    XCTAssertFalse(snapshot.session.executions.contains { $0.status == .running })
    XCTAssertTrue(result.stdout.contains("\"failureKind\":\"cancelled\""), result.stdout)
  }

  private func writeCancellationWorkflow(
    workflowDirectory: URL,
    nodesDirectory: URL,
    executable: URL,
    argument: URL
  ) throws {
    try """
    {
      "workflowId": "cancelled-run",
      "defaults": { "maxLoopIterations": 1, "nodeTimeoutMs": 10000 },
      "entryStepId": "main-worker",
      "nodes": [{ "id": "main-worker", "nodeFile": "nodes/main-worker.json" }],
      "steps": [{ "id": "main-worker", "nodeId": "main-worker", "role": "worker" }]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "main-worker",
      "nodeType": "command",
      "modelFreeze": false,
      "command": {
        "executable": "\(executable.path)",
        "arguments": ["\(argument.path)"]
      }
    }
    """.write(to: nodesDirectory.appendingPathComponent("main-worker.json"), atomically: true, encoding: .utf8)
  }

  private func waitForCancellationSession(sessionStore: URL) async throws -> PersistedCLIWorkflowSession {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if let record = try? CLIWorkflowSessionStore(rootDirectory: sessionStore.path).loadAll().first(where: {
        $0.workflowName == "cancelled-run"
      }) {
        return record
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("timed out waiting for live persisted session")
    throw CancellationTestError.timedOutWaitingForSession
  }
}

private enum CancellationTestError: Error {
  case timedOutWaitingForSession
}
