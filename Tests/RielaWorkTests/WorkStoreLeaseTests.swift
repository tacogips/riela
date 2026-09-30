import Foundation
import RielaCore
import RielaSQLite
import XCTest
@testable import RielaWork

final class WorkStoreLeaseTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("riela-work-lease-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  func testReservationStoresFencedLeaseAndHeartbeatExtendsIt() throws {
    let store = WorkStore(rootDirectory: root.path)
    var task = sampleTask()
    task.guardPolicy.lease = LeasePolicy(ttlMs: 2_000, heartbeatMs: 250)
    try store.saveTask(task)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reservation = try store.reserveAttempt(request(task: task, now: now, hostId: "worker-east"))
    let lease = try XCTUnwrap(store.loadLease(attemptId: reservation.attempt.id))
    XCTAssertEqual(lease.fence, 1)
    XCTAssertEqual(reservation.task.fence, lease.fence)
    XCTAssertEqual(lease.hostId, "worker-east")
    XCTAssertEqual(lease.heartbeatAt, now)
    XCTAssertEqual(lease.expiresAt, now.addingTimeInterval(2))
    XCTAssertEqual(try store.verifyLeaseToken(attemptId: lease.attemptId, token: reservation.launchToken), lease)
    XCTAssertThrowsError(try store.verifyLeaseToken(attemptId: lease.attemptId, token: "wrong"))

    let heartbeatAt = now.addingTimeInterval(1)
    XCTAssertTrue(try store.heartbeat(attemptId: lease.attemptId, fence: lease.fence, now: heartbeatAt, ttlMs: 5_000))
    let refreshed = try XCTUnwrap(store.loadLease(attemptId: lease.attemptId))
    XCTAssertEqual(refreshed.heartbeatAt, heartbeatAt)
    XCTAssertEqual(refreshed.expiresAt, heartbeatAt.addingTimeInterval(5))
    XCTAssertFalse(try store.heartbeat(attemptId: lease.attemptId, fence: lease.fence + 1, now: heartbeatAt, ttlMs: 5_000))

    let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readWriteCreate, options: .writableDefault)
    try database.execute("DELETE FROM work_leases WHERE attempt_id = ?", bindings: [.text(lease.attemptId.rawValue)])
    XCTAssertFalse(try store.heartbeat(attemptId: lease.attemptId, fence: lease.fence, now: heartbeatAt, ttlMs: 5_000))
  }

  func testExpiredLeasesAreOrderedByExpiry() throws {
    let store = WorkStore(rootDirectory: root.path)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    for (id, expiry) in [("task-later", 30), ("task-earlier", 10)] {
      var task = sampleTask(id: id)
      task.guardPolicy.lease = LeasePolicy(ttlMs: expiry * 1_000)
      try store.saveTask(task)
      _ = try store.reserveAttempt(request(task: task, attemptId: "attempt-\(id)", sessionId: "session-\(id)", decisionId: "decision-\(id)", now: now))
    }
    XCTAssertEqual(try store.expiredLeases(now: now.addingTimeInterval(40)).map(\.taskId), [TaskID("task-earlier"), TaskID("task-later")])
    XCTAssertTrue(try store.expiredLeases(now: now.addingTimeInterval(5)).isEmpty)
  }

  func testAuthorizedLaunchRotatesToRandomLeaseCredential() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = sampleTask()
    try store.saveTask(task)
    let reservation = try store.reserveAttempt(request(task: task, now: Date()))
    let authorization = try store.authorizeAttemptLaunchIssuingLeaseCredential(
      attemptId: reservation.attempt.id,
      launchToken: reservation.launchToken
    )

    XCTAssertEqual(
      try store.verifyLeaseToken(attemptId: reservation.attempt.id, token: authorization.leaseCredential).attemptId,
      reservation.attempt.id
    )
    XCTAssertThrowsError(try store.verifyLeaseToken(attemptId: reservation.attempt.id, token: reservation.launchToken))
    XCTAssertThrowsError(try store.verifyLeaseToken(
      attemptId: reservation.attempt.id,
      token: "consumed:\(reservation.attempt.id.rawValue):\(reservation.attempt.sessionId)"
    ))
  }

  private func request(
    task: WorkTask, attemptId: String = "attempt-1", sessionId: String = "session-1",
    decisionId: String = "decision-1", now: Date, hostId: String = "local"
  ) -> AttemptReservationRequest {
    AttemptReservationRequest(
      taskId: task.id, expectedTaskVersion: task.version, attemptId: AttemptID(attemptId), sessionId: sessionId,
      workflowId: "flow", entryStepId: "start", entry: .start, decisionId: DecisionID(decisionId),
      producer: .policy(rule: "dispatch"), reason: "start task", launchToken: "lease-token", hostId: hostId, now: now
    )
  }

  private func sampleTask(id: String = "task-1") -> WorkTask {
    WorkTask(id: TaskID(id), intentId: IntentID("intent-\(id)"), title: "Task", instruction: "Work",
             plan: .workflow(WorkflowReference(name: "flow")), state: .ready)
  }
}
