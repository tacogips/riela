import Crypto
import Foundation
import RielaSQLite

public struct SpecialistClarificationContinuation: Equatable, Sendable {
  public let task: SpecialistTask
  public let request: SpecialistRequest

  public init(task: SpecialistTask, request: SpecialistRequest) {
    self.task = task
    self.request = request
  }
}

/// A persisted continuation that the service routing lane may consume. The
/// task remains the original authority, so this cannot allocate another owner
/// or child dispatch after a service restart.
public struct SpecialistPendingContinuation: Equatable, Sendable {
  public let task: SpecialistTask
  public let request: SpecialistRequest

  public init(task: SpecialistTask, request: SpecialistRequest) {
    self.task = task
    self.request = request
  }
}

public struct SpecialistCapacityWaitRequest: Equatable, Sendable {
  public let task: SpecialistTask
  public let request: SpecialistRequest
}

extension SpecialistSupervisorStore {
  /// Durable retry lane for saturated claimants. It intentionally reuses the
  /// original accepted request and sealed classifier round; no Matrix message
  /// is replayed and no model decision is reissued merely because capacity was
  /// released.
  public func pendingCapacityWaitRequests(limit: Int = 100) throws -> [SpecialistCapacityWaitRequest] {
    guard limit > 0, limit <= 1_000, FileManager.default.fileExists(atPath: databasePath) else { return [] }
    let database = try SQLiteDatabase.open(path: databasePath, mode: .readOnly, options: .readOnlyDefault)
    try verifySchema(database)
    let rows = try database.query(
      "SELECT json(t.task_json) AS task_json, json(r.request_json) AS request_json "
        + "FROM specialist_tasks t JOIN specialist_requests r ON r.request_id = t.request_id "
        + "WHERE t.state = 'capacity_wait' ORDER BY t.updated_at ASC, t.task_id ASC LIMIT ?",
      bindings: [.int(Int64(limit))]
    )
    return try rows.compactMap { row in
      guard let taskJSON = row["task_json"], let requestJSON = row["request_json"] else { return nil }
      return SpecialistCapacityWaitRequest(task: try decode(SpecialistTask.self, json: taskJSON), request: try decode(SpecialistRequest.self, json: requestJSON))
    }
  }

  @discardableResult
  public func reopenCapacityWait(taskId: String, expectedVersion: Int) throws -> SpecialistTask {
    try transition(taskId: taskId, to: .queued, expectedVersion: expectedVersion, statusDestination: "tracker")
  }

  /// A clarification is a new durable inbound record, not a transient chat
  /// turn. It reopens only the requester's latest pending clarification and
  /// preserves its original task/ownership correlation for a later router pass.
  public func continueClarification(_ request: SpecialistRequest) throws -> SpecialistTask? {
    try beginClarificationContinuation(request)?.task
  }

  /// Turns a clarification reply into one durable, restart-safe work-routing
  /// request. The continuation is idempotently linked to its original task;
  /// callers must pass the returned request through the normal classifier and
  /// dispatch path rather than merely leaving the task queued.
  public func beginClarificationContinuation(
    _ request: SpecialistRequest
  ) throws -> SpecialistClarificationContinuation? {
    let accepted = try accept(request)
    guard accepted.route == .clarification else { return nil }
    let continuationDigest = SHA256.hash(
      data: Data((accepted.requestId + "\u{1F}" + accepted.sourceEventId).utf8)
    ).map { String(format: "%02x", $0) }.joined()
    let continuation = SpecialistRequest(
      requestId: "continuation-\(continuationDigest.prefix(40))",
      sourceEventId: "continuation-\(continuationDigest.prefix(40))",
      principal: accepted.principal,
      route: .work,
      body: "Clarification for pending task: \(String(accepted.body.prefix(16_384)))",
      receivedAt: accepted.receivedAt
    )
    let durableContinuation = try accept(continuation)
    let database = try openWritable()
    return try database.transaction { database throws -> SpecialistClarificationContinuation? in
      let rows = try database.query(
        """
        SELECT json(task_json) AS task_json FROM specialist_tasks
        WHERE json_extract(task_json, '$.principal.accountId') = ?
          AND json_extract(task_json, '$.principal.actorId') = ?
          AND json_extract(task_json, '$.principal.roomId') = ?
          AND json_extract(task_json, '$.principal.threadId') IS ?
          AND (state = 'needs_clarification'
            OR json_extract(task_json, '$.continuationRequestId') = ?)
        ORDER BY updated_at DESC, task_id ASC LIMIT 1
        """,
        bindings: [.text(accepted.principal.accountId), .text(accepted.principal.actorId), .text(accepted.principal.roomId),
                   .optionalText(accepted.principal.threadId), .text(durableContinuation.requestId)]
      )
      guard let json = rows.first?["task_json"] else { return nil }
      var task = try decode(SpecialistTask.self, json: json)
      if let existing = task.continuationRequestId {
        guard existing == durableContinuation.requestId else {
          throw SpecialistSupervisorStoreError.requestConflict(task.taskId)
        }
        return SpecialistClarificationContinuation(task: task, request: durableContinuation)
      }
      task.state = .queued
      task.progressUncertain = true
      task.continuationRequestId = durableContinuation.requestId
      task.version += 1
      task.updatedAt = accepted.receivedAt
      try update(task, in: database)
      return SpecialistClarificationContinuation(task: task, request: durableContinuation)
    }
  }

  /// Returns durable, not-yet-dispatched clarification continuations. This is
  /// deliberately a query rather than a claim: `submit` records routing and
  /// reserves the dispatch transactionally, so a second service/retry either
  /// observes that dispatch or gets the canonical idempotent result.
  public func pendingClarificationContinuations(
    limit: Int = 100
  ) throws -> [SpecialistPendingContinuation] {
    guard limit > 0, limit <= 1_000, FileManager.default.fileExists(atPath: databasePath) else { return [] }
    let database = try SQLiteDatabase.open(path: databasePath, mode: .readOnly, options: .readOnlyDefault)
    try verifySchema(database)
    let rows = try database.query(
      """
      SELECT json(t.task_json) AS task_json, json(r.request_json) AS request_json
      FROM specialist_tasks t
      JOIN specialist_requests r ON r.request_id = json_extract(t.task_json, '$.continuationRequestId')
      WHERE t.state = 'queued'
        AND json_extract(t.task_json, '$.dispatchId') IS NULL
        AND json_extract(t.task_json, '$.continuationRequestId') IS NOT NULL
      ORDER BY t.updated_at ASC, t.task_id ASC LIMIT ?
      """,
      bindings: [.int(Int64(limit))]
    )
    return try rows.compactMap { row in
      guard let taskJSON = row["task_json"], let requestJSON = row["request_json"] else { return nil }
      return SpecialistPendingContinuation(
        task: try decode(SpecialistTask.self, json: taskJSON),
        request: try decode(SpecialistRequest.self, json: requestJSON)
      )
    }
  }

  /// Returns the one task that owns an original or clarification-continuation
  /// work-routing request. This lookup is principal-scoped so a forged request
  /// identifier cannot cross account, room, actor, or thread boundaries.
  public func taskForRoutingRequest(
    requestId: String, principal: SpecialistPrincipal
  ) throws -> SpecialistTask? {
    try validateIdentifier(requestId)
    guard FileManager.default.fileExists(atPath: databasePath) else { return nil }
    let database = try SQLiteDatabase.open(path: databasePath, mode: .readOnly, options: .readOnlyDefault)
    try verifySchema(database)
    let rows = try database.query(
      """
      SELECT json(task_json) AS task_json FROM specialist_tasks
      WHERE (request_id = ? OR json_extract(task_json, '$.continuationRequestId') = ?)
        AND json_extract(task_json, '$.principal.accountId') = ?
        AND json_extract(task_json, '$.principal.actorId') = ?
        AND json_extract(task_json, '$.principal.roomId') = ?
        AND json_extract(task_json, '$.principal.threadId') IS ?
      LIMIT 1
      """,
      bindings: [.text(requestId), .text(requestId), .text(principal.accountId), .text(principal.actorId),
                 .text(principal.roomId), .optionalText(principal.threadId)]
    )
    guard let json = rows.first?["task_json"] else { return nil }
    return try decode(SpecialistTask.self, json: json)
  }

  /// Enqueues one reply for an authenticated request, without creating a task,
  /// taking capacity, or scheduling tracker/child work. Replays retain the
  /// original observed status and provider transaction identity.
  @discardableResult
  public func enqueueStatusReply(_ request: SpecialistRequest) throws -> SpecialistOutboxEvent {
    let accepted = try accept(request)
    let eventId = "status-" + SHA256.hash(data: Data(accepted.requestId.utf8)).map { String(format: "%02x", $0) }.joined()
    let database = try openWritable()
    return try database.transaction { database in
      if let existing = try database.query(
        "SELECT json(event_json) AS event_json FROM specialist_outbox WHERE event_id = ?", bindings: [.text(eventId)]
      ).first?["event_json"] {
        return try decode(SpecialistOutboxEvent.self, json: existing)
      }
      let principal = accepted.principal
      let requestedTaskID = statusTaskReference(in: accepted.body)
      let rows = try database.query(
        """
        SELECT json(task_json) AS task_json FROM specialist_tasks
        WHERE json_extract(task_json, '$.principal.accountId') = ?
          AND json_extract(task_json, '$.principal.actorId') = ?
          AND json_extract(task_json, '$.principal.roomId') = ?
          AND json_extract(task_json, '$.principal.threadId') IS ?
        ORDER BY updated_at DESC, task_id ASC LIMIT 20
        """, bindings: [.text(principal.accountId), .text(principal.actorId), .text(principal.roomId), .optionalText(principal.threadId)]
      )
      let visibleTasks = try rows.compactMap { $0["task_json"] }.map { try decode(SpecialistTask.self, json: $0) }
      let tasks: [SpecialistTask]
      if let requestedTaskID {
        tasks = visibleTasks.filter { $0.taskId == requestedTaskID }
      } else {
        tasks = visibleTasks
      }
      let payload: String
      if let requestedTaskID, tasks.isEmpty {
        payload = "No task named \(requestedTaskID) is visible to this requester."
      } else if tasks.isEmpty {
        payload = "No tasks found for this conversation and requester."
      } else {
        payload = tasks.map { task in
          let dispatchDetail = task.childSessionId.map { " child=\($0)" } ?? ""
          let formatter = ISO8601DateFormatter()
          let child = task.childStepId.map { " childStep=\($0)" } ?? " childStep=unavailable"
          let childObserved = task.childObservedAt.map { " childObserved=\(formatter.string(from: $0))" } ?? " childObserved=unavailable"
          let trackerObserved = task.trackerObservedAt.map { " trackerObserved=\(formatter.string(from: $0))" } ?? " trackerObserved=unavailable"
          let childStaleness = factualStaleness(task.childObservedAt, now: Date())
          let trackerStaleness = factualStaleness(task.trackerObservedAt, now: Date())
          let uncertainty = task.progressUncertain == true ? " progress=uncertain" : " progress=factual"
          return "\(task.taskId): \(task.state.rawValue) " +
            "(owner: \(task.ownerId ?? "unassigned")\(dispatchDetail)\(child)" +
            "\(childObserved) childObservation=\(childStaleness)" +
            "\(trackerObserved) trackerObservation=\(trackerStaleness)\(uncertainty); " +
            "observed \(formatter.string(from: task.updatedAt)))"
        }.joined(separator: "\n")
      }
      let event = SpecialistOutboxEvent(eventId: eventId, destination: "chat", operation: "status", payload: payload,
                                        sequence: 1, recipient: principal)
      try database.execute(
        "INSERT INTO specialist_outbox (event_id, task_id, destination, sequence, event_json) VALUES (?, NULL, 'chat', 1, jsonb(?))",
        bindings: [.text(eventId), .text(try encode(event))]
      )
      let receipt = SpecialistDeliveryReceipt(eventId: eventId, destination: "chat", state: .pending, attempt: 0, generation: 0)
      try database.execute("INSERT INTO specialist_delivery_receipts (event_id, receipt_json) VALUES (?, jsonb(?))",
                           bindings: [.text(eventId), .text(try encode(receipt))])
      return event
    }
  }

  /// Persists a control-plane response for a no-owner, capacity-wait,
  /// clarification, or cancellation route.  These paths are never silently
  /// consumed merely because no child can yet be launched.
  @discardableResult
  public func enqueueControlReply(_ request: SpecialistRequest, message: String) throws -> SpecialistOutboxEvent {
    let accepted = try accept(request)
    let body = String(message.prefix(2_000))
    let digest = SHA256.hash(data: Data((accepted.requestId + "\u{1F}" + body).utf8))
      .map { String(format: "%02x", $0) }.joined()
    let eventId = "control-" + digest
    let database = try openWritable()
    return try database.transaction { database in
      if let existing = try database.query(
        "SELECT json(event_json) AS event_json FROM specialist_outbox WHERE event_id = ?", bindings: [.text(eventId)]
      ).first?["event_json"] {
        return try decode(SpecialistOutboxEvent.self, json: existing)
      }
      let event = SpecialistOutboxEvent(eventId: eventId, destination: "chat", operation: "control", payload: body,
                                        sequence: 1, recipient: accepted.principal)
      try database.execute(
        "INSERT INTO specialist_outbox (event_id, task_id, destination, sequence, event_json) VALUES (?, NULL, 'chat', 1, jsonb(?))",
        bindings: [.text(eventId), .text(try encode(event))]
      )
      let receipt = SpecialistDeliveryReceipt(eventId: eventId, destination: "chat", state: .pending, attempt: 0, generation: 0)
      try database.execute("INSERT INTO specialist_delivery_receipts (event_id, receipt_json) VALUES (?, jsonb(?))",
                           bindings: [.text(eventId), .text(try encode(receipt))])
      return event
    }
  }

  private func statusTaskReference(in body: String) -> String? {
    let parts = body.split(whereSeparator: \.isWhitespace)
    guard parts.first?.lowercased() == "/status", parts.count == 2 else { return nil }
    let value = String(parts[1])
    guard (try? validateIdentifier(value)) != nil else { return nil }
    return value
  }

  /// Status derives only a bounded freshness label from persisted observation
  /// times. It intentionally never estimates progress, completion, or ETA.
  private func factualStaleness(_ observedAt: Date?, now: Date) -> String {
    guard let observedAt else { return "unavailable" }
    return now.timeIntervalSince(observedAt) > 300 ? "stale" : "fresh"
  }
}
