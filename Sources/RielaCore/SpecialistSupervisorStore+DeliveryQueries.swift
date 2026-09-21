import Foundation
import RielaSQLite

extension SpecialistSupervisorStore {
  /// Binds the provider task returned by the configured gateway exactly once.
  /// A changed value is an explicit reconciliation conflict rather than a
  /// reason to create another remote task.
  public func recordTrackerTask(taskId: String, remoteTaskId: String) throws -> SpecialistTask {
    try validateOpaqueProviderValue(remoteTaskId)
    let database = try openWritable()
    return try database.transaction { database in
      var task = try loadTask(taskId, in: database)
      if let existing = task.trackerTaskId {
        guard existing == remoteTaskId else {
          throw SpecialistSupervisorStoreError.invalidTransition("tracker task conflicts for \(taskId)")
        }
        return task
      }
      task.trackerTaskId = remoteTaskId
      task.version += 1
      task.updatedAt = Date()
      try update(task, in: database)
      return task
    }
  }

  public func trackerTaskId(taskId: String) throws -> String? {
    guard FileManager.default.fileExists(atPath: databasePath) else { return nil }
    let database = try SQLiteDatabase.open(path: databasePath, mode: .readOnly, options: .readOnlyDefault)
    try verifySchema(database)
    return try dispatch(taskId: taskId, in: database)
  }

  /// Projects the canonical child runtime observation into supervisor state.
  /// The caller supplies observed timestamps from durable sources; no percent,
  /// ETA, or inferred completion is manufactured here.
  @discardableResult
  public func projectProgress(
    taskId: String,
    childStepId: String?,
    childObservedAt: Date?,
    trackerObservedAt: Date?,
    uncertain: Bool
  ) throws -> SpecialistTask {
    let database = try openWritable()
    return try database.transaction { database in
      var task = try loadTask(taskId, in: database)
      task.childStepId = childStepId
      task.childObservedAt = childObservedAt
      task.trackerObservedAt = trackerObservedAt
      task.progressUncertain = uncertain
      task.version += 1
      task.updatedAt = Date()
      try update(task, in: database)
      return task
    }
  }

  @discardableResult
  public func recordTrackerObservation(taskId: String, observedAt: Date = Date()) throws -> SpecialistTask {
    let database = try openWritable()
    return try database.transaction { database in
      var task = try loadTask(taskId, in: database)
      task.trackerObservedAt = observedAt
      task.version += 1
      task.updatedAt = observedAt
      try update(task, in: database)
      return task
    }
  }

  public func outboxEvents(taskId: String) throws -> [SpecialistOutboxEvent] {
    guard FileManager.default.fileExists(atPath: databasePath) else { return [] }
    let database = try SQLiteDatabase.open(path: databasePath, mode: .readOnly, options: .readOnlyDefault)
    try verifySchema(database)
    return try database.query(
      "SELECT json(event_json) AS event_json FROM specialist_outbox WHERE task_id = ? ORDER BY sequence ASC, event_id ASC",
      bindings: [.text(taskId)]
    ).compactMap { $0["event_json"] }.map { try decode(SpecialistOutboxEvent.self, json: $0) }
  }

  /// Returns delivery candidates in destination/sequence order. The worker
  /// obtains the per-event fenced lease with `beginDelivery` before any remote
  /// call. Interrupted deliveries are first fenced into `uncertain` by
  /// `fenceExpiredDeliveries`, never silently retried as a fresh write.
  public func pendingOutboxEvents(limit: Int = 100, now: Date = Date()) throws -> [SpecialistOutboxEvent] {
    guard FileManager.default.fileExists(atPath: databasePath) else { return [] }
    let database = try SQLiteDatabase.open(path: databasePath, mode: .readOnly, options: .readOnlyDefault)
    try verifySchema(database)
    let bounded = max(1, min(limit, 200))
    return try database.query(
      """
      SELECT json(o.event_json) AS event_json
      FROM specialist_outbox o JOIN specialist_delivery_receipts r ON r.event_id = o.event_id
      WHERE json_extract(r.receipt_json, '$.state') IN ('pending', 'retryable_failure')
        AND (json_extract(r.receipt_json, '$.nextAttemptAt') IS NULL
          OR json_extract(r.receipt_json, '$.nextAttemptAt') <= ?)
        AND NOT EXISTS (
          SELECT 1
          FROM specialist_outbox earlier
          JOIN specialist_delivery_receipts earlier_receipt ON earlier_receipt.event_id = earlier.event_id
          WHERE earlier.task_id IS o.task_id
            AND earlier.destination = o.destination
            AND earlier.sequence < o.sequence
            AND json_extract(earlier_receipt.receipt_json, '$.state') != 'delivered'
        )
      ORDER BY o.destination, o.task_id, o.sequence, o.event_id LIMIT ?
      """, bindings: [.text(timestamp(now)), .int(Int64(bounded))]
    ).compactMap { $0["event_json"] }.map { try decode(SpecialistOutboxEvent.self, json: $0) }
  }

  /// Uncertain deliveries are never retried as writes. They remain visible for
  /// a reader-tier provider reconciliation, which may only promote a matching
  /// durable correlation receipt to delivered.
  public func uncertainOutboxEvents(limit: Int = 100) throws -> [SpecialistOutboxEvent] {
    guard FileManager.default.fileExists(atPath: databasePath) else { return [] }
    let database = try SQLiteDatabase.open(path: databasePath, mode: .readOnly, options: .readOnlyDefault)
    try verifySchema(database)
    let bounded = max(1, min(limit, 200))
    return try database.query(
      """
      SELECT json(o.event_json) AS event_json
      FROM specialist_outbox o JOIN specialist_delivery_receipts r ON r.event_id = o.event_id
      WHERE json_extract(r.receipt_json, '$.state') = 'uncertain'
      ORDER BY o.destination, o.task_id, o.sequence, o.event_id LIMIT ?
      """, bindings: [.int(Int64(bounded))]
    ).compactMap { $0["event_json"] }.map { try decode(SpecialistOutboxEvent.self, json: $0) }
  }

  /// A delivery process may die after it has obtained a write lease but before
  /// it persists the provider outcome. Once the bounded lease expires, that
  /// generation is conclusively unusable. Promote it to `uncertain` so no
  /// worker can issue a replacement write; a destination-specific reader or
  /// an operator must provide matching stable-transaction evidence.
  @discardableResult
  public func fenceExpiredDeliveries(
    now: Date = Date(), staleAfter: TimeInterval = 60, limit: Int = 100
  ) throws -> [SpecialistDeliveryReceipt] {
    let bounded = max(1, min(limit, 200))
    let cutoff = now.addingTimeInterval(-max(1, staleAfter))
    let database = try openWritable()
    return try database.transaction { database in
      let rows = try database.query(
        "SELECT json(receipt_json) AS receipt_json FROM specialist_delivery_receipts "
          + "WHERE json_extract(receipt_json, '$.state') = 'delivering' "
          + "AND json_extract(receipt_json, '$.observedAt') <= ? ORDER BY event_id LIMIT ?",
        bindings: [.text(timestamp(cutoff)), .int(Int64(bounded))]
      )
      return try rows.compactMap { $0["receipt_json"] }.map { try decode(SpecialistDeliveryReceipt.self, json: $0) }.map { current in
        let uncertain = SpecialistDeliveryReceipt(
          eventId: current.eventId, destination: current.destination, state: .uncertain,
          attempt: current.attempt, generation: current.generation, observedAt: now
        )
        try saveDeliveryReceipt(uncertain, in: database)
        return uncertain
      }
    }
  }
}
