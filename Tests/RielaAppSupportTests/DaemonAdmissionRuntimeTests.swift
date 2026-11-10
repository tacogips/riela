#if os(macOS)
import Foundation
import RielaCore
import RielaServer
@testable import RielaAppSupport
import XCTest

private final class AdmissionTestHandle: WorkflowServeEventSourceHandle, @unchecked Sendable {
  var status: WorkflowServeEventSourceStatus { .init(sourceId: "fixture", status: "running", generationId: "g") }
  func shutdown() async throws {}
}
private final class AdmissionTestFactory: WorkflowServeEventSourceFactory, @unchecked Sendable {
  var fail = false
  func startEventSources(for resolvedWorkflow: WorkflowServeResolvedWorkflow, request: WorkflowServeStartRequest,
                         generationId: String) async throws -> [any WorkflowServeEventSourceHandle] {
    if fail { throw RuntimeEnvironmentError.sourceFailed }
    return [AdmissionTestHandle()]
  }
}
final class DaemonAdmissionRuntimeTests: XCTestCase {
  private func root() throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/instance-control/instance-control-06-parent-admission-runtime/fixtures/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  private func launch(_ body: String, channel: Bool = true, timeout: TimeInterval = 0.15) throws -> any RielaAppDaemonEventServeProcessHandle {
    let directory = try root()
    let script = directory.appendingPathComponent("child.py")
    try ("#!/usr/bin/python3 -u\n" + body).write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    var command = RielaAppDaemonEventServeCommand(executablePath: script.path, arguments: [], workingDirectory: directory.path, environment: [:])
    if channel { command.runtimeEnvironmentGeneration = 1 }
    return try DefaultEventServeProcessLauncher(admissionTimeoutSeconds: timeout).launch(command)
  }
  func testMatchingAckAndFrameSerialization() async throws {
    let process = try launch("""
    import sys, json
    for line in sys.stdin:
        f = json.loads(line)
        if 'generation' in f:
            print(json.dumps({'type':'runtime-environment-ack','generation':f['generation'],'names':f['managedNames'],'accepted':True}), flush=True)
        else:
            print(json.dumps({'type':'admission-ack','requestId':'other','state':'open','running':0,'queued':0}), flush=True)
            print(json.dumps({'type':'admission-ack','requestId':f['requestId'],'state':'closed','running':1,'queued':2}), flush=True)
    """, timeout: 5)
    do {
      async let environment: Void = process.updateRuntimeEnvironment(generation: 2, names: [], values: [:])
      try await Task.sleep(nanoseconds: 20_000_000)
      let ack = try await process.admissionControl(.init(type: "admission-close", requestId: "wanted"))
      try await environment
      XCTAssertEqual(ack.requestId, "wanted")
      XCTAssertEqual(ack.state, .closed)
      XCTAssertEqual(ack.running, 1)
    } catch { await process.terminate(); throw error }
    await process.terminate()
  }
  func testTimeoutUnsupportedAndExited() async throws {
    let process = try launch("import sys\nfor line in sys.stdin: pass\n")
    do { _ = try await process.admissionControl(.init(type: "admission-close", requestId: "timeout")); XCTFail("expected timeout")
    } catch { XCTAssertEqual(error as? WorkflowServeAdmissionError, .noAcknowledgement) }
    await process.terminate()
    do { _ = try await process.admissionControl(.init(type: "admission-close", requestId: "exit")); XCTFail("expected exit")
    } catch { XCTAssertEqual(error as? WorkflowServeAdmissionError, .childExited) }
    let unsupported = try launch("import time\ntime.sleep(5)\n", channel: false)
    do { _ = try await unsupported.admissionControl(.init(type: "admission-close", requestId: "unsupported")); XCTFail("expected unsupported")
    } catch { XCTAssertEqual(error as? WorkflowServeAdmissionError, .unsupported) }
    await unsupported.terminate()
  }
  @MainActor func testInstalledRecordSurvivesStopAndFailedReplacement() async throws {
    let directory = try root()
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try """
    {"workflowId":"fixture","defaults":{"nodeTimeoutMs":1000,"maxLoopIterations":1},"entryStepId":"worker",
     "nodes":[{"id":"worker","nodeFile":"nodes/worker.node.json"}],"steps":[{"id":"worker","nodeId":"worker","role":"worker"}]}
    """.write(to: directory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try #"{"id":"worker","model":"gpt-5","modelFreeze":false,"promptTemplate":"Reply"}"#.write(to: directory.appendingPathComponent("nodes/worker.node.json"), atomically: true, encoding: .utf8)
    let candidate = RielaAppDaemonWorkflowCandidate(
      id: "user-workflow:fixture", workflowId: "fixture", displayName: "fixture", sourceDescription: "fixture",
      workflowDirectory: directory.path, workingDirectory: directory.path, eventRoot: directory.appendingPathComponent(".riela-events").path,
      eventSources: [.init(id: "chat", kind: "telegram-gateway")])
    let a = RielaAppInstanceStartRecord(workflowDirectory: "A", eventRoot: nil, eventRootDigest: "a", triggerDefaultsFingerprint: "a")
    let b = RielaAppInstanceStartRecord(workflowDirectory: "B", eventRoot: nil, eventRootDigest: "b", triggerDefaultsFingerprint: "b")
    let factory = AdmissionTestFactory()
    let runtime = RielaAppDaemonWorkflowRuntime(eventSourceFactory: factory, monitorIntervalNanoseconds: 0, startRecordProvider: { _, _ in a })
    let config = WorkflowServeRuntimeConfiguration(workingDirectory: directory.path)
    let server = RielaServerConfiguration()
    let sessions = directory.appendingPathComponent("sessions").path
    await runtime.start(candidate, configuration: config, server: server, sessionStoreRoot: sessions)
    XCTAssertEqual(runtime.snapshot(for: candidate.id).status, .running)
    XCTAssertTrue(runtime.isChildRunning(identity: candidate.id))
    XCTAssertEqual(runtime.installedStartRecord(identity: candidate.id), a)
    await runtime.stop(identity: candidate.id)
    XCTAssertEqual(runtime.installedStartRecord(identity: candidate.id), a)
    runtime.setStartRecordProvider { _, _ in b }
    factory.fail = true
    _ = await runtime.replaceChild(candidate, configuration: config, server: server, sessionStoreRoot: sessions)
    XCTAssertEqual(runtime.snapshot(for: candidate.id).status, .failed)
    XCTAssertEqual(runtime.installedStartRecord(identity: candidate.id), a)
    factory.fail = false
    _ = await runtime.replaceChild(candidate, configuration: config, server: server, sessionStoreRoot: sessions)
    XCTAssertEqual(runtime.snapshot(for: candidate.id).status, .running)
    XCTAssertEqual(runtime.installedStartRecord(identity: candidate.id), b)
    runtime.setStartRecordProvider(nil)
    _ = await runtime.replaceChild(candidate, configuration: config, server: server, sessionStoreRoot: sessions)
    XCTAssertNil(runtime.installedStartRecord(identity: candidate.id))
    await runtime.stop(identity: candidate.id)
  }
}
#endif
