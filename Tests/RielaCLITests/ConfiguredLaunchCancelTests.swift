import Foundation
import RielaAppSupport
import RielaCore
import RielaServer
import RielaWorkflowRegistry
import XCTest
@testable import RielaCLI

final class ConfiguredLaunchCancelTests: XCTestCase {
  func testFirstSessionCallbackRunsOnceOutsideLock() {
    let launch = WebWorkflowLaunch(profile: "default")
    let called = expectation(description: "first session callback")
    called.assertForOverFulfill = true
    launch.onFirstSessionId = { id in
      XCTAssertEqual(id, "first")
      XCTAssertEqual(launch.snapshot["sessionId"], .string("first"))
      called.fulfill()
    }
    launch.append(#"{"sessionId":"first"}"#)
    launch.append(#"{"sessionId":"second"}"#)
    wait(for: [called], timeout: 1)
  }

  @MainActor
  func testConfiguredLaunchCancellationIsIdentityAndSessionScoped() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("tmp/instance-cancel/instance-cancel-08-app-launch-registry/fixture-\(UUID())")
    let workflow = root.appendingPathComponent("workflow")
    let store = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"""
      {"workflowId":"cancel-test","entryStepId":"work","defaults":{"nodeTimeoutMs":300000,"maxLoopIterations":1},
      "nodes":[{"id":"work","nodeFile":"nodes/work.json"}],"steps":[{"id":"work","nodeId":"work","role":"worker"}]}
      """#.utf8)
      .write(to: workflow.appendingPathComponent("workflow.json"))
    let node: [String: Any] = ["id": "work", "nodeType": "command", "modelFreeze": false,
      "command": ["executable": "/bin/sh", "arguments": ["-c", "touch ready; exec sleep 300"]]]
    try JSONSerialization.data(withJSONObject: node).write(to: workflow.appendingPathComponent("nodes/work.json"))
    let candidate = RielaAppDaemonWorkflowCandidate(id: "cancel-test", workflowId: "cancel-test", displayName: "test",
      sourceDescription: "test", workflowDirectory: workflow.path, workingDirectory: root.path, eventRoot: nil, eventSources: [])
    let context = RielaWebWorkflowContext(profile: .default, assistant: .init(), sources: [candidate], workingDirectory: root,
      appRoot: root, sessionStoreRoot: store.path, principalId: "test", environment: ["HOME": root.path])
    let runtime = RielaWebWorkflowRuntime()
    let handler = runtime.handler(context: context)
    let config = WorkflowInstanceConfiguration(workingDirectory: root.path)
    XCTAssertEqual(handler.launchConfiguredWorkflow(identity: "one", source: candidate, configuration: config, variables: [:]).status, 202)
    XCTAssertEqual(handler.launchConfiguredWorkflow(identity: "one", source: candidate, configuration: config, variables: [:], allowOverlap: true).status, 202)
    for _ in 0..<400 {
      if runtime.liveLaunchInventory(identity: "one").sessionIds.count == 2 && FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    let ids = runtime.liveLaunchInventory(identity: "one").sessionIds
    guard ids.count == 2 else { await runtime.shutdown(); return XCTFail("launches did not start: \(ids)") }
    let oldest = try XCTUnwrap(runtime.launches.values.sorted { $0.createdAt < $1.createdAt }.first)
    let busy = handler.launchConfiguredWorkflow(identity: "one", source: candidate, configuration: config, variables: [:])
    XCTAssertEqual(busy.status, 409)
    XCTAssertEqual(try JSONDecoder().decode(JSONObject.self, from: busy.body)["error"], .object([
      "code": .string("instance_busy"), "runningSessionId": try XCTUnwrap(oldest.snapshot["sessionId"])
    ]))
    XCTAssertEqual(runtime.cancelLaunch(identity: "other", sessionId: ids[0], reason: "dup", actor: "rielaapp-api:default"), .notFound)
    XCTAssertEqual(runtime.cancelLaunch(identity: "one", sessionId: "missing", reason: "dup", actor: "rielaapp-api:default"), .notFound)
    XCTAssertEqual(runtime.cancelLaunch(identity: "one", sessionId: ids[0], reason: "dup", actor: "rielaapp-api:default"), .cancelRequested)
    XCTAssertEqual(runtime.cancelLaunch(identity: "one", sessionId: ids[0], reason: "dup", actor: "rielaapp-api:default"), .alreadyRequested)
    for _ in 0..<400 {
      if !runtime.liveLaunchInventory(identity: "one").sessionIds.contains(ids[0]) { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertEqual(runtime.liveLaunchInventory(identity: "one").sessionIds, [ids[1]])
    let launch = try XCTUnwrap(runtime.launches.values.first { $0.snapshot["sessionId"] == .string(ids[0]) })
    XCTAssertEqual(Set(launch.snapshot.keys), Set(["id", "status", "sessionId", "error"]))
    XCTAssertEqual(launch.snapshot["status"], .string("failed"))
    let persisted = try CLIWorkflowSessionStore(rootDirectory: store.path).loadStrictReadOnly(sessionId: ids[0])
    XCTAssertEqual(persisted.session.status, .cancelled)
    XCTAssertEqual(persisted.session.failureReason, "operator_cancelled by rielaapp-api:default: dup")
    XCTAssertEqual(runtime.cancelLaunch(identity: "one", sessionId: ids[1], reason: "cleanup", actor: "test"), .cancelRequested)
    for _ in 0..<400 {
      if (try? CLIWorkflowSessionStore(rootDirectory: store.path).loadStrictReadOnly(sessionId: ids[1]).session.status) == .cancelled { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertEqual(try CLIWorkflowSessionStore(rootDirectory: store.path).loadStrictReadOnly(sessionId: ids[1]).session.status, .cancelled)
    XCTAssertEqual(handler.launchConfiguredWorkflow(identity: "one", source: candidate, configuration: config, variables: [:]).status, 202)
    await runtime.shutdown()
    XCTAssertTrue(runtime.liveLaunchInventory(identity: "one").sessionIds.isEmpty)
  }
  @MainActor
  func testBusyCheckIgnoresRunningLaunchWhoseSessionIsPersistedTerminal() async throws {
    for (sessionId, status, expectedStatus, blocker) in [
      ("stale-1", WorkflowSessionStatus.cancelled as WorkflowSessionStatus?, 202, ""),
      ("", nil, 409, "pending"),
      ("live-1", .running, 409, "live-1"),
      ("ghost-1", nil, 409, "ghost-1")
    ] {
      let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("tmp/instance-cancel/busy-\(UUID())")
      defer { try? FileManager.default.removeItem(at: root) }
      let workflow = root.appendingPathComponent("workflow")
      let store = root.appendingPathComponent("sessions")
      try FileManager.default.createDirectory(at: workflow.appendingPathComponent("nodes"), withIntermediateDirectories: true)
      try Data(#"""
        {"workflowId":"cancel-test","entryStepId":"work","defaults":{"nodeTimeoutMs":300000,"maxLoopIterations":1},"nodes":[{"id":"work","nodeFile":"nodes/work.json"}],
        "steps":[{"id":"work","nodeId":"work","role":"worker"}]}
        """#.utf8).write(to: workflow.appendingPathComponent("workflow.json"))
      let node: [String: Any] = ["id": "work", "nodeType": "command", "modelFreeze": false,
        "command": ["executable": "/bin/sh", "arguments": ["-c", "true"]]]
      try JSONSerialization.data(withJSONObject: node).write(to: workflow.appendingPathComponent("nodes/work.json"))
      let candidate = RielaAppDaemonWorkflowCandidate(id: "cancel-test", workflowId: "cancel-test", displayName: "test",
        sourceDescription: "test", workflowDirectory: workflow.path, workingDirectory: root.path, eventRoot: nil, eventSources: [])
      let context = RielaWebWorkflowContext(profile: .default, assistant: .init(), sources: [candidate], workingDirectory: root,
        appRoot: root, sessionStoreRoot: store.path, principalId: "test", environment: ["HOME": root.path])
      let runtime = RielaWebWorkflowRuntime()
      let stale = WebWorkflowLaunch(profile: "default", identity: "one")
      if !sessionId.isEmpty { stale.append("{\"sessionId\":\"\(sessionId)\"}") }
      runtime.launches[stale.id] = stale
      if let status {
        let now = Date()
        let session = WorkflowSession(workflowId: "cancel-test", sessionId: sessionId, status: status,
          entryStepId: "work", createdAt: now, updatedAt: now)
        try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: store.path))
          .save(WorkflowRuntimePersistenceSnapshot(session: session))
      }
      let response = runtime.handler(context: context).launchConfiguredWorkflow(identity: "one", source: candidate,
        configuration: WorkflowInstanceConfiguration(workingDirectory: root.path), variables: [:])
      XCTAssertEqual(response.status, expectedStatus, "case \(sessionId)")
      if expectedStatus == 409 {
        XCTAssertEqual(try JSONDecoder().decode(JSONObject.self, from: response.body)["error"], .object([
          "code": .string("instance_busy"), "runningSessionId": .string(blocker)
        ]))
        if sessionId.isEmpty {
          XCTAssertFalse(FileManager.default.fileExists(atPath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(
            rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: store.path))))
        }
      }
      await runtime.shutdown()
    }
  }

}
