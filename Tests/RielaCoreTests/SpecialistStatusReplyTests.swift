import Foundation
import XCTest
@testable import RielaCore

final class SpecialistStatusReplyTests: XCTestCase {
  func testStatusReplyIsScopedDurableAndDoesNotDispatchWork() throws {
    let store = try makeStore()
    let principal = SpecialistPrincipal(accountId: "account", actorId: "actor", roomId: "room", threadId: "thread")
    let ownRequest = SpecialistRequest(requestId: "own", sourceEventId: "own-event", principal: principal, route: .work, body: "work")
    _ = try store.createTaskIfWorkRequest(ownRequest, taskId: "visible-task")
    for (index, other) in [
      SpecialistPrincipal(accountId: "other", actorId: "actor", roomId: "room", threadId: "thread"),
      SpecialistPrincipal(accountId: "account", actorId: "other", roomId: "room", threadId: "thread"),
      SpecialistPrincipal(accountId: "account", actorId: "actor", roomId: "other", threadId: "thread"),
      SpecialistPrincipal(accountId: "account", actorId: "actor", roomId: "room", threadId: nil)
    ].enumerated() {
      _ = try store.createTaskIfWorkRequest(.init(requestId: "private-\(index)", sourceEventId: "private-event-\(index)",
                                                 principal: other, route: .work, body: "secret"), taskId: "hidden-task-\(index)")
    }
    let status = SpecialistRequest(requestId: "status", sourceEventId: "status-event", principal: principal, route: .status, body: "/status")
    let reply = try store.enqueueStatusReply(status)
    XCTAssertTrue(reply.payload.contains("visible-task: queued"))
    XCTAssertFalse(reply.payload.contains("hidden-task"))
    XCTAssertEqual(reply.recipient, principal)
    XCTAssertNil(reply.taskId)
    XCTAssertEqual(reply.destination, "chat")
    let reopened = SpecialistSupervisorStore(databasePath: store.databasePath)
    XCTAssertEqual(try reopened.enqueueStatusReply(status), reply)
    XCTAssertEqual(try reopened.pendingOutboxEvents().map(\.eventId), [reply.eventId])
    XCTAssertTrue(try reopened.recoverableDispatches().isEmpty)
    XCTAssertNil(try reopened.task(taskId: "task-status", principal: principal))
  }

  func testStatusReplyProjectsFactualObservationStalenessAndUncertainty() throws {
    let store = try makeStore()
    let principal = SpecialistPrincipal(accountId: "account", actorId: "actor", roomId: "room")
    let request = SpecialistRequest(
      requestId: "progress", sourceEventId: "progress-event", principal: principal, route: .work, body: "work"
    )
    _ = try store.createTaskIfWorkRequest(request, taskId: "progress-task")
    let oldObservation = Date().addingTimeInterval(-301)
    _ = try store.projectProgress(
      taskId: "progress-task",
      childStepId: "durable-step",
      childObservedAt: oldObservation,
      trackerObservedAt: oldObservation,
      uncertain: true
    )

    let reply = try store.enqueueStatusReply(SpecialistRequest(
      requestId: "progress-status", sourceEventId: "progress-status-event",
      principal: principal, route: .status, body: "/status progress-task"
    ))
    XCTAssertTrue(reply.payload.contains("childStep=durable-step"))
    XCTAssertTrue(reply.payload.contains("childObservation=stale"))
    XCTAssertTrue(reply.payload.contains("trackerObservation=stale"))
    XCTAssertTrue(reply.payload.contains("progress=uncertain"))
    XCTAssertFalse(reply.payload.contains("%"))
    XCTAssertFalse(reply.payload.localizedCaseInsensitiveContains("eta"))
  }

  func testLifecycleUncertaintyAndClarificationContinuationAreDurable() throws {
    let store = try makeStore()
    let principal = SpecialistPrincipal(accountId: "account", actorId: "actor", roomId: "room")
    let request = SpecialistRequest(requestId: "pending", sourceEventId: "pending-event", principal: principal, route: .work, body: "work")
    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "pending-task"))
    let clarification = try store.transition(taskId: task.taskId, to: .needsClarification, expectedVersion: task.version)
    let clarificationRequest = SpecialistRequest(
      requestId: "clarification", sourceEventId: "clarification-event", principal: principal,
      route: .clarification, body: "the requested details"
    )
    let continuation = try XCTUnwrap(try store.beginClarificationContinuation(clarificationRequest))
    let continued = continuation.task
    XCTAssertEqual(clarification.state, .needsClarification)
    XCTAssertEqual(continued.taskId, task.taskId)
    XCTAssertEqual(continued.state, .queued)
    XCTAssertEqual(continued.progressUncertain, true)
    XCTAssertEqual(continued.continuationRequestId, continuation.request.requestId)
    let reopened = SpecialistSupervisorStore(databasePath: store.databasePath)
    let replayed = try XCTUnwrap(try reopened.beginClarificationContinuation(clarificationRequest))
    XCTAssertEqual(replayed.task.taskId, continuation.task.taskId)
    XCTAssertEqual(replayed.request.requestId, continuation.request.requestId)
    XCTAssertEqual(
      try reopened.taskForRoutingRequest(requestId: continuation.request.requestId, principal: principal)?.taskId,
      task.taskId,
      "Restart-safe continuation routing must retain one task identity"
    )
    let pending = try reopened.pendingClarificationContinuations()
    XCTAssertEqual(pending.map(\.request.requestId), [continuation.request.requestId])
    XCTAssertEqual(pending.first?.task.taskId, task.taskId)

    let recovery = try store.transition(taskId: task.taskId, to: .recoveryRequired, expectedVersion: continued.version)
    let reply = try store.enqueueStatusReply(.init(
      requestId: "recovery-status", sourceEventId: "recovery-status-event", principal: principal,
      route: .status, body: "/status pending-task"
    ))
    XCTAssertEqual(recovery.state, .recoveryRequired)
    XCTAssertTrue(reply.payload.contains("recovery_required"))
    XCTAssertTrue(reply.payload.contains("progress=uncertain"))
  }

  private func makeStore() throws -> SpecialistSupervisorStore {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/status-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return SpecialistSupervisorStore(rootDirectory: root.path)
  }
}
