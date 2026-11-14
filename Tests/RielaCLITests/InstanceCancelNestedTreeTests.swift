import Foundation
import RielaCore
import RielaServer
import XCTest
@testable import RielaCLI
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private final class NestedSessionIds: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: String] = [:]
  func set(_ run: String, _ id: String) { lock.lock(); defer { lock.unlock() }; values[run] = id }
  func get(_ run: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[run] }
}

@MainActor
final class InstanceCancelNestedTreeTests: XCTestCase {
  func testConcurrentNestedTreesAreCancelledIndividually() async throws {
    #if os(Linux)
    let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
      .deletingLastPathComponent().appendingPathComponent("riela")
    #else
    let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("riela").resolvingSymlinksInPath()
    #endif
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
      throw XCTSkip("run `swift build --product riela` first")
    }
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/instance-cancel/instance-cancel-11-nested-tree-e2e/fixture-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      for run in ["A", "B"] {
        for name in ["wrapper", "nested", "inner"] {
          if let pid = try? readPID(root, "\(name)-\(run)") { _ = kill(pid, SIGKILL) }
        }
      }
      try? FileManager.default.removeItem(at: root)
    }
    let finished = expectation(description: "nested tree regression completes within 120 seconds")
    let task = Task {
      defer { finished.fulfill() }
      do { try await runConcurrentNestedTrees(binary: binary, root: root) } catch { XCTFail("nested tree regression failed: \(error)") }
    }
    defer { task.cancel() }
    await fulfillment(of: [finished], timeout: 120)
  }

  private func runConcurrentNestedTrees(binary: URL, root: URL) async throws {
    let definitions = root.appendingPathComponent("definitions")
    let store = root.appendingPathComponent("sessions")
    for run in ["A", "B"] {
      let inner = "echo $$ > \(quote(root.path + "/inner-\(run).pid")); trap 'sleep 1; exit 0' TERM; touch \(quote(root.path + "/ready-\(run)")); while :; do sleep 1; done"
      try writeWorkflow(definitions, name: "inner-\(run)", script: inner)
      let wrapper = "trap 'exit 0' TERM; echo $$ > \(quote(root.path + "/wrapper-\(run).pid")); "
        + "\(quote(binary.path)) workflow run inner-\(run) --workflow-definition-dir \(quote(definitions.path)) "
        + "--session-store \(quote(root.path + "/inner-store-\(run)")) & echo $! > \(quote(root.path + "/nested-\(run).pid")); wait"
      try writeWorkflow(definitions, name: "outer-\(run)", script: wrapper)
    }
    let registry = LiveSessionCancelRegistry()
    var server = DefaultEventLiveServer(workflowRunner: CLIEventWorkflowRunner())
    server.sessionCancelRegistry = registry
    let configured = server
    let ids = NestedSessionIds()
    let parsed = try ParsedParityOptions(["--workflow-definition-dir", definitions.path, "--session-store", store.path,
      "--working-dir", root.path])
    func launch(_ run: String) -> Task<WorkflowRunResult, Error> {
      Task { try await configured.runEventWorkflow(.init(workflowName: "outer-\(run)", runtimeVariables: [:], parsed: parsed,
        onSessionStarted: { ids.set(run, $0) })) }
    }
    let first = launch("A"), second = launch("B")
    defer { first.cancel(); second.cancel() }
    for _ in 0..<600 {
      if ["A", "B"].allSatisfy({ FileManager.default.fileExists(atPath: root.appendingPathComponent("ready-\($0)").path) && ids.get($0) != nil }) { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    let a = try XCTUnwrap(ids.get("A")), b = try XCTUnwrap(ids.get("B"))
    for run in ["A", "B"] { XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("ready-\(run)").path)) }
    let pidsA = try ["wrapper", "nested", "inner"].map { try readPID(root, "\($0)-A") }
    let pidsB = try ["wrapper", "nested", "inner"].map { try readPID(root, "\($0)-B") }
    try await cancel(first, id: a, registry: registry, pids: pidsA)
    try assertCancelled(root: root, store: store, run: "A", id: a)
    XCTAssertEqual(kill(pidsB[2], 0), 0)
    XCTAssertEqual(try CLIWorkflowSessionStore(rootDirectory: store.path).loadStrictReadOnly(sessionId: b).session.status, .running)
    try await cancel(second, id: b, registry: registry, pids: pidsB)
    try assertCancelled(root: root, store: store, run: "B", id: b)
  }

  private func cancel(_ task: Task<WorkflowRunResult, Error>, id: String, registry: LiveSessionCancelRegistry, pids: [pid_t]) async throws {
    XCTAssertEqual(registry.requestCancel(sessionId: id, reason: "dup", actor: "rielaapp-api:default"), .cancelRequested)
    do { _ = try await task.value; XCTFail("expected operator cancellation") } catch { XCTAssertTrue(error is EventOperatorCancelled, "\(error)") }
    for pid in pids { XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH, "pid \(pid) still exists") }
  }

  private func assertCancelled(root: URL, store: URL, run: String, id: String) throws {
    let session = try CLIWorkflowSessionStore(rootDirectory: store.path).loadStrictReadOnly(sessionId: id).session
    XCTAssertEqual(session.status, .cancelled)
    XCTAssertEqual(session.failureKind, .cancelled)
    XCTAssertEqual(session.failureReason, "operator_cancelled by rielaapp-api:default: dup")
    let nested = try CLIWorkflowSessionStore(rootDirectory: root.appendingPathComponent("inner-store-\(run)").path).list()
    XCTAssertEqual(nested.count, 1)
    XCTAssertEqual(nested.first?.session.status, .cancelled)
  }

  private func readPID(_ root: URL, _ name: String) throws -> pid_t {
    let text = try String(contentsOf: root.appendingPathComponent("\(name).pid"), encoding: .utf8)
    return try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
  }

  private func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

  private func writeWorkflow(_ root: URL, name: String, script: String) throws {
    let dir = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    let workflow: [String: Any] = ["workflowId": name, "entryStepId": "work", "defaults": ["nodeTimeoutMs": 300000, "maxLoopIterations": 1],
      "nodes": [["id": "work", "nodeFile": "nodes/work.json"]], "steps": [["id": "work", "nodeId": "work", "role": "worker"]]]
    let node: [String: Any] = ["id": "work", "nodeType": "command", "modelFreeze": false,
      "command": ["executable": "/bin/sh", "arguments": ["-c", script]]]
    try JSONSerialization.data(withJSONObject: workflow).write(to: dir.appendingPathComponent("workflow.json"))
    try JSONSerialization.data(withJSONObject: node).write(to: dir.appendingPathComponent("nodes/work.json"))
  }
}
