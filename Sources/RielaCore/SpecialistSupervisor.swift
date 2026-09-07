import Crypto
import Foundation
import RielaSQLite

private struct CanonicalSourceKey: Codable {
  let accountId: String
  let roomId: String
  let sourceEventId: String
}

private struct CanonicalRequestFingerprint: Codable {
  let route: SpecialistRequestRoute
  let principal: SpecialistPrincipal
  let body: String
}

private struct CanonicalOutboxKey: Codable {
  let taskId: String
  let sequence: Int
  let destination: String
  let operation: String
}

/// Transactional persistence for requests, task ownership, dispatch identity,
/// and immutable outbox records.  Provider delivery deliberately lives outside
/// this type; callers must persist a receipt instead of treating a timeout as
/// a safe retry.
public struct SpecialistSupervisorStore: Sendable {
  public static let schemaGeneration: Int64 = 2
  public static let databaseFileName = "runtime-message-log.sqlite"

  public let databasePath: String

  public init(rootDirectory: String) {
    // Use the same canonical runtime root as the CLI session store.  A
    // reservation is therefore visible to `WorkflowRunCommand` without a
    // cross-database copy or a second, incompatible session root.
    let runtimeRoot = URL(fileURLWithPath: rootDirectory, isDirectory: true)
      .appendingPathComponent("runtime-records", isDirectory: true).path
    databasePath = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: runtimeRoot)
  }

  public init(databasePath: String) {
    self.databasePath = databasePath
  }

  /// Records the source event exactly once.  A repeated event with identical
  /// contents returns the original request; changed content is rejected.
  @discardableResult
  public func accept(_ request: SpecialistRequest) throws -> SpecialistRequest {
    try validate(request)
    let database = try openWritable()
    return try database.transaction { database in
      // Provider re-delivery can acquire a fresh local request ID.  Source
      // idempotency is therefore keyed by a canonical semantic fingerprint,
      // while request-id conflicts remain a separate protection below.
      let hash = digest(request)
      let sourceKey = scopedSourceKey(request)
      let rows = try database.query(
        "SELECT json(request_json) AS request_json, request_hash FROM specialist_requests WHERE source_key = ?",
        bindings: [.text(sourceKey)]
      )
      if let row = rows.first, let storedHash = row["request_hash"], let json = row["request_json"] {
        guard storedHash == hash else { throw SpecialistSupervisorStoreError.requestConflict(request.sourceEventId) }
        return try decode(SpecialistRequest.self, json: json)
      }
      let requestRows = try database.query(
        "SELECT json(request_json) AS request_json, request_hash FROM specialist_requests WHERE request_id = ?",
        bindings: [.text(request.requestId)]
      )
      if let row = requestRows.first, let storedHash = row["request_hash"], let json = row["request_json"] {
        let original = try decode(SpecialistRequest.self, json: json)
        guard storedHash == hash, scopedSourceKey(original) == sourceKey else {
          throw SpecialistSupervisorStoreError.requestConflict(request.requestId)
        }
        return original
      }
      let requestJSON = try encode(request)
      try database.execute(
        "INSERT INTO specialist_requests (request_id, source_key, request_hash, request_json, received_at) VALUES (?, ?, ?, jsonb(?), ?)",
        bindings: [.text(request.requestId), .text(sourceKey), .text(hash), .text(requestJSON), .text(timestamp(request.receivedAt))]
      )
      return request
    }
  }

  /// Creates one task per accepted work request. Status and cancellation
  /// routes intentionally never create a task, slot, tracker event, or child.
  @discardableResult
  public func createTaskIfWorkRequest(_ request: SpecialistRequest, taskId: String) throws -> SpecialistTask? {
    let accepted = try accept(request)
    guard accepted.route == .work else { return nil }
    try validateIdentifier(taskId)
    let database = try openWritable()
    return try database.transaction { database in
      let rows = try database.query(
        "SELECT json(task_json) AS task_json FROM specialist_tasks WHERE request_id = ?",
        bindings: [.text(accepted.requestId)]
      )
      if let json = rows.first?["task_json"] { return try decode(SpecialistTask.self, json: json) }
      let task = SpecialistTask(taskId: taskId, requestId: accepted.requestId, principal: accepted.principal)
      try insert(task, in: database)
      return task
    }
  }

  /// Seals classifier output for an accepted request. Replays must carry the
  /// exact same decision/settlement record; late model responses cannot alter
  /// ownership after a task was created.
  @discardableResult
  public func recordRouting(
    requestId: String,
    settlement: SpecialistRoutingSettlement,
    decisions: [SpecialistDecision]
  ) throws -> SpecialistRoutingRecord {
    try validateIdentifier(requestId)
    let record = SpecialistRoutingRecord(requestId: requestId, settlement: settlement, decisions: decisions)
    let database = try openWritable()
    return try database.transaction { database in
      guard try database.query("SELECT request_id FROM specialist_requests WHERE request_id = ?", bindings: [.text(requestId)]).isEmpty == false else {
        throw SpecialistSupervisorStoreError.taskNotFound(requestId)
      }
      let rows = try database.query("SELECT json(routing_json) AS routing_json FROM specialist_routing WHERE request_id = ?", bindings: [.text(requestId)])
      if let json = rows.first?["routing_json"] {
        let existing = try decode(SpecialistRoutingRecord.self, json: json)
        guard existing == record else { throw SpecialistSupervisorStoreError.requestConflict(requestId) }
        return existing
      }
      try database.execute("INSERT INTO specialist_routing (request_id, routing_json) VALUES (?, jsonb(?))", bindings: [.text(requestId), .text(try encode(record))])
      return record
    }
  }

  /// Starts (or returns) the one authenticated classifier round for a request.
  /// The immutable configuration/catalog revisions make a resumed round
  /// auditable; a changed policy must start a new request rather than silently
  /// reuse model output.
  @discardableResult
  public func beginClassificationRound(_ round: SpecialistClassificationRound) throws -> SpecialistClassificationRound {
    try validateIdentifier(round.requestId)
    let database = try openWritable()
    return try database.transaction { database in
      guard (try database.query("SELECT request_id FROM specialist_requests WHERE request_id = ?", bindings: [.text(round.requestId)])).isEmpty == false else {
        throw SpecialistSupervisorStoreError.taskNotFound(round.requestId)
      }
      let rows = try database.query("SELECT json(round_json) AS round_json FROM specialist_classification_rounds WHERE request_id = ?", bindings: [.text(round.requestId)])
      if let json = rows.first?["round_json"] {
        let existing = try decode(SpecialistClassificationRound.self, json: json)
        guard existing.configurationRevision == round.configurationRevision,
              existing.catalogRevision == round.catalogRevision else {
          throw SpecialistSupervisorStoreError.requestConflict(round.requestId)
        }
        return existing
      }
      try database.execute(
        "INSERT INTO specialist_classification_rounds (request_id, round_json) VALUES (?, jsonb(?))",
        bindings: [.text(round.requestId), .text(try encode(round))]
      )
      return round
    }
  }

  /// Seals the authenticated output exactly once. A retry of the same result
  /// is harmless; a late or changed result is an explicit conflict.
  @discardableResult
  public func sealClassificationRound(
    requestId: String, decisions: [SpecialistDecision], now: Date = Date()
  ) throws -> SpecialistClassificationRound {
    try validateIdentifier(requestId)
    let database = try openWritable()
    return try database.transaction { database in
      let rows = try database.query("SELECT json(round_json) AS round_json FROM specialist_classification_rounds WHERE request_id = ?", bindings: [.text(requestId)])
      guard let json = rows.first?["round_json"] else { throw SpecialistSupervisorStoreError.taskNotFound(requestId) }
      var round = try decode(SpecialistClassificationRound.self, json: json)
      let canonical = decisions.sorted { ($0.specialistId, $0.kind.rawValue, $0.reason) < ($1.specialistId, $1.kind.rawValue, $1.reason) }
      if round.sealed {
        guard round.decisions == canonical else { throw SpecialistSupervisorStoreError.requestConflict(requestId) }
        return round
      }
      // The deadline bounds provider work, not the durability of its result.
      // A caller that observed the deadline must seal the deterministic set of
      // available and unavailable outcomes, otherwise a crash between timeout
      // and write would leave the request forever un-settleable.
      round.decisions = canonical
      round.sealed = true
      try database.execute("UPDATE specialist_classification_rounds SET round_json = jsonb(?) WHERE request_id = ?", bindings: [.text(try encode(round)), .text(requestId)])
      return round
    }
  }

  /// Reserves a nested invocation identity before a child effect. The
  /// invocation is idempotent only when every immutable identity field agrees.
  @discardableResult
  public func reserveNestedInvocation(_ invocation: SpecialistNestedInvocation) throws -> SpecialistNestedInvocation {
    for identifier in [invocation.rootDispatchId, invocation.parentSessionId, invocation.sourceExecutionId, invocation.branchId, invocation.childSessionId] {
      try validateIdentifier(identifier)
    }
    guard invocation.transitionOrdinal >= 0 else { throw SpecialistSupervisorStoreError.invalidIdentifier("transition ordinal") }
    let database = try openWritable()
    return try database.transaction { database in
      let key = digest([invocation.rootDispatchId, invocation.parentSessionId, invocation.sourceExecutionId, String(invocation.transitionOrdinal), invocation.branchId].joined(separator: "\u{1F}"))
      let rows = try database.query("SELECT json(invocation_json) AS invocation_json FROM specialist_nested_invocations WHERE invocation_key = ?", bindings: [.text(key)])
      if let json = rows.first?["invocation_json"] {
        let existing = try decode(SpecialistNestedInvocation.self, json: json)
        guard existing.rootDispatchId == invocation.rootDispatchId,
              existing.parentSessionId == invocation.parentSessionId,
              existing.sourceExecutionId == invocation.sourceExecutionId,
              existing.transitionOrdinal == invocation.transitionOrdinal,
              existing.branchId == invocation.branchId,
              existing.childSessionId == invocation.childSessionId else {
          throw SpecialistSupervisorStoreError.invalidTransition("nested invocation conflicts")
        }
        return existing
      }
      try database.execute(
        "INSERT INTO specialist_nested_invocations (invocation_key, invocation_json) VALUES (?, jsonb(?))",
        bindings: [.text(key), .text(try encode(invocation))]
      )
      return invocation
    }
  }

  /// Records a child terminal value before one fenced parent delivery. The
  /// caller supplies the durable result hash, never a mutable child name.
  @discardableResult
  public func publishNestedResult(_ invocation: SpecialistNestedInvocation, resultHash: String) throws -> SpecialistNestedInvocation {
    guard !resultHash.isEmpty else { throw SpecialistSupervisorStoreError.invalidIdentifier("nested result hash") }
    let reserved = try reserveNestedInvocation(invocation)
    let database = try openWritable()
    return try database.transaction { database in
      let key = digest([reserved.rootDispatchId, reserved.parentSessionId, reserved.sourceExecutionId, String(reserved.transitionOrdinal), reserved.branchId].joined(separator: "\u{1F}"))
      guard let json = try database.query("SELECT json(invocation_json) AS invocation_json FROM specialist_nested_invocations WHERE invocation_key = ?", bindings: [.text(key)]).first?["invocation_json"] else {
        throw SpecialistSupervisorStoreError.taskNotFound(reserved.childSessionId)
      }
      var stored = try decode(SpecialistNestedInvocation.self, json: json)
      if let existing = stored.resultHash, existing != resultHash { throw SpecialistSupervisorStoreError.invalidTransition("nested result conflicts") }
      stored.resultHash = resultHash
      stored.delivered = true
      try database.execute("UPDATE specialist_nested_invocations SET invocation_json = jsonb(?) WHERE invocation_key = ?", bindings: [.text(try encode(stored)), .text(key)])
      return stored
    }
  }

  /// Atomically chooses an owner, consumes capacity and creates the ownership
  /// notices. Retrying the same decision is idempotent; a different owner or
  /// capacity is a conflict rather than a silent reassignment.
  @discardableResult
  public func claim(
    taskId: String,
    ownerId: String,
    capacity: Int,
    expectedVersion: Int,
    destinations: [String] = ["chat", "tracker"]
  ) throws -> SpecialistTask {
    try validateIdentifier(taskId)
    try validateIdentifier(ownerId)
    guard capacity > 0 else { throw SpecialistSupervisorStoreError.capacityUnavailable(ownerId) }
    let database = try openWritable()
    return try database.transaction { database in
      var task = try loadTask(taskId, in: database)
      if task.ownerId != nil {
        guard task.ownerId == ownerId, task.version == expectedVersion else {
          throw SpecialistSupervisorStoreError.taskOwnerConflict(taskId)
        }
        return task
      }
      guard task.version == expectedVersion else { throw SpecialistSupervisorStoreError.taskVersionConflict(taskId) }
      guard task.state == .queued || task.state == .needsClarification else {
        throw SpecialistSupervisorStoreError.invalidTransition("cannot claim \(task.state.rawValue)")
      }
      let usage = try database.query(
        "SELECT COUNT(*) AS count FROM specialist_tasks WHERE owner_id = ? AND state IN ('queued', 'running', 'needs_clarification', 'cancel_requested')",
        bindings: [.text(ownerId)]
      ).first?.string("count") ?? "0"
      guard (Int(usage) ?? 0) < capacity else { throw SpecialistSupervisorStoreError.capacityUnavailable(ownerId) }
      task.ownerId = ownerId
      task.state = .queued
      task.version += 1
      task.updatedAt = Date()
      try update(task, in: database)
      for destination in Set(destinations).sorted() {
        try appendOutbox(
          taskId: task.taskId,
          destination: destination,
          operation: "ownership",
          payload: "task \(task.taskId) is owned by \(ownerId) and queued",
          taskState: task.state,
          in: database
        )
      }
      return task
    }
  }

  /// Reserves a stable child identity before launch.  The caller may retry
  /// after a crash and receives the same reservation; a changed child identity
  /// is rejected, preventing accidental duplicate workflow dispatch.
  @discardableResult
  public func reserveDispatch(
    taskId: String,
    dispatchId: String,
    childSessionId: String,
    expectedVersion: Int,
    workflowId: String? = nil,
    workflowOriginId: String? = nil,
    workflowRevision: String? = nil,
    entryStepId: String? = nil,
    inputJSON: String? = nil
  ) throws -> SpecialistTask {
    try validateIdentifier(dispatchId)
    try validateIdentifier(childSessionId)
    let database = try openWritable()
    return try database.transaction { database in
      var task = try loadTask(taskId, in: database)
      if let existingDispatch = task.dispatchId {
        guard existingDispatch == dispatchId, task.childSessionId == childSessionId else {
          throw SpecialistSupervisorStoreError.invalidTransition("dispatch reservation conflicts for \(taskId)")
        }
        if let existing = try dispatch(dispatchId: dispatchId, in: database),
           existing.workflowId != workflowId || existing.workflowOriginId != workflowOriginId
             || existing.workflowRevision != workflowRevision || existing.inputJSON != inputJSON {
          throw SpecialistSupervisorStoreError.invalidTransition("dispatch payload conflicts for \(taskId)")
        }
        return task
      }
      guard task.version == expectedVersion, task.ownerId != nil, task.state == .queued else {
        throw SpecialistSupervisorStoreError.invalidTransition("task is not eligible for dispatch")
      }
      task.dispatchId = dispatchId
      task.childSessionId = childSessionId
      task.selectedWorkflowId = workflowId
      task.version += 1
      task.updatedAt = Date()
      try update(task, in: database)
      try database.execute(
        "INSERT INTO specialist_dispatches (dispatch_id, task_id, child_session_id, state) VALUES (?, ?, ?, 'prepared')",
        bindings: [.text(dispatchId), .text(taskId), .text(childSessionId)]
      )
      let record = SpecialistDispatch(
        dispatchId: dispatchId,
        taskId: taskId,
        childSessionId: childSessionId,
        workflowId: workflowId,
        workflowOriginId: workflowOriginId,
        workflowRevision: workflowRevision,
        entryStepId: entryStepId,
        inputJSON: inputJSON
      )
      try saveDispatch(record, in: database)
      // A supervised child is a canonical runtime session before any worker
      // can start it.  This snapshot is in the same immediate transaction as
      // task/dispatch reservation, so a restart resumes this exact identity.
      if let workflowId, let entryStepId {
        let now = Date()
        let session = WorkflowSession(
          workflowId: workflowId,
          sessionId: childSessionId,
          status: .created,
          entryStepId: entryStepId,
          currentStepId: entryStepId,
          createdAt: now,
          updatedAt: now,
          rootSessionId: childSessionId
        )
        try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRootDirectory)
          .save(WorkflowRuntimePersistenceSnapshot(session: session), in: database)
      }
      return task
    }
  }

  public func dispatch(dispatchId: String) throws -> SpecialistDispatch? {
    guard FileManager.default.fileExists(atPath: databasePath) else { return nil }
    let database = try SQLiteDatabase.open(path: databasePath, mode: .readOnly, options: .readOnlyDefault)
    try verifySchema(database)
    return try dispatch(dispatchId: dispatchId, in: database)
  }

  /// Marks an already-reserved child as running.  A retry never allocates a
  /// replacement child and a terminal/uncertain record cannot be relaunched.
  public func beginDispatch(dispatchId: String) throws -> SpecialistDispatch {
    let database = try openWritable()
    return try database.transaction { database in
      var record = try requiredDispatch(dispatchId: dispatchId, in: database)
      switch record.state {
      case .prepared:
        var task = try loadTask(record.taskId, in: database)
        guard task.state == .queued else {
          throw SpecialistSupervisorStoreError.invalidTransition("task is not eligible for launch")
        }
        record.state = .running
        record.launchPhase = .preflighted
        try saveDispatch(record, in: database)
        if task.state == .queued {
          task.state = .running
          task.version += 1
          task.updatedAt = Date()
          try update(task, in: database)
        }
      case .running:
        throw SpecialistSupervisorStoreError.invalidTransition("dispatch is already running")
      case .terminal, .delivered, .recoveryRequired:
        throw SpecialistSupervisorStoreError.invalidTransition("cannot launch \(record.state.rawValue) dispatch")
      }
      return record
    }
  }

  /// Persists the child result and parent delivery intent atomically.  A crash
  /// after this commit is recovered by delivery workers; it cannot rerun the
  /// child merely because the parent notification was not sent yet.
  public func completeDispatch(
    dispatchId: String,
    succeeded: Bool,
    resultJSON: String
  ) throws -> SpecialistDispatch {
    let database = try openWritable()
    return try database.transaction { database in
      var record = try requiredDispatch(dispatchId: dispatchId, in: database)
      let resultHash = digest("\(succeeded ? "succeeded" : "failed")\n\(resultJSON)")
      if record.state == .terminal || record.state == .delivered {
        guard record.resultHash == resultHash else {
          throw SpecialistSupervisorStoreError.invalidTransition("dispatch result conflicts for \(dispatchId)")
        }
        return record
      }
      guard record.state == .running else {
        throw SpecialistSupervisorStoreError.invalidTransition("dispatch is not running")
      }
      record.state = .terminal
      record.resultHash = resultHash
      record.resultJSON = resultJSON
      try saveDispatch(record, in: database)
      var task = try loadTask(record.taskId, in: database)
      guard task.state == .running || task.state == .cancelRequested else {
        throw SpecialistSupervisorStoreError.invalidTransition("task is not awaiting child completion")
      }
      // A cancellation request is intentionally not terminal on its own. Once
      // the execution monitor has observed the child stop, however, it wins
      // over a late normal result: callers must never report success after
      // accepting a cancellation request.
      task.state = task.state == .cancelRequested ? .cancelled : (succeeded ? .succeeded : .failed)
      task.version += 1
      task.updatedAt = Date()
      try update(task, in: database)
      for destination in ["chat", "tracker"] {
        try appendOutbox(
          taskId: task.taskId,
          destination: destination,
          operation: "child_terminal",
          payload: "task \(task.taskId) child \(record.childSessionId) is \(task.state.rawValue)",
          taskState: task.state,
          in: database
        )
      }
      return record
    }
  }

  public func recoverableDispatches() throws -> [SpecialistDispatch] {
    guard FileManager.default.fileExists(atPath: databasePath) else { return [] }
    let database = try SQLiteDatabase.open(path: databasePath, mode: .readOnly, options: .readOnlyDefault)
    try verifySchema(database)
    return try database.query(
      "SELECT json(dispatch_json) AS dispatch_json FROM specialist_dispatch_details WHERE state IN ('prepared', 'running', 'terminal', 'recovery_required') ORDER BY dispatch_id",
      bindings: []
    ).compactMap { $0["dispatch_json"] }.map { try decode(SpecialistDispatch.self, json: $0) }
  }

  @discardableResult
  public func transition(
    taskId: String,
    to state: SpecialistTaskState,
    expectedVersion: Int,
    statusDestination: String = "tracker"
  ) throws -> SpecialistTask {
    let database = try openWritable()
    return try database.transaction { database in
      var task = try loadTask(taskId, in: database)
      guard task.version == expectedVersion else { throw SpecialistSupervisorStoreError.taskVersionConflict(taskId) }
      guard canTransition(from: task.state, to: state) else {
        throw SpecialistSupervisorStoreError.invalidTransition("\(task.state.rawValue) -> \(state.rawValue)")
      }
      task.state = state
      task.version += 1
      task.updatedAt = Date()
      try update(task, in: database)
      try appendOutbox(
        taskId: task.taskId,
        destination: statusDestination,
        operation: "lifecycle",
        payload: "task \(task.taskId) is \(state.rawValue)",
        taskState: state,
        in: database
      )
      return task
    }
  }

  public func task(taskId: String, principal: SpecialistPrincipal) throws -> SpecialistTask? {
    guard FileManager.default.fileExists(atPath: databasePath) else { return nil }
    let database = try SQLiteDatabase.open(path: databasePath, mode: .readOnly, options: .readOnlyDefault)
    try verifySchema(database)
    let rows = try database.query("SELECT json(task_json) AS task_json FROM specialist_tasks WHERE task_id = ?", bindings: [.text(taskId)])
    guard let json = rows.first?["task_json"] else { return nil }
    let found = try decode(SpecialistTask.self, json: json)
    guard found.principal == principal else { return nil }
    return found
  }

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

  /// Returns delivery candidates in destination/sequence order.  The worker
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
  /// it persists the provider outcome.  Once the bounded lease expires, that
  /// generation is conclusively unusable.  Promote it to `uncertain` so no
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

  public func deliveryReceipt(eventId: String) throws -> SpecialistDeliveryReceipt? {
    guard FileManager.default.fileExists(atPath: databasePath) else { return nil }
    let database = try SQLiteDatabase.open(path: databasePath, mode: .readOnly, options: .readOnlyDefault)
    try verifySchema(database)
    return try database.query(
      "SELECT json(receipt_json) AS receipt_json FROM specialist_delivery_receipts WHERE event_id = ?",
      bindings: [.text(eventId)]
    ).first?["receipt_json"].map { try decode(SpecialistDeliveryReceipt.self, json: $0) }
  }

  /// Records reader-tier reconciliation without reopening the outbox write.
  /// A provider receipt may settle uncertainty; not-found and conflict retain
  /// uncertainty because neither proves that a prior remote mutation failed.
  public func reconcileDelivery(eventId: String, remoteReceiptId: String) throws -> SpecialistDeliveryReceipt {
    try validateOpaqueProviderValue(remoteReceiptId)
    let database = try openWritable()
    return try database.transaction { database in
      let current = try deliveryReceipt(eventId: eventId, in: database)
      guard current.state == .uncertain else { return current }
      let settled = SpecialistDeliveryReceipt(
        eventId: current.eventId, destination: current.destination, state: .delivered,
        attempt: current.attempt, generation: current.generation,
        remoteReceiptId: remoteReceiptId
      )
      try saveDeliveryReceipt(settled, in: database)
      return settled
    }
  }

  /// An operator may settle a fenced delivery only with the generation they
  /// inspected and a destination receipt tied to the stable event/transaction
  /// ID. This is deliberately not a retry API.
  public func reconcileDelivery(
    eventId: String, expectedGeneration: Int, remoteReceiptId: String
  ) throws -> SpecialistDeliveryReceipt {
    try validateOpaqueProviderValue(remoteReceiptId)
    let database = try openWritable()
    return try database.transaction { database in
      let current = try deliveryReceipt(eventId: eventId, in: database)
      guard current.state == .uncertain, current.generation == expectedGeneration else {
        throw SpecialistSupervisorStoreError.deliveryConflict(eventId)
      }
      let settled = SpecialistDeliveryReceipt(
        eventId: current.eventId, destination: current.destination, state: .delivered,
        attempt: current.attempt, generation: current.generation, remoteReceiptId: remoteReceiptId
      )
      try saveDeliveryReceipt(settled, in: database)
      try database.execute(
        "INSERT INTO specialist_reconciliation_audit (audit_id, audit_json) VALUES (?, jsonb(?))",
        bindings: [.text("delivery-\(eventId)-\(current.generation)"), .text(try encode(["eventId": eventId, "generation": String(current.generation), "remoteReceiptId": remoteReceiptId, "kind": "delivery_receipt"]))]
      )
      return settled
    }
  }

  /// Persist an expected-version, request-scoped operator decision for an
  /// ambiguous dispatch. The decision is terminal and auditable; it cannot
  /// cause the service to launch a replacement child implicitly.
  @discardableResult
  public func reconcileDispatch(
    taskId: String, requestId: String, expectedVersion: Int,
    outcome: SpecialistDispatchReconciliationOutcome, evidence: String
  ) throws -> SpecialistTask {
    try validateIdentifier(taskId); try validateIdentifier(requestId)
    let boundedEvidence = String(evidence.prefix(2_000))
    guard !boundedEvidence.isEmpty else { throw SpecialistSupervisorStoreError.invalidIdentifier("reconciliation evidence") }
    let database = try openWritable()
    return try database.transaction { database in
      var task = try loadTask(taskId, in: database)
      guard task.requestId == requestId, task.version == expectedVersion else {
        throw SpecialistSupervisorStoreError.taskVersionConflict(taskId)
      }
      guard let dispatchId = task.dispatchId else { throw SpecialistSupervisorStoreError.invalidTransition("task has no dispatch to reconcile") }
      var dispatch = try requiredDispatch(dispatchId: dispatchId, in: database)
      guard dispatch.state == .recoveryRequired else {
        throw SpecialistSupervisorStoreError.invalidTransition("dispatch is not awaiting recovery reconciliation")
      }
      dispatch.state = .terminal
      dispatch.resultJSON = try encode([
        "reconciliation": outcome.rawValue, "evidence": boundedEvidence, "requestId": requestId
      ])
      dispatch.resultHash = digest("\(outcome.rawValue)\n\(dispatch.resultJSON ?? "")")
      task.state = .failed
      task.progressUncertain = outcome == .terminalFailure
      task.version += 1
      task.updatedAt = Date()
      try update(task, in: database)
      try saveDispatch(dispatch, in: database)
      for destination in ["chat", "tracker"] {
        try appendOutbox(
          taskId: task.taskId, destination: destination, operation: "operator_reconciliation",
          payload: "task \(task.taskId) reconciled as \(outcome.rawValue)", taskState: .failed, in: database
        )
      }
      let auditID = "dispatch-\(dispatchId)-v\(expectedVersion)"
      try database.execute(
        "INSERT INTO specialist_reconciliation_audit (audit_id, audit_json) VALUES (?, jsonb(?))",
        bindings: [.text(auditID), .text(try encode([
          "taskId": taskId, "requestId": requestId, "expectedVersion": String(expectedVersion),
          "outcome": outcome.rawValue, "evidence": boundedEvidence
        ]))]
      )
      return task
    }
  }

  /// Claims an outbox delivery using a fenced generation. Only the worker that
  /// acquired this generation may record its result. This makes stale retries
  /// harmless after a restart without pretending remote effects are exactly-once.
  public func beginDelivery(eventId: String) throws -> SpecialistDeliveryReceipt {
    let database = try openWritable()
    return try database.transaction { database in
      let current = try deliveryReceipt(eventId: eventId, in: database)
      guard current.state != .delivering else {
        throw SpecialistSupervisorStoreError.deliveryConflict(eventId)
      }
      guard current.state != .delivered, current.state != .permanentFailure,
            current.state != .uncertain else { return current }
      let next = SpecialistDeliveryReceipt(
        eventId: current.eventId,
        destination: current.destination,
        state: .delivering,
        attempt: current.attempt + 1,
        generation: current.generation + 1
      )
      try saveDeliveryReceipt(next, in: database)
      return next
    }
  }

  /// Records a provider outcome only if it belongs to the current delivery
  /// lease. Uncertain delivery is terminal until an operator reconciliation
  /// provides evidence; it is never automatically retried.
  public func completeDelivery(
    _ receipt: SpecialistDeliveryReceipt,
    state: SpecialistDeliveryState,
    remoteReceiptId: String? = nil,
    retryAfter: TimeInterval? = nil
  ) throws -> SpecialistDeliveryReceipt {
    guard state != .pending, state != .delivering else {
      throw SpecialistSupervisorStoreError.deliveryConflict(receipt.eventId)
    }
    let database = try openWritable()
    return try database.transaction { database in
      let current = try deliveryReceipt(eventId: receipt.eventId, in: database)
      guard current.generation == receipt.generation, current.state == .delivering else {
        throw SpecialistSupervisorStoreError.deliveryConflict(receipt.eventId)
      }
      let retryDeadline: Date?
      if state == .retryableFailure {
        // 1, 2, 4 ... seconds, respecting a bounded provider Retry-After.
        // The stored deadline, not process memory, is retry authority after a
        // restart. A malformed provider value can never disable backoff.
        let exponential = TimeInterval(min(60, 1 << min(max(current.attempt - 1, 0), 6)))
        let requested = retryAfter.map { min(60, max(0, $0.isFinite ? $0 : 0)) } ?? 0
        let seconds = max(exponential, requested)
        retryDeadline = Date().addingTimeInterval(TimeInterval(seconds))
      } else {
        retryDeadline = nil
      }
      let completed = SpecialistDeliveryReceipt(
        eventId: current.eventId,
        destination: current.destination,
        state: state,
        attempt: current.attempt,
        generation: current.generation,
        remoteReceiptId: remoteReceiptId,
        nextAttemptAt: retryDeadline
      )
      try saveDeliveryReceipt(completed, in: database)
      return completed
    }
  }

  func openWritable() throws -> SQLiteDatabase {
    let database = try SQLiteDatabase.open(path: databasePath, mode: .readWriteCreate, options: .writableDefault)
    try prepareSchema(database)
    return database
  }

  private func prepareSchema(_ database: SQLiteDatabase) throws {
    try database.transaction { database in
      try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRootDirectory).prepareSchema(in: database)
      try verifySchema(database)
      try database.execute(requestsTableSQL)
      try database.execute(tasksTableSQL)
      try database.execute("CREATE INDEX IF NOT EXISTS idx_specialist_tasks_owner_state ON specialist_tasks (owner_id, state)")
      try database.execute(dispatchesTableSQL)
      try database.execute(dispatchDetailsTableSQL)
      try database.execute(outboxTableSQL)
      try database.execute("CREATE TABLE IF NOT EXISTS specialist_routing (request_id TEXT PRIMARY KEY REFERENCES specialist_requests(request_id), routing_json BLOB NOT NULL CHECK (json_valid(routing_json, 8)))")
      try database.execute(classificationRoundsTableSQL)
      try database.execute("CREATE TABLE IF NOT EXISTS specialist_nested_invocations (invocation_key TEXT PRIMARY KEY, invocation_json BLOB NOT NULL CHECK (json_valid(invocation_json, 8)))")
      try database.execute("CREATE TABLE IF NOT EXISTS specialist_service_lease (name TEXT PRIMARY KEY, lease_json BLOB NOT NULL CHECK (json_valid(lease_json, 8)))")
      try database.execute("CREATE TABLE IF NOT EXISTS specialist_provider_cursors (provider TEXT PRIMARY KEY, cursor TEXT NOT NULL)")
      try database.execute("CREATE TABLE IF NOT EXISTS specialist_delivery_receipts (event_id TEXT PRIMARY KEY REFERENCES specialist_outbox(event_id), receipt_json BLOB NOT NULL CHECK (json_valid(receipt_json, 8)))")
      try database.execute("CREATE TABLE IF NOT EXISTS specialist_reconciliation_audit (audit_id TEXT PRIMARY KEY, audit_json BLOB NOT NULL CHECK (json_valid(audit_json, 8)))")
    }
  }

  private var requestsTableSQL: String {
    [
      "CREATE TABLE IF NOT EXISTS specialist_requests (request_id TEXT PRIMARY KEY,",
      "source_key TEXT NOT NULL UNIQUE, request_hash TEXT NOT NULL,",
      "request_json BLOB NOT NULL CHECK (json_valid(request_json, 8)), received_at TEXT NOT NULL)"
    ].joined(separator: " ")
  }

  private var tasksTableSQL: String {
    [
      "CREATE TABLE IF NOT EXISTS specialist_tasks (task_id TEXT PRIMARY KEY,",
      "request_id TEXT NOT NULL UNIQUE, owner_id TEXT, state TEXT NOT NULL, version INTEGER NOT NULL,",
      "task_json BLOB NOT NULL CHECK (json_valid(task_json, 8)), updated_at TEXT NOT NULL)"
    ].joined(separator: " ")
  }

  private var dispatchesTableSQL: String {
    "CREATE TABLE IF NOT EXISTS specialist_dispatches (dispatch_id TEXT PRIMARY KEY, task_id TEXT NOT NULL UNIQUE, child_session_id TEXT NOT NULL UNIQUE, state TEXT NOT NULL)"
  }

  private var dispatchDetailsTableSQL: String {
    [
      "CREATE TABLE IF NOT EXISTS specialist_dispatch_details (dispatch_id TEXT PRIMARY KEY",
      "REFERENCES specialist_dispatches(dispatch_id), state TEXT NOT NULL,",
      "dispatch_json BLOB NOT NULL CHECK (json_valid(dispatch_json, 8)))"
    ].joined(separator: " ")
  }

  private var outboxTableSQL: String {
    [
      "CREATE TABLE IF NOT EXISTS specialist_outbox (event_id TEXT PRIMARY KEY, task_id TEXT,",
      "destination TEXT NOT NULL, sequence INTEGER NOT NULL,",
      "event_json BLOB NOT NULL CHECK (json_valid(event_json, 8)), UNIQUE(task_id, destination, sequence))"
    ].joined(separator: " ")
  }

  private var classificationRoundsTableSQL: String {
    [
      "CREATE TABLE IF NOT EXISTS specialist_classification_rounds (",
      "request_id TEXT PRIMARY KEY REFERENCES specialist_requests(request_id),",
      "round_json BLOB NOT NULL CHECK (json_valid(round_json, 8)))"
    ].joined(separator: " ")
  }

  func verifySchema(_ database: SQLiteDatabase) throws {
    do {
      try SQLiteWorkflowRuntimePersistenceStore.requireCompatibleSchemaGeneration(in: database)
    } catch {
      let version = Int64(try database.query("PRAGMA user_version").first?.string("user_version") ?? "0") ?? 0
      throw SpecialistSupervisorStoreError.schemaTooNew(version)
    }
  }

  private var runtimeRootDirectory: String {
    URL(fileURLWithPath: databasePath).deletingLastPathComponent().path
  }

  private func insert(_ task: SpecialistTask, in database: SQLiteDatabase) throws {
    try database.execute(
      "INSERT INTO specialist_tasks (task_id, request_id, owner_id, state, version, task_json, updated_at) VALUES (?, ?, ?, ?, ?, jsonb(?), ?)",
      bindings: [.text(task.taskId), .text(task.requestId), .optionalText(task.ownerId), .text(task.state.rawValue), .int(Int64(task.version)), .text(try encode(task)), .text(timestamp(task.updatedAt))]
    )
  }

  func update(_ task: SpecialistTask, in database: SQLiteDatabase) throws {
    try database.execute(
      "UPDATE specialist_tasks SET owner_id = ?, state = ?, version = ?, task_json = jsonb(?), updated_at = ? WHERE task_id = ?",
      bindings: [.optionalText(task.ownerId), .text(task.state.rawValue), .int(Int64(task.version)), .text(try encode(task)), .text(timestamp(task.updatedAt)), .text(task.taskId)]
    )
  }

  func loadTask(_ taskId: String, in database: SQLiteDatabase) throws -> SpecialistTask {
    guard let json = try database.query("SELECT json(task_json) AS task_json FROM specialist_tasks WHERE task_id = ?", bindings: [.text(taskId)]).first?["task_json"] else {
      throw SpecialistSupervisorStoreError.taskNotFound(taskId)
    }
    return try decode(SpecialistTask.self, json: json)
  }

  private func dispatch(dispatchId: String, in database: SQLiteDatabase) throws -> SpecialistDispatch? {
    guard let json = try database.query(
      "SELECT json(dispatch_json) AS dispatch_json FROM specialist_dispatch_details WHERE dispatch_id = ?",
      bindings: [.text(dispatchId)]
    ).first?["dispatch_json"] else { return nil }
    return try decode(SpecialistDispatch.self, json: json)
  }

  private func dispatch(taskId: String, in database: SQLiteDatabase) throws -> String? {
    guard let json = try database.query(
      "SELECT json(task_json) AS task_json FROM specialist_tasks WHERE task_id = ?",
      bindings: [.text(taskId)]
    ).first?["task_json"] else { return nil }
    return try decode(SpecialistTask.self, json: json).trackerTaskId
  }

  func requiredDispatch(dispatchId: String, in database: SQLiteDatabase) throws -> SpecialistDispatch {
    guard let record = try dispatch(dispatchId: dispatchId, in: database) else {
      throw SpecialistSupervisorStoreError.taskNotFound(dispatchId)
    }
    return record
  }

  func saveDispatch(_ dispatch: SpecialistDispatch, in database: SQLiteDatabase) throws {
    try database.execute(
      "INSERT INTO specialist_dispatch_details (dispatch_id, state, dispatch_json) VALUES (?, ?, jsonb(?)) ON CONFLICT(dispatch_id) DO UPDATE SET state = excluded.state, dispatch_json = excluded.dispatch_json",
      bindings: [.text(dispatch.dispatchId), .text(dispatch.state.rawValue), .text(try encode(dispatch))]
    )
    try database.execute(
      "UPDATE specialist_dispatches SET state = ? WHERE dispatch_id = ?",
      bindings: [.text(dispatch.state.rawValue), .text(dispatch.dispatchId)]
    )
  }

  func appendOutbox(
    taskId: String, destination: String, operation: String, payload: String,
    taskState: SpecialistTaskState? = nil, in database: SQLiteDatabase
  ) throws {
    let sequence = Int(try database.query(
      "SELECT COALESCE(MAX(sequence), 0) + 1 AS sequence FROM specialist_outbox WHERE task_id = ? AND destination = ?",
      bindings: [.text(taskId), .text(destination)]
    ).first?.string("sequence") ?? "1") ?? 1
    let event = SpecialistOutboxEvent(
      eventId: digest(CanonicalOutboxKey(taskId: taskId, sequence: sequence, destination: destination, operation: operation)),
      taskId: taskId,
      destination: destination,
      operation: operation,
      payload: payload,
      sequence: sequence,
      taskState: taskState,
      recipient: try loadTask(taskId, in: database).principal
    )
    try database.execute(
      "INSERT INTO specialist_outbox (event_id, task_id, destination, sequence, event_json) VALUES (?, ?, ?, ?, jsonb(?))",
      bindings: [.text(event.eventId), .text(taskId), .text(destination), .int(Int64(sequence)), .text(try encode(event))]
    )
    let receipt = SpecialistDeliveryReceipt(eventId: event.eventId, destination: destination, state: .pending, attempt: 0, generation: 0)
    try saveDeliveryReceipt(receipt, in: database)
  }

  private func deliveryReceipt(eventId: String, in database: SQLiteDatabase) throws -> SpecialistDeliveryReceipt {
    guard let json = try database.query(
      "SELECT json(receipt_json) AS receipt_json FROM specialist_delivery_receipts WHERE event_id = ?",
      bindings: [.text(eventId)]
    ).first?["receipt_json"] else {
      throw SpecialistSupervisorStoreError.deliveryConflict(eventId)
    }
    return try decode(SpecialistDeliveryReceipt.self, json: json)
  }

  private func saveDeliveryReceipt(_ receipt: SpecialistDeliveryReceipt, in database: SQLiteDatabase) throws {
    try database.execute(
      "INSERT INTO specialist_delivery_receipts (event_id, receipt_json) VALUES (?, jsonb(?)) ON CONFLICT(event_id) DO UPDATE SET receipt_json = excluded.receipt_json",
      bindings: [.text(receipt.eventId), .text(try encode(receipt))]
    )
  }

  private func validate(_ request: SpecialistRequest) throws {
    try validateIdentifier(request.requestId)
    try validateOpaqueProviderValue(request.sourceEventId)
    guard !request.body.isEmpty, request.body.utf8.count <= 32_768 else { throw SpecialistSupervisorStoreError.invalidIdentifier("request body") }
    for value in [request.principal.accountId, request.principal.actorId, request.principal.roomId] { try validateOpaqueProviderValue(value) }
    if let threadId = request.principal.threadId { try validateOpaqueProviderValue(threadId) }
  }

  func validateIdentifier(_ value: String) throws {
    guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression) != nil else {
      throw SpecialistSupervisorStoreError.invalidIdentifier(value)
    }
  }

  private func scopedSourceKey(_ request: SpecialistRequest) -> String {
    digest(CanonicalSourceKey(accountId: request.principal.accountId, roomId: request.principal.roomId, sourceEventId: request.sourceEventId))
  }

  private func digest(_ request: SpecialistRequest) -> String {
    digest(CanonicalRequestFingerprint(route: request.route, principal: request.principal, body: request.body))
  }

  private func digest<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(value)) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  func validateOpaqueProviderValue(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 512,
          !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
      throw SpecialistSupervisorStoreError.invalidIdentifier(value)
    }
  }

  private func canTransition(from: SpecialistTaskState, to: SpecialistTaskState) -> Bool {
    switch (from, to) {
    case (.queued, .running), (.queued, .unclaimed), (.queued, .capacityWait),
         (.queued, .needsClarification), (.queued, .recoveryRequired), (.queued, .cancelRequested),
         (.unclaimed, .queued), (.capacityWait, .queued),
         (.running, .succeeded), (.running, .failed), (.running, .cancelRequested),
         (.running, .recoveryRequired),
         (.needsClarification, .queued), (.needsClarification, .cancelRequested),
         (.recoveryRequired, .queued),
         (.cancelRequested, .cancelled):
      true
    default:
      false
    }
  }

  func encode<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    guard let json = String(data: try encoder.encode(value), encoding: .utf8) else {
      throw SpecialistSupervisorStoreError.encodingFailure
    }
    return json
  }

  func decode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(json.utf8))
  }

  private func timestamp(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}
