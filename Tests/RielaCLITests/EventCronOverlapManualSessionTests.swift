import Foundation
import RielaCore
import RielaEvents
import RielaObservability
@testable import RielaCLI
import XCTest

final class EventCronOverlapManualSessionTests: XCTestCase {
  func testIdleSkipAndCancelRunningNameManualSession() async throws {
    for policy in [EventOverlapPolicy.skip, .cancelRunning] {
      let root = try temporaryRoot("manual-skip")
      defer { try? FileManager.default.removeItem(at: root) }
      let runner = BlockingCronRunner()
      let probe = ManualSessionProbe(["manual-1"])
      let dispatcher = try makeDispatcher(root, runner, policy: policy, probe: probe)
      let outcome = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "a"))
      XCTAssertEqual(outcome, .skipped(reason: "overlap-skip:binding:manual-1"))
      let receipt = try CronOverlapTestSupport.decodeReceipt(url: CronOverlapTestSupport.receiptURL(root: root, eventId: "a"))
      XCTAssertEqual(receipt.status, "skipped")
      XCTAssertEqual(receipt.reason, "overlap-skip:binding:manual-1")
      let count = await runner.requestCount
      XCTAssertEqual(count, 0)
    }
  }

  func testConcurrentCountsExternalSessions() async throws {
    let root = try temporaryRoot("manual-cap")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = BlockingCronRunner()
    let probe = ManualSessionProbe(["manual-1"])
    let capped = try makeDispatcher(root, runner, policy: .concurrent, cap: 1, probe: probe)
    let outcome = await capped.submit(CronOverlapTestSupport.fire(eventId: "a"))
    XCTAssertEqual(outcome, .skipped(reason: "overlap-concurrency-cap:binding:1"))
    let uncapped = try makeDispatcher(root, runner, policy: .concurrent, probe: probe)
    let started = await uncapped.submit(CronOverlapTestSupport.fire(eventId: "b"))
    XCTAssertEqual(started, .started)
    await waitForSession(uncapped, expected: "session-1")
    await runner.release(index: 0)
    await uncapped.drain()
  }

  func testQueueAdvancesBeforeNewSubmitAndRetainsHeadWhileBlocked() async throws {
    let root = try temporaryRoot("manual-fifo")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = BlockingCronRunner()
    let probe = ManualSessionProbe(["manual-1"])
    let dispatcher = try makeDispatcher(root, runner, policy: .queue, queueCap: 1, probe: probe)
    let first = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "a"))
    XCTAssertEqual(first, .queued(position: 1))
    let full = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "b"))
    XCTAssertEqual(full, .skipped(reason: "overlap-queue-full:binding:1"))
    probe.set([])
    let next = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "c"))
    XCTAssertEqual(next, .queued(position: 1))
    let firstReceipt = try CronOverlapTestSupport.decodeReceipt(url: CronOverlapTestSupport.receiptURL(root: root, eventId: "a"))
    XCTAssertEqual(firstReceipt.status, "dispatched")
    await waitForSession(dispatcher, expected: "session-1")
    await runner.release(index: 0)
    await waitForSession(dispatcher, expected: "session-2")
    await runner.release(index: 1)
    await dispatcher.drain()
  }

  func testExplicitAdvanceAndFailOpen() async throws {
    let root = try temporaryRoot("manual-advance")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = BlockingCronRunner()
    let probe = ManualSessionProbe(["manual-1"])
    let dispatcher = try makeDispatcher(root, runner, policy: .queue, probe: probe)
    let queued = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "a"))
    XCTAssertEqual(queued, .queued(position: 1))
    probe.set([])
    await dispatcher.advanceAllExternallyBlocked()
    await waitForSession(dispatcher, expected: "session-1")
    await runner.release(index: 0)
    await dispatcher.drain()
    probe.fail = true
    let started = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "b"))
    XCTAssertEqual(started, .started)
    await waitForSession(dispatcher, expected: "session-2")
    await runner.release(index: 1)
    await dispatcher.drain()
  }

  func testInProcessSessionTakesPrecedenceAndNilProbeWorks() async throws {
    let root = try temporaryRoot("manual-precedence")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = BlockingCronRunner()
    let probe = ManualSessionProbe([])
    let dispatcher = try makeDispatcher(root, runner, policy: .skip, probe: probe)
    let started = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "a"))
    XCTAssertEqual(started, .started)
    await waitForSession(dispatcher, expected: "session-1")
    probe.set(["manual-1"])
    let skipped = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "b"))
    XCTAssertEqual(skipped, .skipped(reason: "overlap-skip:binding:session-1"))
    await runner.release(index: 0)
    await dispatcher.drain()
    let noProbe = try makeDispatcher(root, runner, policy: .skip)
    let nilStarted = await noProbe.submit(CronOverlapTestSupport.fire(eventId: "c"))
    XCTAssertEqual(nilStarted, .started)
    await waitForSession(noProbe, expected: "session-2")
    await runner.release(index: 1)
    await noProbe.drain()
  }

  func testProbeFailureEmitsTelemetry() async throws {
    let root = try temporaryRoot("manual-telemetry")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = BlockingCronRunner()
    let telemetry = InMemoryRielaTelemetry()
    let probe = ManualSessionProbe([])
    probe.fail = true
    let dispatcher = try makeDispatcher(root, runner, policy: .skip, probe: probe, telemetry: telemetry)
    let outcome = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "a"))
    XCTAssertEqual(outcome, .started)
    let observed = await waitUntil("probe failure telemetry") {
      await telemetry.logs().contains { $0.attributes["overlap.reason"] == "overlap-external-probe-failed" }
    }
    XCTAssertTrue(observed)
    await waitForSession(dispatcher, expected: "session-1")
    await runner.release(index: 0)
    await dispatcher.drain()
  }

  func testInactiveQueuedHeadReleasesAdmissionReservation() async throws {
    let root = try temporaryRoot("manual-routine")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RoutineStore(rootDirectory: root.appendingPathComponent("routines").path)
    var routine = RoutineRecord(
      routineId: "manual-routine", name: "queued gate", task: "run", schedule: "* * * * * *",
      workflowName: "flow", status: .active, createdAt: RoutineStore.timestamp(), updatedAt: RoutineStore.timestamp(),
      eventRoot: root.path, sourceId: "cron", bindingId: "binding"
    )
    try store.save(routine)
    let runner = BlockingCronRunner()
    let probe = ManualSessionProbe(["manual-1"])
    let gate = EventAdmissionGate(clock: SystemEventServeClock())
    let dispatcher = try makeDispatcher(root, runner, policy: .queue, probe: probe, gate: gate)
    let queued = await dispatcher.submit(CronOverlapTestSupport.fire(
      eventId: "a", routineId: routine.routineId, routineStoreRoot: store.rootDirectory
    ))
    XCTAssertEqual(queued, .queued(position: 1))
    routine.status = .disabled
    try store.save(routine)
    probe.set([])
    let started = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "b"))
    XCTAssertEqual(started, .started)
    let receipt = try CronOverlapTestSupport.decodeReceipt(url: CronOverlapTestSupport.receiptURL(root: root, eventId: "a"))
    XCTAssertEqual(receipt.status, "skipped")
    XCTAssertEqual(receipt.reason, "routine-disabled:manual-routine")
    await waitForSession(dispatcher, expected: "session-1")
    await runner.release(index: 0)
    await dispatcher.drain()
    let drained = await waitUntil("queued admission released") {
      await gate.confirm(requestId: "test").queued == 0
    }
    XCTAssertTrue(drained)
  }

  func testConcurrentCapIncludesExternalWhileRunning() async throws {
    let root = try temporaryRoot("manual-running-cap")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = BlockingCronRunner()
    let probe = ManualSessionProbe([])
    let dispatcher = try makeDispatcher(root, runner, policy: .concurrent, cap: 2, probe: probe)
    let first = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "a"))
    XCTAssertEqual(first, .started)
    await waitForSession(dispatcher, expected: "session-1")
    probe.set(["manual-1"])
    let second = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "b"))
    XCTAssertEqual(second, .skipped(reason: "overlap-concurrency-cap:binding:2"))
    await runner.release(index: 0)
    await dispatcher.drain()
  }

  func testNilProbeQueuePreservesExistingBehavior() async throws {
    let root = try temporaryRoot("manual-nil-queue")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = BlockingCronRunner()
    let dispatcher = try makeDispatcher(root, runner, policy: .queue)
    let first = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "a"))
    XCTAssertEqual(first, .started)
    await waitForSession(dispatcher, expected: "session-1")
    let second = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "b"))
    XCTAssertEqual(second, .queued(position: 1))
    await runner.release(index: 0)
    await waitForSession(dispatcher, expected: "session-2")
    await runner.release(index: 1)
    await dispatcher.drain()
  }

  func testLimitDrainReprobesExternallyBlockedQueue() async throws {
    let root = try temporaryRoot("manual-drain")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = BlockingCronRunner()
    let probe = ManualSessionProbe(["manual-1"])
    let clock = ManualEventServeClock()
    let dispatcher = CronOverlapDispatcher(
      server: DefaultEventLiveServer(workflowRunner: runner), eventRoot: root,
      parsed: try ParsedParityOptions([]),
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .queue, source: .binding)],
      clock: clock, cancelSettleTimeout: .seconds(30),
      externalProbe: probe, bindingWorkflowIds: ["binding": "flow"]
    )
    let queued = await dispatcher.submit(CronOverlapTestSupport.fire(eventId: "a"))
    XCTAssertEqual(queued, .queued(position: 1))
    let drain = Task { try await drainHonoringCancellation(dispatcher, clock: clock) }
    let sleeping = await waitUntil("drain waits for the next probe") { clock.waiterCount == 1 }
    XCTAssertTrue(sleeping)
    probe.set([])
    clock.advance(by: .seconds(1))
    await waitForSession(dispatcher, expected: "session-1")
    await runner.release(index: 0)
    try await drain.value
    let receipt = try CronOverlapTestSupport.decodeReceipt(url: CronOverlapTestSupport.receiptURL(root: root, eventId: "a"))
    XCTAssertEqual(receipt.status, "completed")
  }

  private func temporaryRoot(_ suffix: String) throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/manual-overlap-terminal-reserve/mrot-04-cron-dispatcher-manual-sessions/tests/\(suffix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func waitForSession(
    _ dispatcher: CronOverlapDispatcher, expected: String, file: StaticString = #filePath, line: UInt = #line
  ) async {
    await CronOverlapTestSupport.waitForSession(dispatcher, expected: expected, file: file, line: line)
  }

  private func waitUntil(
    _ description: String, file: StaticString = #filePath, line: UInt = #line,
    _ condition: () async -> Bool
  ) async -> Bool {
    await CronOverlapTestSupport.waitUntil(description, file: file, line: line, condition)
  }

  private func makeDispatcher(
    _ root: URL, _ runner: BlockingCronRunner, policy: EventOverlapPolicy,
    cap: Int? = nil, queueCap: Int? = nil, probe: ManualSessionProbe? = nil,
    gate: EventAdmissionGate? = nil, telemetry: InMemoryRielaTelemetry? = nil
  ) throws -> CronOverlapDispatcher {
    var server = DefaultEventLiveServer(workflowRunner: runner, telemetry: telemetry)
    server.admissionGate = gate
    return CronOverlapDispatcher(
      server: server, eventRoot: root,
      parsed: try ParsedParityOptions([]),
      policies: ["binding": EffectiveEventOverlapPolicy(policy: policy, source: .binding,
                                                        maxQueuedRuns: queueCap, maxConcurrentRuns: cap)],
      clock: SystemEventServeClock(), cancelSettleTimeout: .seconds(30), admissionGate: gate,
      externalProbe: probe, bindingWorkflowIds: ["binding": "flow"]
    )
  }
}

private final class ManualSessionProbe: ExternalRunProbing, @unchecked Sendable {
  private let lock = NSLock()
  private var ids: [String]
  private var shouldFail = false
  init(_ ids: [String]) { self.ids = ids }
  var fail: Bool {
    get { lock.withLock { shouldFail } }
    set { lock.withLock { shouldFail = newValue } }
  }
  func set(_ ids: [String]) { lock.withLock { self.ids = ids } }
  func liveManualSessionIds(workflowId: String) throws -> [String] {
    try lock.withLock {
      if shouldFail { throw ProbeError.failed }
      return ids
    }
  }
  private enum ProbeError: Error { case failed }
}
