import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import RielaCore
import RielaEvents
@testable import RielaCLI
import XCTest

final class EventCronOverlapTests: XCTestCase {
  func testSkipRecordsSessionIdAndLaterFireCompletes() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cron-overlap-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let runner = BlockingCronRunner()
    let server = DefaultEventLiveServer(workflowRunner: runner)
    let dispatcher = CronOverlapDispatcher(
      server: server,
      eventRoot: root,
      parsed: try ParsedParityOptions([]),
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .skip, source: .binding)],
      clock: SystemEventServeClock(),
      cancelSettleTimeout: .seconds(30)
    )
    let first = fire(eventId: "tick-1")
    let firstOutcome = await dispatcher.submit(first)
    XCTAssertEqual(firstOutcome, .started)
    for _ in 0..<500 {
      if await dispatcher.runningSessionIds(bindingId: "binding").contains(where: { $0 != nil }) { break }
      await Task.yield()
    }
    let outcome = await dispatcher.submit(fire(eventId: "tick-2"))
    XCTAssertEqual(outcome, .skipped(reason: "overlap-skip:binding:session-1"))

    let receiptURL = root.appendingPathComponent("receipts", isDirectory: true)
      .appendingPathComponent(receiptId(sourceId: "cron", eventId: "tick-2", bindingId: "binding") + ".json")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let receipt = try decoder.decode(PersistedEventReceipt.self, from: Data(contentsOf: receiptURL))
    XCTAssertEqual(receipt.status, "skipped")
    XCTAssertEqual(receipt.reason, "overlap-skip:binding:session-1")

    await runner.release(index: 0)
    await dispatcher.drain()
    let completion = try String(contentsOf: root.appendingPathComponent("receipts")
      .appendingPathComponent(receiptId(sourceId: "cron", eventId: "tick-1", bindingId: "binding") + ".json"), encoding: .utf8)
    XCTAssertTrue(completion.contains("\"status\" : \"completed\""), completion)
  }

  func testDueTicksIsAscendingAndCatchUpBounded() {
    let source = CronScheduleSource(id: "cron", schedule: "*/30 * * * * *", timezone: "UTC")
    let now = Date(timeIntervalSince1970: 1_754_438_400)
    let ticks = source.dueTicks(after: now.addingTimeInterval(-95), until: now)
    XCTAssertEqual(ticks, [-90, -60, -30, 0].map { now.addingTimeInterval(Double($0)) })
    XCTAssertTrue(source.dueTicks(after: now, until: now.addingTimeInterval(10)).isEmpty)
    let longWindow = source.dueTicks(after: now.addingTimeInterval(-10_000), until: now)
    XCTAssertLessThanOrEqual(longWindow.count, CronSchedule.maximumCatchUpSeconds / 30 + 1)
  }

  func testServeResolvesWorkflowDefaultsAndFallsBackToSkipWhenUnresolved() async throws {
    let cases = [
      StartupResolverCase(
        name: "binding", resolver: FixedTriggerDefaultsResolver(settings: EventOverlapSettings(overlapPolicy: "queue")),
        bindingPolicy: "skip", expectedPolicy: "skip", expectedSource: "binding"
      ),
      StartupResolverCase(
        name: "workflow", resolver: FixedTriggerDefaultsResolver(settings: EventOverlapSettings(overlapPolicy: "queue", maxQueuedRuns: 2)),
        expectedPolicy: "queue", expectedSource: "workflow"
      ),
      StartupResolverCase(
        name: "unresolved", resolver: FixedTriggerDefaultsResolver(error: TestResolverError.unavailable),
        expectedPolicy: "skip", expectedSource: "default", expectedDiagnostic: "overlap_policy_workflow_unresolved"
      )
    ]
    for testCase in cases {
      let root = try temporaryRoot("startup-\(testCase.name)")
      defer { try? FileManager.default.removeItem(at: root) }
      try writeServeCronConfig(root: root, overlapPolicy: testCase.bindingPolicy)
      let server = DefaultEventLiveServer(
        workflowRunner: FakeEventWorkflowRunner(replyText: "", replyAs: ""),
        clock: AutoAdvanceEventServeClock(), triggerDefaultsResolver: testCase.resolver
      )
      _ = try await server.serve(
        eventRoot: root, target: nil, parsed: try ParsedParityOptions(["--limit", "1"]), output: .json
      )
      let record = try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("serve-record.json"))
      ) as? [String: Any]
      let policies = try XCTUnwrap(record?["overlapPolicies"] as? [String: [String: Any]])
      let binding = try XCTUnwrap(policies["binding"])
      XCTAssertEqual(binding["policy"] as? String, testCase.expectedPolicy)
      XCTAssertEqual(binding["source"] as? String, testCase.expectedSource)
      XCTAssertEqual(binding["diagnostic"] as? String, testCase.expectedDiagnostic)
    }
  }

  func testServeFailsClosedForInvalidBindingOverlapPolicy() async throws {
    let root = try temporaryRoot("invalid-startup-policy")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeServeCronConfig(root: root, overlapPolicy: "bogus")
    let server = DefaultEventLiveServer(
      workflowRunner: FakeEventWorkflowRunner(replyText: "", replyAs: ""),
      clock: AutoAdvanceEventServeClock()
    )

    do {
      _ = try await server.serve(
        eventRoot: root, target: nil, parsed: try ParsedParityOptions(["--limit", "1"]), output: .json
      )
      XCTFail("invalid binding overlapPolicy must fail startup")
    } catch {
      XCTAssertTrue(
        String(describing: error).contains("overlapPolicy must be one of skip, cancelRunning, queue, concurrent"),
        String(describing: error)
      )
    }
    let record = try JSONSerialization.jsonObject(
      with: Data(contentsOf: root.appendingPathComponent("serve-record.json"))
    ) as? [String: Any]
    XCTAssertEqual(record?["status"] as? String, "failed")
    XCTAssertTrue((record?["detail"] as? String)?.hasPrefix("overlapPolicy must be one of skip, cancelRunning, queue, concurrent") == true)
  }

  func testConcurrentSubmitsEveryDueTickAndSkipRecordsCoalescedCount() async throws {
    let root = try temporaryRoot("coalesced-count")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeServeCronConfig(root: root)
    var config = try EventLiveConfig.load(eventRoot: root)
    config.bindings[0].overlapPolicy = "concurrent"
    let source = CronScheduleSource(id: "cron", schedule: "* * * * * *", timezone: "UTC")
    let start = Date(timeIntervalSince1970: 1_754_438_400)
    let runner = BlockingCronRunner()
    let server = DefaultEventLiveServer(workflowRunner: runner)
    let concurrent = CronOverlapDispatcher(
      server: server, eventRoot: root, parsed: try ParsedParityOptions([]),
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .concurrent, source: .binding)],
      clock: SystemEventServeClock(), cancelSettleTimeout: .seconds(30)
    )
    for offset in 0..<3 {
      _ = try await server.dispatchCronTick(
        source: source, scheduledAt: start.addingTimeInterval(Double(offset)),
        firedAt: start.addingTimeInterval(Double(offset) + 1), config: config, eventRoot: root,
        parsed: try ParsedParityOptions([]), dispatcher: concurrent, isLatestDueTick: offset == 2,
        coalescedTickCount: 2
      )
    }
    for index in 1...3 { await waitForSession(concurrent, expected: "session-\(index)") }
    let concurrentRequests = await runner.requestCount
    XCTAssertEqual(concurrentRequests, 3)
    await waitForRunnerWaiters(runner, expected: 3)
    for index in 0..<3 { await runner.release(index: index) }
    await concurrent.drain()
    let concurrentReceipts = try receiptFiles(root: root).map(decodeReceipt)
    XCTAssertEqual(concurrentReceipts.count, 3)
    XCTAssertTrue(concurrentReceipts.allSatisfy { $0.coalescedTickCount == nil })

    let skipRoot = try temporaryRoot("latest-coalesced")
    defer { try? FileManager.default.removeItem(at: skipRoot) }
    try writeServeCronConfig(root: skipRoot)
    let skipConfig = try EventLiveConfig.load(eventRoot: skipRoot)
    let skipRunner = FakeEventWorkflowRunner(replyText: "", replyAs: "")
    let skipServer = DefaultEventLiveServer(workflowRunner: skipRunner)
    let skipDispatcher = CronOverlapDispatcher(
      server: skipServer, eventRoot: skipRoot, parsed: try ParsedParityOptions([]),
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .skip, source: .default)],
      clock: SystemEventServeClock(), cancelSettleTimeout: .seconds(30)
    )
    for offset in 0..<3 {
      _ = try await skipServer.dispatchCronTick(
        source: source, scheduledAt: start.addingTimeInterval(Double(offset)),
        firedAt: start.addingTimeInterval(Double(offset) + 1), config: skipConfig, eventRoot: skipRoot,
        parsed: try ParsedParityOptions([]), dispatcher: skipDispatcher, isLatestDueTick: offset == 2,
        coalescedTickCount: 2
      )
    }
    await skipDispatcher.drain()
    let latestReceipt = try XCTUnwrap(receiptFiles(root: skipRoot).map(decodeReceipt).first)
    XCTAssertEqual(latestReceipt.coalescedTickCount, 2)
    let skipRequests = await skipRunner.requests
    XCTAssertEqual(skipRequests.count, 1)
  }

  func testQueuedRoutineIsRecheckedAfterRunningFireCompletes() async throws {
    let root = try temporaryRoot("deferred-routine-gate")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RoutineStore(rootDirectory: root.appendingPathComponent("routines").path)
    var routine = RoutineRecord(
      routineId: "routine-queued", name: "queued gate", task: "run", schedule: "* * * * * *",
      workflowName: "flow", status: .active, createdAt: RoutineStore.timestamp(), updatedAt: RoutineStore.timestamp(),
      eventRoot: root.path, sourceId: "cron", bindingId: "binding"
    )
    try store.save(routine)
    let runner = BlockingCronRunner()
    let dispatcher = CronOverlapDispatcher(
      server: DefaultEventLiveServer(workflowRunner: runner), eventRoot: root,
      parsed: try ParsedParityOptions([]),
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .queue, source: .binding, maxQueuedRuns: 1)],
      clock: SystemEventServeClock(), cancelSettleTimeout: .seconds(30)
    )
    _ = await dispatcher.submit(fire(eventId: "routine-first", routineId: routine.routineId, routineStoreRoot: store.rootDirectory))
    await waitForSession(dispatcher)
    let queued = await dispatcher.submit(fire(eventId: "routine-queued", routineId: routine.routineId, routineStoreRoot: store.rootDirectory))
    XCTAssertEqual(queued, .queued(position: 1))
    routine.status = .disabled
    try store.save(routine)
    await runner.release(index: 0)
    await waitForReceipt(root: root, eventId: "routine-queued")
    await dispatcher.drain()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let receipt = try decoder.decode(PersistedEventReceipt.self, from: Data(contentsOf: receiptURL(root: root, eventId: "routine-queued")))
    XCTAssertEqual(receipt.status, "skipped")
    XCTAssertEqual(receipt.reason, "routine-disabled:routine-queued")
    let requestCount = await runner.requestCount
    XCTAssertEqual(requestCount, 1)
  }

  func testServeDispatchesSecondCronWhileFirstRunIsBlocked() async throws {
    let root = try temporaryRoot("serve-nonblocking")
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceDirectory = root.appendingPathComponent("sources", isDirectory: true)
    let bindingDirectory = root.appendingPathComponent("bindings", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bindingDirectory, withIntermediateDirectories: true)
    for suffix in ["a", "b"] {
      try """
      {"id":"cron-\(suffix)","kind":"cron","schedule":"* * * * * *","timezone":"UTC"}
      """.write(to: sourceDirectory.appendingPathComponent("cron-\(suffix).json"), atomically: true, encoding: .utf8)
      try """
      {"id":"binding-\(suffix)","sourceId":"cron-\(suffix)","workflowName":"flow-\(suffix)","match":{"eventType":"cron.tick"},"inputMapping":{"mode":"event-input"}}
      """.write(to: bindingDirectory.appendingPathComponent("binding-\(suffix).json"), atomically: true, encoding: .utf8)
    }
    let runner = SecondCronReleasesFirstRunner()
    let server = DefaultEventLiveServer(workflowRunner: runner, clock: AutoAdvanceEventServeClock())
    let result = try await server.serve(
      eventRoot: root, target: nil, parsed: try ParsedParityOptions(["--limit", "2"]), output: .json
    )
    XCTAssertEqual(result.status, "ok")
    XCTAssertTrue(result.records.contains("processedEvents=2"))
    let requests = await runner.requestCount
    XCTAssertEqual(requests, 2)
  }

  func testSignalDuringLimitDrainCancelsRunAndReturns() async throws {
    let root = try temporaryRoot("limit-drain-cancellation")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeServeCronConfig(root: root)
    let runner = BlockingCronRunner()
    let clock = ManualEventServeClock()
    let server = DefaultEventLiveServer(
      workflowRunner: runner, clock: clock, cancelSettleTimeout: .seconds(30)
    )
    let serve = Task {
      try await server.serve(
        eventRoot: root, target: nil,
        parsed: try ParsedParityOptions(["--limit", "1"]), output: .json
      )
    }

    var serveReady = false
    for _ in 0..<50_000 {
      if let data = try? Data(contentsOf: root.appendingPathComponent("serve-record.json")),
        let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        record["status"] as? String == "ready", clock.waiterCount > 0 {
        serveReady = true
        break
      }
      await Task.yield()
    }
    XCTAssertTrue(serveReady, "serve must reach its ready record and wait for the next tick")
    clock.advance(by: .seconds(1))
    var runStarted = false
    for _ in 0..<50_000 {
      if await runner.requestCount == 1 {
        runStarted = true
        break
      }
      await Task.yield()
    }
    XCTAssertTrue(runStarted, "the manual tick must start one cron workflow")
    serve.cancel()
    do {
      _ = try await serve.value
      XCTFail("cancelled serve must rethrow cancellation")
    } catch is CancellationError {
      // Expected: the cancelled drain routes through shutdownCancelling.
    }

    var cancelledReceipt: PersistedEventReceipt?
    for _ in 0..<10_000 {
      cancelledReceipt = try? receiptFiles(root: root).map(decodeReceipt(url:)).first { $0.status == "cancelled" }
      if cancelledReceipt != nil { break }
      await Task.yield()
    }
    let receipt = try XCTUnwrap(cancelledReceipt)
    XCTAssertEqual(receipt.status, "cancelled")
    let requestCount = await runner.requestCount
    XCTAssertEqual(requestCount, 1)
  }

  func testQueueStartsDeferredFireInFIFOOrder() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cron-queue-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = BlockingCronRunner()
    let server = DefaultEventLiveServer(workflowRunner: runner)
    let dispatcher = CronOverlapDispatcher(
      server: server, eventRoot: root, parsed: try ParsedParityOptions([]),
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .queue, source: .binding, maxQueuedRuns: 1)],
      clock: SystemEventServeClock(), cancelSettleTimeout: .seconds(30)
    )
    let firstOutcome = await dispatcher.submit(fire(eventId: "first"))
    XCTAssertEqual(firstOutcome, .started)
    await waitForSession(dispatcher)
    let queuedOutcome = await dispatcher.submit(fire(eventId: "second"))
    let overflowOutcome = await dispatcher.submit(fire(eventId: "third"))
    XCTAssertEqual(queuedOutcome, .queued(position: 1))
    XCTAssertEqual(overflowOutcome, .skipped(reason: "overlap-queue-full:binding:1"))

    await runner.release(index: 0)
    await waitForSession(dispatcher, expected: "session-2")
    await runner.release(index: 1)
    await dispatcher.drain()
    let requests = await runner.requestCount
    XCTAssertEqual(requests, 2)
  }

  func testConcurrentCapStartsUpToCapAndRecordsOverflow() async throws {
    let root = try temporaryRoot("concurrent-cap")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = BlockingCronRunner()
    let dispatcher = CronOverlapDispatcher(
      server: DefaultEventLiveServer(workflowRunner: runner), eventRoot: root,
      parsed: try ParsedParityOptions([]),
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .concurrent, source: .binding, maxConcurrentRuns: 2)],
      clock: SystemEventServeClock(), cancelSettleTimeout: .seconds(30)
    )
    let first = await dispatcher.submit(fire(eventId: "concurrent-1"))
    await waitForSession(dispatcher)
    let second = await dispatcher.submit(fire(eventId: "concurrent-2"))
    await waitForSession(dispatcher, expected: "session-2")
    let overflow = await dispatcher.submit(fire(eventId: "concurrent-3"))
    XCTAssertEqual(first, .started)
    XCTAssertEqual(second, .started)
    XCTAssertEqual(overflow, .skipped(reason: "overlap-concurrency-cap:binding:2"))
    await runner.release(index: 0)
    await runner.release(index: 1)
    await dispatcher.drain()
    let requests = await runner.requestCount
    XCTAssertEqual(requests, 2)
  }

  func testCancelRunningWaitsForSessionAndStartsLatestFire() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cron-cancel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = BlockingCronRunner()
    let server = DefaultEventLiveServer(workflowRunner: runner)
    let dispatcher = CronOverlapDispatcher(
      server: server, eventRoot: root, parsed: try ParsedParityOptions([]),
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .cancelRunning, source: .binding)],
      clock: SystemEventServeClock(), cancelSettleTimeout: .seconds(30)
    )
    _ = await dispatcher.submit(fire(eventId: "first"))
    await waitForSession(dispatcher)
    let outcome = await dispatcher.submit(fire(eventId: "second"))
    XCTAssertEqual(outcome, .cancelPending)
    await waitForSession(dispatcher, expected: "session-2")
    let secondURL = receiptURL(root: root, eventId: "second")
    for _ in 0..<500 where !FileManager.default.fileExists(atPath: secondURL.path) { await Task.yield() }
    XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let secondReceipt = try decoder.decode(PersistedEventReceipt.self, from: Data(contentsOf: secondURL))
    XCTAssertEqual(secondReceipt.cancelledSessionIds, ["session-1"])
    XCTAssertEqual(secondReceipt.reason, "overlap-cancel-running:binding:session-1")

    let firstReceipt = try decoder.decode(PersistedEventReceipt.self, from: Data(contentsOf: receiptURL(root: root, eventId: "first")))
    XCTAssertEqual(firstReceipt.status, "cancelled")
    XCTAssertEqual(firstReceipt.reason, "overlap-cancelled:binding:\(secondReceipt.receiptId)")
    await runner.release(index: 1)
    await dispatcher.drain()
  }

  func testCancelTimeoutKeepsUnsettledRunTrackedAndDoesNotStartPendingFire() async throws {
    let root = try temporaryRoot("timeout")
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = ManualEventServeClock()
    let runner = BlockingCronRunner(ignoresCancellation: true)
    let dispatcher = CronOverlapDispatcher(
      server: DefaultEventLiveServer(workflowRunner: runner), eventRoot: root,
      parsed: try ParsedParityOptions([]),
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .cancelRunning, source: .binding)],
      clock: clock, cancelSettleTimeout: .seconds(30)
    )
    _ = await dispatcher.submit(fire(eventId: "timeout-1"))
    await waitForSession(dispatcher)
    _ = await dispatcher.submit(fire(eventId: "timeout-2"))
    await waitForClock(clock)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let awaiting = try decoder.decode(PersistedEventReceipt.self, from: Data(contentsOf: receiptURL(root: root, eventId: "timeout-2")))
    XCTAssertEqual(awaiting.status, "queued")
    XCTAssertEqual(awaiting.reason, "overlap-cancel-pending:binding")
    clock.advance(by: .seconds(30))
    await waitForReceipt(root: root, eventId: "timeout-2", status: "skipped")
    let pending = try decoder.decode(PersistedEventReceipt.self, from: Data(contentsOf: receiptURL(root: root, eventId: "timeout-2")))
    XCTAssertEqual(pending.status, "skipped")
    XCTAssertEqual(pending.reason, "overlap-cancel-timeout:binding:session-1")
    let requestsBeforeRelease = await runner.requestCount
    XCTAssertEqual(requestsBeforeRelease, 1)
    await runner.release(index: 0)
    await dispatcher.drain()
    let requestsAfterRelease = await runner.requestCount
    XCTAssertEqual(requestsAfterRelease, 1)
  }

  func testCancelRunningSupersedesPendingFireWithinOriginalSettleBound() async throws {
    let root = try temporaryRoot("superseded")
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = ManualEventServeClock()
    let runner = BlockingCronRunner(ignoresCancellation: true)
    let dispatcher = CronOverlapDispatcher(
      server: DefaultEventLiveServer(workflowRunner: runner), eventRoot: root,
      parsed: try ParsedParityOptions([]),
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .cancelRunning, source: .binding)],
      clock: clock, cancelSettleTimeout: .seconds(30)
    )
    _ = await dispatcher.submit(fire(eventId: "superseded-1"))
    await waitForSession(dispatcher)
    _ = await dispatcher.submit(fire(eventId: "superseded-2"))
    _ = await dispatcher.submit(fire(eventId: "superseded-3"))
    await waitForClock(clock)
    XCTAssertEqual(clock.waiterCount, 1)
    clock.advance(by: .seconds(30))
    await waitForReceipt(root: root, eventId: "superseded-3", status: "skipped")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let superseded = try decoder.decode(PersistedEventReceipt.self, from: Data(contentsOf: receiptURL(root: root, eventId: "superseded-2")))
    let timedOut = try decoder.decode(PersistedEventReceipt.self, from: Data(contentsOf: receiptURL(root: root, eventId: "superseded-3")))
    XCTAssertEqual(superseded.reason, "overlap-superseded:binding")
    XCTAssertEqual(timedOut.reason, "overlap-cancel-timeout:binding:session-1")
    await runner.release(index: 0)
    await dispatcher.drain()
    let requests = await runner.requestCount
    XCTAssertEqual(requests, 1)
  }

  func testShutdownReturnsAfterBoundWithCancellationIgnoringRun() async throws {
    let root = try temporaryRoot("shutdown")
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = ManualEventServeClock()
    let runner = BlockingCronRunner(ignoresCancellation: true)
    let dispatcher = CronOverlapDispatcher(
      server: DefaultEventLiveServer(workflowRunner: runner), eventRoot: root,
      parsed: try ParsedParityOptions([]), policies: [:], clock: clock, cancelSettleTimeout: .seconds(30)
    )
    _ = await dispatcher.submit(fire(eventId: "shutdown-1"))
    await waitForSession(dispatcher)
    let shutdown = Task { await dispatcher.shutdownCancelling() }
    await waitForClock(clock)
    clock.advance(by: .seconds(30))
    await shutdown.value
    let runningIds = await dispatcher.runningSessionIds(bindingId: "binding").compactMap { $0 }
    XCTAssertEqual(runningIds, ["session-1"])
    await runner.release(index: 0)
  }

  func testShutdownDiscardsQueuedFireAndCancelsRunningRun() async throws {
    let root = try temporaryRoot("shutdown-queued")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = BlockingCronRunner()
    let dispatcher = CronOverlapDispatcher(
      server: DefaultEventLiveServer(workflowRunner: runner), eventRoot: root,
      parsed: try ParsedParityOptions([]),
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .queue, source: .binding, maxQueuedRuns: 1)],
      clock: ManualEventServeClock(), cancelSettleTimeout: .seconds(30)
    )
    let firstOutcome = await dispatcher.submit(fire(eventId: "sd-1"))
    XCTAssertEqual(firstOutcome, .started)
    await waitForSession(dispatcher)
    await waitForRunnerWaiters(runner, expected: 1)
    let queuedOutcome = await dispatcher.submit(fire(eventId: "sd-2"))
    XCTAssertEqual(queuedOutcome, .queued(position: 1))

    await dispatcher.shutdownCancelling()

    let firstReceipt = try decodeReceipt(url: receiptURL(root: root, eventId: "sd-1"))
    let queuedReceipt = try decodeReceipt(url: receiptURL(root: root, eventId: "sd-2"))
    XCTAssertEqual(firstReceipt.status, "cancelled")
    XCTAssertEqual(firstReceipt.reason, "overlap-shutdown-cancelled:binding")
    XCTAssertEqual(queuedReceipt.status, "discarded")
    XCTAssertEqual(queuedReceipt.reason, "overlap-shutdown-discarded:binding")
    let runningIds = await dispatcher.runningSessionIds(bindingId: "binding")
    XCTAssertEqual(runningIds, [])
    let requestCount = await runner.requestCount
    XCTAssertEqual(requestCount, 1)
  }

  func testShutdownDiscardsPendingAfterCancelAndInvalidatesSettleTimeout() async throws {
    let root = try temporaryRoot("shutdown-pending")
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = ManualEventServeClock()
    let runner = BlockingCronRunner(ignoresCancellation: true)
    let dispatcher = CronOverlapDispatcher(
      server: DefaultEventLiveServer(workflowRunner: runner), eventRoot: root,
      parsed: try ParsedParityOptions([]),
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .cancelRunning, source: .binding)],
      clock: clock, cancelSettleTimeout: .seconds(30)
    )
    _ = await dispatcher.submit(fire(eventId: "sp-1"))
    await waitForSession(dispatcher)
    await waitForRunnerWaiters(runner, expected: 1)
    let pendingOutcome = await dispatcher.submit(fire(eventId: "sp-2"))
    XCTAssertEqual(pendingOutcome, .cancelPending)
    await waitForClock(clock)
    XCTAssertGreaterThanOrEqual(clock.waiterCount, 1)
    let shutdown = Task { await dispatcher.shutdownCancelling() }
    await waitForClock(clock, expected: 2)
    clock.advance(by: .seconds(30))
    await shutdown.value

    let discarded = try decodeReceipt(url: receiptURL(root: root, eventId: "sp-2"))
    XCTAssertEqual(discarded.status, "discarded")
    XCTAssertEqual(discarded.reason, "overlap-shutdown-discarded:binding")
    await runner.release(index: 0)
    await dispatcher.drain()
    let finalPendingReceipt = try decodeReceipt(url: receiptURL(root: root, eventId: "sp-2"))
    XCTAssertEqual(finalPendingReceipt.status, "discarded")
    XCTAssertEqual(finalPendingReceipt.reason, "overlap-shutdown-discarded:binding")
    let requestCount = await runner.requestCount
    XCTAssertEqual(requestCount, 1)
  }

  func testRoutineAccountingCountsOnlySuccessfulRuns() async throws {
    let root = try temporaryRoot("routine-accounting")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RoutineStore(rootDirectory: root.appendingPathComponent("routines").path)
    let routineId = "routine-accounting"
    let routine = RoutineRecord(
      routineId: routineId, name: "accounting", task: "run", schedule: "* * * * * *",
      workflowName: "flow", status: .active, createdAt: RoutineStore.timestamp(), updatedAt: RoutineStore.timestamp(),
      eventRoot: root.path, sourceId: "cron", bindingId: "binding"
    )
    try store.save(routine)
    let parsed = try ParsedParityOptions([])
    let fireWithRoutine: (String) -> CronOverlapFire = { eventId in
      self.fire(eventId: eventId, routineId: routineId, routineStoreRoot: store.rootDirectory)
    }

    let concurrentRunner = BlockingCronRunner()
    let concurrent = CronOverlapDispatcher(
      server: DefaultEventLiveServer(workflowRunner: concurrentRunner), eventRoot: root, parsed: parsed,
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .concurrent, source: .binding)],
      clock: ManualEventServeClock(), cancelSettleTimeout: .seconds(30)
    )
    _ = await concurrent.submit(fireWithRoutine("account-concurrent-1"))
    await waitForSession(concurrent)
    _ = await concurrent.submit(fireWithRoutine("account-concurrent-2"))
    await waitForSession(concurrent, expected: "session-2")
    await waitForRunnerWaiters(concurrentRunner, expected: 2)
    await concurrentRunner.release(index: 0)
    await concurrentRunner.release(index: 1)
    await concurrent.drain()
    XCTAssertEqual(try store.load(routineId: routineId)?.runCount, 2)

    let skipRunner = BlockingCronRunner()
    let skip = CronOverlapDispatcher(
      server: DefaultEventLiveServer(workflowRunner: skipRunner), eventRoot: root, parsed: parsed,
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .skip, source: .binding)],
      clock: ManualEventServeClock(), cancelSettleTimeout: .seconds(30)
    )
    _ = await skip.submit(fireWithRoutine("account-skip-1"))
    await waitForSession(skip)
    await waitForRunnerWaiters(skipRunner, expected: 1)
    let skippedOutcome = await skip.submit(fireWithRoutine("account-skip-2"))
    XCTAssertEqual(skippedOutcome, .skipped(reason: "overlap-skip:binding:session-1"))
    await skipRunner.release(index: 0)
    await skip.drain()
    XCTAssertEqual(try store.load(routineId: routineId)?.runCount, 3)

    let failedRunner = BlockingCronRunner()
    let failed = CronOverlapDispatcher(
      server: DefaultEventLiveServer(workflowRunner: failedRunner), eventRoot: root, parsed: parsed,
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .skip, source: .binding)],
      clock: ManualEventServeClock(), cancelSettleTimeout: .seconds(30)
    )
    _ = await failed.submit(fireWithRoutine("account-failed"))
    await waitForSession(failed)
    await waitForRunnerWaiters(failedRunner, expected: 1)
    await failedRunner.fail(index: 0)
    await failed.drain()
    XCTAssertEqual(try decodeReceipt(url: receiptURL(root: root, eventId: "account-failed")).status, "failed")
    XCTAssertEqual(try store.load(routineId: routineId)?.runCount, 3)

    let cancelRunner = BlockingCronRunner()
    let cancel = CronOverlapDispatcher(
      server: DefaultEventLiveServer(workflowRunner: cancelRunner), eventRoot: root, parsed: parsed,
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .cancelRunning, source: .binding)],
      clock: ManualEventServeClock(), cancelSettleTimeout: .seconds(30)
    )
    _ = await cancel.submit(fireWithRoutine("account-cancelled"))
    await waitForSession(cancel)
    await waitForRunnerWaiters(cancelRunner, expected: 1)
    let cancelOutcome = await cancel.submit(fireWithRoutine("account-superseding"))
    XCTAssertEqual(cancelOutcome, .cancelPending)
    await waitForSession(cancel, expected: "session-2")
    await waitForRunnerWaiters(cancelRunner, expected: 1)
    await cancelRunner.release(index: 1)
    await cancel.drain()
    XCTAssertEqual(try decodeReceipt(url: receiptURL(root: root, eventId: "account-cancelled")).status, "cancelled")
    XCTAssertEqual(try decodeReceipt(url: receiptURL(root: root, eventId: "account-superseding")).status, "completed")
    XCTAssertEqual(try store.load(routineId: routineId)?.runCount, 4)
  }

  func testCancelRunningWithRealRunnerRecordsRuntimeSessionId() async throws {
    let root = try temporaryRoot("real-runner")
    defer { try? FileManager.default.removeItem(at: root) }
    let workflowRoot = root.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("sleep-flow", isDirectory: true)
    let nodes = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    try FileManager.default.createDirectory(at: nodes, withIntermediateDirectories: true)
    let pidFile = root.appendingPathComponent("child.pid")
    let script = root.appendingPathComponent("sleep-child.sh")
    try "#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec /bin/sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    try """
    {"workflowId":"sleep-flow","defaults":{"nodeTimeoutMs":120000,"maxLoopIterations":10},"entryStepId":"run","nodes":[{"id":"run","nodeFile":"nodes/run.json"}],"steps":[{"id":"run","nodeId":"run","role":"worker"}]}
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {"id":"run","nodeType":"command","command":{"scriptPath":"\(script.path)"}}
    """.write(to: nodes.appendingPathComponent("run.json"), atomically: true, encoding: .utf8)

    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
    let parsed = try ParsedParityOptions([
      "--workflow-definition-dir", workflowRoot.path,
      "--working-dir", root.path,
      "--session-store", sessions.path,
      "--artifact-root", artifacts.path
    ])
    let eventRoot = root.appendingPathComponent("events", isDirectory: true)
    let dispatcher = CronOverlapDispatcher(
      server: DefaultEventLiveServer(workflowRunner: CLIEventWorkflowRunner()),
      eventRoot: eventRoot,
      parsed: parsed,
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .cancelRunning, source: .binding)],
      clock: SystemEventServeClock(),
      cancelSettleTimeout: .seconds(30)
    )
    _ = await dispatcher.submit(fire(eventId: "real-first", workflowName: "sleep-flow"))
    // A real workflow run compiles nothing but still spawns a shell; on a
    // loaded machine that took longer than 5 s, so wait on a wall-clock bound.
    _ = await waitUntil("runtime session and child pid", timeout: .seconds(90)) {
      let started = await dispatcher.runningSessionIds(bindingId: "binding").contains { $0 != nil }
      return started && FileManager.default.fileExists(atPath: pidFile.path)
    }
    let sessionId = await dispatcher.runningSessionIds(bindingId: "binding").compactMap { $0 }.first
    let recordPath = eventRoot.appendingPathComponent("serve-record.json")
    let diagnostic = (try? String(contentsOf: recordPath, encoding: .utf8)) ?? "no serve record"
    let receiptDiagnostic = (try? String(contentsOf: receiptURL(root: eventRoot, eventId: "real-first"), encoding: .utf8)) ?? "no first receipt"
    let debug = "\(diagnostic); receipt: \(receiptDiagnostic)"
    let observedSessionId = try XCTUnwrap(sessionId, "runtime session did not start; \(debug)")
    let childPid = try XCTUnwrap(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    _ = await dispatcher.submit(fire(eventId: "real-second", workflowName: "sleep-flow"))
    let secondSessionStarted = await waitUntil("superseding runtime session", timeout: .seconds(90)) {
      await dispatcher.runningSessionIds(bindingId: "binding").compactMap { $0 }.contains { $0 != observedSessionId }
    }
    XCTAssertTrue(secondSessionStarted)
    let receiptDecoder = JSONDecoder()
    receiptDecoder.dateDecodingStrategy = .iso8601
    let receipt = try receiptDecoder.decode(
      PersistedEventReceipt.self,
      from: Data(contentsOf: receiptURL(root: eventRoot, eventId: "real-second"))
    )
    XCTAssertEqual(receipt.cancelledSessionIds, [observedSessionId])
    XCTAssertEqual(receipt.reason, "overlap-cancel-running:binding:\(observedSessionId)")
    let firstReceipt = try receiptDecoder.decode(
      PersistedEventReceipt.self,
      from: Data(contentsOf: receiptURL(root: eventRoot, eventId: "real-first"))
    )
    XCTAssertEqual(firstReceipt.status, "cancelled")
    XCTAssertEqual(firstReceipt.workflowExecutionId, observedSessionId)
    XCTAssertEqual(firstReceipt.reason, "overlap-cancelled:binding:\(receipt.receiptId)")
    let runtimeStore = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessions.path))
    let cancelled = try runtimeStore.load(sessionId: observedSessionId)
    XCTAssertEqual(cancelled.session.failureKind, .cancelled)
    XCTAssertEqual(kill(childPid, 0), -1)
    XCTAssertEqual(errno, ESRCH)
    await dispatcher.shutdownCancelling()
  }

  func testSessionStartedJustBeforeCancellationReachesSupersedingReceipt() async throws {
    let root = try temporaryRoot("session-hop")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = GatedSessionRunner()
    let dispatcher = CronOverlapDispatcher(
      server: DefaultEventLiveServer(workflowRunner: runner), eventRoot: root,
      parsed: try ParsedParityOptions([]),
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .cancelRunning, source: .binding)],
      clock: ManualEventServeClock(), cancelSettleTimeout: .seconds(30)
    )
    _ = await dispatcher.submit(fire(eventId: "hop-1"))
    let gated = await waitUntil("first run reaches the gate") { await runner.isGated }
    XCTAssertTrue(gated)
    let outcome = await dispatcher.submit(fire(eventId: "hop-2"))
    XCTAssertEqual(outcome, .cancelPending)
    // The first run now emits session_started and throws CancellationError at once.
    await runner.openGate()
    await waitForSession(dispatcher, expected: "session-2")
    let superseding = try decodeReceipt(url: receiptURL(root: root, eventId: "hop-2"))
    XCTAssertEqual(superseding.cancelledSessionIds, ["session-1"])
    XCTAssertEqual(superseding.reason, "overlap-cancel-running:binding:session-1")
    let cancelled = try decodeReceipt(url: receiptURL(root: root, eventId: "hop-1"))
    XCTAssertEqual(cancelled.status, "cancelled")
    XCTAssertEqual(cancelled.workflowExecutionId, "session-1")
    XCTAssertEqual(cancelled.reason, "overlap-cancelled:binding:\(superseding.receiptId)")
    await dispatcher.drain()
  }

  func testRunEndingAfterCancelTimeoutKeepsSupersedingReceiptId() async throws {
    let root = try temporaryRoot("timeout-reason")
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = ManualEventServeClock()
    let runner = BlockingCronRunner(ignoresCancellation: true)
    let dispatcher = CronOverlapDispatcher(
      server: DefaultEventLiveServer(workflowRunner: runner), eventRoot: root,
      parsed: try ParsedParityOptions([]),
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .cancelRunning, source: .binding)],
      clock: clock, cancelSettleTimeout: .seconds(30)
    )
    _ = await dispatcher.submit(fire(eventId: "late-1"))
    await waitForSession(dispatcher)
    await waitForRunnerWaiters(runner, expected: 1)
    _ = await dispatcher.submit(fire(eventId: "late-2"))
    await waitForClock(clock)
    clock.advance(by: .seconds(30))
    await waitForReceipt(root: root, eventId: "late-2", status: "skipped")
    await runner.fail(index: 0)
    await dispatcher.drain()
    let cancelled = try decodeReceipt(url: receiptURL(root: root, eventId: "late-1"))
    XCTAssertEqual(cancelled.status, "cancelled")
    XCTAssertEqual(
      cancelled.reason,
      "overlap-cancelled:binding:\(receiptId(sourceId: "cron", eventId: "late-2", bindingId: "binding"))"
    )
  }

  private func fire(
    eventId: String,
    workflowName: String = "flow",
    routineId: String? = nil,
    routineStoreRoot: String? = nil
  ) -> CronOverlapFire {
    CronOverlapTestSupport.fire(
      eventId: eventId, workflowName: workflowName, routineId: routineId, routineStoreRoot: routineStoreRoot
    )
  }

  private func writeServeCronConfig(root: URL, overlapPolicy: String? = nil) throws {
    try CronOverlapTestSupport.writeServeCronConfig(root: root, overlapPolicy: overlapPolicy)
  }

  private func receiptFiles(root: URL) throws -> [URL] {
    try CronOverlapTestSupport.receiptFiles(root: root)
  }

  private func decodeReceipt(url: URL) throws -> PersistedEventReceipt {
    try CronOverlapTestSupport.decodeReceipt(url: url)
  }

  private func receiptId(sourceId: String, eventId: String, bindingId: String) -> String {
    cronOverlapReceiptId(sourceId: sourceId, eventId: eventId, bindingId: bindingId)
  }

  private func receiptURL(root: URL, eventId: String) -> URL {
    CronOverlapTestSupport.receiptURL(root: root, eventId: eventId)
  }

  private func temporaryRoot(_ suffix: String) throws -> URL {
    try CronOverlapTestSupport.temporaryRoot(suffix)
  }

  private func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(30),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async -> Bool
  ) async -> Bool {
    await CronOverlapTestSupport.waitUntil(description, timeout: timeout, file: file, line: line, condition)
  }

  // Advancing before a sleeper registers would strand it, so wait on real time
  // once yielding alone has not let a detached sleeper reach the clock.
  private func waitForClock(_ clock: ManualEventServeClock, expected: Int = 1) async {
    for attempt in 0..<3_000 {
      if clock.waiterCount >= expected { return }
      if attempt < 500 { await Task.yield() } else { try? await Task.sleep(nanoseconds: 2_000_000) }
    }
    XCTFail("clock did not register \(expected) sleeper(s)")
  }

  private func waitForReceipt(
    root: URL, eventId: String, status: String? = nil, file: StaticString = #filePath, line: UInt = #line
  ) async {
    let url = receiptURL(root: root, eventId: eventId)
    _ = await waitUntil("receipt \(eventId) reaches \(status ?? "any status")", file: file, line: line) {
      if let status {
        return (try? self.decodeReceipt(url: url))?.status == status
      }
      return FileManager.default.fileExists(atPath: url.path)
    }
  }

  private func waitForSession(
    _ dispatcher: CronOverlapDispatcher, expected: String = "session-1", file: StaticString = #filePath, line: UInt = #line
  ) async {
    await CronOverlapTestSupport.waitForSession(dispatcher, expected: expected, file: file, line: line)
  }

  private func waitForRunnerWaiters(_ runner: BlockingCronRunner, expected: Int) async {
    for _ in 0..<500 {
      if await runner.waitingCount >= expected { return }
      await Task.yield()
    }
    XCTFail("runner did not install \(expected) continuation(s)")
  }
}

private struct FixedTriggerDefaultsResolver: EventWorkflowTriggerDefaultsResolving {
  var settings: EventOverlapSettings?
  var error: TestResolverError?

  init(settings: EventOverlapSettings? = nil, error: TestResolverError? = nil) {
    self.settings = settings
    self.error = error
  }

  func triggerDefaults(workflowName: String, parsed: ParsedParityOptions) throws -> EventOverlapSettings? {
    if let error { throw error }
    return settings
  }
}

private struct StartupResolverCase {
  var name: String
  var resolver: FixedTriggerDefaultsResolver
  var bindingPolicy: String?
  var expectedPolicy: String
  var expectedSource: String
  var expectedDiagnostic: String?

  init(
    name: String,
    resolver: FixedTriggerDefaultsResolver,
    bindingPolicy: String? = nil,
    expectedPolicy: String,
    expectedSource: String,
    expectedDiagnostic: String? = nil
  ) {
    self.name = name
    self.resolver = resolver
    self.bindingPolicy = bindingPolicy
    self.expectedPolicy = expectedPolicy
    self.expectedSource = expectedSource
    self.expectedDiagnostic = expectedDiagnostic
  }
}

private enum TestResolverError: Error, Sendable {
  case unavailable
}

actor BlockingCronRunner: EventWorkflowRunning {
  private var continuations: [Int: CheckedContinuation<WorkflowRunResult, Error>] = [:]
  private var nextIndex = 0
  private(set) var requestCount = 0
  private let ignoresCancellation: Bool

  var waitingCount: Int { continuations.count }

  init(ignoresCancellation: Bool = false) {
    self.ignoresCancellation = ignoresCancellation
  }

  func runWorkflow(_ request: EventWorkflowRunRequest) async throws -> WorkflowRunResult {
    let index = nextIndex
    nextIndex += 1
    requestCount += 1
    request.onSessionStarted?("session-\(index + 1)")
    if ignoresCancellation {
      return try await withCheckedThrowingContinuation { continuation in
        install(continuation, index: index)
      }
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        install(continuation, index: index)
      }
    } onCancel: {
      Task { await self.cancel(index: index) }
    }
  }

  // The session id is published before the continuation exists; a release
  // that wins that race must still complete the run.
  private var earlyReleases: Set<Int> = []

  private func install(_ continuation: CheckedContinuation<WorkflowRunResult, Error>, index: Int) {
    if earlyReleases.remove(index) != nil {
      continuation.resume(returning: result())
    } else {
      continuations[index] = continuation
    }
  }

  func release(index: Int) {
    if let continuation = continuations.removeValue(forKey: index) {
      continuation.resume(returning: result())
    } else if index < nextIndex {
      earlyReleases.insert(index)
    }
  }

  func fail(index: Int) {
    continuations.removeValue(forKey: index)?.resume(throwing: BlockingCronRunnerError.expectedFailure)
  }

  private func cancel(index: Int) {
    continuations.removeValue(forKey: index)?.resume(throwing: CancellationError())
  }

  private func result() -> WorkflowRunResult {
    let date = Date(timeIntervalSince1970: 0)
    let session = WorkflowSession(
      workflowId: "flow", sessionId: "session-1", status: .completed, entryStepId: "entry",
      createdAt: date, updatedAt: date, executions: []
    )
    return WorkflowRunResult(workflowId: "flow", session: session, rootOutput: nil, exitCode: 0, transitions: 0)
  }
}

enum BlockingCronRunnerError: Error {
  case expectedFailure
}

final class ManualEventServeClock: EventServeClock, @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSince1970: 1_754_438_400)
  private var continuations: [CheckedContinuation<Void, Error>] = []

  var waiterCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return continuations.count
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func sleep(for duration: Duration) async throws {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      continuations.append(continuation)
      lock.unlock()
    }
  }

  func advance(by duration: Duration) {
    lock.lock()
    let components = duration.components
    current = current.addingTimeInterval(Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000)
    let pending = continuations
    continuations.removeAll()
    lock.unlock()
    pending.forEach { $0.resume() }
  }
}

final class AutoAdvanceEventServeClock: EventServeClock, @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSince1970: 1_754_438_400)

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func sleep(for duration: Duration) async throws {
    lock.withLock {
      let components = duration.components
      current = current.addingTimeInterval(Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000)
    }
    await Task.yield()
  }
}

private actor SecondCronReleasesFirstRunner: EventWorkflowRunning {
  private var firstContinuation: CheckedContinuation<WorkflowRunResult, Never>?
  private var secondRequestSeen = false
  private(set) var requestCount = 0

  func runWorkflow(_ request: EventWorkflowRunRequest) async throws -> WorkflowRunResult {
    requestCount += 1
    request.onSessionStarted?("serve-session-\(requestCount)")
    if requestCount > 1 {
      secondRequestSeen = true
      firstContinuation?.resume(returning: result(for: "flow-a", sessionId: "serve-session-1"))
      firstContinuation = nil
      return result(for: request.workflowName, sessionId: "serve-session-\(requestCount)")
    }
    if secondRequestSeen { return result(for: request.workflowName, sessionId: "serve-session-1") }
    return await withCheckedContinuation { continuation in
      if secondRequestSeen {
        continuation.resume(returning: result(for: request.workflowName, sessionId: "serve-session-1"))
      } else {
        firstContinuation = continuation
      }
    }
  }

  private func result(for workflowName: String, sessionId: String) -> WorkflowRunResult {
    let date = Date(timeIntervalSince1970: 0)
    let session = WorkflowSession(
      workflowId: workflowName, sessionId: sessionId, status: .completed, entryStepId: "entry",
      createdAt: date, updatedAt: date, executions: []
    )
    return WorkflowRunResult(workflowId: workflowName, session: session, rootOutput: nil, exitCode: 0, transitions: 0)
  }
}

/// Blocks the first run (not cancellably) until the test opens the gate; the
/// run then emits `session_started` and throws `CancellationError` at once.
private actor GatedSessionRunner: EventWorkflowRunning {
  private var gate: CheckedContinuation<Void, Never>?
  private var nextIndex = 0

  var isGated: Bool { gate != nil }

  func runWorkflow(_ request: EventWorkflowRunRequest) async throws -> WorkflowRunResult {
    nextIndex += 1
    let index = nextIndex
    if index == 1 {
      await withCheckedContinuation { gate = $0 }
      request.onSessionStarted?("session-1")
      throw CancellationError()
    }
    request.onSessionStarted?("session-\(index)")
    let date = Date(timeIntervalSince1970: 0)
    let session = WorkflowSession(
      workflowId: "flow", sessionId: "session-\(index)", status: .completed, entryStepId: "entry",
      createdAt: date, updatedAt: date, executions: []
    )
    return WorkflowRunResult(workflowId: "flow", session: session, rootOutput: nil, exitCode: 0, transitions: 0)
  }

  func openGate() {
    gate?.resume()
    gate = nil
  }
}
