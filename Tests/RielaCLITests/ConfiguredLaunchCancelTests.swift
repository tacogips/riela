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
    XCTAssertEqual(handler.launchConfiguredWorkflow(identity: "one", source: candidate, configuration: config, variables: [:]).status, 202)
    for _ in 0..<400 {
      if runtime.liveLaunchInventory(identity: "one").sessionIds.count == 2 && FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    let ids = runtime.liveLaunchInventory(identity: "one").sessionIds
    guard ids.count == 2 else { await runtime.shutdown(); return XCTFail("launches did not start: \(ids)") }
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
    await runtime.shutdown()
    XCTAssertTrue(runtime.liveLaunchInventory(identity: "one").sessionIds.isEmpty)
  }
}
