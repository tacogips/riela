import Foundation
import RielaCore
import RielaSQLite

public extension WorkStore {
  func requestHandover(
    taskId: TaskID, reason: String, immediate: Bool, target: String?,
    sinks: [HandoverSinkKind], now: Date
  ) throws -> HandoverRequestRecord {
    let database = try openWritable()
    return try database.transaction { database in
      guard let attempt = try database.query(
        "SELECT json(record) AS record FROM work_attempts WHERE task_id = ? AND state = 'running' ORDER BY generation DESC, attempt_id DESC LIMIT 1",
        bindings: [.text(taskId.rawValue)]
      ).first?["record"].map({ try decode(Attempt.self, json: $0) }) else {
        throw WorkStoreError("handover request requires a running attempt")
      }
      if let existing = try database.query(
        "SELECT json(record) AS record FROM work_handover_requests WHERE attempt_id = ? AND consumed_at IS NULL LIMIT 1",
        bindings: [.text(attempt.id.rawValue)]
      ).first?["record"] {
        return try decode(HandoverRequestRecord.self, json: existing)
      }
      let request = HandoverRequestRecord(
        requestId: UUID().uuidString.lowercased(), taskId: taskId, attemptId: attempt.id,
        reason: reason, immediate: immediate, target: target, sinks: Array(Set(sinks)).sorted { $0.rawValue < $1.rawValue },
        requestedAt: now
      )
      try database.execute(
        "INSERT INTO work_handover_requests (request_id, task_id, attempt_id, record, requested_at, consumed_at) VALUES (?, ?, ?, jsonb(?), ?, NULL)",
        bindings: [
          .text(request.requestId), .text(taskId.rawValue), .text(attempt.id.rawValue),
          .text(try encode(request)), .text(Self.timestamp(now))
        ]
      )
      return request
    }
  }

  func pendingHandoverRequest(attemptId: AttemptID) throws -> HandoverRequestRecord? {
    guard FileManager.default.fileExists(atPath: databasePath) else { return nil }
    let database = try SQLiteDatabase.open(
      path: databasePath,
      mode: immutableReadOnly ? .strictReadOnlyWithImmutableFallback : .readOnly,
      options: .readOnlyDefault
    )
    guard try database.tableExists("work_handover_requests"),
          let row = try database.query(
            "SELECT json(record) AS record FROM work_handover_requests WHERE attempt_id = ? AND consumed_at IS NULL LIMIT 1",
            bindings: [.text(attemptId.rawValue)]
          ).first,
          let record = row["record"] else { return nil }
    return try decode(HandoverRequestRecord.self, json: record)
  }

  func consumeHandoverRequest(requestId: String, now: Date) throws {
    let database = try openWritable()
    try database.transaction { database in
      guard let record = try database.query(
        "SELECT json(record) AS record FROM work_handover_requests WHERE request_id = ? AND consumed_at IS NULL LIMIT 1",
        bindings: [.text(requestId)]
      ).first?["record"] else {
        throw WorkStoreError("handover request '\(requestId)' is missing or already consumed")
      }
      var request = try decode(HandoverRequestRecord.self, json: record)
      request.consumedAt = now
      let changed = try database.executeAndReturnChangedRowCount(
        "UPDATE work_handover_requests SET record = jsonb(?), consumed_at = ? WHERE request_id = ? AND consumed_at IS NULL",
        bindings: [.text(try encode(request)), .text(Self.timestamp(now)), .text(requestId)]
      )
      guard changed == 1 else { throw WorkStoreError("handover request '\(requestId)' is missing or already consumed") }
    }
  }
}
