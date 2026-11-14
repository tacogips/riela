import Foundation
import XCTest
@testable import RielaCore

final class SpecialistSupervisorStoreTests: XCTestCase {
  func testReplayConflictOwnershipCapacityAndDispatchReservationAreDurable() throws {
    let store = SpecialistSupervisorStore(rootDirectory: try temporaryDirectory().path)
    let request = makeRequest()

    XCTAssertEqual(try store.accept(request), request)
    XCTAssertEqual(try store.accept(request), request)
    var changed = request
    changed.body = "changed payload"
    XCTAssertThrowsError(try store.accept(changed)) { error in
      XCTAssertEqual(error as? SpecialistSupervisorStoreError, .requestConflict(request.sourceEventId))
    }

    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "task-1"))
    let claimed = try store.claim(taskId: task.taskId, ownerId: "specialist-a", capacity: 1, expectedVersion: task.version)
    XCTAssertEqual(claimed.ownerId, "specialist-a")
    XCTAssertEqual(claimed.version, 1)
    XCTAssertEqual(Set(try store.outboxEvents(taskId: task.taskId).map(\.destination)), Set(["chat", "tracker"]))

    let reserved = try store.reserveDispatch(
      taskId: task.taskId,
      dispatchId: "dispatch-1",
      childSessionId: "child-1",
      expectedVersion: claimed.version
    )
    XCTAssertEqual(reserved.dispatchId, "dispatch-1")
    let replayedReservation = try store.reserveDispatch(
      taskId: task.taskId,
      dispatchId: "dispatch-1",
      childSessionId: "child-1",
      expectedVersion: claimed.version
    )
    XCTAssertEqual(replayedReservation.taskId, reserved.taskId)
    XCTAssertEqual(replayedReservation.dispatchId, reserved.dispatchId)
    XCTAssertEqual(replayedReservation.childSessionId, reserved.childSessionId)
    XCTAssertEqual(replayedReservation.version, reserved.version)
    XCTAssertThrowsError(try store.reserveDispatch(
      taskId: task.taskId,
      dispatchId: "dispatch-2",
      childSessionId: "child-2",
      expectedVersion: reserved.version
    ))
  }

  func testStatusRequestNeverCreatesTaskAndDeliveryCompletionIsFenced() throws {
    let store = SpecialistSupervisorStore(rootDirectory: try temporaryDirectory().path)
    var status = makeRequest()
    status.requestId = "request-status"
    status.sourceEventId = "event-status"
    status.route = .status
    XCTAssertNil(try store.createTaskIfWorkRequest(status, taskId: "task-status"))
    XCTAssertNil(try store.task(taskId: "task-status", principal: status.principal))

    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(makeRequest(), taskId: "task-1"))
    let claimed = try store.claim(taskId: task.taskId, ownerId: "specialist-a", capacity: 1, expectedVersion: task.version)
    let event = try XCTUnwrap(try store.outboxEvents(taskId: claimed.taskId).first)
    let firstLease = try store.beginDelivery(eventId: event.eventId)
    let delivered = try store.completeDelivery(firstLease, state: .delivered, remoteReceiptId: "receipt-1")
    XCTAssertEqual(delivered.state, .delivered)
    let replayedDelivery = try store.beginDelivery(eventId: event.eventId)
    XCTAssertEqual(replayedDelivery.state, .delivered)
    XCTAssertEqual(replayedDelivery.generation, delivered.generation)
    XCTAssertEqual(replayedDelivery.remoteReceiptId, delivered.remoteReceiptId)
    XCTAssertThrowsError(try store.completeDelivery(firstLease, state: .retryableFailure)) { error in
      XCTAssertEqual(error as? SpecialistSupervisorStoreError, .deliveryConflict(event.eventId))
    }
  }

  func testMatrixOpaqueIDsReplayAndChildCompletionSurvivesReopen() throws {
    let root = try temporaryDirectory()
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let principal = SpecialistPrincipal(
      accountId: "@bot:example.test",
      actorId: "@person:example.test",
      roomId: "!room:example.test",
      threadId: "$thread/1"
    )
    let request = SpecialistRequest(
      requestId: "request-matrix",
      sourceEventId: "$event/1",
      principal: principal,
      route: .work,
      body: "run work"
    )
    let accepted = try store.accept(request)
    var replay = request
    replay.requestId = "request-redelivery"
    let replayed = try store.accept(replay)
    XCTAssertEqual(replayed.requestId, accepted.requestId)
    XCTAssertEqual(replayed.sourceEventId, accepted.sourceEventId)
    XCTAssertEqual(replayed.principal, accepted.principal)

    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "task-matrix"))
    let claimed = try store.claim(taskId: task.taskId, ownerId: "specialist-a", capacity: 1, expectedVersion: task.version)
    _ = try store.reserveDispatch(
      taskId: task.taskId,
      dispatchId: "dispatch-matrix",
      childSessionId: "child-matrix",
      expectedVersion: claimed.version,
      workflowId: "existing-workflow",
      inputJSON: #"{"request":"work"}"#
    )
    XCTAssertEqual(try store.dispatch(dispatchId: "dispatch-matrix")?.state, .prepared)
    _ = try store.beginDispatch(dispatchId: "dispatch-matrix")
    // Simulates reopening after child completion but before any outbox sender.
    let reopened = SpecialistSupervisorStore(rootDirectory: root.path)
    let terminal = try reopened.completeDispatch(
      dispatchId: "dispatch-matrix",
      succeeded: true,
      resultJSON: #"{"result":"ok"}"#
    )
    XCTAssertEqual(terminal.state, .terminal)
    XCTAssertEqual(try reopened.task(taskId: task.taskId, principal: principal)?.state, .succeeded)
    XCTAssertEqual(Set(try reopened.outboxEvents(taskId: task.taskId).suffix(2).map(\.destination)), Set(["chat", "tracker"]))
    XCTAssertEqual(try reopened.completeDispatch(dispatchId: "dispatch-matrix", succeeded: true, resultJSON: #"{"result":"ok"}"#), terminal)
  }

  func testRetryableDeliveryUsesDurableBackoffAndBlocksLaterDestinationEvents() throws {
    let store = SpecialistSupervisorStore(rootDirectory: try temporaryDirectory().path)
    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(makeRequest(), taskId: "task-backoff"))
    let claimed = try store.claim(taskId: task.taskId, ownerId: "specialist-a", capacity: 1, expectedVersion: task.version)
    let firstTracker = try XCTUnwrap(
      try store.outboxEvents(taskId: claimed.taskId).first { $0.destination == "tracker" }
    )
    let lease = try store.beginDelivery(eventId: firstTracker.eventId)
    let retry = try store.completeDelivery(lease, state: .retryableFailure)
    XCTAssertEqual(retry.state, .retryableFailure)
    XCTAssertNotNil(retry.nextAttemptAt)

    let transitioned = try store.transition(
      taskId: claimed.taskId, to: .needsClarification, expectedVersion: claimed.version
    )
    XCTAssertEqual(transitioned.state, .needsClarification)
    let pending = try store.pendingOutboxEvents()
    XCTAssertFalse(pending.contains { $0.destination == "tracker" }, "the backoff and ordering gate must hold tracker updates")
    XCTAssertTrue(pending.contains { $0.destination == "chat" }, "independent destinations remain eligible")
  }

  func testExpiredDeliveringReceiptIsFencedUncertainBeforeAnyLaterWrite() throws {
    let root = try temporaryDirectory()
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(makeRequest(), taskId: "task-expired-delivery"))
    _ = try store.claim(taskId: task.taskId, ownerId: "specialist-a", capacity: 1, expectedVersion: task.version)
    let event = try XCTUnwrap(try store.outboxEvents(taskId: task.taskId).first { $0.destination == "chat" })
    let lease = try store.beginDelivery(eventId: event.eventId)
    XCTAssertEqual(lease.state, .delivering)
    let fenced = try store.fenceExpiredDeliveries(now: Date().addingTimeInterval(61), staleAfter: 60)
    XCTAssertEqual(fenced.map(\.eventId), [event.eventId])
    XCTAssertEqual(try store.deliveryReceipt(eventId: event.eventId)?.state, .uncertain)
    XCTAssertEqual(try store.beginDelivery(eventId: event.eventId).state, .uncertain)
    XCTAssertEqual(try store.uncertainOutboxEvents().map(\.eventId), [event.eventId])
  }

  func testPreparedCancellationAndOperatorRecoveryAreDurableAndVersionFenced() throws {
    let store = SpecialistSupervisorStore(rootDirectory: try temporaryDirectory().path)
    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(makeRequest(), taskId: "task-cancel-before-start"))
    let claimed = try store.claim(taskId: task.taskId, ownerId: "specialist-a", capacity: 1, expectedVersion: task.version)
    _ = try store.reserveDispatch(
      taskId: task.taskId, dispatchId: "dispatch-cancel-before-start", childSessionId: "child-cancel-before-start",
      expectedVersion: claimed.version
    )
    let cancelling = try store.transition(taskId: task.taskId, to: .cancelRequested, expectedVersion: claimed.version + 1)
    let cancelled = try store.cancelPreparedDispatch(dispatchId: "dispatch-cancel-before-start")
    XCTAssertEqual(cancelled.state, .terminal)
    XCTAssertEqual(try store.task(taskId: task.taskId, principal: task.principal)?.state, .cancelled)

    var second = makeRequest(); second.requestId = "request-recovery"; second.sourceEventId = "event-recovery"
    let recoveryTask = try XCTUnwrap(try store.createTaskIfWorkRequest(second, taskId: "task-recovery"))
    let recoveryClaim = try store.claim(taskId: recoveryTask.taskId, ownerId: "specialist-b", capacity: 1, expectedVersion: recoveryTask.version)
    _ = try store.reserveDispatch(taskId: recoveryTask.taskId, dispatchId: "dispatch-recovery", childSessionId: "child-recovery", expectedVersion: recoveryClaim.version)
    _ = try store.beginDispatch(dispatchId: "dispatch-recovery")
    _ = try store.requireDispatchRecovery(dispatchId: "dispatch-recovery")
    let unresolved = try XCTUnwrap(try store.task(taskId: recoveryTask.taskId, principal: second.principal))
    XCTAssertThrowsError(try store.reconcileDispatch(
      taskId: unresolved.taskId, requestId: second.requestId, expectedVersion: unresolved.version + 1,
      outcome: .confirmedNoEffect, evidence: "checked canonical receipt"
    ))
    let reconciled = try store.reconcileDispatch(
      taskId: unresolved.taskId, requestId: second.requestId, expectedVersion: unresolved.version,
      outcome: .confirmedNoEffect, evidence: "checked canonical receipt"
    )
    XCTAssertEqual(reconciled.state, .failed)
    XCTAssertEqual(try store.dispatch(dispatchId: "dispatch-recovery")?.state, .terminal)
    XCTAssertEqual(cancelling.state, .cancelRequested)
  }

  private func makeRequest() -> SpecialistRequest {
    SpecialistRequest(
      requestId: "request-1",
      sourceEventId: "event-1",
      principal: SpecialistPrincipal(accountId: "account-1", actorId: "actor-1", roomId: "room-1"),
      route: .work,
      body: "run the registered workflow",
      receivedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  private func temporaryDirectory() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = repository.appendingPathComponent("tmp/specialist-supervisor/store-tests/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: url) }
    return url
  }
}
