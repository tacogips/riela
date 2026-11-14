import Foundation
import RielaCore
import RielaEvents
import RielaServer
@testable import RielaCLI
import XCTest

final class EventAdmissionGateTests: XCTestCase {
  func testAdmissionCloseBoundaryRace() async throws {
    for index in 0..<200 {
      let gate = EventAdmissionGate(clock: ManualEventServeClock())
      async let admitted: Bool = Self.attemptAdmission(gate)
      async let closed = gate.close(requestId: "race-\(index)", leaseSeconds: 120)
      let (didAdmit, acknowledgement) = await (admitted, closed)
      XCTAssertEqual(acknowledgement.running, didAdmit ? 1 : 0)
      if didAdmit { await gate.release() }
    }
  }

  func testConfirmReopenAndLeaseExpiry() async throws {
    let clock = ManualEventServeClock()
    let gate = EventAdmissionGate(clock: clock)
    _ = await gate.close(requestId: "first", leaseSeconds: 5)
    let confirmed = await gate.confirm(requestId: "first")
    XCTAssertEqual(confirmed.state, .closed)
    XCTAssertEqual(confirmed.running, 0)
    XCTAssertEqual(confirmed.queued, 0)
    for _ in 0..<10_000 {
      if clock.waiterCount > 0 { break }
      await Task.yield()
    }
    XCTAssertGreaterThan(clock.waiterCount, 0)
    clock.advance(by: .seconds(5))
    var state = await gate.confirm(requestId: "first")
    for _ in 0..<10_000 where state.state != .expired {
      await Task.yield()
      state = await gate.confirm(requestId: "first")
    }
    XCTAssertEqual(state.state, .expired)
    try await gate.admit()
    await gate.release()
    _ = await gate.close(requestId: "second", leaseSeconds: 5)
    let reopened = await gate.reopen(requestId: "second")
    XCTAssertEqual(reopened.state, .open)
    try await gate.admit()
    await gate.release()
  }

  func testFailedAdmittedRunReleasesGate() async throws {
    let runner = BlockingCronRunner()
    let gate = EventAdmissionGate(clock: ManualEventServeClock())
    var server = DefaultEventLiveServer(workflowRunner: runner)
    server.admissionGate = gate
    let request = EventWorkflowRunRequest(workflowName: "flow", runtimeVariables: [:], parsed: try ParsedParityOptions([]))
    let task = Task { try await server.runEventWorkflow(request) }
    for _ in 0..<10_000 {
      if await runner.waitingCount > 0 { break }
      await Task.yield()
    }
    let waiters = await runner.waitingCount
    guard waiters == 1 else {
      task.cancel()
      XCTFail("runner did not start")
      return
    }
    await runner.fail(index: 0)
    do { _ = try await task.value; XCTFail("runner should fail") } catch {}
    let closed = await gate.close(requestId: "after-failure", leaseSeconds: 120)
    XCTAssertEqual(closed.running, 0)
  }

  func testClosedCronSubmitRecordsSkippedReceipt() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = BlockingCronRunner()
    let gate = EventAdmissionGate(clock: ManualEventServeClock())
    var server = DefaultEventLiveServer(workflowRunner: runner)
    server.admissionGate = gate
    let dispatcher = try makeDispatcher(server: server, gate: gate, root: root)
    _ = await gate.close(requestId: "close", leaseSeconds: 120)
    let result = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "closed"))
    XCTAssertEqual(result, .skipped(reason: "reload-handoff:binding"))
    let receipt = try CronOverlapTestSupport.decodeReceipt(url: CronOverlapTestSupport.receiptURL(root: root, eventId: "closed"))
    XCTAssertEqual(receipt.status, "skipped")
    XCTAssertEqual(receipt.reason, "reload-handoff:binding")
    let count = await runner.requestCount
    XCTAssertEqual(count, 0)
  }

  func testQueuedCronIsSkippedAfterClose() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = BlockingCronRunner()
    let gate = EventAdmissionGate(clock: ManualEventServeClock())
    var server = DefaultEventLiveServer(workflowRunner: runner)
    server.admissionGate = gate
    let dispatcher = try makeDispatcher(server: server, gate: gate, root: root)
    _ = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "first"))
    await CronOverlapTestSupport.waitForSession(dispatcher, expected: "session-1", file: #filePath, line: #line)
    let queued = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "second"))
    XCTAssertEqual(queued, .queued(position: 1))
    let closed = await gate.close(requestId: "close", leaseSeconds: 120)
    XCTAssertEqual(closed.running, 1)
    XCTAssertEqual(closed.queued, 1)
    await runner.release(index: 0)
    await dispatcher.drain()
    let receipt = try CronOverlapTestSupport.decodeReceipt(url: CronOverlapTestSupport.receiptURL(root: root, eventId: "second"))
    XCTAssertEqual(receipt.status, "skipped")
    XCTAssertEqual(receipt.reason, "reload-handoff:binding")
    let count = await runner.requestCount
    XCTAssertEqual(count, 1)
  }

  func testRejectedNonCronReceiptCanBeLoaded() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let envelope = ExternalEventEnvelope(sourceId: "source", eventId: "event", provider: "test",
      eventType: "test.event", receivedAt: Date(timeIntervalSince1970: 0), input: [:])
    let server = DefaultEventLiveServer()
    try await server.recordWorkflowDispatchFailure(eventRoot: root, sourceKind: "webhook", sourceId: "source",
      workflowName: "flow", error: EventAdmissionClosed(), envelope: envelope)
    let store = EventReceiptStore(eventRoot: root)
    let receipts = try store.list()
    XCTAssertEqual(receipts.count, 1)
    let receipt = try XCTUnwrap(receipts.first)
    XCTAssertTrue(receipt.receiptId.hasPrefix("event-handoff-"))
    XCTAssertEqual(receipt.status, "rejected")
    XCTAssertEqual(receipt.reason, "reload-handoff")
    let loaded = try XCTUnwrap(store.load(receipt.receiptId))
    XCTAssertEqual(loaded.envelope.eventId, envelope.eventId)
  }

  func testRejectedNonCronReceiptSaveFailureThrows() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let blocked = root.appendingPathComponent("receipts")
    try Data("blocked".utf8).write(to: blocked)
    let envelope = ExternalEventEnvelope(sourceId: "source", eventId: "event", provider: "test",
      eventType: "test.event", receivedAt: Date(timeIntervalSince1970: 0), input: [:])
    do {
      try await DefaultEventLiveServer().recordWorkflowDispatchFailure(
        eventRoot: root, sourceKind: "webhook", sourceId: "source", workflowName: "flow",
        error: EventAdmissionClosed(), envelope: envelope
      )
      XCTFail("Receipt persistence failure must propagate")
    } catch {
      XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.path))
    }
  }

  func testSlackReceiptSaveFailureDoesNotAdvanceCursor() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sources = root.appendingPathComponent("sources")
    let bindings = root.appendingPathComponent("bindings")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bindings, withIntermediateDirectories: true)
    try Data(#"{"id":"slack-live","kind":"slack-gateway","provider":"slack","tokenEnv":"TEST_SLACK_TOKEN","botUserIdEnv":"TEST_SLACK_BOT_USER_ID","channels":[{"id":"C200"}],"polling":{"limit":1}}"#.utf8)
      .write(to: sources.appendingPathComponent("slack-live.json"))
    let bindingJSON = #"""
    {"id":"slack-to-workflow","sourceId":"slack-live","workflowName":"slack-flow",
     "match":{"eventType":"chat.message"},"inputMapping":{"mode":"template",
     "template":{"request":"{{event.input.text}}"},"mirrorToHumanInput":true}}
    """#
    try Data(bindingJSON.utf8)
      .write(to: bindings.appendingPathComponent("slack-to-workflow.json"))
    try Data("blocked".utf8).write(to: root.appendingPathComponent("receipts"))
    let config = try EventLiveConfig.load(eventRoot: root)
    let source = try XCTUnwrap(config.slackSources(eventRoot: root).first)
    let api = FakeSlackGatewayAPI(messages: [try SlackMessage.fixture(ts: "1780000000.000100", text: "Riela, hello")])
    let runner = BlockingCronRunner()
    let gate = EventAdmissionGate(clock: ManualEventServeClock())
    _ = await gate.close(requestId: "close", leaseSeconds: 120)
    var server = DefaultEventLiveServer(slackAPI: api, workflowRunner: runner)
    server.admissionGate = gate
    let configuredServer = server
    do {
      _ = try await CLIRuntimeEnvironment.$overrides.withValue([
        "TEST_SLACK_TOKEN": "test-token", "TEST_SLACK_BOT_USER_ID": "U999"
      ]) {
        try await configuredServer.pollSlackSource(source, config: config, eventRoot: root, parsed: ParsedParityOptions([]))
      }
      XCTFail("Receipt persistence failure must escape the provider")
    } catch {
      let cursor = root.appendingPathComponent("slack/slack-live-C200-offset.json")
      XCTAssertFalse(FileManager.default.fileExists(atPath: cursor.path))
    }
    let requests = await api.getMessageRequests
    XCTAssertEqual(requests.count, 1)
    let runCount = await runner.requestCount
    XCTAssertEqual(runCount, 0)
  }

  func testAdmissionFrameDoesNotReachEnvironmentDecoder() async throws {
    let input = Pipe(), output = Pipe()
    let gate = EventAdmissionGate(clock: ManualEventServeClock())
    let state = EventRuntimeEnvironment(base: [:], requiresBootstrap: true)
    let channel = RuntimeEnvironmentChannel(state: state, input: input.fileHandleForReading,
      output: output.fileHandleForWriting, admissionGate: gate)
    defer { channel.stop() }
    let frame = WorkflowServeAdmissionFrame(type: "admission-close", requestId: "request", leaseSeconds: 120)
    try input.fileHandleForWriting.write(contentsOf: frame.encodedLine())
    let admissionData = output.fileHandleForReading.availableData
    let acknowledgement = try XCTUnwrap(WorkflowServeAdmissionAcknowledgement.decodeLine(admissionData))
    XCTAssertEqual(acknowledgement.state, .closed)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: admissionData) as? [String: Any])
    XCTAssertEqual(Set(object.keys), Set(["type", "requestId", "state", "running", "queued"]))
    let environment = try JSONSerialization.data(withJSONObject: ["generation": 1, "managedNames": ["KEY"], "values": ["KEY": "test-value"]])
    try input.fileHandleForWriting.write(contentsOf: environment + Data([10]))
    let environmentData = output.fileHandleForReading.availableData
    let environmentAck = try JSONDecoder().decode(RuntimeEnvironmentAcknowledgement.self, from: environmentData)
    XCTAssertTrue(environmentAck.accepted)
    let snapshot = try await state.capture()
    XCTAssertEqual(snapshot["KEY"], "test-value")
  }

  private static func attemptAdmission(_ gate: EventAdmissionGate) async -> Bool {
    do { try await gate.admit(); return true } catch { return false }
  }

  private func temporaryRoot() throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/instance-control/instance-control-05-child-admission-gate/test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeDispatcher(server: DefaultEventLiveServer, gate: EventAdmissionGate, root: URL) throws -> CronOverlapDispatcher {
    CronOverlapDispatcher(server: server, eventRoot: root, parsed: try ParsedParityOptions([]),
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .queue, source: .binding, maxQueuedRuns: 1)],
      clock: SystemEventServeClock(), cancelSettleTimeout: .seconds(30), admissionGate: gate)
  }
}
