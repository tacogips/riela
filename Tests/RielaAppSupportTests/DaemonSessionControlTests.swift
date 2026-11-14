#if os(macOS)
import Foundation
import RielaCore
import RielaServer
@testable import RielaAppSupport
import XCTest

private final class SessionHandle: WorkflowServeEventSourceHandle, @unchecked Sendable {
  let id: String
  let outcome: WorkflowServeSessionCancelOutcome
  let pending: Int
  init(_ id: String, _ outcome: WorkflowServeSessionCancelOutcome, _ pending: Int) {
    self.id = id
    self.outcome = outcome
    self.pending = pending
  }
  var status: WorkflowServeEventSourceStatus { .init(sourceId: id, status: "running", generationId: "g") }
  func shutdown() async throws {}
  func sessionControl(_ frame: WorkflowServeSessionControlFrame) async throws -> WorkflowServeSessionControlAcknowledgement {
    if frame.type == "session-list" { return .listAck(requestId: frame.requestId, sessionIds: [id], pendingRunCount: pending) }
    return .cancelAck(requestId: frame.requestId, sessionId: frame.sessionId ?? "", outcome: outcome)
  }
}
private final class SessionFactory: WorkflowServeEventSourceFactory, @unchecked Sendable {
  func startEventSources(for resolvedWorkflow: WorkflowServeResolvedWorkflow, request: WorkflowServeStartRequest,
                         generationId: String) async throws -> [any WorkflowServeEventSourceHandle] {
    [SessionHandle("b", .notFound, 1), SessionHandle("a", .cancelRequested, 0)]
  }
}
final class DaemonSessionControlTests: XCTestCase {
  private func root() throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/instance-cancel/instance-cancel-07-app-child-channel/fixture-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  @MainActor func testRuntimeForwardingAndAggregation() async throws {
    let directory = try root()
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try """
    {"workflowId":"fixture","defaults":{"nodeTimeoutMs":1000,"maxLoopIterations":1},"entryStepId":"worker",
     "nodes":[{"id":"worker","nodeFile":"nodes/worker.node.json"}],"steps":[{"id":"worker","nodeId":"worker","role":"worker"}]}
    """.write(to: directory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try #"{"id":"worker","model":"gpt-5","modelFreeze":false,"promptTemplate":"Reply"}"#.write(
      to: directory.appendingPathComponent("nodes/worker.node.json"), atomically: true, encoding: .utf8)
    let candidate = RielaAppDaemonWorkflowCandidate(
      id: "user-workflow:fixture", workflowId: "fixture", displayName: "fixture", sourceDescription: "fixture",
      workflowDirectory: directory.path, workingDirectory: directory.path, eventRoot: directory.appendingPathComponent(".riela-events").path,
      eventSources: [.init(id: "chat", kind: "telegram-gateway")])
    let runtime = RielaAppDaemonWorkflowRuntime(eventSourceFactory: SessionFactory(), monitorIntervalNanoseconds: 0)
    await runtime.start(candidate, configuration: .init(workingDirectory: directory.path), server: .init(),
                        sessionStoreRoot: directory.appendingPathComponent("sessions").path)
    let cancel = try await runtime.sessionControl(identity: candidate.id, frame: .init(type: "session-cancel", requestId: "c", sessionId: "s"))
    XCTAssertEqual(cancel.outcome, .cancelRequested)
    let list = try await runtime.sessionControl(identity: candidate.id, frame: .init(type: "session-list", requestId: "l"))
    XCTAssertEqual(list.sessionIds, ["a", "b"])
    XCTAssertEqual(list.pendingRunCount, 1)
    await runtime.stop(identity: candidate.id)
    do {
      _ = try await runtime.sessionControl(identity: "unknown", frame: .init(type: "session-list", requestId: "x"))
      XCTFail("expected childExited")
    } catch { XCTAssertEqual(error as? WorkflowServeSessionControlError, .childExited) }
  }
  func testUnsupportedAndNoGeneration() async throws {
    let frame = WorkflowServeSessionControlFrame(type: "session-list", requestId: "x")
    do {
      _ = try await InProcessWorkflowServeEventSourceHandle(status: .init(sourceId: "a", status: "running", generationId: "g"))
        .sessionControl(frame)
      XCTFail("expected unsupported")
    } catch { XCTAssertEqual(error as? WorkflowServeSessionControlError, .unsupported) }
    do {
      _ = try await WorkflowServingController().sessionControl(frame)
      XCTFail("expected childExited")
    } catch { XCTAssertEqual(error as? WorkflowServeSessionControlError, .childExited) }
  }
  func testMixedAcknowledgements() async throws {
    let directory = try root()
    let script = directory.appendingPathComponent("child.py")
    try """
    #!/usr/bin/python3 -u
    import sys, json
    for line in sys.stdin:
        f = json.loads(line)
        if f['type'] == 'session-list':
            session = {'type':'session-list-ack','requestId':f['requestId'],'sessionIds':['a'],'pendingRunCount':1}
            admission = {'type':'admission-ack','requestId':'adm','state':'closed','running':1,'queued':0}
            sys.stdout.write(json.dumps(session) + '\\n' + json.dumps(admission) + '\\n')
            sys.stdout.flush()
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    var command = RielaAppDaemonEventServeCommand(executablePath: script.path, arguments: [], workingDirectory: directory.path, environment: [:])
    command.runtimeEnvironmentGeneration = 1
    let process = try DefaultEventServeProcessLauncher(admissionTimeoutSeconds: 5).launch(command)
    do {
      let session = try await process.sessionControl(.init(type: "session-list", requestId: "session"))
      let admission = try await process.admissionControl(.init(type: "admission-close", requestId: "adm"))
      XCTAssertEqual(session.sessionIds, ["a"])
      XCTAssertEqual(admission.state, .closed)
    } catch { await process.terminate(); throw error }
    await process.terminate()
  }
}
#endif
