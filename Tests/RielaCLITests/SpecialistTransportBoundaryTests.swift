import Crypto
import Foundation
import XCTest
import RielaCore
import RielaWorkflowRegistry
@testable import RielaCLI

final class SpecialistTransportBoundaryTests: XCTestCase {
  func testServeMixedStatusAndClaimQueuesOnlyScopedStatusReply() async throws {
    let root = try taskDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let work = root.appendingPathComponent("work")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let classifier = work.appendingPathComponent("specialists.json")
    let configuration = #"""
    {"specialists":[{"id":"engineering","capacity":1,"domain":"software","allowedOriginIds":["project"]},{"id":"support","capacity":1,"domain":"support","allowedOriginIds":["project"]}],
    "classifier":{"fixtureDecisions":[{"specialistId":"engineering","kind":"claim","reason":"work"},{"specialistId":"support","kind":"status","reason":"progress"}]}}
    """#
    try Data(configuration.utf8)
      .write(to: classifier)
    let transportConfig = work.appendingPathComponent("transport.json")
    try Data(#"{"matrix":{"homeserver":"https://matrix.invalid","fixtureAccessToken":"stub","roomId":"!room:example.org","accountId":"account","localUserId":"@bot:example.org"}}"#.utf8)
      .write(to: transportConfig)

    let transport = MixedStatusTransport()
    let result = await SpecialistCommandRunner(
      classifierAdapter: makeProductionNodeAdapter(), httpTransport: transport
    ).run(SpecialistCommand(kind: .serve, options: .init(
      scope: "specialist", command: "serve", target: nil,
      arguments: ["--state-root", root.path, "--working-dir", work.path, "--specialist-config", classifier.path,
                  "--transport-config", transportConfig.path, "--mock-scenario", root.appendingPathComponent("fixture.json").path, "--once"],
      output: .json
    )))
    XCTAssertEqual(result.exitCode, .success, result.stderr)

    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let principal = SpecialistPrincipal(accountId: "account", actorId: "@user:example.org", roomId: "!room:example.org")
    let digest = SHA256.hash(data: Data("$mixed-status".utf8)).map { String(format: "%02x", $0) }.joined()
    XCTAssertNil(try store.task(taskId: "task-matrix-\(digest.prefix(48))", principal: principal))
    XCTAssertTrue(try store.recoverableDispatches().isEmpty)
    XCTAssertTrue(try store.pendingOutboxEvents().isEmpty)
    let messageCount = await transport.sentMessageCount()
    XCTAssertEqual(messageCount, 1, "A mixed status/claim must only project a chat clarification/status reply")
  }

  func testServeOnceComposesMatrixClassifierRunnerAndWrikeStubs() async throws {
    let root = try taskDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let work = root.appendingPathComponent("work")
    let workflow = work.appendingPathComponent(".riela/workflows/stub-lifecycle")
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("prompts"), withIntermediateDirectories: true)
    let definition = #"""
    {"workflowId":"stub-lifecycle","description":"Stub lifecycle workflow",
    "defaults":{"maxLoopIterations":3,"nodeTimeoutMs":120000},
    "prompts":{"workerSystemPromptTemplate":"Return concise stub JSON."},
    "entryStepId":"work","nodes":[{"id":"work","nodeFile":"nodes/work.json"}],
    "steps":[{"id":"work","nodeId":"work","role":"worker"}]}
    """#
    try Data(definition.utf8)
      .write(to: workflow.appendingPathComponent("workflow.json"))
    try Data(#"{"id":"work","executionBackend":"codex-agent","model":"gpt-5.4-mini","modelFreeze":false,"promptTemplateFile":"prompts/work.md","variables":{},"output":{"description":"stub"}}"#.utf8)
      .write(to: workflow.appendingPathComponent("nodes/work.json"))
    try Data("return stub JSON".utf8).write(to: workflow.appendingPathComponent("prompts/work.md"))
    let scenario = work.appendingPathComponent("scenario.json")
    try Data(#"{"work":{"provider":"stub","model":"fixture","payload":{"ok":true}}}"#.utf8).write(to: scenario)
    _ = try WorkflowCompactCatalog().refresh(workingDirectory: work.path)
    let card = try WorkflowCompactCatalog().select(workflowId: "stub-lifecycle", workingDirectory: work.path)
    let classifier = work.appendingPathComponent("specialists.json")
    try Data("""
    {"specialists":[{"id":"engineering","capacity":1,"domain":"software","allowedOriginIds":["\(card.originId)"]}],"classifier":{"fixtureDecisions":[{"specialistId":"engineering","kind":"claim","reason":"stub"}]}}
    """.utf8)
      .write(to: classifier)
    let transport = LifecycleTransport()
    let runner = SpecialistCommandRunner(
      classifierAdapter: makeProductionNodeAdapter(), httpTransport: transport, wrikeGateway: LifecycleWrikeGateway()
    )
    let transportConfiguration = work.appendingPathComponent("transport.json")
    try Data(#"{"matrix":{"homeserver":"https://matrix.invalid","fixtureAccessToken":"stub","roomId":"!room:example.org","accountId":"account","localUserId":"@bot:example.org"},"wrike":{"folderId":"folder","statusByLifecycle":{}}}"#.utf8)
      .write(to: transportConfiguration)

    let options = CLICommandOptions(
      scope: "specialist", command: "serve", target: nil,
      arguments: ["--state-root", root.path, "--working-dir", work.path, "--workflow", "stub-lifecycle",
                  "--variables", "{}", "--specialist-config", classifier.path, "--transport-config", transportConfiguration.path,
                  "--mock-scenario", scenario.path, "--once"], output: .json
    )
    let result = await runner.run(SpecialistCommand(kind: .serve, options: options))
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let restart = await runner.run(SpecialistCommand(kind: .serve, options: options))
    XCTAssertEqual(restart.exitCode, .success, restart.stderr)
    let principal = SpecialistPrincipal(accountId: "account", actorId: "@user:example.org", roomId: "!room:example.org")
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let task = try XCTUnwrap(try store.task(taskId: "task-matrix-940ffb8fc9eedd9c606a71df9cf9f467e5d3c1e94d187461", principal: principal))
    XCTAssertEqual(task.state, .succeeded)
    XCTAssertEqual(try store.pendingOutboxEvents().count, 0)
    let sentMessages = await transport.sentMessageCount()
    XCTAssertTrue(sentMessages >= 2, "ownership and terminal chat projection use the configured Matrix boundary")
  }

  #if canImport(WrikeGatewayCore)
  func testTrackerStatusUsesTypedStateNotDisplayText() throws {
    let adapter = SpecialistWrikeGatewayAdapter(configuration: .init(folderId: "fixture-folder", statusByLifecycle: [:]))
    var update = event()
    update.operation = "lifecycle"
    update.payload = "task-failed-cancelled-succeeded is running"
    update.taskState = .running
    XCTAssertEqual(try adapter.lifecycleStatus(for: update), "Active")
    update.taskState = .failed
    update.payload = "a harmless display string"
    XCTAssertEqual(try adapter.lifecycleStatus(for: update), "Deferred")
    update.taskState = nil
    XCTAssertThrowsError(try adapter.lifecycleStatus(for: update))
  }
  #endif

  func testMatrixSuccessWithoutRemoteReceiptIsNotReportedAsDelivered() async throws {
    let adapter = SpecialistMatrixDeliveryAdapter(
      homeserver: try XCTUnwrap(URL(string: "https://matrix.invalid")), accessToken: "fixture-token",
      transport: SpecialistBoundaryHTTPFixture(status: 200, responseBody: "{}")
    )
    do {
      _ = try await adapter.deliver(event(), roomId: "!room:example.org")
      XCTFail("Missing event_id must not be replaced with a synthetic successful receipt")
    } catch {
      // The request may have been applied; malformed evidence cannot prove delivery.
      guard case SpecialistRemoteDeliveryError.uncertain = error else {
        return XCTFail("Expected uncertain delivery, got \(error)")
      }
    }
  }

  func testMatrixAuthenticationAndPermanentFailuresDoNotEnterRetryOrUncertainStates() async throws {
    for status in [400, 401, 403, 404] {
      let adapter = SpecialistMatrixDeliveryAdapter(
        homeserver: try XCTUnwrap(URL(string: "https://matrix.invalid")), accessToken: "fixture-token",
        transport: SpecialistBoundaryHTTPFixture(status: status, responseBody: "{}")
      )
      do {
        _ = try await adapter.deliver(event(), roomId: "!room:example.org")
        XCTFail("HTTP \(status) must be a terminal delivery failure")
      } catch let error as SpecialistRemoteDeliveryError {
        guard case .permanent = error else { return XCTFail("HTTP \(status) incorrectly became \(error)") }
      }
    }
  }

  func testTimeoutAfterAcceptanceRemainsUncertainAndCannotRegressToDeliveredWithoutReceipt() async throws {
    let root = try taskDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let principal = SpecialistPrincipal(accountId: "account", actorId: "actor", roomId: "!room:example.org")
    let request = SpecialistRequest(requestId: "timeout-request", sourceEventId: "timeout-event", principal: principal, route: .work, body: "work")
    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "timeout-task"))
    _ = try store.claim(taskId: task.taskId, ownerId: "owner", capacity: 1, expectedVersion: task.version, destinations: ["chat"])
    let worker = SpecialistOutboxDeliveryWorker(
      store: store,
      matrix: SpecialistMatrixDeliveryAdapter(
        homeserver: try XCTUnwrap(URL(string: "https://matrix.invalid")), accessToken: "fixture",
        transport: ThrowingBoundaryTransport()
      ),
      matrixRoomID: "!room:example.org", wrike: nil, matrixAccountID: "account"
    )
    let receipts = await worker.deliverPending()
    let receipt = try XCTUnwrap(receipts.first)
    XCTAssertEqual(receipt.state, .uncertain)
    XCTAssertTrue(try store.pendingOutboxEvents().isEmpty)
    XCTAssertEqual(try store.uncertainOutboxEvents().map(\.eventId), [receipt.eventId])
  }

  func testMatrixRetryAfterIsPersistedAndFencesLaterSameDestinationEvents() async throws {
    let root = try taskDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let principal = SpecialistPrincipal(accountId: "account", actorId: "actor", roomId: "!room:example.org")
    let request = SpecialistRequest(requestId: "request", sourceEventId: "event", principal: principal, route: .work, body: "work")
    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "task"))
    _ = try store.claim(taskId: task.taskId, ownerId: "owner", capacity: 1, expectedVersion: task.version, destinations: ["chat"])
    let start = Date()
    let worker = SpecialistOutboxDeliveryWorker(
      store: store,
      matrix: SpecialistMatrixDeliveryAdapter(
        homeserver: try XCTUnwrap(URL(string: "https://matrix.invalid")), accessToken: "fixture",
        transport: RetryAfterTransport()
      ),
      matrixRoomID: "!room:example.org",
      wrike: nil,
      matrixAccountID: "account"
    )

    let receipts = await worker.deliverPending()
    let receipt = try XCTUnwrap(receipts.first)
    XCTAssertEqual(receipt.state, .retryableFailure)
    XCTAssertEqual(receipt.attempt, 1)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(receipt.nextAttemptAt).timeIntervalSince(start), 4.5)
    XCTAssertTrue(try store.pendingOutboxEvents().isEmpty, "The persisted first-event backoff fences dependent chat projections")
  }

  func testStaleAcknowledgmentAndTerminalRegressionAreFencedByDeliveryGeneration() throws {
    let root = try taskDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let request = SpecialistRequest(
      requestId: "stale-ack-request", sourceEventId: "stale-ack-event",
      principal: .init(accountId: "account", actorId: "actor", roomId: "room"), route: .work, body: "work"
    )
    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "stale-ack-task"))
    _ = try store.claim(taskId: task.taskId, ownerId: "owner", capacity: 1, expectedVersion: task.version, destinations: ["chat"])
    let event = try XCTUnwrap(try store.pendingOutboxEvents().first)
    let first = try store.beginDelivery(eventId: event.eventId)
    _ = try store.completeDelivery(first, state: .retryableFailure)
    let second = try store.beginDelivery(eventId: event.eventId)
    XCTAssertThrowsError(try store.completeDelivery(first, state: .delivered, remoteReceiptId: "$late"))
    _ = try store.completeDelivery(second, state: .permanentFailure)
    XCTAssertThrowsError(try store.completeDelivery(second, state: .delivered, remoteReceiptId: "$regression"))
  }

  func testDelayedStaleMatrixAcknowledgementIsFencedThroughOutboxWorker() async throws {
    let root = try taskDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let principal = SpecialistPrincipal(accountId: "account", actorId: "actor", roomId: "room")
    let request = SpecialistRequest(
      requestId: "worker-stale-ack-request", sourceEventId: "worker-stale-ack-event",
      principal: principal, route: .work, body: "work"
    )
    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "worker-stale-ack-task"))
    _ = try store.claim(taskId: task.taskId, ownerId: "owner", capacity: 1, expectedVersion: task.version, destinations: ["chat"])
    let transport = DelayedStaleAcknowledgementTransport(store: store)
    let worker = SpecialistOutboxDeliveryWorker(
      store: store,
      matrix: SpecialistMatrixDeliveryAdapter(
        homeserver: try XCTUnwrap(URL(string: "https://matrix.invalid")), accessToken: "fixture", transport: transport
      ),
      matrixRoomID: "room", wrike: nil, matrixAccountID: "account"
    )

    let firstReceipts = await worker.deliverPending()
    let first = try XCTUnwrap(firstReceipts.first)
    XCTAssertEqual(first.state, .retryableFailure)
    await transport.installDelayedAcknowledgement(first)

    let secondReceipts = await worker.deliverPending(
      now: try XCTUnwrap(first.nextAttemptAt).addingTimeInterval(1)
    )
    let second = try XCTUnwrap(secondReceipts.first)
    XCTAssertEqual(second.state, .delivered)
    XCTAssertGreaterThan(second.generation, first.generation)
    let staleWasRejected = await transport.staleAcknowledgementWasRejected()
    XCTAssertTrue(staleWasRejected)
    XCTAssertEqual(try store.pendingOutboxEvents().count, 0)
  }

  func testIndependentTrackerDestinationCompletesWhenChatDestinationIsBackedOff() async throws {
    let root = try taskDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let request = SpecialistRequest(
      requestId: "independent-request", sourceEventId: "independent-event",
      principal: .init(accountId: "account", actorId: "actor", roomId: "room"), route: .work, body: "work"
    )
    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "independent-task"))
    _ = try store.claim(taskId: task.taskId, ownerId: "owner", capacity: 1, expectedVersion: task.version, destinations: ["chat", "tracker"])
    let worker = SpecialistOutboxDeliveryWorker(
      store: store,
      matrix: SpecialistMatrixDeliveryAdapter(
        homeserver: try XCTUnwrap(URL(string: "https://matrix.invalid")), accessToken: "fixture", transport: RetryAfterTransport()
      ),
      matrixRoomID: "room",
      wrike: SpecialistWrikeDeliveryAdapter(gateway: LifecycleWrikeGateway()),
      matrixAccountID: "account"
    )
    let receipts = await worker.deliverPending()
    XCTAssertEqual(receipts.first { $0.destination == "chat" }?.state, .retryableFailure)
    XCTAssertEqual(receipts.first { $0.destination == "tracker" }?.state, .delivered)
  }

  func testWrikeServerFailureDoesNotAuthorizeBlindWriteRetry() async throws {
    let adapter = SpecialistWrikeDeliveryAdapter(
      gateway: SpecialistAmbiguousWrikeGateway()
    )
    do {
      _ = try await adapter.deliver(event())
      XCTFail("An ambiguous write failure must not be reported as delivered")
    } catch {
      guard case SpecialistRemoteDeliveryError.uncertain = error else {
        return XCTFail("A server error may follow a committed remote write; got \(error)")
      }
    }
  }

  func testAuthenticatedMatrixPollDerivesProviderPrincipalAndIgnoresSelf() async throws {
    let body = #"""
    {"next_batch":"cursor-2","rooms":{"join":{"!room:example.org":{"timeline":{"events":[
      {"type":"m.room.message","event_id":"$self","sender":"@bot:example.org","content":{"body":"ignore"}},
      {"type":"m.room.message","event_id":"$user","sender":"@user:example.org","content":{"body":"status","m.relates_to":{"rel_type":"m.thread","event_id":"$thread"}}}
    ]}}}}}
    """#
    let adapter = SpecialistMatrixIntakeAdapter(
      homeserver: try XCTUnwrap(URL(string: "https://matrix.invalid")), accessToken: "token",
      accountId: "account", localUserId: "@bot:example.org",
      transport: SpecialistBoundaryHTTPFixture(status: 200, responseBody: body)
    )
    let page = try await adapter.poll(since: "cursor-1")
    XCTAssertEqual(page.nextBatch, "cursor-2")
    let event = try XCTUnwrap(page.events.first)
    XCTAssertEqual(event.sourceEventId, "$user")
    XCTAssertEqual(event.principal, SpecialistPrincipal(accountId: "account", actorId: "@user:example.org", roomId: "!room:example.org", threadId: "$thread"))
  }

  func testResponseLossThenReaderReceiptSettlesWithoutSecondWrite() async throws {
    let root = try taskDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let principal = SpecialistPrincipal(accountId: "account", actorId: "actor", roomId: "room")
    let request = SpecialistRequest(requestId: "request", sourceEventId: "event", principal: principal, route: .work, body: "work")
    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "task"))
    _ = try store.claim(taskId: task.taskId, ownerId: "owner", capacity: 1, expectedVersion: task.version, destinations: ["tracker"])

    let uncertainWorker = SpecialistOutboxDeliveryWorker(
      store: store, matrix: nil, matrixRoomID: nil,
      wrike: SpecialistWrikeDeliveryAdapter(gateway: ReconciliationGateway(outcome: .notFound))
    )
    _ = await uncertainWorker.deliverPending()
    let uncertain = try XCTUnwrap(try store.uncertainOutboxEvents().first)

    let repairWorker = SpecialistOutboxDeliveryWorker(
      store: store, matrix: nil, matrixRoomID: nil,
      wrike: SpecialistWrikeDeliveryAdapter(gateway: ReconciliationGateway(outcome: .delivered("wrike-receipt")))
    )
    let repaired = await repairWorker.reconcileUncertain()
    XCTAssertEqual(repaired.map(\.eventId), [uncertain.eventId])
    XCTAssertTrue(try store.uncertainOutboxEvents().isEmpty)
  }

  func testNegativeAndConflictingReaderResultsKeepResponseLossUncertain() async throws {
    let root = try taskDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for outcome in [SpecialistWrikeReconciliation.notFound, .conflicting] {
      let stateRoot = root.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
      let store = SpecialistSupervisorStore(rootDirectory: stateRoot.path)
      let principal = SpecialistPrincipal(accountId: "account", actorId: "actor", roomId: "room")
      let request = SpecialistRequest(requestId: "request-\(UUID().uuidString)", sourceEventId: "event-\(UUID().uuidString)", principal: principal, route: .work, body: "work")
      let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "task-\(UUID().uuidString)"))
      _ = try store.claim(taskId: task.taskId, ownerId: "owner", capacity: 1, expectedVersion: task.version, destinations: ["tracker"])
      let worker = SpecialistOutboxDeliveryWorker(
        store: store, matrix: nil, matrixRoomID: nil,
        wrike: SpecialistWrikeDeliveryAdapter(gateway: ReconciliationGateway(outcome: outcome))
      )
      _ = await worker.deliverPending()
      _ = await worker.reconcileUncertain()
      XCTAssertEqual(try store.uncertainOutboxEvents().count, 1)
    }
  }

  private func event() -> SpecialistOutboxEvent {
    SpecialistOutboxEvent(eventId: "event-1", taskId: "task-1", destination: "chat", operation: "ownership", payload: "owned", sequence: 1)
  }

  private func taskDirectory() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/transport-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

private struct SpecialistBoundaryHTTPFixture: SpecialistHTTPTransport {
  let status: Int
  let responseBody: String

  func send(url: URL, method: String, headers: [String: String], body: Data) async throws -> (status: Int, body: Data) {
    (status, Data(responseBody.utf8))
  }
}

private struct ThrowingBoundaryTransport: SpecialistHTTPTransport {
  func send(url _: URL, method _: String, headers _: [String: String], body _: Data) async throws -> (status: Int, body: Data) {
    throw URLError(.timedOut)
  }
}

private struct RetryAfterTransport: SpecialistHTTPTransport {
  func send(url _: URL, method _: String, headers _: [String: String], body _: Data) async throws -> (status: Int, body: Data) {
    (429, Data())
  }

  func sendWithHeaders(url _: URL, method _: String, headers _: [String: String], body _: Data) async throws -> SpecialistHTTPResponse {
    SpecialistHTTPResponse(status: 429, body: Data(), headers: ["retry-after": "5"])
  }
}

/// Models a provider response that arrives after the worker has already
/// persisted a retry and started a newer fenced attempt. The stale completion
/// is injected at the HTTP boundary, not by the test after delivery returns.
private actor DelayedStaleAcknowledgementTransport: SpecialistHTTPTransport {
  private let store: SpecialistSupervisorStore
  private var callCount = 0
  private var delayedReceipt: SpecialistDeliveryReceipt?
  private var staleWasRejected = false

  init(store: SpecialistSupervisorStore) {
    self.store = store
  }

  func installDelayedAcknowledgement(_ receipt: SpecialistDeliveryReceipt) {
    delayedReceipt = receipt
  }

  func send(url _: URL, method _: String, headers _: [String: String], body _: Data) async throws -> (status: Int, body: Data) {
    callCount += 1
    if callCount == 1 {
      return (503, Data())
    }
    if let delayedReceipt {
      do {
        _ = try store.completeDelivery(delayedReceipt, state: .delivered, remoteReceiptId: "$late")
      } catch {
        staleWasRejected = true
      }
    }
    return (200, Data(#"{"event_id":"$current"}"#.utf8))
  }

  func staleAcknowledgementWasRejected() -> Bool {
    staleWasRejected
  }
}

private struct SpecialistAmbiguousWrikeGateway: SpecialistWrikeGateway {
  func deliver(_ event: SpecialistOutboxEvent, trackerTaskId: String?) async throws -> String {
    throw SpecialistRemoteDeliveryError.uncertain
  }
}

private struct ReconciliationGateway: SpecialistWrikeGateway {
  let outcome: SpecialistWrikeReconciliation

  func deliver(_: SpecialistOutboxEvent, trackerTaskId _: String?) async throws -> String {
    throw SpecialistRemoteDeliveryError.uncertain
  }

  func reconcile(_: SpecialistOutboxEvent, trackerTaskId _: String?) async throws -> SpecialistWrikeReconciliation {
    outcome
  }
}

private actor LifecycleTransport: SpecialistHTTPTransport {
  private var sentMessages = 0

  func send(url: URL, method: String, headers _: [String: String], body _: Data) async throws -> (status: Int, body: Data) {
    if method == "GET", url.path.hasSuffix("/_matrix/client/v3/sync") {
      let response = #"{"next_batch":"stub-cursor","rooms":{"join":{"!room:example.org":{"timeline":{"events":[{"type":"m.room.message","event_id":"$event","sender":"@user:example.org","content":{"body":"run fixture"}}]}}}}}"#
      return (200, Data(response.utf8))
    }
    if method == "PUT" {
      sentMessages += 1
      return (200, Data(#"{"event_id":"$stub-receipt"}"#.utf8))
    }
    return (404, Data())
  }

  func sentMessageCount() -> Int { sentMessages }
}

private actor MixedStatusTransport: SpecialistHTTPTransport {
  private var sentInbound = false
  private var sentMessages = 0

  func send(url: URL, method: String, headers _: [String: String], body _: Data) async throws -> (status: Int, body: Data) {
    if method == "GET", url.path.hasSuffix("/_matrix/client/v3/sync") {
      defer { sentInbound = true }
      let events = sentInbound ? "[]" : #"[{"type":"m.room.message","event_id":"$mixed-status","sender":"@user:example.org","content":{"body":"What is the status?"}}]"#
      let response = #"{"next_batch":"mixed-cursor","rooms":{"join":{"!room:example.org":{"timeline":{"events":\#(events)}}}}}"#
      return (200, Data(response.utf8))
    }
    if method == "PUT" {
      sentMessages += 1
      return (200, Data(#"{"event_id":"$mixed-receipt"}"#.utf8))
    }
    return (404, Data())
  }

  func sentMessageCount() -> Int { sentMessages }
}

private struct LifecycleWrikeGateway: SpecialistWrikeGateway {
  func deliver(_ event: SpecialistOutboxEvent, trackerTaskId _: String?) async throws -> String {
    "wrike-" + event.eventId
  }

  func reconcile(_: SpecialistOutboxEvent, trackerTaskId _: String?) async throws -> SpecialistWrikeReconciliation {
    .notFound
  }
}
