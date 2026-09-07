import Foundation
import XCTest
@testable import RielaCore

final class SpecialistMonitorControlTests: XCTestCase {
  func testLaunchFencingRevokesUnstartedMonitorButNeverReopensNodeStartedChild() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let principal = SpecialistPrincipal(accountId: "local", actorId: "operator", roomId: "local")

    func reserve(_ suffix: String) throws -> SpecialistDispatch {
      let request = SpecialistRequest(requestId: "request-\(suffix)", sourceEventId: "event-\(suffix)", principal: principal, route: .work, body: "work")
      let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "task-\(suffix)"))
      let claimed = try store.claim(taskId: task.taskId, ownerId: "owner", capacity: 2, expectedVersion: task.version)
      _ = try store.reserveDispatch(
        taskId: task.taskId, dispatchId: "dispatch-\(suffix)", childSessionId: "child-\(suffix)",
        expectedVersion: claimed.version, workflowId: "workflow", entryStepId: "entry"
      )
      let dispatch = try store.beginDispatch(dispatchId: "dispatch-\(suffix)")
      let now = Date()
      try SQLiteWorkflowRuntimePersistenceStore(
        rootDirectory: root.appendingPathComponent("runtime-records").path
      ).save(WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(
        workflowId: "workflow", sessionId: try XCTUnwrap(dispatch.childSessionId), status: .created,
        entryStepId: "entry", currentStepId: "entry", createdAt: now, updatedAt: now,
        rootSessionId: try XCTUnwrap(dispatch.childSessionId)
      )))
      return dispatch
    }

    _ = try reserve("unstarted")
    let nonce = UUID().uuidString + UUID().uuidString
    XCTAssertEqual(try store.authorizeChildMonitorLaunch(dispatchId: "dispatch-unstarted", controlToken: nonce).launchPhase, .launchAuthorized)
    XCTAssertEqual(try store.bindChildMonitor(dispatchId: "dispatch-unstarted", childSessionId: "child-unstarted", token: nonce).launchPhase, .monitorBound)
    _ = try store.requireDispatchRecovery(dispatchId: "dispatch-unstarted")
    XCTAssertEqual(try store.reopenUnstartedDispatch(dispatchId: "dispatch-unstarted").state, .prepared)
    XCTAssertNil(try store.dispatch(dispatchId: "dispatch-unstarted")?.childControlTokenHash)
    XCTAssertEqual(try store.task(taskId: "task-unstarted", principal: principal)?.state, .queued)

    _ = try reserve("started")
    let startedNonce = UUID().uuidString + UUID().uuidString
    _ = try store.authorizeChildMonitorLaunch(dispatchId: "dispatch-started", controlToken: startedNonce)
    _ = try store.bindChildMonitor(dispatchId: "dispatch-started", childSessionId: "child-started", token: startedNonce)
    _ = try store.beginChildNodeExecution(dispatchId: "dispatch-started", childSessionId: "child-started", token: startedNonce)
    _ = try store.requireDispatchRecovery(dispatchId: "dispatch-started")
    XCTAssertThrowsError(try store.reopenUnstartedDispatch(dispatchId: "dispatch-started"))
    XCTAssertEqual(try store.task(taskId: "task-started", principal: principal)?.state, .recoveryRequired)
  }

  func testNonceAndSessionBindHeartbeatAndDurableCancellation() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let principal = SpecialistPrincipal(accountId: "local", actorId: "operator", roomId: "local")
    let request = SpecialistRequest(requestId: "request", sourceEventId: "event", principal: principal, route: .work, body: "work")
    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "task"))
    let claimed = try store.claim(taskId: task.taskId, ownerId: "owner", capacity: 1, expectedVersion: task.version)
    _ = try store.reserveDispatch(taskId: task.taskId, dispatchId: "dispatch", childSessionId: "child", expectedVersion: claimed.version)
    _ = try store.beginDispatch(dispatchId: "dispatch")
    let token = UUID().uuidString + UUID().uuidString
    XCTAssertEqual(try store.pollChildMonitorControl(dispatchId: "dispatch", childSessionId: "child", token: token), .awaitingBinding)
    let bound = try store.recordChildMonitor(dispatchId: "dispatch", processId: 123, receiptPath: "/receipt", controlToken: token)
    XCTAssertNotEqual(bound.childControlTokenHash, token)
    XCTAssertNil(bound.childMonitorHeartbeatAt)
    XCTAssertThrowsError(try store.pollChildMonitorControl(dispatchId: "dispatch", childSessionId: "wrong-child", token: token))
    XCTAssertThrowsError(try store.pollChildMonitorControl(dispatchId: "dispatch", childSessionId: "child", token: String(repeating: "x", count: 72)))
    XCTAssertThrowsError(try store.pollChildMonitorControl(dispatchId: "dispatch", childSessionId: "child", token: XCTUnwrap(bound.childControlTokenHash)))
    XCTAssertNil(try store.dispatch(dispatchId: "dispatch")?.childMonitorHeartbeatAt)
    let heartbeat = Date(timeIntervalSince1970: 10)
    XCTAssertEqual(try store.pollChildMonitorControl(dispatchId: "dispatch", childSessionId: "child", token: token, now: heartbeat), .run)
    XCTAssertEqual(try store.dispatch(dispatchId: "dispatch")?.childMonitorHeartbeatAt, heartbeat)
    let running = try XCTUnwrap(try store.task(taskId: task.taskId, principal: principal))
    _ = try store.transition(taskId: task.taskId, to: .cancelRequested, expectedVersion: running.version)
    XCTAssertEqual(try SpecialistSupervisorStore(rootDirectory: root.path).pollChildMonitorControl(
      dispatchId: "dispatch", childSessionId: "child", token: token
    ), .cancel)
    XCTAssertEqual(try store.task(taskId: task.taskId, principal: principal)?.state, .cancelRequested)
    XCTAssertFalse(try store.outboxEvents(taskId: task.taskId).contains { $0.taskState == .cancelled })
  }

  func testKernelBackedLaunchWindowsReopenOnlyWithCanonicalNoEffectEvidence() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let principal = SpecialistPrincipal(accountId: "local", actorId: "operator", roomId: "local")

    for phase in ["after-begin-dispatch", "after-process-run-before-monitor-binding"] {
      let request = SpecialistRequest(
        requestId: "request-\(phase)", sourceEventId: "event-\(phase)", principal: principal,
        route: .work, body: "work"
      )
      let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "task-\(phase)"))
      let claimed = try store.claim(taskId: task.taskId, ownerId: "owner", capacity: 2, expectedVersion: task.version)
      _ = try store.reserveDispatch(
        taskId: task.taskId, dispatchId: "dispatch-\(phase)", childSessionId: "child-\(phase)",
        expectedVersion: claimed.version, workflowId: "workflow", entryStepId: "entry"
      )
      _ = try store.beginDispatch(dispatchId: "dispatch-\(phase)")
      let now = Date()
      let runtime = SQLiteWorkflowRuntimePersistenceStore(
        rootDirectory: root.appendingPathComponent("runtime-records").path
      )
      try runtime.save(WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(
        workflowId: "workflow", sessionId: "child-\(phase)", status: .created,
        entryStepId: "entry", currentStepId: "entry", createdAt: now, updatedAt: now,
        rootSessionId: "child-\(phase)"
      )))

      if phase == "after-process-run-before-monitor-binding" {
        let token = UUID().uuidString + UUID().uuidString
        _ = try store.authorizeChildMonitorLaunch(dispatchId: "dispatch-\(phase)", controlToken: token)
      }
      // This is a real kernel child. It models service death immediately after
      // beginDispatch, and separately after Process.run but before the durable
      // monitor binding write; neither path has node-start evidence.
      let child = Process()
      child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
      try child.run()
      child.waitUntilExit()
      _ = try store.requireDispatchRecovery(dispatchId: "dispatch-\(phase)")
      XCTAssertEqual(try store.reopenUnstartedDispatch(dispatchId: "dispatch-\(phase)").state, .prepared)
    }

    let uncertainRequest = SpecialistRequest(requestId: "request-uncertain", sourceEventId: "event-uncertain", principal: principal, route: .work, body: "work")
    let uncertainTask = try XCTUnwrap(try store.createTaskIfWorkRequest(uncertainRequest, taskId: "task-uncertain"))
    let uncertainClaim = try store.claim(taskId: uncertainTask.taskId, ownerId: "owner", capacity: 3, expectedVersion: uncertainTask.version)
    _ = try store.reserveDispatch(taskId: uncertainTask.taskId, dispatchId: "dispatch-uncertain", childSessionId: "child-uncertain", expectedVersion: uncertainClaim.version)
    // Missing canonical child evidence is never enough to reopen a launch.
    XCTAssertThrowsError(try store.reopenUnstartedDispatch(dispatchId: "dispatch-uncertain"))
  }

  private func temporaryRoot() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/monitor-control/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
