import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

extension WorkflowCommandTests {
  func testAutoImproveRetriesStalledWorkflowFromActiveStep() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-auto-improve-stall-\(UUID().uuidString)", isDirectory: true)
    let workflowRoot = tempDir.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("stall-then-ready", isDirectory: true)
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)
    let counterFile = tempDir.appendingPathComponent("attempt-count.txt")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)

    let script = try createExecutable(
      directory: tempDir,
      name: "stall-once.sh",
      body: """
      if [ ! -f "$1" ]; then
        printf first > "$1"
        sleep 5
        exit 99
      fi
      printf '%s\\n' '{"status":"ready"}'
      """
    )
    try writeSingleCommandWorkflow(
      workflowDirectory: workflowDirectory,
      nodesDirectory: nodesDirectory,
      workflowId: "stall-then-ready",
      executable: script,
      argument: counterFile
    )

    let result = await RielaCLIApplication().run([
      "workflow", "run", "stall-then-ready",
      "--workflow-definition-dir", workflowRoot.path,
      "--session-store", sessionStore.path,
      "--auto-improve",
      "--max-supervised-attempts", "2",
      "--monitor-interval-ms", "100",
      "--stall-timeout-ms", "1000",
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let runResult = try decodeJSON(WorkflowRunResult.self, from: result.stdout)
    XCTAssertEqual(runResult.status, .completed)
    XCTAssertEqual(runResult.rootOutput?["status"], .string("ready"))
    let supervision = try XCTUnwrap(runResult.supervision)
    XCTAssertEqual(supervision["status"], .string("succeeded"))
    XCTAssertEqual(supervision["attempts"], .number(2))
    guard case let .object(policy)? = supervision["policy"] else {
      return XCTFail("expected supervision policy")
    }
    XCTAssertEqual(policy["stallDetectionEnabled"], .bool(true))
    guard case let .array(incidents)? = supervision["incidents"] else {
      return XCTFail("expected supervision incidents")
    }
    guard case let .object(incident)? = incidents.first else {
      return XCTFail("expected stall incident")
    }
    XCTAssertEqual(incident["category"], .string("stall"))
    XCTAssertEqual(incident["stepId"], .string("main-worker"))
    guard case let .array(remediations)? = supervision["remediations"] else {
      return XCTFail("expected supervision remediations")
    }
    guard case let .object(remediation)? = remediations.first else {
      return XCTFail("expected rerun remediation")
    }
    XCTAssertEqual(remediation["action"], .string("rerun-workflow"))
    XCTAssertEqual(remediation["targetSessionId"], .string(runResult.session.sessionId))
    XCTAssertNotEqual(remediation["sourceSessionId"], remediation["targetSessionId"])
  }

  func testAutoImproveTreatsOnlyHeartbeatObservedAgentBackendAsStallDetectable() {
    let now = Date()
    let later = now.addingTimeInterval(60)
    let silentAgentExecution = WorkflowStepExecution(
      executionId: "exec-silent-agent",
      stepId: "agent-step",
      nodeId: "agent-node",
      attempt: 1,
      backend: .codexAgent,
      status: .running,
      createdAt: later,
      updatedAt: later
    )
    let heartbeatAgentExecution = WorkflowStepExecution(
      executionId: "exec-heartbeat-agent",
      stepId: "agent-heartbeat-step",
      nodeId: "agent-heartbeat-node",
      attempt: 1,
      backend: .codexAgent,
      status: .running,
      lastBackendEventAt: later,
      lastBackendEventType: "turn.started",
      createdAt: now,
      updatedAt: now
    )
    let commandExecution = WorkflowStepExecution(
      executionId: "exec-command",
      stepId: "command-step",
      nodeId: "command-node",
      attempt: 1,
      backend: nil,
      status: .running,
      createdAt: now,
      updatedAt: now
    )
    XCTAssertFalse(workflowAutoImproveCanDetectStall(in: silentAgentExecution))
    XCTAssertTrue(workflowAutoImproveCanDetectStall(in: heartbeatAgentExecution))
    XCTAssertTrue(workflowAutoImproveCanDetectStall(in: commandExecution))

    let session = WorkflowSession(
      workflowId: "mixed-running",
      sessionId: "session-mixed",
      status: .running,
      entryStepId: "command-step",
      createdAt: now,
      updatedAt: later,
      executions: [commandExecution, silentAgentExecution, heartbeatAgentExecution]
    )
    XCTAssertEqual(workflowAutoImproveStallTarget(in: session)?.executionId, "exec-heartbeat-agent")
    XCTAssertEqual(workflowAutoImproveLatestStallActivityDate(in: session), later)
  }

  func testAutoImproveStallRetryRequiresExplicitStallTimeout() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-auto-improve-no-stall-\(UUID().uuidString)", isDirectory: true)
    let workflowRoot = tempDir.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("slow-ready", isDirectory: true)
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)
    let counterFile = tempDir.appendingPathComponent("attempt-count.txt")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)

    let script = try createExecutable(
      directory: tempDir,
      name: "slow-ready.sh",
      body: """
      count=0
      if [ -f "$1" ]; then
        count="$(cat "$1")"
      fi
      count=$((count + 1))
      printf '%s' "$count" > "$1"
      sleep 1
      printf '%s\\n' '{"status":"ready"}'
      """
    )
    try writeSingleCommandWorkflow(
      workflowDirectory: workflowDirectory,
      nodesDirectory: nodesDirectory,
      workflowId: "slow-ready",
      executable: script,
      argument: counterFile
    )

    let result = await RielaCLIApplication().run([
      "workflow", "run", "slow-ready",
      "--workflow-definition-dir", workflowRoot.path,
      "--session-store", sessionStore.path,
      "--auto-improve",
      "--max-supervised-attempts", "2",
      "--monitor-interval-ms", "100",
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let runResult = try decodeJSON(WorkflowRunResult.self, from: result.stdout)
    XCTAssertEqual(runResult.status, .completed)
    XCTAssertEqual(runResult.rootOutput?["status"], .string("ready"))
    let supervision = try XCTUnwrap(runResult.supervision)
    XCTAssertEqual(supervision["attempts"], .number(1))
    XCTAssertEqual(try String(contentsOf: counterFile, encoding: .utf8), "1")
  }

  func testAutoImproveCancellationDoesNotCreateIncidentOrRerun() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-auto-improve-cancel-\(UUID().uuidString)", isDirectory: true)
    let workflowRoot = tempDir.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("cancelled-run", isDirectory: true)
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)
    let ignoredArgument = tempDir.appendingPathComponent("unused.txt")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)

    let script = try createExecutable(
      directory: tempDir,
      name: "wait-forever.sh",
      body: """
      while :; do
        sleep 1
      done
      """
    )
    try writeSingleCommandWorkflow(
      workflowDirectory: workflowDirectory,
      nodesDirectory: nodesDirectory,
      workflowId: "cancelled-run",
      executable: script,
      argument: ignoredArgument
    )

    let task = Task {
      await RielaCLIApplication().run([
        "workflow", "run", "cancelled-run",
        "--workflow-definition-dir", workflowRoot.path,
        "--session-store", sessionStore.path,
        "--auto-improve",
        "--max-supervised-attempts", "3",
        "--output", "json"
      ])
    }

    let liveRecord = try await waitForPersistedSession(sessionStore: sessionStore, workflowName: "cancelled-run")
    task.cancel()
    let result = await task.value

    XCTAssertEqual(result.exitCode, .failure, result.stderr + result.stdout)
    XCTAssertTrue(result.stderr.isEmpty, result.stderr)
    let runResult = try decodeJSON(WorkflowRunResult.self, from: result.stdout)
    XCTAssertEqual(runResult.session.sessionId, liveRecord.session.sessionId)
    XCTAssertEqual(runResult.status, .failed)
    let supervision = try XCTUnwrap(runResult.supervision)
    XCTAssertEqual(supervision["status"], .string("cancelled"))
    XCTAssertEqual(supervision["attempts"], .number(1))
    XCTAssertEqual(supervision["targetSessionId"], .string(runResult.session.sessionId))
    XCTAssertEqual(supervision["incidents"], .array([]))
    XCTAssertEqual(supervision["remediations"], .array([]))
    guard case let .object(managerControl)? = supervision["managerControl"] else {
      return XCTFail("expected supervision managerControl")
    }
    XCTAssertEqual(managerControl["targetedRerun"], .bool(false))

    let sessions = try CLIWorkflowSessionStore(rootDirectory: sessionStore.path).loadAll()
    XCTAssertEqual(sessions.map(\.session.sessionId), [runResult.session.sessionId])

    let supervisionRecord = URL(fileURLWithPath: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path), isDirectory: true)
      .appendingPathComponent(runResult.session.sessionId, isDirectory: true)
      .appendingPathComponent("supervision-record.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: supervisionRecord.path))
    let persistedSupervision = try decodeJSON(JSONObject.self, from: String(contentsOf: supervisionRecord, encoding: .utf8))
    XCTAssertEqual(persistedSupervision["status"], .string("cancelled"))
    XCTAssertEqual(persistedSupervision["incidents"], .array([]))
    XCTAssertEqual(persistedSupervision["remediations"], .array([]))
  }

  private func writeSingleCommandWorkflow(
    workflowDirectory: URL,
    nodesDirectory: URL,
    workflowId: String,
    executable: URL,
    argument: URL
  ) throws {
    try """
    {
      "workflowId": "\(workflowId)",
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

  private func waitForPersistedSession(sessionStore: URL, workflowName: String) async throws -> PersistedCLIWorkflowSession {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if let record = try? CLIWorkflowSessionStore(rootDirectory: sessionStore.path).loadAll().first(where: {
        $0.workflowName == workflowName
      }) {
        return record
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("timed out waiting for live persisted session")
    throw AutoImproveTestError.timedOutWaitingForSession
  }
}

private enum AutoImproveTestError: Error {
  case timedOutWaitingForSession
}
