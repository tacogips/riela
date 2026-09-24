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

public struct AttemptCancellationRecord: Equatable, Sendable {
  public let taskId: TaskID
  public let attemptId: AttemptID
  public let sessionId: String
  public let decisionId: DecisionID
  public let acknowledged: Bool
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

public enum AttemptReservationResult: Equatable, Sendable {
  case reserved(AttemptReservation)
  case wait(WaitReason)

  public var reservation: AttemptReservation? {
    guard case let .reserved(value) = self else { return nil }
    return value
  }

  public var task: WorkTask {
    guard case let .reserved(value) = self else { preconditionFailure("wait has no advanced task") }
    return value.task
  }
  public var attempt: Attempt {
    guard case let .reserved(value) = self else { preconditionFailure("wait has no attempt") }
    return value.attempt
  }
  public var decision: Decision {
    guard case let .reserved(value) = self else { preconditionFailure("wait has no decision") }
    return value.decision
  }
  public var launchToken: String {
    guard case let .reserved(value) = self else { preconditionFailure("wait has no token") }
    return value.launchToken
  }
}

public extension WorkStore {
  /// Atomically commits one task attempt, its launch lease and decision, and
  /// the canonical `.created` workflow snapshot on the shared connection.
  func reserveAttempt(_ request: AttemptReservationRequest) throws -> AttemptReservationResult {
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
      guard try dependenciesAreSatisfied(of: task, in: database) else { return .wait(.dependency) }
      try requireExecutionAdmissionBudget(for: task, in: database)
      let pendingRequest = try database.query(
        "SELECT request_id, decision_id, predecessor_attempt_id, json(entry_record) AS entry_record FROM work_pending_reservations WHERE task_id = ? AND consumed_attempt_id IS NULL LIMIT 1",
        bindings: [.text(task.id.rawValue)]
      ).first
      if let pendingRequest {
        guard request.pendingRequestId == pendingRequest["request_id"],
              request.decisionId.rawValue == pendingRequest["decision_id"],
              let entryRecord = pendingRequest["entry_record"],
              try decode(AttemptEntry.self, json: entryRecord) == request.entry else {
          throw WorkStoreError("pending reservation must be consumed by its matching request")
        }
      }

      let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: rootDirectory)
      try persistence.prepareSchema(in: database)
      let existingSession = try database.query(
        "SELECT workflow_execution_id FROM workflow_runtime_snapshots WHERE workflow_execution_id = ? LIMIT 1",
        bindings: [.text(request.sessionId)]
      )
      guard existingSession.isEmpty else {
        throw WorkStoreError("workflow session '\(request.sessionId)' already exists")
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
      if let pendingRequest {
        guard decision.attemptId?.rawValue == pendingRequest["predecessor_attempt_id"] else {
          throw WorkStoreError("pending reservation predecessor does not match its decision")
        }
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
      try persistence.save(WorkflowRuntimePersistenceSnapshot(session: session), in: database)
      try failIfRequested(.session, request: request)
      return .reserved(AttemptReservation(task: updatedTask, attempt: attempt, decision: decision, launchToken: token))
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
      try rejectPendingCancellation(for: attempt.id, in: database)
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
      try rejectPendingCancellation(for: attempt.id, in: database)
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
      try enqueuePendingReservation(request, now: now, in: database)
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
      try validateCancellationDecision(
        decisionId,
        taskId: attempt.taskId,
        attemptId: attempt.id,
        in: database
      )
      try rejectTerminalCancellation(for: attempt, in: database)
      try database.execute(
        "INSERT INTO work_cancellations (attempt_id, task_id, decision_id, requested_at) VALUES (?, ?, ?, ?)",
        bindings: [
          .text(attempt.id.rawValue), .text(attempt.taskId.rawValue),
          .text(decisionId.rawValue), .text(Self.timestamp(now))
        ]
      )
    }
  }

  /// Reads the durable request for one exact reserved execution. Callers must
  /// retain the fence when this read fails or a requested cancellation lacks
  /// worker-stop and terminal-session proof.
  func attemptCancellation(
    taskId: TaskID, attemptId: AttemptID, sessionId: String
  ) throws -> AttemptCancellationRecord? {
    let database = try openWritable()
    return try database.transaction { database in
      let attempt = try requiredAttempt(attemptId, in: database)
      guard attempt.taskId == taskId, attempt.sessionId == sessionId else {
        throw WorkStoreError("cancellation read does not match the reserved task session")
      }
      guard let row = try database.query(
        "SELECT decision_id, acknowledged_at FROM work_cancellations WHERE task_id = ? AND attempt_id = ? LIMIT 1",
        bindings: [.text(taskId.rawValue), .text(attemptId.rawValue)]
      ).first else { return nil }
      guard let decisionId = row["decision_id"] else {
        throw WorkStoreError("cancellation request has no decision")
      }
      return AttemptCancellationRecord(
        taskId: taskId, attemptId: attemptId, sessionId: sessionId,
        decisionId: DecisionID(decisionId), acknowledged: row["acknowledged_at"] != nil
      )
    }
  }

  /// Persists the reserved session's cancellation only while authorization is
  /// still impossible. A nil result means the request or prelaunch phase is
  /// absent; a caller must then await ordinary owned execution-stop proof.
  func persistPreLaunchCancellation(
    taskId: TaskID, attemptId: AttemptID, sessionId: String, now: Date = Date()
  ) throws -> WorkflowRuntimePersistenceSnapshot? {
    let database = try openWritable()
    return try database.transaction { database in
      let attempt = try requiredAttempt(attemptId, in: database)
      guard attempt.taskId == taskId, attempt.sessionId == sessionId else {
        throw WorkStoreError("prelaunch cancellation does not match the reserved task session")
      }
      guard let row = try database.query(
        "SELECT decision_id FROM work_cancellations WHERE task_id = ? AND attempt_id = ? AND acknowledged_at IS NULL",
        bindings: [.text(taskId.rawValue), .text(attemptId.rawValue)]
      ).first else { return nil }
      guard let decisionId = row["decision_id"] else {
        throw WorkStoreError("prelaunch cancellation has no decision")
      }
      try validateCancellationDecision(DecisionID(decisionId), taskId: taskId, attemptId: attemptId, in: database)
      guard attempt.launch?.phase == .reserved, attempt.state == .prepared else { return nil }
      let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: rootDirectory)
      var snapshot = try persistence.load(sessionId: sessionId, in: database)
      if snapshot.session.status == .failed && snapshot.session.failureKind == .cancelled
        && snapshot.session.executions.isEmpty { return snapshot }
      guard snapshot.session.status == .created, snapshot.session.executions.isEmpty else {
        throw WorkStoreError("prelaunch cancellation cannot replace an active or terminal session")
      }
      snapshot.session.status = .failed
      snapshot.session.failureKind = .cancelled
      snapshot.session.failureReason = "workflow run cancelled before launch"
      snapshot.session.failedAt = now
      snapshot.session.updatedAt = now
      try persistence.save(snapshot, in: database)
      return snapshot
    }
  }

  /// Called only after the task owner has joined its execution. A pending
  /// request may have beaten ordinary terminal persistence by one transaction.
  func persistJoinedCancellation(
    taskId: TaskID, attemptId: AttemptID, sessionId: String,
    selectedHostStopProven: Bool, now: Date = Date()
  ) throws -> WorkflowRuntimePersistenceSnapshot? {
    let database = try openWritable()
    return try database.transaction { database in
      let attempt = try requiredAttempt(attemptId, in: database)
      guard attempt.taskId == taskId, attempt.sessionId == sessionId else {
        throw WorkStoreError("joined cancellation does not match the reserved task session")
      }
      guard let cancellation = try database.query(
        "SELECT decision_id FROM work_cancellations WHERE task_id = ? AND attempt_id = ? AND acknowledged_at IS NULL",
        bindings: [.text(taskId.rawValue), .text(attemptId.rawValue)]
      ).first else { return nil }
      guard selectedHostStopProven else {
        throw WorkStoreError(
          "joined cancellation requires proven selected-host stop",
          isSelectedHostStopProofRequired: true
        )
      }
      guard let decisionId = cancellation["decision_id"] else {
        throw WorkStoreError("joined cancellation has no decision")
      }
      try validateCancellationDecision(DecisionID(decisionId), taskId: taskId, attemptId: attemptId, in: database)
      let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: rootDirectory)
      var snapshot = try persistence.load(sessionId: sessionId, in: database)
      if snapshot.session.status == .failed && snapshot.session.failureKind == .cancelled {
        return snapshot
      }
      guard snapshot.session.status == .created || snapshot.session.status == .running else {
        throw WorkStoreError("joined cancellation cannot replace an ordinary terminal session")
      }
      snapshot.session.status = .failed
      snapshot.session.failureKind = .cancelled
      snapshot.session.failureReason = "workflow run cancelled after owned execution stopped"
      snapshot.session.failedAt = now
      snapshot.session.updatedAt = now
      try persistence.save(snapshot, in: database)
      return snapshot
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
        "SELECT decision_id, acknowledged_at FROM work_cancellations WHERE attempt_id = ?",
        bindings: [.text(attemptId.rawValue)]
      ).first
      guard cancellation != nil, cancellation?["acknowledged_at"] == nil else {
        throw WorkStoreError("attempt '\(attemptId.rawValue)' has no pending cancellation")
      }
      var attempt = try requiredAttempt(attemptId, in: database)
      guard attempt.state == .prepared || attempt.state == .running || attempt.state == .terminal else {
        throw WorkStoreError("attempt '\(attempt.id.rawValue)' is not live")
      }
      guard let decisionId = cancellation?["decision_id"] else {
        throw WorkStoreError("attempt '\(attempt.id.rawValue)' cancellation has no decision")
      }
      try validateCancellationDecision(
        DecisionID(decisionId),
        taskId: attempt.taskId,
        attemptId: attempt.id,
        in: database
      )
      let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: rootDirectory).load(
        sessionId: attempt.sessionId,
        in: database
      )
      let canonicalOutcome = WorkEvidenceProjector.outcome(from: snapshot)
      guard canonicalOutcome.sessionStatus == .failed,
            canonicalOutcome.failureKind == .cancelled,
            canonicalOutcome == outcome else {
        throw WorkStoreError("attempt '\(attempt.id.rawValue)' has no matching cancelled workflow snapshot")
      }
      attempt.state = .reconciled
      attempt.outcome = canonicalOutcome
      attempt.launch?.phase = .terminal
      attempt.launch?.updatedAt = now
      try replaceAttempt(attempt, in: database)
      try database.execute(
        "UPDATE work_cancellations SET acknowledged_at = ?, terminal_status = ? WHERE attempt_id = ?",
        bindings: [.text(Self.timestamp(now)), .text(outcome.sessionStatus.rawValue), .text(attempt.id.rawValue)]
      )
      try database.execute("DELETE FROM work_leases WHERE attempt_id = ?", bindings: [.text(attempt.id.rawValue)])
      var task = try requiredTask(attempt.taskId, in: database)
      if !task.state.isTerminal {
        let expectedVersion = task.version
        guard let decision = try storedDecision(DecisionID(decisionId), in: database) else {
          throw WorkStoreError("cancellation decision is missing")
        }
        switch decision.kind {
        case .cancel: task.state = .cancelled
        case .reject, .stop: task.state = .failed
        case .rerun, .recover: task.state = .scheduled
        default: throw WorkStoreError("cancellation decision is not terminal or replacement")
        }
        task.version += 1
        try updateTask(task, expectedVersion: expectedVersion, in: database)
      }
      return attempt
    }
  }

  private func validateCancellationDecision(
    _ decisionId: DecisionID,
    taskId: TaskID,
    attemptId: AttemptID,
    in database: SQLiteDatabase
  ) throws {
    guard let decision = try storedDecision(decisionId, in: database),
          decision.taskId == taskId,
          decision.attemptId == attemptId,
          Self.requiresCancellationAcknowledgment(decision.kind) else {
      throw WorkStoreError("cancellation decision '\(decisionId.rawValue)' does not match attempt '\(attemptId.rawValue)'")
    }
  }

  static func requiresCancellationAcknowledgment(_ kind: DecisionKind) -> Bool {
    switch kind {
    case .cancel, .stop, .reject, .rerun, .recover: true
    default: false
    }
  }

  private func rejectPendingCancellation(for attemptId: AttemptID, in database: SQLiteDatabase) throws {
    let cancellation = try database.query(
      "SELECT 1 FROM work_cancellations WHERE attempt_id = ? AND acknowledged_at IS NULL LIMIT 1",
      bindings: [.text(attemptId.rawValue)]
    ).first
    guard cancellation == nil else {
      throw WorkStoreError("attempt '\(attemptId.rawValue)' has a pending cancellation")
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
      try rejectPendingCancellation(for: attempt.id, in: database)
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
      let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: rootDirectory).load(
        sessionId: attempt.sessionId,
        in: database
      )
      let canonicalOutcome = WorkEvidenceProjector.outcome(from: snapshot)
      guard canonicalOutcome.sessionStatus == .completed || canonicalOutcome.sessionStatus == .failed,
            canonicalOutcome == outcome else {
        throw WorkStoreError("attempt '\(attempt.id.rawValue)' has no matching terminal workflow snapshot")
      }
      attempt.state = .reconciled
      attempt.outcome = canonicalOutcome
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

  func dependenciesAreSatisfied(of task: WorkTask, in database: SQLiteDatabase) throws -> Bool {
    for dependencyId in task.dependsOn {
      let dependency = try requiredTask(dependencyId, in: database)
      guard dependency.state == .succeeded else {
        return false
      }
    }
    return true
  }

  func attemptCount(for taskId: TaskID, in database: SQLiteDatabase) throws -> Int {
    let value = try database.query(
      "SELECT COUNT(*) AS count FROM work_attempts WHERE task_id = ?",
      bindings: [.text(taskId.rawValue)]
    ).first?["count"] ?? "0"
    return Int(value) ?? 0
  }

  /// Admission is the common fence for direct reservations and the shared
  /// decision applier. Costs are replay-deduplicated by their attempt-scoped
  /// runner execution id; wall-clock budget snapshots are durable guard evidence.
  func requireExecutionAdmissionBudget(for task: WorkTask, in database: SQLiteDatabase) throws {
    guard let budget = task.guardPolicy.budget else { return }
    if let maximum = budget.maxAttempts,
       try attemptCount(for: task.id, in: database) >= maximum {
      throw WorkStoreError("task '\(task.id.rawValue)' exhausted its attempt budget")
    }

    let attempts = try decodeDecisionRows(Attempt.self, from: database.query(
      "SELECT json(record) AS record FROM work_attempts WHERE task_id = ?",
      bindings: [.text(task.id.rawValue)]
    ))
    var costsByExecution: [String: LoopCostEvidence] = [:]
    for attempt in attempts {
      for cost in attempt.outcome?.costs ?? [] {
        costsByExecution["\(attempt.id.rawValue)\u{0}\(cost.stepExecutionId)"] = cost
      }
    }
    let tokens = costsByExecution.values.compactMap(\.totalTokens).reduce(0, +)
    let proposals = try database.query(
      "SELECT COUNT(*) AS count FROM work_decisions WHERE task_id = ? AND kind = 'proposeWorkflowChange'",
      bindings: [.text(task.id.rawValue)]
    ).first?["count"].flatMap(Int.init) ?? 0
    let exhaustedEvidence = try exhaustedBudgetEvidenceDimensions(for: task.id, budget: budget, in: database)

    try requireExecutionBudget(
      .tokens, used: tokens, limit: budget.maxTotalTokens,
      hasExhaustedEvidence: exhaustedEvidence.contains(.tokens), task: task
    )
    try requireExecutionBudget(
      .wallClock, used: 0, limit: budget.maxWallClockMs,
      hasExhaustedEvidence: exhaustedEvidence.contains(.wallClock), task: task
    )
    try requireExecutionBudget(
      .proposals, used: proposals, limit: budget.maxProposals,
      hasExhaustedEvidence: exhaustedEvidence.contains(.proposals), task: task
    )
  }

  func exhaustedBudgetEvidenceDimensions(
    for taskId: TaskID,
    budget: BudgetGuard,
    in database: SQLiteDatabase
  ) throws -> [BudgetDimension] {
    let evidence = try decodeDecisionRows(Evidence.self, from: database.query(
      "SELECT json(record) AS record FROM work_evidence WHERE task_id = ? AND kind = ?",
      bindings: [.text(taskId.rawValue), .text(EvidenceKind.guardViolation.rawValue)]
    ))
    return evidence.compactMap { record in
      guard let payload = record.payloadRef.inlinePayload,
            payload["kind"] == .string("budget"),
            case let .string(value)? = payload["dimension"],
            let dimension = BudgetDimension(rawValue: value),
            case let .integer(used)? = payload["used"],
            case let .integer(limit)? = payload["limit"],
            used >= limit,
            let currentLimit = budgetLimit(for: dimension, budget: budget),
            used >= currentLimit else {
        return nil
      }
      return dimension
    }
  }

  func budgetLimit(for dimension: BudgetDimension, budget: BudgetGuard) -> Int? {
    switch dimension {
    case .attempts: budget.maxAttempts
    case .tokens: budget.maxTotalTokens
    case .wallClock: budget.maxWallClockMs
    case .proposals: budget.maxProposals
    }
  }

  func requireExecutionBudget(
    _ dimension: BudgetDimension,
    used: Int,
    limit: Int?,
    hasExhaustedEvidence: Bool,
    task: WorkTask
  ) throws {
    guard let limit, used >= limit || hasExhaustedEvidence else { return }
    throw WorkStoreError("task '\(task.id.rawValue)' exhausted its \(dimension.rawValue) budget")
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

  /// Adds a durable retry request to the caller's existing write transaction.
  /// Decision application uses this seam so its decision and request cannot
  /// commit separately.
  func enqueuePendingReservation(
    _ request: PendingAttemptReservation,
    now: Date,
    in database: SQLiteDatabase
  ) throws {
    let decision = try storedDecision(request.decisionId, in: database)
    guard let decision, decision.taskId == request.taskId,
          decision.attemptId == request.predecessorAttemptId,
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

  func rejectTerminalCancellation(for attempt: Attempt, in database: SQLiteDatabase) throws {
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: rootDirectory)
      .load(sessionId: attempt.sessionId, in: database)
    guard snapshot.session.sessionId == attempt.sessionId else {
      throw WorkStoreError("cancellation session does not match the reserved attempt")
    }
    if snapshot.session.status == .completed || snapshot.session.status == .failed {
      throw WorkStoreError.alreadyTerminal(sessionId: attempt.sessionId)
    }
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
