import Foundation
import XCTest
@testable import RielaCore

final class SpecialistSupervisorBoundaryTests: XCTestCase {
  func testMatrixIdentifiersAreAcceptedAndSurviveReopening() throws {
    try withStore { store, root in
      let request = SpecialistRequest(
        requestId: "request-matrix",
        sourceEventId: "$event/base64+token:example.org",
        principal: SpecialistPrincipal(
          accountId: "matrix-account", actorId: "@alice:example.org",
          roomId: "!room:example.org", threadId: "$thread:example.org"
        ),
        route: .work, body: "Please handle this task"
      )
      let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "task-matrix"))
      let reopened = SpecialistSupervisorStore(rootDirectory: root.path)
      XCTAssertEqual(try reopened.task(taskId: task.taskId, principal: request.principal)?.requestId, request.requestId)
    }
  }

  func testSourceReplayWithNewLocalRequestIdentityReturnsOriginalTask() throws {
    try withStore { store, _ in
      let request = makeRequest()
      let original = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "task-original"))
      var replay = request
      replay.requestId = "request-after-restart"
      replay.receivedAt = request.receivedAt.addingTimeInterval(60)
      let result = try XCTUnwrap(try store.createTaskIfWorkRequest(replay, taskId: "task-duplicate"))
      XCTAssertEqual(result.taskId, original.taskId)
      XCTAssertEqual(result.requestId, original.requestId)
      XCTAssertNil(try store.task(taskId: "task-duplicate", principal: request.principal))
    }
  }

  func testRequestIdentityCannotBeReusedForDifferentSourceEvent() throws {
    try withStore { store, _ in
      let request = makeRequest()
      _ = try store.accept(request)
      var changed = request
      changed.sourceEventId = "different-event"
      XCTAssertThrowsError(try store.accept(changed))
    }
  }

  func testConcurrentDeliveryStartCannotAcquireAnotherSendPermission() throws {
    try withStore { store, root in
      let request = makeRequest()
      let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "task-delivery"))
      _ = try store.claim(taskId: task.taskId, ownerId: "specialist", capacity: 1, expectedVersion: task.version)
      let event = try XCTUnwrap(try store.outboxEvents(taskId: task.taskId).first)
      let first = try store.beginDelivery(eventId: event.eventId)
      XCTAssertEqual(first.state, .delivering)
      let competingStore = SpecialistSupervisorStore(rootDirectory: root.path)
      XCTAssertThrowsError(try competingStore.beginDelivery(eventId: event.eventId))
      let receipt = try store.completeDelivery(first, state: .delivered, remoteReceiptId: "remote-receipt")
      XCTAssertEqual(receipt.state, .delivered)
    }
  }

  func testServiceLeaseExcludesConcurrentExecutionWorkers() throws {
    try withStore { store, root in
      let first = try store.acquireServiceLease(workerId: "worker-one")
      let otherConnection = SpecialistSupervisorStore(rootDirectory: root.path)
      XCTAssertThrowsError(try otherConnection.acquireServiceLease(workerId: "worker-two"))
      try store.releaseServiceLease(first)
      XCTAssertEqual(try otherConnection.acquireServiceLease(workerId: "worker-two").workerId, "worker-two")
    }
  }

  func testRenewedServiceLeaseCannotBeTakenOverUsingOriginalExpiry() throws {
    try withStore { store, root in
      let start = Date(timeIntervalSince1970: 1_700_000_000)
      let first = try store.acquireServiceLease(workerId: "worker-one", now: start, staleAfter: 60)
      let renewed = try store.renewServiceLease(first, now: start.addingTimeInterval(59))
      let other = SpecialistSupervisorStore(rootDirectory: root.path)
      XCTAssertThrowsError(try other.acquireServiceLease(
        workerId: "worker-two", now: start.addingTimeInterval(61), staleAfter: 60
      ))
      XCTAssertEqual(try other.acquireServiceLease(
        workerId: "worker-two", now: start.addingTimeInterval(120), staleAfter: 60
      ).generation, renewed.generation + 1)
    }
  }

  private func makeRequest() -> SpecialistRequest {
    SpecialistRequest(
      requestId: "request-1", sourceEventId: "source-1",
      principal: SpecialistPrincipal(accountId: "account", actorId: "actor", roomId: "room"),
      route: .work, body: "work", receivedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  func testRunningDispatchCannotBeStartedTwice() throws {
    try withPreparedDispatch { store, dispatchId, _ in
      _ = try store.beginDispatch(dispatchId: dispatchId)
      XCTAssertThrowsError(try store.beginDispatch(dispatchId: dispatchId))
    }
  }

  func testCancellationBeforeLaunchPreventsDispatchStart() throws {
    try withPreparedDispatch { store, dispatchId, task in
      _ = try store.transition(taskId: task.taskId, to: .cancelRequested, expectedVersion: task.version)
      XCTAssertThrowsError(try store.beginDispatch(dispatchId: dispatchId))
      XCTAssertEqual(try store.dispatch(dispatchId: dispatchId)?.state, .prepared)
    }
  }

  func testConfirmedRunningCancellationRemainsDistinctFromRequestAndNeverProjectsSuccess() throws {
    try withPreparedDispatch { store, dispatchId, task in
      _ = try store.beginDispatch(dispatchId: dispatchId)
      let requested = try store.transition(taskId: task.taskId, to: .cancelRequested, expectedVersion: task.version + 1)
      XCTAssertEqual(requested.state, .cancelRequested)
      _ = try store.completeDispatch(
        dispatchId: dispatchId,
        succeeded: false,
        resultJSON: #"{"cancellation":"confirmed_process_termination"}"#
      )
      let confirmed = try XCTUnwrap(try store.task(taskId: task.taskId, principal: task.principal))
      XCTAssertEqual(confirmed.state, .cancelled)
      XCTAssertNotEqual(confirmed.state, .succeeded)
      XCTAssertEqual(try store.dispatch(dispatchId: dispatchId)?.state, .terminal)
      XCTAssertThrowsError(try store.beginDispatch(dispatchId: dispatchId))
    }
  }

  func testTerminalReplayCannotChangeSuccessFlag() throws {
    try withPreparedDispatch { store, dispatchId, _ in
      _ = try store.beginDispatch(dispatchId: dispatchId)
      _ = try store.completeDispatch(dispatchId: dispatchId, succeeded: true, resultJSON: "{}")
      XCTAssertThrowsError(try store.completeDispatch(dispatchId: dispatchId, succeeded: false, resultJSON: "{}"))
    }
  }

  func testCapacityIsSharedAcrossConnectionsAndReleasedAfterCompletion() throws {
    try withPreparedDispatch { store, dispatchId, _ in
      var request = makeRequest()
      request.requestId = "request-second"
      request.sourceEventId = "source-second"
      let second = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "task-second"))
      let otherConnection = SpecialistSupervisorStore(databasePath: store.databasePath)
      XCTAssertThrowsError(try otherConnection.claim(
        taskId: second.taskId, ownerId: "specialist", capacity: 1, expectedVersion: second.version
      )) { error in
        XCTAssertEqual(error as? SpecialistSupervisorStoreError, .capacityUnavailable("specialist"))
      }
      _ = try store.beginDispatch(dispatchId: dispatchId)
      _ = try store.completeDispatch(dispatchId: dispatchId, succeeded: true, resultJSON: "{}")
      let claimed = try otherConnection.claim(
        taskId: second.taskId, ownerId: "specialist", capacity: 1, expectedVersion: second.version
      )
      XCTAssertEqual(claimed.ownerId, "specialist")
    }
  }

  func testTaskStatusDoesNotCrossActorRoomOrThreadBoundaries() throws {
    try withStore { store, _ in
      let request = makeRequest()
      let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "task-private"))
      var actor = request.principal
      actor.actorId = "another-actor"
      var room = request.principal
      room.roomId = "another-room"
      var thread = request.principal
      thread.threadId = "another-thread"
      for principal in [actor, room, thread] {
        XCTAssertNil(try store.task(taskId: task.taskId, principal: principal))
      }
      XCTAssertNotNil(try store.task(taskId: task.taskId, principal: request.principal))
    }
  }

  private func withPreparedDispatch(
    _ body: (SpecialistSupervisorStore, String, SpecialistTask) throws -> Void
  ) throws {
    try withStore { store, _ in
      let task = try XCTUnwrap(try store.createTaskIfWorkRequest(makeRequest(), taskId: "task-dispatch"))
      let claimed = try store.claim(taskId: task.taskId, ownerId: "specialist", capacity: 1, expectedVersion: task.version)
      let reserved = try store.reserveDispatch(
        taskId: task.taskId, dispatchId: "dispatch", childSessionId: "child",
        expectedVersion: claimed.version, workflowId: "workflow", inputJSON: "{}"
      )
      try body(store, "dispatch", reserved)
    }
  }

  private func withStore(_ body: (SpecialistSupervisorStore, URL) throws -> Void) throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/boundary-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(SpecialistSupervisorStore(rootDirectory: root.path), root)
  }
}
