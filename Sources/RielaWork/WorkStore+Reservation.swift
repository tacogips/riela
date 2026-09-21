import Crypto
import Foundation
import RielaCore
import RielaSQLite

public struct AttemptReservationRequest: Equatable, Sendable {
  public var taskId: TaskID
  public var expectedTaskVersion: Int
  public var attemptId: AttemptID
  public var sessionId: String
  public var workflowId: String
  public var entryStepId: String
  public var entry: AttemptEntry
  public var decisionId: DecisionID
  public var producer: DecisionProducer
  public var reason: String
  public var causedBy: [EvidenceID]
  public var placementEvidence: Evidence?
  public var pendingRequestId: String?
  public var launchToken: String?
  public var now: Date
  var failurePoint: AttemptReservationFailurePoint?

  public init(
    taskId: TaskID,
    expectedTaskVersion: Int,
    attemptId: AttemptID,
    sessionId: String,
    workflowId: String,
    entryStepId: String,
    entry: AttemptEntry,
    decisionId: DecisionID,
    producer: DecisionProducer,
    reason: String,
    causedBy: [EvidenceID] = [],
    placementEvidence: Evidence? = nil,
    pendingRequestId: String? = nil,
    launchToken: String? = nil,
    now: Date = Date()
  ) {
    self.taskId = taskId
    self.expectedTaskVersion = expectedTaskVersion
    self.attemptId = attemptId
    self.sessionId = sessionId
    self.workflowId = workflowId
    self.entryStepId = entryStepId
    self.entry = entry
    self.decisionId = decisionId
    self.producer = producer
    self.reason = reason
    self.causedBy = causedBy
    self.placementEvidence = placementEvidence
    self.pendingRequestId = pendingRequestId
    self.launchToken = launchToken
    self.now = now
    failurePoint = nil
  }
}

enum AttemptReservationFailurePoint: CaseIterable, Sendable {
  case attempt, decisionOrRequest, lease, evidence, task, session
}

public struct PendingAttemptReservation: Equatable, Sendable {
  public var id: String
  public var taskId: TaskID
  public var decisionId: DecisionID
  public var predecessorAttemptId: AttemptID?
  public var entry: AttemptEntry

  public init(id: String, taskId: TaskID, decisionId: DecisionID, predecessorAttemptId: AttemptID?, entry: AttemptEntry) {
    self.id = id
    self.taskId = taskId
    self.decisionId = decisionId
    self.predecessorAttemptId = predecessorAttemptId
    self.entry = entry
  }
}

public struct AttemptReservation: Equatable, Sendable {
  public var task: WorkTask
  public var attempt: Attempt
  public var decision: Decision
  public var launchToken: String

  public init(task: WorkTask, attempt: Attempt, decision: Decision, launchToken: String) {
    self.task = task
    self.attempt = attempt
    self.decision = decision
    self.launchToken = launchToken
  }
}

public extension WorkStore {
  /// Atomically commits one task attempt, its launch lease and decision, and
  /// the canonical `.created` workflow snapshot on the shared connection.
  func reserveAttempt(_ request: AttemptReservationRequest) throws -> AttemptReservation {
    let database = try openWritable()
    return try database.transaction { database in
      let task = try requiredTask(request.taskId, in: database)
      guard task.version == request.expectedTaskVersion else {
        throw WorkStoreError.versionConflict(taskId: task.id, expected: request.expectedTaskVersion)
      }
      let live = try database.query(
        "SELECT attempt_id FROM work_attempts WHERE task_id = ? AND state IN ('prepared', 'running', 'terminal') LIMIT 1",
        bindings: [.text(task.id.rawValue)]
      )
      guard live.isEmpty else {
        throw WorkStoreError("task '\(task.id.rawValue)' already has a live attempt")
      }
      guard Self.dispatchEligibleStates.contains(task.state) else {
        throw WorkStoreError("task '\(task.id.rawValue)' is not eligible for dispatch from state '\(task.state.rawValue)'")
      }
      guard task.plan != nil else {
        throw WorkStoreError("task '\(task.id.rawValue)' has no executable plan")
      }
      try validateDependencies(of: task, in: database)
      if let maximum = task.guardPolicy.budget?.maxAttempts {
        let used = try attemptCount(for: task.id, in: database)
        guard used < maximum else {
          throw WorkStoreError("task '\(task.id.rawValue)' exhausted its attempt budget")
        }
      }

      let token = request.launchToken ?? UUID().uuidString.lowercased()
      let digest = Self.launchTokenDigest(token)
      let launch = AttemptLaunchMetadata(
        phase: .reserved,
        tokenDigest: digest,
        reservedAt: request.now,
        updatedAt: request.now
      )
      let attempt = Attempt(
        id: request.attemptId,
        taskId: task.id,
        generation: try nextGeneration(for: task.id, in: database),
        sessionId: request.sessionId,
        entry: request.entry,
        state: .prepared,
        launch: launch
      )
      let decision: Decision
      if request.pendingRequestId != nil {
        guard let existing = try storedDecision(request.decisionId, in: database),
              existing.taskId == task.id,
              Self.requestedEntry(for: existing.kind) == request.entry else {
          throw WorkStoreError("pending reservation decision is missing or conflicts")
        }
        decision = existing
      } else {
        decision = Decision(
          id: request.decisionId,
          taskId: task.id,
          attemptId: attempt.id,
          producer: request.producer,
          kind: Self.decisionKind(for: request.entry),
          reason: request.reason,
          causedBy: request.causedBy,
          createdAt: request.now
        )
      }
      var updatedTask = task
      updatedTask.state = .running
      updatedTask.version += 1

      try insertAttempt(attempt, in: database, createdAt: request.now)
      try failIfRequested(.attempt, request: request)
      if let pendingRequestId = request.pendingRequestId {
        try consumePendingReservation(
          id: pendingRequestId,
          taskId: task.id,
          decision: decision,
          attemptId: attempt.id,
          now: request.now,
          in: database
        )
      } else {
        try insertDecision(decision, in: database)
      }
      try failIfRequested(.decisionOrRequest, request: request)
      try database.execute(
        "INSERT INTO work_leases (attempt_id, task_id, session_id, token_digest, acquired_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
        bindings: [
          .text(attempt.id.rawValue), .text(task.id.rawValue), .text(attempt.sessionId),
          .text(digest), .text(Self.timestamp(request.now)), .text(Self.timestamp(request.now))
        ]
      )
      try failIfRequested(.lease, request: request)
      if let evidence = request.placementEvidence {
        guard evidence.taskId == task.id, evidence.attemptId == nil || evidence.attemptId == attempt.id else {
          throw WorkStoreError("placement evidence does not belong to the reserved task and attempt")
        }
        try insertEvidence(evidence, in: database)
      }
      try failIfRequested(.evidence, request: request)
      try updateTask(updatedTask, expectedVersion: task.version, in: database)
      try failIfRequested(.task, request: request)

      let session = WorkflowSession(
        workflowId: request.workflowId,
        sessionId: request.sessionId,
        status: .created,
        entryStepId: request.entryStepId,
        currentStepId: request.entryStepId,
        createdAt: request.now,
        updatedAt: request.now,
        rootSessionId: request.sessionId
      )
      let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: rootDirectory)
      try persistence.prepareSchema(in: database)
      try persistence.save(WorkflowRuntimePersistenceSnapshot(session: session), in: database)
      try failIfRequested(.session, request: request)
      return AttemptReservation(task: updatedTask, attempt: attempt, decision: decision, launchToken: token)
    }
  }

  /// Exchanges the one-time opaque token for launch authorization. Replays
  /// and every state other than the exact reserved phase fail closed.
  func authorizeAttemptLaunch(attemptId: AttemptID, launchToken: String, now: Date = Date()) throws -> Attempt {
    let database = try openWritable()
    return try database.transaction { database in
      var attempt = try requiredAttempt(attemptId, in: database)
      try verifyLaunchToken(launchToken, attempt: attempt)
      guard attempt.launch?.phase == .reserved, attempt.state == .prepared else {
        throw WorkStoreError("attempt '\(attempt.id.rawValue)' is not awaiting launch authorization")
      }
      let consumedDigest = Self.launchTokenDigest("consumed:\(attempt.id.rawValue):\(attempt.sessionId)")
      attempt.launch?.phase = .authorized
      attempt.launch?.tokenDigest = consumedDigest
      attempt.launch?.authorizedAt = now
      attempt.launch?.updatedAt = now
      attempt.state = .running
      try replaceAttempt(attempt, in: database)
      let changed = try database.executeAndReturnChangedRowCount(
        "UPDATE work_leases SET token_digest = ?, updated_at = ? WHERE attempt_id = ? AND session_id = ? AND token_digest = ?",
        bindings: [
          .text(consumedDigest), .text(Self.timestamp(now)), .text(attempt.id.rawValue),
          .text(attempt.sessionId), .text(Self.launchTokenDigest(launchToken))
        ]
      )
      guard changed == 1 else { throw WorkStoreError("attempt launch lease is missing or replaced") }
      return attempt
    }
  }

  func markAttemptNodeStarted(attemptId: AttemptID, now: Date = Date()) throws -> Attempt {
    let database = try openWritable()
    return try database.transaction { database in
      var attempt = try requiredAttempt(attemptId, in: database)
      guard attempt.launch?.phase == .authorized, attempt.state == .running else {
        throw WorkStoreError("attempt '\(attempt.id.rawValue)' is not authorized for a node start")
      }
      attempt.launch?.phase = .nodeStarted
      attempt.launch?.nodeStartedAt = now
      attempt.launch?.updatedAt = now
      try replaceAttempt(attempt, in: database)
      let changed = try database.executeAndReturnChangedRowCount(
        "UPDATE work_leases SET updated_at = ? WHERE attempt_id = ? AND session_id = ? AND token_digest = ?",
        bindings: [
          .text(Self.timestamp(now)), .text(attempt.id.rawValue), .text(attempt.sessionId),
          .text(try Self.requiredLaunchDigest(attempt))
        ]
      )
      guard changed == 1 else { throw WorkStoreError("attempt launch lease is missing or replaced") }
      return attempt
    }
  }

  func enqueuePendingReservation(_ request: PendingAttemptReservation, now: Date = Date()) throws {
    let database = try openWritable()
    try database.transaction { database in
      let decision = try storedDecision(request.decisionId, in: database)
      guard let decision, decision.taskId == request.taskId,
            Self.requestedEntry(for: decision.kind) == request.entry else {
        throw WorkStoreError("pending reservation must reference its matching stored decision")
      }
      try database.execute(
        "INSERT INTO work_pending_reservations (request_id, task_id, decision_id, predecessor_attempt_id, entry_record, created_at) VALUES (?, ?, ?, ?, jsonb(?), ?)",
        bindings: [
          .text(request.id), .text(request.taskId.rawValue), .text(request.decisionId.rawValue),
          request.predecessorAttemptId.map { .text($0.rawValue) } ?? .null,
          .text(try encode(request.entry)), .text(Self.timestamp(now))
        ]
      )
    }
  }

  func requestAttemptCancellation(
    attemptId: AttemptID,
    decisionId: DecisionID,
    now: Date = Date()
  ) throws {
    let database = try openWritable()
    try database.transaction { database in
      let attempt = try requiredAttempt(attemptId, in: database)
      guard attempt.state != .reconciled else {
        throw WorkStoreError("attempt '\(attempt.id.rawValue)' is already reconciled")
      }
      try database.execute(
        "INSERT INTO work_cancellations (attempt_id, task_id, decision_id, requested_at) VALUES (?, ?, ?, ?)",
        bindings: [
          .text(attempt.id.rawValue), .text(attempt.taskId.rawValue),
          .text(decisionId.rawValue), .text(Self.timestamp(now))
        ]
      )
    }
  }

  @discardableResult
  func acknowledgeAttemptCancellation(
    attemptId: AttemptID,
    outcome: AttemptOutcome,
    now: Date = Date()
  ) throws -> Attempt {
    let database = try openWritable()
    return try database.transaction { database in
      let cancellation = try database.query(
        "SELECT acknowledged_at FROM work_cancellations WHERE attempt_id = ?",
        bindings: [.text(attemptId.rawValue)]
      ).first
      guard cancellation != nil, cancellation?["acknowledged_at"] == nil else {
        throw WorkStoreError("attempt '\(attemptId.rawValue)' has no pending cancellation")
      }
      var attempt = try requiredAttempt(attemptId, in: database)
      guard attempt.state == .prepared || attempt.state == .running || attempt.state == .terminal else {
        throw WorkStoreError("attempt '\(attempt.id.rawValue)' is not live")
      }
      attempt.state = .reconciled
      attempt.outcome = outcome
      attempt.launch?.phase = .terminal
      attempt.launch?.updatedAt = now
      try replaceAttempt(attempt, in: database)
      try database.execute(
        "UPDATE work_cancellations SET acknowledged_at = ?, terminal_status = ? WHERE attempt_id = ?",
        bindings: [.text(Self.timestamp(now)), .text(outcome.sessionStatus.rawValue), .text(attempt.id.rawValue)]
      )
      try database.execute("DELETE FROM work_leases WHERE attempt_id = ?", bindings: [.text(attempt.id.rawValue)])
      return attempt
    }
  }

  /// Fences only a reservation that was never authorized. Authorized launch
  /// loss is intentionally uncertain and cannot be recovered by this path.
  @discardableResult
  func recoverPreLaunchReservation(
    attemptId: AttemptID,
    launchToken: String,
    expectedTaskVersion: Int,
    now: Date = Date()
  ) throws -> WorkTask {
    let database = try openWritable()
    return try database.transaction { database in
      var attempt = try requiredAttempt(attemptId, in: database)
      try verifyLaunchToken(launchToken, attempt: attempt)
      guard attempt.launch?.phase == .reserved, attempt.state == .prepared else {
        throw WorkStoreError("attempt '\(attempt.id.rawValue)' cannot be recovered after launch authorization")
      }
      var task = try requiredTask(attempt.taskId, in: database)
      guard task.version == expectedTaskVersion else {
        throw WorkStoreError.versionConflict(taskId: task.id, expected: expectedTaskVersion)
      }
      attempt.launch?.phase = .fenced
      attempt.launch?.updatedAt = now
      attempt.state = .reconciled
      try replaceAttempt(attempt, in: database)
      try database.execute("DELETE FROM work_leases WHERE attempt_id = ?", bindings: [.text(attempt.id.rawValue)])
      task.state = .scheduled
      task.version += 1
      try updateTask(task, expectedVersion: expectedTaskVersion, in: database)
      return task
    }
  }

  @discardableResult
  func reconcileAttempt(
    attemptId: AttemptID,
    outcome: AttemptOutcome,
    now: Date = Date()
  ) throws -> Attempt {
    let database = try openWritable()
    return try database.transaction { database in
      var attempt = try requiredAttempt(attemptId, in: database)
      let cancellationPending = try database.query(
        "SELECT attempt_id FROM work_cancellations WHERE attempt_id = ? AND acknowledged_at IS NULL",
        bindings: [.text(attemptId.rawValue)]
      )
      guard cancellationPending.isEmpty else {
        throw WorkStoreError("attempt '\(attempt.id.rawValue)' awaits cancellation acknowledgment")
      }
      guard attempt.state == .running || attempt.state == .terminal else {
        throw WorkStoreError("attempt '\(attempt.id.rawValue)' is not live")
      }
      attempt.state = .reconciled
      attempt.outcome = outcome
      attempt.launch?.phase = .terminal
      attempt.launch?.updatedAt = now
      try replaceAttempt(attempt, in: database)
      try database.execute("DELETE FROM work_leases WHERE attempt_id = ?", bindings: [.text(attempt.id.rawValue)])
      var task = try requiredTask(attempt.taskId, in: database)
      if task.state == .running {
        let expected = task.version
        task.state = .verifying
        task.version += 1
        try updateTask(task, expectedVersion: expected, in: database)
      }
      return attempt
    }
  }
}

extension WorkStore {
  static let dispatchEligibleStates: Set<TaskState> = [.ready, .scheduled, .waiting]

  static func launchTokenDigest(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static func decisionKind(for entry: AttemptEntry) -> DecisionKind {
    switch entry {
    case .start: return .start
    case .resume, .director: return .resume
    case let .rerunFromStep(stepId): return .rerun(fromStepId: stepId)
    case let .recoverFromGate(gateId): return .recover(fromGateId: gateId)
    }
  }

  func nextGeneration(for taskId: TaskID, in database: SQLiteDatabase) throws -> Int {
    let row = try database.query(
      "SELECT COALESCE(MAX(generation), 0) AS generation FROM work_attempts WHERE task_id = ?",
      bindings: [.text(taskId.rawValue)]
    ).first
    return (Int(row?["generation"] ?? "0") ?? 0) + 1
  }

  func requiredTask(_ id: TaskID, in database: SQLiteDatabase) throws -> WorkTask {
    let rows = try database.query(
      "SELECT json(record) AS record FROM work_tasks WHERE task_id = ? LIMIT 1",
      bindings: [.text(id.rawValue)]
    )
    guard let json = rows.first?["record"] else {
      throw WorkStoreError("task '\(id.rawValue)' was not found")
    }
    return try decode(WorkTask.self, json: json)
  }

  func requiredAttempt(_ id: AttemptID, in database: SQLiteDatabase) throws -> Attempt {
    let rows = try database.query(
      "SELECT json(record) AS record FROM work_attempts WHERE attempt_id = ? LIMIT 1",
      bindings: [.text(id.rawValue)]
    )
    guard let json = rows.first?["record"] else {
      throw WorkStoreError("attempt '\(id.rawValue)' was not found")
    }
    return try decode(Attempt.self, json: json)
  }

  func decode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      return try decoder.decode(type, from: Data(json.utf8))
    } catch {
      throw WorkStoreError("work store contains an invalid \(type) record: \(error)")
    }
  }

  func insertAttempt(_ attempt: Attempt, in database: SQLiteDatabase, createdAt: Date) throws {
    try database.execute(
      "INSERT INTO work_attempts (attempt_id, record, created_at) VALUES (?, jsonb(?), ?)",
      bindings: [.text(attempt.id.rawValue), .text(try encode(attempt)), .text(Self.timestamp(createdAt))]
    )
  }

  func replaceAttempt(_ attempt: Attempt, in database: SQLiteDatabase) throws {
    try database.execute(
      "UPDATE work_attempts SET record = jsonb(?) WHERE attempt_id = ?",
      bindings: [.text(try encode(attempt)), .text(attempt.id.rawValue)]
    )
  }

  func insertDecision(_ decision: Decision, in database: SQLiteDatabase) throws {
    try database.execute(
      "INSERT INTO work_decisions (decision_id, record, created_at) VALUES (?, jsonb(?), ?)",
      bindings: [
        .text(decision.id.rawValue), .text(try encode(decision)), .text(Self.timestamp(decision.createdAt))
      ]
    )
  }

  func updateTask(_ task: WorkTask, expectedVersion: Int, in database: SQLiteDatabase) throws {
    let changed = try database.executeAndReturnChangedRowCount(
      "UPDATE work_tasks SET record = jsonb(?), updated_at = ? WHERE task_id = ? AND version = ?",
      bindings: [
        .text(try encode(task)), .text(Self.timestamp()), .text(task.id.rawValue), .int(Int64(expectedVersion))
      ]
    )
    guard changed == 1 else {
      throw WorkStoreError.versionConflict(taskId: task.id, expected: expectedVersion)
    }
  }

  func verifyLaunchToken(_ token: String, attempt: Attempt) throws {
    guard let metadata = attempt.launch,
          metadata.tokenDigest == Self.launchTokenDigest(token) else {
      throw WorkStoreError("attempt launch token is invalid")
    }
  }

  func validateDependencies(of task: WorkTask, in database: SQLiteDatabase) throws {
    for dependencyId in task.dependsOn {
      let dependency = try requiredTask(dependencyId, in: database)
      guard dependency.state == .succeeded else {
        throw WorkStoreError("task '\(task.id.rawValue)' dependency '\(dependencyId.rawValue)' is not satisfied")
      }
    }
  }

  func attemptCount(for taskId: TaskID, in database: SQLiteDatabase) throws -> Int {
    let value = try database.query(
      "SELECT COUNT(*) AS count FROM work_attempts WHERE task_id = ?",
      bindings: [.text(taskId.rawValue)]
    ).first?["count"] ?? "0"
    return Int(value) ?? 0
  }

  func consumePendingReservation(
    id: String,
    taskId: TaskID,
    decision: Decision,
    attemptId: AttemptID,
    now: Date,
    in database: SQLiteDatabase
  ) throws {
    let changed = try database.executeAndReturnChangedRowCount(
      "UPDATE work_pending_reservations SET consumed_attempt_id = ?, consumed_at = ? WHERE request_id = ? AND task_id = ? AND decision_id = ? AND consumed_attempt_id IS NULL",
      bindings: [
        .text(attemptId.rawValue), .text(Self.timestamp(now)), .text(id),
        .text(taskId.rawValue), .text(decision.id.rawValue)
      ]
    )
    guard changed == 1 else { throw WorkStoreError("pending reservation was missing, mismatched, or already consumed") }
  }

  func failIfRequested(_ point: AttemptReservationFailurePoint, request: AttemptReservationRequest) throws {
    guard request.failurePoint == point else { return }
    throw WorkStoreError("injected reservation failure after \(point)")
  }
}

private extension WorkStore {
  static func requiredLaunchDigest(_ attempt: Attempt) throws -> String {
    guard let digest = attempt.launch?.tokenDigest else {
      throw WorkStoreError("attempt launch metadata is missing")
    }
    return digest
  }
}
