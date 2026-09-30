import Foundation
import RielaSQLite

public extension WorkStore {
  func loadLease(attemptId: AttemptID) throws -> AttemptLease? {
    let database = try readLeaseDatabase()
    guard let database else { return nil }
    let row = try database.query(
      "SELECT attempt_id, task_id, session_id, token_digest, fence, heartbeat_at, expires_at, host_id FROM work_leases WHERE attempt_id = ? LIMIT 1",
      bindings: [.text(attemptId.rawValue)]
    ).first
    return try row.map(decodeLease)
  }

  func loadLease(taskId: TaskID) throws -> AttemptLease? {
    let database = try readLeaseDatabase()
    guard let database else { return nil }
    let row = try database.query(
      "SELECT attempt_id, task_id, session_id, token_digest, fence, heartbeat_at, expires_at, host_id FROM work_leases WHERE task_id = ? LIMIT 1",
      bindings: [.text(taskId.rawValue)]
    ).first
    return try row.map(decodeLease)
  }

  @discardableResult
  func heartbeat(attemptId: AttemptID, fence: Int, now: Date, ttlMs: Int) throws -> Bool {
    let database = try openWritable()
    let expiresAt = now.addingTimeInterval(Double(ttlMs) / 1_000)
    let changed = try database.executeAndReturnChangedRowCount(
      "UPDATE work_leases SET heartbeat_at = ?, expires_at = ?, updated_at = ? WHERE attempt_id = ? AND fence = ?",
      bindings: [
        .text(Self.timestamp(now)), .text(Self.timestamp(expiresAt)), .text(Self.timestamp(now)),
        .text(attemptId.rawValue), .int(Int64(fence))
      ]
    )
    return changed == 1
  }

  func verifyLeaseToken(attemptId: AttemptID, token: String) throws -> AttemptLease {
    guard let lease = try loadLease(attemptId: attemptId),
          lease.tokenDigest == Self.launchTokenDigest(token) else {
      throw WorkStoreError("lease token does not match")
    }
    return lease
  }

  func expiredLeases(now: Date) throws -> [AttemptLease] {
    guard let database = try readLeaseDatabase() else { return [] }
    let rows = try database.query(
      "SELECT attempt_id, task_id, session_id, token_digest, fence, heartbeat_at, expires_at, host_id FROM work_leases WHERE expires_at < ? ORDER BY expires_at ASC, attempt_id ASC",
      bindings: [.text(Self.timestamp(now))]
    )
    return try rows.map(decodeLease)
  }

  private func readLeaseDatabase() throws -> SQLiteDatabase? {
    guard FileManager.default.fileExists(atPath: databasePath) else { return nil }
    let database = try SQLiteDatabase.open(
      path: databasePath,
      mode: immutableReadOnly ? .strictReadOnlyWithImmutableFallback : .readOnly,
      options: .readOnlyDefault
    )
    guard try database.tableExists("work_leases") else { return nil }
    return database
  }

  func decodeLease(_ row: SQLiteRow) throws -> AttemptLease {
    guard let attemptId = row["attempt_id"], let taskId = row["task_id"],
          let sessionId = row["session_id"], let tokenDigest = row["token_digest"],
          let fence = row["fence"].flatMap(Int.init),
          let heartbeat = row["heartbeat_at"].flatMap(Self.parseStoreTimestamp),
          let expiry = row["expires_at"].flatMap(Self.parseStoreTimestamp),
          let hostId = row["host_id"] else {
      throw WorkStoreError("work store contains an invalid lease record")
    }
    return AttemptLease(
      attemptId: AttemptID(attemptId), taskId: TaskID(taskId), sessionId: sessionId,
      tokenDigest: tokenDigest, fence: fence, heartbeatAt: heartbeat, expiresAt: expiry, hostId: hostId
    )
  }

  private static func parseStoreTimestamp(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    return standard.date(from: value)
  }
}
