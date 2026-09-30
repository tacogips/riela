import Foundation
import RielaCore
import RielaSQLite
import XCTest
@testable import RielaWork

private final class LeaseClaimRaceResults: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Bool] = []
  private var failures: [String] = []

  func append(_ value: Bool) {
    lock.lock()
    values.append(value)
    lock.unlock()
  }

  func appendFailure(_ error: Error) {
    lock.lock()
    failures.append(String(describing: error))
    lock.unlock()
  }

  var result: (values: [Bool], failures: [String]) {
    lock.lock()
    defer { lock.unlock() }
    return (values, failures)
  }
}

private struct LeaseClaimSnapshot: Equatable {
  var attemptRecord: String
  var leaseTokenDigest: String
  var fence: String
  var heartbeatAt: String
  var expiresAt: String
  var updatedAt: String
}

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

  func testClaimLeaseForReportRotatesCredentialAndPreservesRecoveryLease() throws {
    let store = WorkStore(rootDirectory: root.path)
    var task = sampleTask()
    task.guardPolicy.lease = LeasePolicy(ttlMs: 1_000, heartbeatMs: 250)
    try store.saveTask(task)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reservation = try store.reserveAttempt(request(task: task, now: now))
    let authorization = try store.authorizeAttemptLaunchIssuingLeaseCredential(
      attemptId: reservation.attempt.id,
      launchToken: reservation.launchToken
    )
    let originalLease = try XCTUnwrap(store.loadLease(attemptId: reservation.attempt.id))

    XCTAssertTrue(try store.claimLeaseForReport(
      attemptId: reservation.attempt.id,
      token: authorization.leaseCredential,
      now: now.addingTimeInterval(1)
    ))

    let claimedLease = try XCTUnwrap(store.loadLease(attemptId: reservation.attempt.id))
    let claimedAttempt = try XCTUnwrap(store.loadAttempt(id: reservation.attempt.id))
    XCTAssertEqual(claimedLease.fence, originalLease.fence)
    XCTAssertEqual(claimedLease.expiresAt, originalLease.expiresAt)
    XCTAssertEqual(claimedLease.heartbeatAt, originalLease.heartbeatAt)
    XCTAssertNotEqual(claimedLease.tokenDigest, WorkStore.launchTokenDigest(authorization.leaseCredential))
    XCTAssertEqual(claimedAttempt.launch?.tokenDigest, claimedLease.tokenDigest)
    XCTAssertEqual(claimedAttempt.launch?.updatedAt, now.addingTimeInterval(1))
    XCTAssertTrue(try store.expiredLeases(now: originalLease.expiresAt.addingTimeInterval(1)).contains {
      $0.attemptId == reservation.attempt.id
    })

    let afterClaim = try claimSnapshot(store: store, attemptId: reservation.attempt.id)
    XCTAssertFalse(try store.claimLeaseForReport(
      attemptId: reservation.attempt.id,
      token: authorization.leaseCredential,
      now: now.addingTimeInterval(1)
    ))
    XCTAssertFalse(try store.claimLeaseForReport(
      attemptId: reservation.attempt.id,
      token: "wrong-credential",
      now: now.addingTimeInterval(1)
    ))
    XCTAssertEqual(try claimSnapshot(store: store, attemptId: reservation.attempt.id), afterClaim)

    let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readWriteCreate, options: .writableDefault)
    try database.execute(
      "DELETE FROM work_leases WHERE attempt_id = ?",
      bindings: [.text(reservation.attempt.id.rawValue)]
    )
    let attemptWithoutLease = try XCTUnwrap(store.loadAttempt(id: reservation.attempt.id))
    XCTAssertFalse(try store.claimLeaseForReport(
      attemptId: reservation.attempt.id,
      token: authorization.leaseCredential,
      now: now.addingTimeInterval(2)
    ))
    XCTAssertEqual(try store.loadAttempt(id: reservation.attempt.id), attemptWithoutLease)
  }

  func testConcurrentLeaseReportClaimsHaveOneWinner() throws {
    let store = WorkStore(rootDirectory: root.path)
    let secondStore = WorkStore(rootDirectory: root.path)
    let task = sampleTask()
    try store.saveTask(task)
    let reservation = try store.reserveAttempt(request(task: task, now: Date()))
    let authorization = try store.authorizeAttemptLaunchIssuingLeaseCredential(
      attemptId: reservation.attempt.id,
      launchToken: reservation.launchToken
    )
    let results = LeaseClaimRaceResults()

    DispatchQueue.concurrentPerform(iterations: 2) { index in
      let claimingStore = index == 0 ? store : secondStore
      do {
        results.append(try claimingStore.claimLeaseForReport(
          attemptId: reservation.attempt.id,
          token: authorization.leaseCredential
        ))
      } catch {
        results.appendFailure(error)
      }
    }

    let result = results.result
    XCTAssertEqual(result.failures, [])
    XCTAssertEqual(result.values.filter { $0 }.count, 1)
    XCTAssertEqual(result.values.filter { !$0 }.count, 1)
  }

  private func claimSnapshot(store: WorkStore, attemptId: AttemptID) throws -> LeaseClaimSnapshot {
    let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
    guard let row = try database.query(
      "SELECT json(attempt.record) AS attempt_record, lease.token_digest, lease.fence, lease.heartbeat_at, lease.expires_at, lease.updated_at " +
        "FROM work_attempts AS attempt JOIN work_leases AS lease ON lease.attempt_id = attempt.attempt_id " +
        "WHERE attempt.attempt_id = ?",
      bindings: [.text(attemptId.rawValue)]
    ).first,
    let attemptRecord = row["attempt_record"],
    let tokenDigest = row["token_digest"],
    let fence = row["fence"],
    let heartbeatAt = row["heartbeat_at"],
    let expiresAt = row["expires_at"],
    let updatedAt = row["updated_at"] else {
      throw WorkStoreError("claim snapshot was not found")
    }
    return LeaseClaimSnapshot(
      attemptRecord: attemptRecord,
      leaseTokenDigest: tokenDigest,
      fence: fence,
      heartbeatAt: heartbeatAt,
      expiresAt: expiresAt,
      updatedAt: updatedAt
    )
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
