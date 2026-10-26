import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import RielaCore
import RielaEvents
import RielaObservability
import WebHooky
@testable import RielaCLI
import XCTest

/// Serve-level and lifecycle coverage for the cron overlap dispatcher: other
/// sources stay live while a cron run is blocked, `--limit` drains queued
/// fires, abandoned receipts are reconciled at startup, and non-start
/// outcomes emit telemetry.
final class EventCronOverlapServeTests: XCTestCase {
  func testQueuedAndCancelPendingOutcomesEmitOverlapTelemetry() async throws {
    let root = try temporaryRoot("telemetry")
    defer { try? FileManager.default.removeItem(at: root) }
    let telemetry = InMemoryRielaTelemetry()
    let runner = BlockingCronRunner()
    let server = DefaultEventLiveServer(workflowRunner: runner, telemetry: telemetry)
    let queue = CronOverlapDispatcher(
      server: server, eventRoot: root, parsed: try ParsedParityOptions([]),
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .queue, source: .binding, maxQueuedRuns: 1)],
      clock: ManualEventServeClock(), cancelSettleTimeout: .seconds(30)
    )
    _ = await queue.submit(fire(eventId: "telemetry-1"))
    await waitForSession(queue)
    let queued = await queue.submit(fire(eventId: "telemetry-2"))
    XCTAssertEqual(queued, .queued(position: 1))
    let cancelRoot = try temporaryRoot("telemetry-cancel")
    defer { try? FileManager.default.removeItem(at: cancelRoot) }
    let cancelRunner = BlockingCronRunner()
    let cancel = CronOverlapDispatcher(
      server: DefaultEventLiveServer(workflowRunner: cancelRunner, telemetry: telemetry), eventRoot: cancelRoot,
      parsed: try ParsedParityOptions([]),
      policies: ["binding": EffectiveEventOverlapPolicy(policy: .cancelRunning, source: .binding)],
      clock: ManualEventServeClock(), cancelSettleTimeout: .seconds(30)
    )
    _ = await cancel.submit(fire(eventId: "telemetry-3"))
    await waitForSession(cancel)
    _ = await cancel.submit(fire(eventId: "telemetry-4"))
    // Neither outcome is a skip, so before D6 no overlap log was emitted at all.
    // Telemetry carries the finite reason kind; the full reason stays on the receipt.
    let expected: Set = ["queue|overlap-queued", "cancelRunning|overlap-cancel-pending"]
    var seen: Set<String> = []
    let observed = await waitUntil("queued and cancel-pending telemetry logs") {
      let logs = await telemetry.logs().filter { $0.name == "riela.events.cron.overlap" }
      seen = Set(logs.map { "\($0.attributes["overlap.policy"] ?? "")|\($0.attributes["overlap.reason"] ?? "")" })
      return expected.isSubset(of: seen)
    }
    XCTAssertTrue(observed, "\(seen)")
    let logs = await telemetry.logs().filter { $0.name == "riela.events.cron.overlap" }
    XCTAssertEqual(logs.count, 2, "\(logs)")
    XCTAssertTrue(logs.allSatisfy { $0.attributes["binding.id"] == "binding" }, "\(logs)")
    await runner.release(index: 0)
    await waitForSession(queue, expected: "session-2")
    await runner.release(index: 1)
    await queue.drain()
    await waitForSession(cancel, expected: "session-2")
    await cancelRunner.release(index: 1)
    await cancel.drain()
  }

  func testStartupClosesReceiptsAbandonedByDeadServeInstance() async throws {
    let root = try temporaryRoot("abandoned")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EventReceiptStore(eventRoot: root)
    func receipt(_ eventId: String, status: String, bindingId: String? = "binding", session: String? = nil) -> PersistedEventReceipt {
      let template = self.fire(eventId: eventId)
      return PersistedEventReceipt(
        receiptId: receiptId(sourceId: "cron", eventId: eventId, bindingId: "binding"), sourceId: "cron",
        eventId: eventId, status: status, duplicate: false, workflowExecutionId: session, workflowName: "flow",
        replayedFromReceiptId: nil, reason: nil, updatedAt: Date(timeIntervalSince1970: 1), envelope: template.envelope,
        bindingId: bindingId, overlapPolicy: bindingId == nil ? nil : "queue", overlapPolicySource: bindingId == nil ? nil : "binding"
      )
    }
    func stamped(_ receipt: PersistedEventReceipt, _ instance: String) -> PersistedEventReceipt {
      var receipt = receipt
      receipt.serveInstanceId = instance
      return receipt
    }
    let deadInstance = "2000000000-deadbeef"
    let liveInstance = "\(getpid())-livefeed"
    try store.save(stamped(receipt("dead-queued", status: "queued"), deadInstance))
    try store.save(receipt("legacy-dispatched", status: "dispatched", session: "session-old"))
    try store.save(stamped(receipt("dead-pending-session", status: "dispatched"), deadInstance))
    try store.save(stamped(receipt("live-queued", status: "queued"), liveInstance))
    try store.save(stamped(receipt("dead-completed", status: "completed"), deadInstance))
    try store.save(stamped(receipt("unbound-queued", status: "queued", bindingId: nil), deadInstance))
    try Data("not json".utf8).write(to: store.root.appendingPathComponent("event-cron-corrupt.json"))

    let dispatcher = CronOverlapDispatcher(
      server: DefaultEventLiveServer(workflowRunner: BlockingCronRunner()), eventRoot: root,
      parsed: try ParsedParityOptions([]), policies: [:], clock: ManualEventServeClock(), cancelSettleTimeout: .seconds(30)
    )
    func load(_ eventId: String) throws -> PersistedEventReceipt {
      try XCTUnwrap(store.load(receiptId(sourceId: "cron", eventId: eventId, bindingId: "binding")))
    }
    XCTAssertEqual(try load("dead-queued").status, "discarded")
    XCTAssertEqual(try load("dead-queued").reason, "overlap-abandoned:binding")
    XCTAssertEqual(try load("dead-queued").serveInstanceId, deadInstance)
    XCTAssertEqual(try load("legacy-dispatched").status, "failed")
    XCTAssertEqual(try load("legacy-dispatched").reason, "overlap-abandoned:binding:session-old")
    XCTAssertEqual(try load("dead-pending-session").reason, "overlap-abandoned:binding:pending")
    XCTAssertEqual(try load("live-queued").status, "queued")
    XCTAssertEqual(try load("dead-completed").status, "completed")
    XCTAssertEqual(try load("unbound-queued").status, "queued")

    _ = await dispatcher.submit(fire(eventId: "fresh"))
    XCTAssertEqual(try load("fresh").serveInstanceId, dispatcher.serveInstanceId)
    await dispatcher.shutdownCancelling()
  }

  func testServeLimitDrainStartsQueuedFireBeforeReturning() async throws {
    let root = try temporaryRoot("limit-drain-queued")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeServeCronConfig(root: root, overlapPolicy: "queue")
    let runner = BlockingCronRunner()
    let server = DefaultEventLiveServer(workflowRunner: runner, clock: AutoAdvanceEventServeClock())
    let serve = Task {
      try await server.serve(eventRoot: root, target: nil, parsed: try ParsedParityOptions(["--limit", "2"]), output: .json)
    }
    let watchdog = Task {
      try await Task.sleep(for: .seconds(60))
      serve.cancel()
    }
    defer { watchdog.cancel() }
    let queuedSeen = await waitUntil("second tick is queued behind the blocked run") {
      ((try? self.receiptFiles(root: root)) ?? []).compactMap { try? self.decodeReceipt(url: $0) }
        .contains { $0.status == "queued" && $0.reason == "overlap-queued:binding:1" }
    }
    XCTAssertTrue(queuedSeen)
    let firstRequestCount = await runner.requestCount
    XCTAssertEqual(firstRequestCount, 1, "the queued fire must not start while the first run is blocked")
    await runner.release(index: 0)
    let secondStarted = await waitUntil("drain starts the queued fire") { await runner.requestCount == 2 }
    XCTAssertTrue(secondStarted)
    await runner.release(index: 1)
    let result = try await serve.value
    XCTAssertEqual(result.status, "ok")
    XCTAssertTrue(result.records.contains("processedEvents=2"), "\(result.records)")
    let statuses = try receiptFiles(root: root).map(decodeReceipt).map(\.status)
    XCTAssertEqual(statuses, ["completed", "completed"])
  }

  func testBlockedCronRunDoesNotBlockFileChangeOrBufferedWebhookyRecord() async throws {
    let root = try temporaryRoot("cron-does-not-block")
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try writeServeCronConfig(root: root)
    try writeFileChangeAndWebhookySources(root: root)
    let webhooky = GatedWebhookyStreamer()
    let runner = MixedSourceRunner(webhooky: webhooky)
    let server = DefaultEventLiveServer(
      webhookyStreamer: webhooky, workflowRunner: runner, clock: SingleTickEventServeClock()
    )
    let serve = Task {
      try await CLIRuntimeEnvironment.$overrides.withValue([
        "TEST_WEBHOOKY_URL": "https://hooks.example.test",
        "TEST_WEBHOOKY_CREDENTIAL": "key-1:secret-1",
        "TEST_WEBHOOKY_FETCH_UUID": "fetch-uuid-1"
      ]) {
        try await server.serve(eventRoot: root, target: nil, parsed: try ParsedParityOptions(["--limit", "3"]), output: .json)
      }
    }
    let watchdog = Task {
      try await Task.sleep(for: .seconds(60))
      serve.cancel()
    }
    defer { watchdog.cancel() }
    // The cron run blocks; only then does the webhooky record arrive and the file appear.
    let cronStarted = await waitUntil("cron run starts and blocks") { await runner.workflows.contains("flow") }
    XCTAssertTrue(cronStarted)
    try Data("%PDF-1.4".utf8).write(to: inbox.appendingPathComponent("paper.pdf"))
    let othersRan = await waitUntil("webhooky and file-change workflows run while cron is blocked") {
      let workflows = await runner.workflows
      return workflows.contains("webhooky-flow") && workflows.contains("document-flow")
    }
    XCTAssertTrue(othersRan)
    let cronStillBlocked = await runner.cronBlocked
    XCTAssertTrue(cronStillBlocked, "the other sources must have been served while the cron run was in flight")
    await runner.releaseCron()
    let result = try await serve.value
    XCTAssertEqual(result.status, "ok")
    XCTAssertTrue(result.records.contains("processedEvents=3"), "\(result.records)")
  }

  private func writeFileChangeAndWebhookySources(root: URL) throws {
    let sources = root.appendingPathComponent("sources", isDirectory: true)
    let bindings = root.appendingPathComponent("bindings", isDirectory: true)
    try """
    {"id":"document-inbox","kind":"file-change","directory":"../inbox","changeTypes":["create"],"filters":{"suffixes":[".pdf"]},"stabilityWindowMs":0}
    """.write(to: sources.appendingPathComponent("document-inbox.json"), atomically: true, encoding: .utf8)
    try """
    {"id":"document-binding","sourceId":"document-inbox","workflowName":"document-flow","match":{"eventType":"file.change.created"},"inputMapping":{"mode":"event-input"}}
    """.write(to: bindings.appendingPathComponent("document-binding.json"), atomically: true, encoding: .utf8)
    try """
    {"id":"webhooky-live","kind":"webhooky","baseUrlEnv":"TEST_WEBHOOKY_URL","credentialEnv":"TEST_WEBHOOKY_CREDENTIAL","fetchUuidEnv":"TEST_WEBHOOKY_FETCH_UUID"}
    """.write(to: sources.appendingPathComponent("webhooky-live.json"), atomically: true, encoding: .utf8)
    try """
    {"id":"webhooky-binding","sourceId":"webhooky-live","workflowName":"webhooky-flow","match":{"eventType":"webhook.record"},"inputMapping":{"mode":"event-input"}}
    """.write(to: bindings.appendingPathComponent("webhooky-binding.json"), atomically: true, encoding: .utf8)
  }

  private func fire(eventId: String) -> CronOverlapFire {
    CronOverlapTestSupport.fire(eventId: eventId)
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

  private func temporaryRoot(_ suffix: String) throws -> URL {
    try CronOverlapTestSupport.temporaryRoot(suffix)
  }

  private func waitForSession(
    _ dispatcher: CronOverlapDispatcher, expected: String = "session-1", file: StaticString = #filePath, line: UInt = #line
  ) async {
    await CronOverlapTestSupport.waitForSession(dispatcher, expected: expected, file: file, line: line)
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
}

/// Helpers shared by the cron overlap test classes.
enum CronOverlapTestSupport {
  static func fire(
    eventId: String,
    workflowName: String = "flow",
    routineId: String? = nil,
    routineStoreRoot: String? = nil
  ) -> CronOverlapFire {
    let date = Date(timeIntervalSince1970: 1_754_438_400)
    return CronOverlapFire(
      bindingId: "binding",
      sourceId: "cron",
      workflowName: workflowName,
      runtimeVariables: [:],
      envelope: ExternalEventEnvelope(
        sourceId: "cron", eventId: eventId, provider: "riela", eventType: "cron.tick",
        receivedAt: date, input: [:]
      ),
      scheduledAt: date,
      firedAt: date,
      routineId: routineId,
      routineStoreRoot: routineStoreRoot,
      coalescedTickCount: 0
    )
  }

  static func writeServeCronConfig(root: URL, overlapPolicy: String? = nil) throws {
    let sources = root.appendingPathComponent("sources", isDirectory: true)
    let bindings = root.appendingPathComponent("bindings", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bindings, withIntermediateDirectories: true)
    try """
    {"id":"cron","kind":"cron","schedule":"* * * * * *","timezone":"UTC"}
    """.write(to: sources.appendingPathComponent("cron.json"), atomically: true, encoding: .utf8)
    let policyField = overlapPolicy.map { ",\"overlapPolicy\":\"\($0)\"" } ?? ""
    try """
    {"id":"binding","sourceId":"cron","workflowName":"flow","match":{"eventType":"cron.tick"},"inputMapping":{"mode":"event-input"}\(policyField)}
    """.write(to: bindings.appendingPathComponent("binding.json"), atomically: true, encoding: .utf8)
  }

  static func receiptFiles(root: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("receipts"), includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
  }

  static func decodeReceipt(url: URL) throws -> PersistedEventReceipt {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(PersistedEventReceipt.self, from: Data(contentsOf: url))
  }

  static func receiptURL(root: URL, eventId: String) -> URL {
    root.appendingPathComponent("receipts", isDirectory: true)
      .appendingPathComponent(cronOverlapReceiptId(sourceId: "cron", eventId: eventId, bindingId: "binding") + ".json")
  }

  static func temporaryRoot(_ suffix: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cron-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  static func waitForSession(
    _ dispatcher: CronOverlapDispatcher, expected: String, file: StaticString, line: UInt
  ) async {
    _ = await waitUntil("running session \(expected)", file: file, line: line) {
      await dispatcher.runningSessionIds(bindingId: "binding").contains(where: { $0 == expected })
    }
  }

  /// Polls a condition with a wall-clock bound and fails the test when it is
  /// never met, so a timeout surfaces here instead of as a later assertion.
  static func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(30),
    file: StaticString,
    line: UInt,
    _ condition: () async -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    var attempt = 0
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      attempt += 1
      if attempt < 500 { await Task.yield() } else { try? await Task.sleep(for: .milliseconds(5)) }
    }
    if await condition() { return true }
    XCTFail("timed out after \(timeout): \(description)", file: file, line: line)
    return false
  }
}

/// Starts the clock at a fixed instant, advances one second on the first
/// sleep (so a per-second cron fires exactly once) and then only yields real
/// time, so later loop iterations keep serving other sources without new ticks.
private final class SingleTickEventServeClock: EventServeClock, @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSince1970: 1_754_438_400)
  private var advanced = false

  func now() -> Date {
    lock.withLock { current }
  }

  func sleep(for duration: Duration) async throws {
    let shouldYieldRealTime = lock.withLock { () -> Bool in
      guard !advanced else { return true }
      advanced = true
      current = current.addingTimeInterval(1)
      return false
    }
    if shouldYieldRealTime {
      try await Task.sleep(for: .milliseconds(10))
    } else {
      await Task.yield()
    }
  }
}

/// A webhooky stream that stays open and yields a record only when told to;
/// records yielded before the serve opens the stream are buffered.
private final class GatedWebhookyStreamer: WebhookyRecordStreaming, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: AsyncThrowingStream<WebhookRecord, Error>.Continuation?
  private var pending: [WebhookRecord] = []

  func stream(
    source: WebhookyStreamSource,
    environment: [String: String]
  ) throws -> AsyncThrowingStream<WebhookRecord, Error> {
    AsyncThrowingStream { continuation in
      let buffered = lock.withLock { () -> [WebhookRecord] in
        self.continuation = continuation
        defer { pending.removeAll() }
        return pending
      }
      buffered.forEach { continuation.yield($0) }
    }
  }

  func yield(_ record: WebhookRecord) {
    let target = lock.withLock { () -> AsyncThrowingStream<WebhookRecord, Error>.Continuation? in
      if continuation == nil { pending.append(record) }
      return continuation
    }
    target?.yield(record)
  }
}

/// The cron workflow (`flow`) blocks until released and, once it is in
/// flight, publishes a webhooky record; every other workflow completes at once.
private actor MixedSourceRunner: EventWorkflowRunning {
  private let webhooky: GatedWebhookyStreamer
  private var cronContinuation: CheckedContinuation<Void, Error>?
  private(set) var workflows: [String] = []
  private(set) var cronBlocked = false

  init(webhooky: GatedWebhookyStreamer) {
    self.webhooky = webhooky
  }

  func runWorkflow(_ request: EventWorkflowRunRequest) async throws -> WorkflowRunResult {
    workflows.append(request.workflowName)
    request.onSessionStarted?("session-\(request.workflowName)")
    if request.workflowName == "flow" {
      cronBlocked = true
      webhooky.yield(WebhookRecord(
        t: 1_754_438_401, fetched: false,
        payload: .object(["events": .array([.object(["eventType": .string("TaskCreated")])])])
      ))
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { cronContinuation = $0 }
      } onCancel: {
        Task { await self.cancelCron() }
      }
      cronBlocked = false
    }
    let date = Date(timeIntervalSince1970: 0)
    let session = WorkflowSession(
      workflowId: request.workflowName, sessionId: "session-\(request.workflowName)", status: .completed,
      entryStepId: "entry", createdAt: date, updatedAt: date, executions: []
    )
    return WorkflowRunResult(workflowId: request.workflowName, session: session, rootOutput: nil, exitCode: 0, transitions: 0)
  }

  func releaseCron() {
    cronContinuation?.resume()
    cronContinuation = nil
  }

  private func cancelCron() {
    cronContinuation?.resume(throwing: CancellationError())
    cronContinuation = nil
  }
}
