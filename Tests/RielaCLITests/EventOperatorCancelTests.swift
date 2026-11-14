import Foundation
import RielaCore
import RielaServer
@testable import RielaCLI
import XCTest

private struct CancelTestRunner: EventWorkflowRunning {
  func runWorkflow(_ request: EventWorkflowRunRequest) async throws -> WorkflowRunResult {
    request.onSessionStarted?(request.workflowName)
    try await Task.sleep(for: .seconds(10))
    throw CancelTestError.expected
  }
}

private enum CancelTestError: Error { case expected }

private struct ReasonTestRunner: EventWorkflowRunning {
  func runWorkflow(_ request: EventWorkflowRunRequest) async throws -> WorkflowRunResult {
    request.onSessionStarted?(request.workflowName)
    XCTAssertEqual(request.operatorCancellation?.failureReason, "operator_cancelled by test: stop")
    try await Task.sleep(for: .seconds(10))
    throw CancelTestError.expected
  }
}

final class EventOperatorCancelTests: XCTestCase {
  func testUnaffectedConcurrentRunCompletes() async throws {
    let registry = LiveSessionCancelRegistry()
    let runner = BlockingCronRunner()
    var server = DefaultEventLiveServer(workflowRunner: runner)
    server.sessionCancelRegistry = registry
    let configured = server
    let request = EventWorkflowRunRequest(workflowName: "flow", runtimeVariables: [:], parsed: try ParsedParityOptions([]))
    let first = Task { try await configured.runEventWorkflow(request) }
    for _ in 0..<10000 {
      if await runner.waitingCount == 1 { break }
      await Task.yield()
    }
    let second = Task { try await configured.runEventWorkflow(request) }
    for _ in 0..<10000 {
      if await runner.waitingCount == 2 { break }
      await Task.yield()
    }
    XCTAssertEqual(registry.liveSnapshot().sessionIds, ["session-1", "session-2"])
    XCTAssertEqual(registry.requestCancel(sessionId: "session-1", reason: "stop", actor: "test"), .cancelRequested)
    do { _ = try await first.value; XCTFail("expected cancellation") } catch {
      XCTAssertTrue(error is EventOperatorCancelled)
    }
    XCTAssertEqual(registry.liveSnapshot().sessionIds, ["session-2"])
    await runner.release(index: 1)
    let result = try await second.value
    XCTAssertEqual(result.session.status, .completed)
    XCTAssertTrue(registry.liveSnapshot().sessionIds.isEmpty)
  }

  func testNoRegistryReturnsSuccessfulResult() async throws {
    let runner = BlockingCronRunner()
    let server = DefaultEventLiveServer(workflowRunner: runner)
    let request = EventWorkflowRunRequest(workflowName: "flow", runtimeVariables: [:], parsed: try ParsedParityOptions([]))
    let run = Task { try await server.runEventWorkflow(request) }
    for _ in 0..<10000 {
      if await runner.waitingCount == 1 { break }
      await Task.yield()
    }
    await runner.release(index: 0)
    let result = try await run.value
    XCTAssertEqual(result.session.status, .completed)
    XCTAssertEqual(result.session.sessionId, "session-1")
  }

  func testCancellationReasonVisibleToRunner() async throws {
    let registry = LiveSessionCancelRegistry()
    var server = DefaultEventLiveServer(workflowRunner: ReasonTestRunner())
    server.sessionCancelRegistry = registry
    let request = EventWorkflowRunRequest(workflowName: "reason", runtimeVariables: [:], parsed: try ParsedParityOptions([]),
      onSessionStarted: { id in _ = registry.requestCancel(sessionId: id, reason: "stop", actor: "test") })
    do { _ = try await server.runEventWorkflow(request); XCTFail("expected cancellation") } catch {
      XCTAssertTrue(error is EventOperatorCancelled)
    }
  }

  func testLateCancellationPreservesSuccessfulResult() async throws {
    let registry = LiveSessionCancelRegistry()
    let runner = BlockingCronRunner(ignoresCancellation: true)
    var server = DefaultEventLiveServer(workflowRunner: runner)
    server.sessionCancelRegistry = registry
    let configured = server
    let request = EventWorkflowRunRequest(workflowName: "late", runtimeVariables: [:], parsed: try ParsedParityOptions([]))
    let run = Task { try await configured.runEventWorkflow(request) }
    for _ in 0..<10000 {
      if await runner.waitingCount == 1 { break }
      await Task.yield()
    }
    XCTAssertEqual(registry.requestCancel(sessionId: "session-1", reason: "stop", actor: "test"), .cancelRequested)
    await runner.release(index: 0)
    let result = try await run.value
    XCTAssertEqual(result.session.status, .completed)
    XCTAssertTrue(registry.liveSnapshot().sessionIds.isEmpty)
  }

  func testIndividualCancelAndAdmissionRelease() async throws {
    let registry = LiveSessionCancelRegistry()
    let gate = EventAdmissionGate(clock: ManualEventServeClock())
    var server = DefaultEventLiveServer(workflowRunner: CancelTestRunner())
    server.sessionCancelRegistry = registry
    server.admissionGate = gate
    let configured = server
    let parsed = try ParsedParityOptions([])
    let first = Task { try await configured.runEventWorkflow(.init(workflowName: "s1", runtimeVariables: [:], parsed: parsed)) }
    let second = Task { try await configured.runEventWorkflow(.init(workflowName: "s2", runtimeVariables: [:], parsed: parsed)) }
    for _ in 0..<10000 {
      if registry.liveSnapshot().sessionIds.count == 2 { break }
      await Task.yield()
    }
    XCTAssertEqual(registry.liveSnapshot().sessionIds, ["s1", "s2"])
    XCTAssertEqual(registry.requestCancel(sessionId: "s1", reason: "stop", actor: "test"), .cancelRequested)
    do { _ = try await first.value; XCTFail("expected cancellation") } catch let error as EventOperatorCancelled {
      XCTAssertEqual(error.sessionId, "s1")
    }
    XCTAssertEqual(registry.liveSnapshot().sessionIds, ["s2"])
    second.cancel()
    do { _ = try await second.value; XCTFail("expected cancellation") } catch {
      XCTAssertFalse(error is EventOperatorCancelled)
    }
    XCTAssertTrue(registry.liveSnapshot().sessionIds.isEmpty)
    XCTAssertEqual(registry.liveSnapshot().pendingRunCount, 0)
    let closed = await gate.close(requestId: "check", leaseSeconds: 10)
    XCTAssertEqual(closed.running, 0)
  }

  func testControlChannelAcknowledgements() async throws {
    let input = Pipe(), output = Pipe()
    let registry = LiveSessionCancelRegistry()
    registry.beginRun()
    registry.beginRun()
    registry.register(sessionId: "live", cancellation: OperatorCancellation(), cancel: {})
    let gate = EventAdmissionGate(clock: ManualEventServeClock())
    let state = EventRuntimeEnvironment(base: [:])
    let channel = RuntimeEnvironmentChannel(state: state, input: input.fileHandleForReading,
      output: output.fileHandleForWriting, admissionGate: gate, sessionRegistry: registry)
    defer { channel.stop() }
    func exchange(_ frame: WorkflowServeSessionControlFrame) throws -> WorkflowServeSessionControlAcknowledgement {
      try input.fileHandleForWriting.write(contentsOf: frame.encodedLine())
      return try JSONDecoder().decode(WorkflowServeSessionControlAcknowledgement.self, from: output.fileHandleForReading.availableData)
    }
    let list = try exchange(.init(type: "session-list", requestId: "list"))
    XCTAssertEqual(list.sessionIds, ["live"])
    XCTAssertEqual(list.pendingRunCount, 1)
    let cancel = try exchange(.init(type: "session-cancel", requestId: "cancel", sessionId: "live", reason: "stop", actor: "test"))
    XCTAssertEqual(cancel.outcome, .cancelRequested)
    let missing = try exchange(.init(type: "session-cancel", requestId: "missing", sessionId: "missing", reason: "stop", actor: "test"))
    XCTAssertEqual(missing.outcome, .notFound)
    let admission = WorkflowServeAdmissionFrame(type: "admission-close", requestId: "admission", leaseSeconds: 120)
    try input.fileHandleForWriting.write(contentsOf: admission.encodedLine())
    let admissionAck = try XCTUnwrap(WorkflowServeAdmissionAcknowledgement.decodeLine(output.fileHandleForReading.availableData))
    XCTAssertEqual(admissionAck.state, .closed)
    let environment = try JSONSerialization.data(withJSONObject: ["generation": 1, "managedNames": ["KEY"], "values": ["KEY": "value"]])
    try input.fileHandleForWriting.write(contentsOf: environment + Data([10]))
    let environmentAck = try JSONDecoder().decode(RuntimeEnvironmentAcknowledgement.self, from: output.fileHandleForReading.availableData)
    XCTAssertTrue(environmentAck.accepted)
    let snapshot = try await state.capture()
    XCTAssertEqual(snapshot["KEY"], "value")
  }

  func testControlChannelWithoutRegistry() throws {
    let input = Pipe(), output = Pipe()
    let channel = RuntimeEnvironmentChannel(state: EventRuntimeEnvironment(base: [:]), input: input.fileHandleForReading,
      output: output.fileHandleForWriting)
    defer { channel.stop() }
    func exchange(_ frame: WorkflowServeSessionControlFrame) throws -> WorkflowServeSessionControlAcknowledgement {
      try input.fileHandleForWriting.write(contentsOf: frame.encodedLine())
      return try JSONDecoder().decode(WorkflowServeSessionControlAcknowledgement.self, from: output.fileHandleForReading.availableData)
    }
    let list = try exchange(.init(type: "session-list", requestId: "list"))
    XCTAssertEqual(list.sessionIds, [])
    XCTAssertEqual(list.pendingRunCount, 0)
    let cancel = try exchange(.init(type: "session-cancel", requestId: "cancel", sessionId: "missing", reason: "stop", actor: "test"))
    XCTAssertEqual(cancel.outcome, .notFound)
  }

  func testCronOperatorCancelAdvancesQueue() async throws {
    let root = testRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = LiveSessionCancelRegistry()
    let runner = BlockingCronRunner()
    var server = DefaultEventLiveServer(workflowRunner: runner)
    server.sessionCancelRegistry = registry
    let dispatcher = CronOverlapDispatcher(server: server, eventRoot: root, parsed: try ParsedParityOptions([]),
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .queue, source: .binding)],
      clock: SystemEventServeClock(), cancelSettleTimeout: .seconds(30))
    _ = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "first"))
    await CronOverlapTestSupport.waitForSession(dispatcher, expected: "session-1", file: #filePath, line: #line)
    for _ in 0..<10000 {
      if await runner.waitingCount == 1 { break }
      await Task.yield()
    }
    let waitingCount = await runner.waitingCount
    XCTAssertEqual(waitingCount, 1)
    let queued = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "second"))
    XCTAssertEqual(queued, .queued(position: 1))
    XCTAssertEqual(registry.requestCancel(sessionId: "session-1", reason: "stop", actor: "test"), .cancelRequested)
    await CronOverlapTestSupport.waitForSession(dispatcher, expected: "session-2", file: #filePath, line: #line)
    await runner.release(index: 1)
    await dispatcher.drain()
    let receipt = try CronOverlapTestSupport.decodeReceipt(url: CronOverlapTestSupport.receiptURL(root: root, eventId: "first"))
    XCTAssertEqual(receipt.status, "cancelled")
    XCTAssertEqual(receipt.reason, "operator-cancelled:binding:session-1")
  }

  func testCronOperatorCancelReleasesSkipWithoutFailureRecord() async throws {
    let root = testRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = LiveSessionCancelRegistry()
    let runner = BlockingCronRunner()
    var server = DefaultEventLiveServer(workflowRunner: runner)
    server.sessionCancelRegistry = registry
    let dispatcher = CronOverlapDispatcher(server: server, eventRoot: root, parsed: try ParsedParityOptions([]),
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .skip, source: .binding)],
      clock: SystemEventServeClock(), cancelSettleTimeout: .seconds(30))
    _ = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "first"))
    for _ in 0..<10000 {
      if await runner.waitingCount == 1 { break }
      await Task.yield()
    }
    XCTAssertEqual(registry.requestCancel(sessionId: "session-1", reason: "stop", actor: "test"), .cancelRequested)
    await dispatcher.drain()
    let running = await dispatcher.runningSessionIds(bindingId: "binding")
    XCTAssertTrue(running.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("serve-record.json").path))
    let outcome = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "second"))
    XCTAssertEqual(outcome, .started)
    await CronOverlapTestSupport.waitForSession(dispatcher, expected: "session-2", file: #filePath, line: #line)
    await runner.release(index: 1)
    await dispatcher.drain()
  }

  func testCronSupersedeWinsOverOperatorCancellation() async throws {
    let root = testRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = LiveSessionCancelRegistry()
    let runner = BlockingCronRunner(ignoresCancellation: true)
    var server = DefaultEventLiveServer(workflowRunner: runner)
    server.sessionCancelRegistry = registry
    let dispatcher = CronOverlapDispatcher(server: server, eventRoot: root, parsed: try ParsedParityOptions([]),
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .cancelRunning, source: .binding)],
      clock: SystemEventServeClock(), cancelSettleTimeout: .seconds(30))
    _ = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "first"))
    for _ in 0..<10000 {
      if await runner.waitingCount == 1 { break }
      await Task.yield()
    }
    let outcome = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "second"))
    XCTAssertEqual(outcome, .cancelPending)
    XCTAssertEqual(registry.requestCancel(sessionId: "session-1", reason: "stop", actor: "test"), .cancelRequested)
    await runner.fail(index: 0)
    await CronOverlapTestSupport.waitForSession(dispatcher, expected: "session-2", file: #filePath, line: #line)
    await runner.release(index: 1)
    await dispatcher.drain()
    let first = try CronOverlapTestSupport.decodeReceipt(url: CronOverlapTestSupport.receiptURL(root: root, eventId: "first"))
    let second = try CronOverlapTestSupport.decodeReceipt(url: CronOverlapTestSupport.receiptURL(root: root, eventId: "second"))
    XCTAssertEqual(first.status, "cancelled")
    XCTAssertEqual(first.reason, "overlap-cancelled:binding:\(second.receiptId)")
  }

  func testCancelFromObserverAndNoRegistryError() async throws {
    let registry = LiveSessionCancelRegistry()
    var server = DefaultEventLiveServer(workflowRunner: CancelTestRunner())
    server.sessionCancelRegistry = registry
    let request = EventWorkflowRunRequest(workflowName: "early", runtimeVariables: [:], parsed: try ParsedParityOptions([]),
      onSessionStarted: { id in _ = registry.requestCancel(sessionId: id, reason: "early", actor: "test") })
    do { _ = try await server.runEventWorkflow(request); XCTFail("expected cancellation") } catch let error as EventOperatorCancelled {
      XCTAssertEqual(error.sessionId, "early")
    }
    XCTAssertTrue(registry.liveSnapshot().sessionIds.isEmpty)
    let noRegistry = DefaultEventLiveServer(workflowRunner: ImmediateFailureRunner())
    do { _ = try await noRegistry.runEventWorkflow(request); XCTFail("expected error") } catch {
      XCTAssertTrue(error is CancelTestError)
    }
  }

  private func testRoot() -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/instance-cancel/instance-cancel-06-event-serve-child/fixture-\(UUID().uuidString)")
  }
}

private struct ImmediateFailureRunner: EventWorkflowRunning {
  func runWorkflow(_ request: EventWorkflowRunRequest) async throws -> WorkflowRunResult { throw CancelTestError.expected }
}
