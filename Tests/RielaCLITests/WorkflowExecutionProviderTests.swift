import Foundation
import RielaCore
import RielaGraphQL
import RielaSQLite
import XCTest
@testable import RielaCLI

final class WorkflowExecutionProviderTests: XCTestCase {
  func testInvalidPatchAndMismatchedSavedInstanceRejectBeforeNodeOrSession() async throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/native-remote-implementation/NRE-03/preflight-\(UUID().uuidString)")
    let workflow = root.appendingPathComponent(".riela/workflows/preflight-run")
    let store = root.appendingPathComponent("sessions")
    let effect = root.appendingPathComponent("invoked")
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"""
      {"workflowId":"preflight-run","entryStepId":"work",
       "defaults":{"nodeTimeoutMs":30000,"maxLoopIterations":1},
       "nodes":[{"id":"work","nodeFile":"nodes/work.json"}],
       "steps":[{"id":"work","nodeId":"work","role":"worker"}]}
      """#.utf8).write(to: workflow.appendingPathComponent("workflow.json"))
    let node: [String: Any] = [
      "id": "work", "nodeType": "command", "modelFreeze": false,
      "command": ["executable": "/usr/bin/touch", "arguments": [effect.path]]
    ]
    try JSONSerialization.data(withJSONObject: node).write(to: workflow.appendingPathComponent("nodes/work.json"))
    let provider = WorkflowExecutionProvider(
      workingDirectory: root.path, sessionStoreRoot: store.path,
      environment: ["HOME": root.path]
    )
    try FileWorkflowInstanceStore(rootDirectory: root.appendingPathComponent(".riela").path)
      .save(WorkflowInstanceDefinition(identity: "prod", workflowId: "other-workflow"))

    for input in [
      GraphQLExecuteWorkflowInput(
        workflowName: "preflight-run", nodePatch: ["work": .object(["unsupported": .bool(true)])]
      ),
      GraphQLExecuteWorkflowInput(workflowName: "preflight-run", instanceIdentity: "prod")
    ] {
      do {
        _ = try await provider.executeWorkflow(input)
        XCTFail("pre-session rejection must not return execution IDs")
      } catch WorkflowExecutionProviderError.runFailed { }
      XCTAssertFalse(FileManager.default.fileExists(atPath: effect.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
    }
    let deactivation = await RielaCLIApplication().run([
      "workflow", "deactivate", "preflight-run", "--scope", "user", "--output", "json"
    ], environment: ["HOME": root.path])
    XCTAssertEqual(deactivation.exitCode, .success, deactivation.stdout + deactivation.stderr)
    do {
      _ = try await provider.executeWorkflow(GraphQLExecuteWorkflowInput(workflowName: "preflight-run"))
      XCTFail("deactivated workflow must reject before a session starts")
    } catch WorkflowExecutionProviderError.runFailed { }
    XCTAssertFalse(FileManager.default.fileExists(atPath: effect.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
  }

  func testRealRunnerCompletedAndStepBudgetFailureAgreeWithPersistence() async throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/native-remote-implementation/NRE-03/real-\(UUID().uuidString)")
    let workflow = root.appendingPathComponent(".riela/workflows/provider-run")
    let sessionRoot = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"""
      {"workflowId":"provider-run","entryStepId":"first",
       "defaults":{"nodeTimeoutMs":30000,"maxLoopIterations":1},
       "nodes":[{"id":"first","nodeFile":"nodes/first.json"},{"id":"last","nodeFile":"nodes/last.json"}],
       "steps":[
         {"id":"first","nodeId":"first","role":"worker","transitions":[{"toStepId":"last"}]},
         {"id":"last","nodeId":"last","role":"worker"}]}
      """#.utf8).write(to: workflow.appendingPathComponent("workflow.json"))
    for name in ["first", "last"] {
      let node: [String: Any] = [
        "id": name, "nodeType": "command", "modelFreeze": false,
        "command": ["executable": "/bin/echo", "arguments": ["{\"ok\":true}"]]
      ]
      try JSONSerialization.data(withJSONObject: node)
        .write(to: workflow.appendingPathComponent("nodes/\(name).json"))
    }
    let provider = WorkflowExecutionProvider(
      workingDirectory: root.path, sessionStoreRoot: sessionRoot.path,
      environment: ["HOME": root.path]
    )
    let fresh = WorkflowExecutionProvider(
      workingDirectory: root.path, sessionStoreRoot: sessionRoot.path,
      environment: ["HOME": root.path]
    )
    for (limit, expectedStatus) in [(3, WorkflowSessionStatus.completed), (1, .failed)] {
      let result = try await provider.executeWorkflow(GraphQLExecuteWorkflowInput(
        workflowName: "provider-run", maxSteps: limit
      ))
      XCTAssertEqual(result.workflowExecutionId, result.sessionId)
      XCTAssertEqual(result.status, expectedStatus.rawValue)
      XCTAssertEqual(result.exitCode == 0, expectedStatus == .completed)
      let record = try CLIWorkflowSessionStore(rootDirectory: sessionRoot.path)
        .loadStrictReadOnly(sessionId: result.sessionId)
      let snapshot = try SQLiteWorkflowRuntimePersistenceStore(
        rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionRoot.path)
      ).loadStrictReadOnly(sessionId: result.sessionId)
      XCTAssertEqual(record.session.status, expectedStatus)
      XCTAssertEqual(snapshot.session.status, expectedStatus)
      XCTAssertEqual(snapshot.session.workflowId, "provider-run")
      if expectedStatus == .failed {
        XCTAssertEqual(snapshot.session.failureKind, .maxStepsExceeded)
      }
      let summary = try await fresh.workflowExecution(workflowExecutionId: result.sessionId)
      XCTAssertEqual(summary?.session.workflowName, "provider-run")
      XCTAssertEqual(summary?.session.workflowId, "provider-run")
      XCTAssertEqual(summary?.nodeExecutions.count, snapshot.session.executions.count)
      XCTAssertEqual(summary?.session.transitions.count, snapshot.workflowMessages.count)
    }
  }

  func testInjectedCommandContradictionsFailClosedInBothDecodeBranches() async throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/native-remote-implementation/NRE-03/contradiction-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = WorkflowSession(
      workflowId: "recorded-workflow", sessionId: "recorded-session", status: .completed,
      entryStepId: "work", createdAt: Date(timeIntervalSince1970: 1_000),
      updatedAt: Date(timeIntervalSince1970: 1_000)
    )
    try CLIWorkflowSessionStore(rootDirectory: root.path).save(
      PersistedCLIWorkflowSession(
        workflowName: "missing-workflow", session: session,
        resolution: WorkflowResolutionOptions(workflowName: "missing-workflow", workingDirectory: root.path)
      ),
      runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: session)
    )
    var failedSession = session
    failedSession.status = .failed
    let fakeRun = WorkflowRunResult(
      workflowId: "recorded-workflow", session: failedSession,
      rootOutput: nil, exitCode: 1, transitions: 0
    )
    let fakeFailure = WorkflowRunFailureResult(
      target: "missing-workflow", exitCode: 1, error: "injected failure",
      sessionId: session.sessionId
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    for injected in [fakeRun as any Encodable, fakeFailure as any Encodable] {
      let output = try XCTUnwrap(String(bytes: encoder.encode(injected), encoding: .utf8))
      var provider = WorkflowExecutionProvider(
        workingDirectory: root.path, sessionStoreRoot: root.path,
        environment: ["HOME": root.path]
      )
      provider.testCommandResultOverride = { _ in CLICommandResult(exitCode: .failure, stdout: output) }
      do {
        _ = try await provider.executeWorkflow(GraphQLExecuteWorkflowInput(workflowName: "missing-workflow"))
        XCTFail("injected command status must not override completed persistence")
      } catch WorkflowExecutionProviderError.persistenceFailed { }
    }
  }

  func testMissingWorkflowFailsBeforeSessionCreation() async throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/native-remote-implementation/NRE-03/missing-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = root.appendingPathComponent("sessions")
    let provider = WorkflowExecutionProvider(
      workingDirectory: root.path, sessionStoreRoot: store.path,
      environment: ["HOME": root.path]
    )
    do {
      _ = try await provider.executeWorkflow(GraphQLExecuteWorkflowInput(workflowName: "missing-workflow"))
      XCTFail("a pre-session failure must not return invented execution IDs")
    } catch WorkflowExecutionProviderError.runFailed { }
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
  }

  func testPostNodeRecordWriteFailureCannotReturnExecutionIDs() async throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/native-remote-implementation/NRE-03/write-failure-\(UUID().uuidString)")
    let workflow = root.appendingPathComponent(".riela/workflows/write-failure")
    let store = root.appendingPathComponent("sessions")
    let effect = root.appendingPathComponent("invoked")
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"""
      {"workflowId":"write-failure","entryStepId":"work",
       "defaults":{"nodeTimeoutMs":30000,"maxLoopIterations":1},
       "nodes":[{"id":"work","nodeFile":"nodes/work.json"}],
       "steps":[{"id":"work","nodeId":"work","role":"worker"}]}
      """#.utf8).write(to: workflow.appendingPathComponent("workflow.json"))
    let databasePath = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: store.path)
    let node: [String: Any] = [
      "id": "work", "nodeType": "command", "modelFreeze": false,
      "command": [
        "executable": "/bin/sh",
        "arguments": [
          "-c", "touch \"$1\"; rm -f \"$2\"; mkdir \"$2\"; printf '{\"ok\":true}\\n'",
          "work", effect.path, databasePath
        ]
      ]
    ]
    try JSONSerialization.data(withJSONObject: node).write(to: workflow.appendingPathComponent("nodes/work.json"))
    let provider = WorkflowExecutionProvider(
      workingDirectory: root.path, sessionStoreRoot: store.path,
      environment: ["HOME": root.path]
    )
    do {
      _ = try await provider.executeWorkflow(GraphQLExecuteWorkflowInput(workflowName: "write-failure"))
      XCTFail("post-node persistence failure must not return execution IDs")
    } catch { }
    XCTAssertTrue(FileManager.default.fileExists(atPath: effect.path))
    var isDirectory: ObjCBool = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: databasePath, isDirectory: &isDirectory))
    XCTAssertTrue(isDirectory.boolValue)
  }

  func testStrictSummaryDistinguishesAbsentValidMissingRuntimeMismatchAndCorruptRecord() async throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/native-remote-implementation/NRE-03/provider-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    let provider = WorkflowExecutionProvider(
      workingDirectory: root.path, sessionStoreRoot: root.path,
      environment: ["HOME": root.path]
    )
    let initiallyAbsent = try await provider.workflowExecution(workflowExecutionId: "absent-session")
    XCTAssertNil(initiallyAbsent)
    XCTAssertFalse(FileManager.default.fileExists(atPath: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path)))

    let date = Date(timeIntervalSince1970: 1_000)
    let session = WorkflowSession(
      workflowId: "fixture-workflow", sessionId: "valid-session", status: .completed,
      entryStepId: "work", createdAt: date, updatedAt: date
    )
    let record = PersistedCLIWorkflowSession(
      workflowName: "fixture-name", session: session,
      resolution: WorkflowResolutionOptions(workflowName: "fixture-name", workingDirectory: root.path)
    )
    try store.save(record, runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: session))
    let validValue = try await provider.workflowExecution(workflowExecutionId: "valid-session")
    let valid = try XCTUnwrap(validValue)
    XCTAssertEqual(valid.session.workflowName, "fixture-name")
    XCTAssertEqual(valid.session.workflowId, "fixture-workflow")
    XCTAssertTrue(valid.session.transitions.isEmpty)
    XCTAssertTrue(valid.nodeExecutions.isEmpty)

    var statusMismatch = record
    statusMismatch.session.status = .failed
    try store.save(statusMismatch)
    do {
      _ = try await provider.workflowExecution(workflowExecutionId: "valid-session")
      XCTFail("CLI and runtime status mismatch must be rejected")
    } catch WorkflowExecutionProviderError.persistenceFailed { }
    try store.save(record)

    var missing = record
    missing.session.sessionId = "missing-runtime"
    try store.save(missing)
    do {
      _ = try await provider.workflowExecution(workflowExecutionId: "missing-runtime")
      XCTFail("missing runtime snapshot must be an execution error")
    } catch CLIWorkflowSessionStoreError.notFound {
      XCTFail("existing CLI record must not be classified as absent")
    } catch { }

    var mismatched = record
    mismatched.session.workflowId = "other-workflow"
    try store.save(mismatched)
    do {
      _ = try await provider.workflowExecution(workflowExecutionId: "valid-session")
      XCTFail("workflow identity mismatch must be rejected")
    } catch WorkflowExecutionProviderError.persistenceFailed { }

    let database = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path))
    try database.execute(
      "UPDATE cli_workflow_sessions SET record_json = jsonb(?) WHERE session_id = ?",
      bindings: [
        .text(#"{"workflowName":"fixture-name","session":{"workflowId":"fixture-workflow","status":"completed"}}"#),
        .text("valid-session")
      ]
    )
    do {
      _ = try await provider.workflowExecution(workflowExecutionId: "valid-session")
      XCTFail("corrupt CLI record must be an execution error")
    } catch CLIWorkflowSessionStoreError.sqliteFailed { }
    let malformedRoot = root.appendingPathComponent("malformed-store")
    try FileManager.default.createDirectory(at: malformedRoot, withIntermediateDirectories: true)
    let malformedDatabase = try SQLiteDatabase.open(
      path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: malformedRoot.path)
    )
    try malformedDatabase.execute("CREATE TABLE cli_workflow_sessions (session_id TEXT, record_json TEXT)")
    try malformedDatabase.execute(
      "INSERT INTO cli_workflow_sessions (session_id, record_json) VALUES (?, ?)",
      bindings: [.text("malformed-session"), .text("{")]
    )
    let malformedProvider = WorkflowExecutionProvider(
      workingDirectory: root.path, sessionStoreRoot: malformedRoot.path,
      environment: ["HOME": root.path]
    )
    do {
      _ = try await malformedProvider.workflowExecution(workflowExecutionId: "malformed-session")
      XCTFail("malformed stored JSON must be an execution error")
    } catch CLIWorkflowSessionStoreError.sqliteFailed { }
    let stillAbsent = try await provider.workflowExecution(workflowExecutionId: "absent-session")
    XCTAssertNil(stillAbsent)
    try database.execute("ALTER TABLE cli_workflow_sessions RENAME COLUMN record_json TO invalid_json")
    do {
      _ = try await provider.workflowExecution(workflowExecutionId: "valid-session")
      XCTFail("SQLite query failure must not return null")
    } catch CLIWorkflowSessionStoreError.sqliteFailed { }
  }

  func testSummaryUsesPersistedOrderAndOnlyRequestedSessionMessages() async throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/native-remote-implementation/NRE-03/order-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let date = Date(timeIntervalSince1970: 1_000)
    var session = WorkflowSession(
      workflowId: "ordered-workflow", sessionId: "ordered-session", status: .completed,
      entryStepId: "work", createdAt: date, updatedAt: date
    )
    session.executions = [
      WorkflowStepExecution(executionId: "node-b", stepId: "work", nodeId: "work", attempt: 1, createdAt: date, updatedAt: date),
      WorkflowStepExecution(executionId: "node-a", stepId: "next", nodeId: "next", attempt: 1, createdAt: date, updatedAt: date)
    ]
    let messages = [
      WorkflowMessageRecord(
        communicationId: "later", workflowExecutionId: session.sessionId, fromStepId: "work",
        toStepId: "next", sourceStepExecutionId: "node-b", transitionCondition: "later",
        payload: [:], createdOrder: 3, createdAt: date
      ),
      WorkflowMessageRecord(
        communicationId: "foreign", workflowExecutionId: "callee-session", fromStepId: "work",
        toStepId: "callee", routingScope: .root, sourceStepExecutionId: "node-b",
        transitionCondition: "foreign", payload: [:], createdOrder: 2, createdAt: date
      ),
      WorkflowMessageRecord(
        communicationId: "earlier", workflowExecutionId: session.sessionId, fromStepId: "work",
        toStepId: "next", sourceStepExecutionId: "node-b", transitionCondition: "earlier",
        payload: [:], createdOrder: 1, createdAt: date
      )
    ]
    try CLIWorkflowSessionStore(rootDirectory: root.path).save(
      PersistedCLIWorkflowSession(
        workflowName: "ordered-name", session: session,
        resolution: WorkflowResolutionOptions(workflowName: "ordered-name", workingDirectory: root.path)
      ),
      runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: session, workflowMessages: messages)
    )
    let fresh = WorkflowExecutionProvider(
      workingDirectory: root.path, sessionStoreRoot: root.path,
      environment: ["HOME": root.path]
    )
    let loaded = try await fresh.workflowExecution(workflowExecutionId: session.sessionId)
    let summary = try XCTUnwrap(loaded)
    XCTAssertEqual(summary.session.workflowName, "ordered-name")
    XCTAssertEqual(summary.nodeExecutions.map(\.nodeExecId), ["node-b", "node-a"])
    XCTAssertEqual(summary.session.transitions.map(\.when), ["earlier", "later"])
    XCTAssertEqual(try CLIWorkflowSessionStore(rootDirectory: root.path)
      .loadStrictReadOnly(sessionId: session.sessionId).session, session)
  }

  func testRealCrossWorkflowSummaryUsesParentPersistedArrays() async throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/native-remote-implementation/NRE-03/cross-\(UUID().uuidString)")
    let workflowRoot = root.appendingPathComponent(".riela/workflows")
    let store = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: workflowRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["workflow-call-live-echo", "workflow-call-live-echo-callee"] {
      try FileManager.default.copyItem(
        at: repository.appendingPathComponent("examples/\(name)"),
        to: workflowRoot.appendingPathComponent(name)
      )
    }
    let provider = WorkflowExecutionProvider(
      workingDirectory: root.path, sessionStoreRoot: store.path,
      environment: ["HOME": root.path]
    )
    let result = try await provider.executeWorkflow(GraphQLExecuteWorkflowInput(
      workflowName: "workflow-call-live-echo"
    ))
    XCTAssertEqual(result.status, WorkflowSessionStatus.completed.rawValue)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: store.path)
    ).loadStrictReadOnly(sessionId: result.sessionId)
    let fresh = WorkflowExecutionProvider(
      workingDirectory: root.path, sessionStoreRoot: store.path,
      environment: ["HOME": root.path]
    )
    let loaded = try await fresh.workflowExecution(workflowExecutionId: result.sessionId)
    let summary = try XCTUnwrap(loaded)
    XCTAssertEqual(summary.nodeExecutions.map(\.nodeExecId), snapshot.session.executions.map(\.executionId))
    XCTAssertEqual(
      summary.session.transitions.map(\.when),
      snapshot.workflowMessages.filter { $0.workflowExecutionId == result.sessionId }
        .sorted { $0.createdOrder < $1.createdOrder }.map(\.transitionCondition)
    )
    XCTAssertGreaterThan(summary.session.transitions.count, 0)
    XCTAssertEqual(snapshot.session.executions.map(\.stepId), ["produce-request", "apply-result"])
  }
}
