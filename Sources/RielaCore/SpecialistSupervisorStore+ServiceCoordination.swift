import Foundation
import RielaSQLite

extension SpecialistSupervisorStore {
  /// A cancellation accepted before launch has a canonical no-effect outcome:
  /// no monitor nonce, process, or child node was started.  Persist both the
  /// terminal dispatch receipt and task projection so recovery does not feed a
  /// cancel-requested prepared record into the normal launch path.
  @discardableResult
  public func cancelPreparedDispatch(dispatchId: String, now: Date = Date()) throws -> SpecialistDispatch {
    let database = try openWritable()
    return try database.transaction { database in
      var record = try requiredDispatch(dispatchId: dispatchId, in: database)
      guard record.state == .prepared else {
        throw SpecialistSupervisorStoreError.invalidTransition("dispatch was already started or terminal")
      }
      var task = try loadTask(record.taskId, in: database)
      guard task.state == .cancelRequested else {
        throw SpecialistSupervisorStoreError.invalidTransition("prepared dispatch has no cancellation request")
      }
      let result = #"{\"cancellation\":\"confirmed_no_effect_before_launch\"}"#
      record.state = .terminal
      record.resultHash = digest("cancelled\n\(result)")
      record.resultJSON = result
      record.launchPhase = nil
      task.state = .cancelled
      task.progressUncertain = false
      task.version += 1
      task.updatedAt = now
      try update(task, in: database)
      try saveDispatch(record, in: database)
      for destination in ["chat", "tracker"] {
        try appendOutbox(
          taskId: task.taskId, destination: destination, operation: "child_terminal",
          payload: "task \(task.taskId) child \(record.childSessionId) is cancelled (no effect before launch)",
          taskState: .cancelled, in: database
        )
      }
      return record
    }
  }

  /// Commit a one-time monitor capability before `Process.run`. A process that
  /// appears after its launcher dies is fenced unless it proves this nonce.
  public func authorizeChildMonitorLaunch(
    dispatchId: String, controlToken: String, now: Date = Date()
  ) throws -> SpecialistDispatch {
    let tokenHash = try Self.monitorControlTokenHash(controlToken)
    let database = try openWritable()
    return try database.transaction { database in
      var record = try requiredDispatch(dispatchId: dispatchId, in: database)
      guard record.state == .running, record.launchPhase == .preflighted else {
        throw SpecialistSupervisorStoreError.invalidTransition("dispatch is not preflighted for monitor launch")
      }
      record.launchPhase = .launchAuthorized
      record.childControlTokenHash = tokenHash
      record.childMonitorHeartbeatAt = now
      try saveDispatch(record, in: database)
      return record
    }
  }

  /// Bind the independently spawned monitor before runner setup or node work.
  public func bindChildMonitor(
    dispatchId: String, childSessionId: String, token: String, now: Date = Date()
  ) throws -> SpecialistDispatch {
    let tokenHash = try Self.monitorControlTokenHash(token)
    let database = try openWritable()
    return try database.transaction { database in
      var record = try requiredDispatch(dispatchId: dispatchId, in: database)
      guard record.state == .running, record.childSessionId == childSessionId,
            record.launchPhase == .launchAuthorized, record.childControlTokenHash == tokenHash else {
        throw SpecialistSupervisorStoreError.invalidTransition("child monitor launch binding is invalid")
      }
      record.launchPhase = .monitorBound
      record.childMonitorHeartbeatAt = now
      try saveDispatch(record, in: database)
      return record
    }
  }

  /// Final durable fence immediately before the monitor enters node execution.
  public func beginChildNodeExecution(
    dispatchId: String, childSessionId: String, token: String, now: Date = Date()
  ) throws -> SpecialistDispatch {
    let tokenHash = try Self.monitorControlTokenHash(token)
    let database = try openWritable()
    return try database.transaction { database in
      var record = try requiredDispatch(dispatchId: dispatchId, in: database)
      guard record.state == .running, record.childSessionId == childSessionId,
            record.launchPhase == .monitorBound, record.childControlTokenHash == tokenHash else {
        throw SpecialistSupervisorStoreError.invalidTransition("child monitor cannot begin node execution")
      }
      record.launchPhase = .nodeStarted
      record.childMonitorHeartbeatAt = now
      try saveDispatch(record, in: database)
      return record
    }
  }

  /// Recovery accepts only canonical no-effect evidence: the child must still
  /// be created with no recorded execution. Clearing the nonce then fences a
  /// delayed old monitor before a replacement returns the dispatch to prepared.
  public func reopenUnstartedDispatch(dispatchId: String, now: Date = Date()) throws -> SpecialistDispatch {
    guard let candidate = try dispatch(dispatchId: dispatchId) else {
      throw SpecialistSupervisorStoreError.taskNotFound(dispatchId)
    }
    let persistence = SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: URL(fileURLWithPath: databasePath).deletingLastPathComponent().path
    )
    let snapshot: WorkflowRuntimePersistenceSnapshot
    do {
      snapshot = try persistence.load(sessionId: candidate.childSessionId)
    } catch {
      throw SpecialistSupervisorStoreError.invalidTransition("dispatch has no canonical no-effect child evidence")
    }
    guard snapshot.session.status == .created, snapshot.session.executions.isEmpty else {
      throw SpecialistSupervisorStoreError.invalidTransition("dispatch has uncertain canonical child execution")
    }
    let database = try openWritable()
    return try database.transaction { database in
      var record = try requiredDispatch(dispatchId: dispatchId, in: database)
      guard record.state == .running || record.state == .recoveryRequired,
            record.launchPhase != .nodeStarted else {
        throw SpecialistSupervisorStoreError.invalidTransition("dispatch has uncertain node execution")
      }
      var task = try loadTask(record.taskId, in: database)
      guard task.state == .running || task.state == .recoveryRequired else {
        throw SpecialistSupervisorStoreError.invalidTransition("task is not recoverable")
      }
      record.state = .prepared
      record.launchPhase = nil
      record.childProcessId = nil
      record.childReceiptPath = nil
      record.childMonitorStartedAt = nil
      record.childControlTokenHash = nil
      record.childMonitorHeartbeatAt = nil
      task.state = .queued
      task.progressUncertain = true
      task.version += 1
      task.updatedAt = now
      try update(task, in: database)
      try saveDispatch(record, in: database)
      return record
    }
  }

  /// One durable supervisor worker owns the execution lane at a time. A
  /// crashed worker may be replaced only after its bounded lease expires;
  /// callers cannot concurrently launch the same prepared child.
  public func acquireServiceLease(workerId: String, now: Date = Date(), staleAfter: TimeInterval = 120) throws -> SpecialistServiceLease {
    try validateIdentifier(workerId)
    let database = try openWritable()
    return try database.transaction { database in
      let rows = try database.query("SELECT json(lease_json) AS lease_json FROM specialist_service_lease WHERE name = 'executor'", bindings: [])
      if let json = rows.first?["lease_json"] {
        let current = try decode(SpecialistServiceLease.self, json: json)
        guard now.timeIntervalSince(current.acquiredAt) >= staleAfter else {
          throw SpecialistSupervisorStoreError.invalidTransition("specialist service worker is already active")
        }
        let replacement = SpecialistServiceLease(workerId: workerId, generation: current.generation + 1, acquiredAt: now)
        try database.execute("UPDATE specialist_service_lease SET lease_json = jsonb(?) WHERE name = 'executor'", bindings: [.text(try encode(replacement))])
        return replacement
      }
      let lease = SpecialistServiceLease(workerId: workerId, generation: 1, acquiredAt: now)
      try database.execute("INSERT INTO specialist_service_lease (name, lease_json) VALUES ('executor', jsonb(?))", bindings: [.text(try encode(lease))])
      return lease
    }
  }

  public func releaseServiceLease(_ lease: SpecialistServiceLease) throws {
    let database = try openWritable()
    try database.transaction { database in
      let rows = try database.query("SELECT json(lease_json) AS lease_json FROM specialist_service_lease WHERE name = 'executor'", bindings: [])
      guard let json = rows.first?["lease_json"] else {
        throw SpecialistSupervisorStoreError.invalidTransition("specialist service lease changed")
      }
      let current = try decode(SpecialistServiceLease.self, json: json)
      guard current.workerId == lease.workerId, current.generation == lease.generation else {
        throw SpecialistSupervisorStoreError.invalidTransition("specialist service lease changed")
      }
      try database.execute("DELETE FROM specialist_service_lease WHERE name = 'executor'", bindings: [])
    }
  }

  /// A restarted service records that it observed the durable running child;
  /// this never re-enters the launch transition.
  public func attachRunningDispatch(dispatchId: String, now: Date = Date()) throws -> SpecialistDispatch {
    let database = try openWritable()
    return try database.transaction { database in
      var record = try requiredDispatch(dispatchId: dispatchId, in: database)
      guard record.state == .running else {
        throw SpecialistSupervisorStoreError.invalidTransition("dispatch is not running")
      }
      record.attachmentGeneration = (record.attachmentGeneration ?? 0) + 1
      record.lastAttachedAt = now
      try saveDispatch(record, in: database)
      return record
    }
  }

  /// Persists the workflow-run monitor that remains parent of child commands
  /// after a serving process is killed.
  public func recordChildMonitor(
    dispatchId: String, processId: Int32, receiptPath: String, controlToken: String? = nil, now: Date = Date()
  ) throws -> SpecialistDispatch {
    guard processId > 0, !receiptPath.isEmpty else {
      throw SpecialistSupervisorStoreError.invalidTransition("child monitor metadata is invalid")
    }
    let tokenHash = try controlToken.map(Self.monitorControlTokenHash)
    let database = try openWritable()
    return try database.transaction { database in
      var record = try requiredDispatch(dispatchId: dispatchId, in: database)
      guard record.state == .running else {
        throw SpecialistSupervisorStoreError.invalidTransition("dispatch is not running")
      }
      if let existing = record.childProcessId {
        guard existing == processId, record.childReceiptPath == receiptPath, record.childControlTokenHash == tokenHash else {
          throw SpecialistSupervisorStoreError.invalidTransition("child monitor conflicts for \(dispatchId)")
        }
        return record
      }
      guard record.launchPhase == .preflighted || record.launchPhase == .launchAuthorized || record.launchPhase == .monitorBound || record.launchPhase == .nodeStarted else {
        throw SpecialistSupervisorStoreError.invalidTransition("child monitor was not authorized before process launch")
      }
      // Compatibility for records created by the older direct monitor API.
      // Product launch uses authorizeChildMonitorLaunch before Process.run.
      if record.launchPhase == .preflighted {
        record.launchPhase = .launchAuthorized
      }
      record.childProcessId = processId
      record.childReceiptPath = receiptPath
      record.childMonitorStartedAt = now
      record.childControlTokenHash = tokenHash
      try saveDispatch(record, in: database)
      return record
    }
  }

  public func recordChildReceiptObserved(dispatchId: String, now: Date = Date()) throws -> SpecialistDispatch {
    let database = try openWritable()
    return try database.transaction { database in
      var record = try requiredDispatch(dispatchId: dispatchId, in: database)
      guard record.state == .terminal || record.state == .delivered else {
        throw SpecialistSupervisorStoreError.invalidTransition("dispatch is not terminal")
      }
      record.childReceiptObservedAt = now
      record.childProcessId = nil
      record.childControlTokenHash = nil
      record.childMonitorHeartbeatAt = nil
      try saveDispatch(record, in: database)
      return record
    }
  }

  /// A dead monitor without a canonical terminal receipt is never relaunched.
  public func requireDispatchRecovery(dispatchId: String) throws -> SpecialistDispatch {
    let database = try openWritable()
    return try database.transaction { database in
      var record = try requiredDispatch(dispatchId: dispatchId, in: database)
      guard record.state == .running else {
        throw SpecialistSupervisorStoreError.invalidTransition("dispatch is not running")
      }
      record.state = .recoveryRequired
      try saveDispatch(record, in: database)
      var task = try loadTask(record.taskId, in: database)
      if task.state == .running {
        task.state = .recoveryRequired
        task.progressUncertain = true
        task.version += 1
        task.updatedAt = Date()
        try update(task, in: database)
      }
      return record
    }
  }

  /// A long-lived service must renew its fenced lease while it remains alive.
  /// The generation is never changed by a heartbeat, so a replaced process
  /// cannot revive itself after a stale takeover.
  @discardableResult
  public func renewServiceLease(_ lease: SpecialistServiceLease, now: Date = Date()) throws -> SpecialistServiceLease {
    let database = try openWritable()
    return try database.transaction { database in
      let rows = try database.query("SELECT json(lease_json) AS lease_json FROM specialist_service_lease WHERE name = 'executor'", bindings: [])
      guard let json = rows.first?["lease_json"] else {
        throw SpecialistSupervisorStoreError.invalidTransition("specialist service lease is absent")
      }
      let current = try decode(SpecialistServiceLease.self, json: json)
      guard current.workerId == lease.workerId, current.generation == lease.generation else {
        throw SpecialistSupervisorStoreError.invalidTransition("specialist service lease was fenced")
      }
      let renewed = SpecialistServiceLease(workerId: current.workerId, generation: current.generation, acquiredAt: now)
      try database.execute("UPDATE specialist_service_lease SET lease_json = jsonb(?) WHERE name = 'executor'", bindings: [.text(try encode(renewed))])
      return renewed
    }
  }

  public func providerCursor(provider: String) throws -> String? {
    guard FileManager.default.fileExists(atPath: databasePath) else { return nil }
    let database = try SQLiteDatabase.open(path: databasePath, mode: .readOnly, options: .readOnlyDefault)
    try verifySchema(database)
    return try database.query("SELECT cursor FROM specialist_provider_cursors WHERE provider = ?", bindings: [.text(provider)]).first?["cursor"]
  }

  /// Advances a provider cursor only after every accepted event from the page
  /// has been persisted. Redelivery is still safe because source receipts are
  /// independently unique.
  public func saveProviderCursor(provider: String, cursor: String) throws {
    try validateIdentifier(provider)
    try validateOpaqueProviderValue(cursor)
    let database = try openWritable()
    try database.execute(
      "INSERT INTO specialist_provider_cursors (provider, cursor) VALUES (?, ?) ON CONFLICT(provider) DO UPDATE SET cursor = excluded.cursor",
      bindings: [.text(provider), .text(cursor)]
    )
  }
}
