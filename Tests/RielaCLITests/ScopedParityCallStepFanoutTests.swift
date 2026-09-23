import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

extension WorkflowCommandTests {
  func testCallStepParityOptionsAcceptSupervisorMode() throws {
    let parsed = try ParsedParityOptions(["--supervisor-mode"])
    XCTAssertTrue(parsed.supervisorMode)
  }

  func testCallStepCompletesChangeTrackedFanoutBeforeStopping() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-call-step-fanout-\(UUID().uuidString)", isDirectory: true)
    defer { removeWorkflowVersioningTestDirectory(tempDir) }

    let workflowRoot = tempDir.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("call-step-fanout", isDirectory: true)
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
    try "unchanged".write(
      to: tempDir.appendingPathComponent("tracked.txt"),
      atomically: true,
      encoding: .utf8
    )
    try """
    {
      "workflowId": "call-step-fanout",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "dispatch",
      "nodes": [
        { "id": "dispatch-node", "nodeFile": "nodes/dispatch.json" },
        { "id": "branch-node", "nodeFile": "nodes/branch.json" },
        { "id": "join-node", "nodeFile": "nodes/join.json" }
      ],
      "steps": [
        {
          "id": "dispatch",
          "nodeId": "dispatch-node",
          "role": "worker",
          "transitions": [{
            "toStepId": "branch",
            "fanout": {
              "groupId": "implementation",
              "itemsFrom": "/items",
              "itemVariable": "implementation",
              "concurrency": 1,
              "joinStepId": "join",
              "failurePolicy": "fail-fast",
              "resultOrder": "input",
              "changeTracking": { "pathsFrom": "/trackedPaths" },
              "writeOwnership": { "mode": "shared-workspace" }
            }
          }]
        },
        { "id": "branch", "nodeId": "branch-node", "role": "worker", "transitions": [{ "toStepId": "join" }] },
        { "id": "join", "nodeId": "join-node", "role": "worker" }
      ]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    for node in ["dispatch", "branch", "join"] {
      try """
      {"id":"\(node)-node","executionBackend":"codex-agent","model":"gpt-5.5","modelFreeze":false,"variables":{}}
      """.write(to: nodesDirectory.appendingPathComponent("\(node).json"), atomically: true, encoding: .utf8)
    }

    let scenario = tempDir.appendingPathComponent("scenario.json")
    try """
    {
      "dispatch": {
        "provider": "scenario-mock",
        "model": "gpt-5.5",
        "payload": { "items": [{ "planId": "p1", "trackedPaths": ["tracked.txt"] }] }
      },
      "branch": { "provider": "scenario-mock", "model": "gpt-5.5", "payload": { "status": "implemented" } },
      "join": { "provider": "scenario-mock", "model": "gpt-5.5", "payload": { "status": "joined" } }
    }
    """.write(to: scenario, atomically: true, encoding: .utf8)

    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)
    let session = WorkflowSession(
      workflowId: "call-step-fanout",
      sessionId: "call-step-fanout-run",
      status: .running,
      entryStepId: "dispatch",
      currentStepId: "dispatch",
      createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 0)
    )
    try CLIWorkflowSessionStore(rootDirectory: sessionStore.path).save(PersistedCLIWorkflowSession(
      workflowName: "call-step-fanout",
      session: session,
      resolution: WorkflowResolutionOptions(
        workflowName: "call-step-fanout",
        scope: .direct,
        workflowDefinitionDir: workflowRoot.path,
        workingDirectory: tempDir.path
      ),
      mockScenarioPath: scenario.path
    ))
    try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
    ).save(WorkflowRuntimePersistenceProjector.snapshot(session: session))

    let result = await RielaCLIApplication().run([
      "call-step", "call-step-fanout", session.sessionId, "dispatch",
      "--workflow-definition-dir", workflowRoot.path,
      "--working-dir", tempDir.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])

    guard result.exitCode == .success else {
      return XCTFail("call-step failed: stdout=\(result.stdout) stderr=\(result.stderr)")
    }
    XCTAssertFalse(result.stderr.contains("fanoutWorkspaceRoot"), result.stderr)
    let run = try decodeJSON(WorkflowRunResult.self, from: result.stdout)
    XCTAssertEqual(run.session.sessionId, session.sessionId)
    XCTAssertEqual(run.exitCode, 0)
    XCTAssertEqual(run.status, .running)
    XCTAssertEqual(run.session.executions.first?.stepId, "dispatch")
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
    ).load(sessionId: session.sessionId)
    XCTAssertEqual(snapshot.session.currentStepId, "join")
    XCTAssertTrue(snapshot.workflowMessages.contains { message in
      guard case let .object(join)? = message.payload["fanoutJoin"] else { return false }
      return join["groupId"] == .string("implementation")
    })
  }
}
