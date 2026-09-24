import Foundation
import RielaCore
import RielaSQLite

public extension WorkStore {
  /// Reconstructs completion from the durable attempt, gates, findings, and
  /// verification ledger. Dispatch uses this before policy evaluation.
  func currentCompletionVerdict(taskId: TaskID, attemptId: AttemptID) throws -> CompletionVerdict {
    let database = try openWritable()
    return try database.transaction { database in
      let task = try requiredTask(taskId, in: database)
      let attempt = try requiredAttempt(attemptId, in: database)
      guard attempt.taskId == taskId, attempt.state == .reconciled else {
        throw WorkStoreError("completion requires a reconciled attempt for the task")
      }
      return try completionVerdict(for: task, attempt: attempt, in: database)
    }
  }

  /// Applies policy and human decisions through one optimistic, replay-safe
  /// transaction. The decision and its causal evidence commit with the task
  /// and attempt state, so no caller can bypass the shared transition table.
  func applyDecision(
    _ decision: Decision,
    expectedTaskVersion: Int,
    completion: CompletionVerdict,
    decisionEvidenceId: EvidenceID,
    pendingReservation: PendingAttemptReservation? = nil
  ) throws -> DecisionApplication {
    let database = try openWritable()
    return try database.transaction { database in
      if let existing = try storedDecision(decision.id, in: database) {
        guard Self.sameReplayIntent(existing, decision) else {
          throw WorkStoreError("decision '\(decision.id.rawValue)' conflicts with an already applied decision")
        }
        guard try storedDecisionEvidenceId(for: decision.id, in: database) == decisionEvidenceId else {
          throw WorkStoreError("decision '\(decision.id.rawValue)' conflicts with its recorded causal evidence")
        }
        if let pendingReservation {
          try validatePendingReservation(pendingReservation, for: existing)
        }
        return try requiredDecisionApplication(decision.id, in: database)
      }

      let task = try requiredTask(decision.taskId, in: database)
      guard task.version == expectedTaskVersion else {
        throw WorkStoreError.versionConflict(taskId: task.id, expected: expectedTaskVersion)
      }
      if Self.requestedEntry(for: decision.kind) != nil {
        try requireExecutionAdmissionBudget(for: task, in: database)
      }
      if Self.requiresPendingReservation(for: decision.kind), pendingReservation == nil {
        throw WorkStoreError("rerun and recover decisions require a pending reservation")
      }
      let attempt = try decision.attemptId.map { try requiredAttempt($0, in: database) }
      if let attempt, attempt.taskId != task.id {
        throw WorkStoreError("decision attempt does not match the target task")
      }
      if case let .agent(sessionId) = decision.producer {
        guard let attempt, attempt.entry != .director, attempt.state == .reconciled,
              let latest = try latestAttempt(for: task, in: database),
              latest.entry == .director, latest.judgedAttemptId == attempt.id,
              latest.taskId == task.id, latest.sessionId == sessionId,
              latest.state == .reconciled,
              latest.outcome?.sessionStatus == .completed,
              latest.generation == attempt.generation + 1 else {
          throw WorkStoreError("agent decision requires the exact successful linked director child")
        }
        if Self.requiresPendingReservation(for: decision.kind) {
          try requireAgentWallClockBudget(for: task, in: database)
        }
      } else if case .accept = decision.kind {
        try requireLatestAttempt(attempt, for: task, action: "accept", in: database)
      } else if Self.requiresLiveCancellation(for: decision.kind) {
        try requireLatestAttempt(attempt, for: task, action: decision.kind.kindName, in: database)
      }
      try validateCausality(of: decision, attempt: attempt, in: database)
      if Self.requiresLiveCancellation(for: decision.kind), let attempt,
         attempt.state == .prepared || attempt.state == .running {
        try rejectTerminalCancellation(for: attempt, in: database)
      }
      let effectiveCompletion: CompletionVerdict
      if case .accept = decision.kind {
        effectiveCompletion = try completionVerdict(for: task, attempt: attempt, in: database)
      } else {
        effectiveCompletion = completion
      }
      var application: DecisionApplication
      let requestsLiveCancellation: Bool
      if Self.requiresLiveCancellation(for: decision.kind), let attempt,
         attempt.state == .prepared || attempt.state == .running {
        application = DecisionApplication(
          task: task,
          attempt: attempt,
          requestedEntry: Self.requestedEntry(for: decision.kind)
        )
        requestsLiveCancellation = true
      } else {
        do {
          application = try DecisionApplier.apply(
            decision, to: task, attempt: attempt,
            completion: effectiveCompletion
          )
        } catch {
          throw WorkStoreError("decision '\(decision.id.rawValue)' was rejected: \(error)")
        }
        requestsLiveCancellation = false
      }
      application.task.version = task.version + 1
      try updateTask(application.task, expectedVersion: task.version, in: database)
      if let updatedAttempt = application.attempt {
        try replaceAttempt(updatedAttempt, in: database)
        if updatedAttempt.state == .reconciled {
          try database.execute(
            "DELETE FROM work_leases WHERE attempt_id = ?",
            bindings: [.text(updatedAttempt.id.rawValue)]
          )
        }
      }
      try insertDecision(decision, in: database)
      if let pendingReservation {
        try validatePendingReservation(pendingReservation, for: decision)
        try enqueuePendingReservation(pendingReservation, now: decision.createdAt, in: database)
      }
      try insertDecisionApplication(application, decisionId: decision.id, in: database)
      if requestsLiveCancellation, let attempt {
        try database.execute(
          "INSERT INTO work_cancellations (attempt_id, task_id, decision_id, requested_at) VALUES (?, ?, ?, ?)",
          bindings: [
            .text(attempt.id.rawValue), .text(task.id.rawValue),
            .text(decision.id.rawValue), .text(Self.timestamp(decision.createdAt))
          ]
        )
      }
      let evidence = Evidence(
        id: decisionEvidenceId,
        taskId: decision.taskId,
        attemptId: decision.attemptId,
        kind: .decision,
        producedBy: Self.evidenceProducer(for: decision.producer),
        causedBy: decision.causedBy,
        payloadRef: .inline([
          "decisionId": .string(decision.id.rawValue),
          "kind": .string(decision.kind.kindName),
          "reason": .string(decision.reason)
        ]),
        createdAt: decision.createdAt
      )
      try insertEvidence(evidence, in: database)
      return application
    }
  }
}

extension WorkStore {
  func requiredDecisionApplication(_ decisionId: DecisionID, in database: SQLiteDatabase) throws -> DecisionApplication {
    guard let record = try database.query(
      "SELECT json(record) AS record FROM work_decision_applications WHERE decision_id = ? LIMIT 1",
      bindings: [.text(decisionId.rawValue)]
    ).first?["record"] else {
      throw WorkStoreError("decision '\(decisionId.rawValue)' has no durable application")
    }
    return try decode(DecisionApplication.self, json: record)
  }

  func storedDecisionEvidenceId(for decisionId: DecisionID, in database: SQLiteDatabase) throws -> EvidenceID? {
    let rows = try database.query(
      "SELECT json(record) AS record FROM work_evidence WHERE kind = ?",
      bindings: [.text(EvidenceKind.decision.rawValue)]
    )
    for row in rows {
      guard let record = row["record"] else { continue }
      let evidence = try decode(Evidence.self, json: record)
      if evidence.payloadRef.inlinePayload?["decisionId"] == .string(decisionId.rawValue) {
        return evidence.id
      }
    }
    return nil
  }

  func insertDecisionApplication(_ application: DecisionApplication, decisionId: DecisionID, in database: SQLiteDatabase) throws {
    try database.execute(
      "INSERT INTO work_decision_applications (decision_id, record) VALUES (?, jsonb(?))",
      bindings: [.text(decisionId.rawValue), .text(try encode(application))]
    )
  }

  func storedDecision(_ id: DecisionID, in database: SQLiteDatabase) throws -> Decision? {
    let row = try database.query(
      "SELECT json(record) AS record FROM work_decisions WHERE decision_id = ? LIMIT 1",
      bindings: [.text(id.rawValue)]
    ).first
    guard let json = row?["record"] else { return nil }
    return try decode(Decision.self, json: json)
  }

  func insertEvidence(_ evidence: Evidence, in database: SQLiteDatabase) throws {
    try database.execute(
      "INSERT INTO work_evidence (evidence_id, record, created_at) VALUES (?, jsonb(?), ?)",
      bindings: [
        .text(evidence.id.rawValue), .text(try encode(evidence)), .text(Self.timestamp(evidence.createdAt))
      ]
    )
  }

  func validatePendingReservation(_ request: PendingAttemptReservation, for decision: Decision) throws {
    guard request.taskId == decision.taskId,
          request.decisionId == decision.id,
          request.predecessorAttemptId == decision.attemptId,
          Self.requestedEntry(for: decision.kind) == request.entry else {
      throw WorkStoreError("pending reservation does not match its decision")
    }
  }

  func validateCausality(of decision: Decision, attempt: Attempt?, in database: SQLiteDatabase) throws {
    if Self.requiresCausalEvidence(decision.kind), decision.causedBy.isEmpty {
      throw WorkStoreError("\(decision.kind.kindName) decision requires causal evidence")
    }
    var causalEvidence: [EvidenceID: Evidence] = [:]
    for evidenceId in decision.causedBy {
      guard let record = try database.query(
        "SELECT json(record) AS record FROM work_evidence WHERE evidence_id = ? LIMIT 1",
        bindings: [.text(evidenceId.rawValue)]
      ).first?["record"] else {
        throw WorkStoreError("decision causal evidence '\(evidenceId.rawValue)' is missing")
      }
      let evidence = try decode(Evidence.self, json: record)
      guard evidence.taskId == decision.taskId,
            attempt == nil || evidence.attemptId == attempt?.id else {
        throw WorkStoreError("decision causal evidence '\(evidenceId.rawValue)' is outside the task attempt scope")
      }
      causalEvidence[evidenceId] = evidence
    }
    if case let .stop(violation) = decision.kind,
       causalEvidence[violation.evidenceId]?.kind != .guardViolation {
      throw WorkStoreError("stop decision requires causal guard-violation evidence")
    }
  }

  static func requiresCausalEvidence(_ kind: DecisionKind) -> Bool {
    switch kind {
    case .accept, .cancel, .stop, .reject, .rerun, .recover: true
    default: false
    }
  }

  static func sameReplayIntent(_ existing: Decision, _ replay: Decision) -> Bool {
    existing.id == replay.id &&
      existing.taskId == replay.taskId &&
      existing.attemptId == replay.attemptId &&
      existing.producer == replay.producer &&
      existing.kind == replay.kind &&
      existing.reason == replay.reason &&
      existing.causedBy == replay.causedBy
  }

  func requireLatestAttempt(
    _ attempt: Attempt?,
    for task: WorkTask,
    action: String,
    in database: SQLiteDatabase
  ) throws {
    guard let latestAttempt = try latestAttempt(for: task, in: database) else {
      return
    }
    guard attempt?.id == latestAttempt.id else {
      throw WorkStoreError("\(action) decision must target the latest attempt for task '\(task.id.rawValue)'")
    }
  }

  func latestAttempt(for task: WorkTask, in database: SQLiteDatabase) throws -> Attempt? {
    guard let latest = try database.query(
      "SELECT json(record) AS record FROM work_attempts WHERE task_id = ? ORDER BY generation DESC, attempt_id DESC LIMIT 1",
      bindings: [.text(task.id.rawValue)]
    ).first?["record"] else {
      return nil
    }
    return try decode(Attempt.self, json: latest)
  }

  func completionVerdict(for task: WorkTask, attempt: Attempt?, in database: SQLiteDatabase) throws -> CompletionVerdict {
    guard let attempt, let outcome = attempt.outcome else {
      return .unmet([.acceptanceAbsent])
    }
    let findings = try decodeDecisionRows(Finding.self, from: database.query(
      "SELECT json(record) AS record FROM work_findings WHERE task_id = ?",
      bindings: [.text(task.id.rawValue)]
    ))
    let evidence = try decodeDecisionRows(Evidence.self, from: database.query(
      "SELECT json(record) AS record FROM work_evidence WHERE task_id = ? AND attempt_id = ?",
      bindings: [.text(task.id.rawValue), .text(attempt.id.rawValue)]
    ))
    let verification = evidence.filter { $0.kind == .verification }.compactMap { record -> VerificationOutcome? in
      guard let payload = record.payloadRef.inlinePayload,
            case let .string(name)? = payload["id"] else { return nil }
      let passed: Bool
      if case let .string(outcome)? = payload["outcome"] { passed = outcome == "passed" } else { passed = false }
      return VerificationOutcome(name: name, passed: passed, evidenceId: record.id)
    }
    let acceptance: GateAcceptance?
    do {
      let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: rootDirectory).load(
        sessionId: attempt.sessionId, in: database
      )
      acceptance = GateAcceptanceParser.acceptance(
        requiredGates: task.completion.gates,
        session: snapshot.session
      )
    } catch let error as WorkflowRuntimePersistenceStoreError {
      guard case .notFound = error else { throw error }
      acceptance = nil
    }
    return CompletionEvaluator.evaluate(
      contract: task.completion, attemptOutcome: outcome,
      ledger: CompletionLedger(verification: verification, findings: findings, acceptance: acceptance)
    )
  }

  func decodeDecisionRows<T: Decodable>(_ type: T.Type, from rows: [SQLiteRow]) throws -> [T] {
    try rows.map { row in
      guard let json = row["record"] else {
        throw WorkStoreError("stored record is missing")
      }
      return try decode(type, json: json)
    }
  }

  static func requestedEntry(for kind: DecisionKind) -> AttemptEntry? {
    switch kind {
    case .start: return .start
    case .resume: return .resume
    case let .rerun(stepId): return .rerunFromStep(stepId)
    case let .recover(gateId): return .recoverFromGate(gateId)
    default: return nil
    }
  }

  static func requiresPendingReservation(for kind: DecisionKind) -> Bool {
    switch kind {
    case .rerun, .recover: true
    default: false
    }
  }

  static func requiresLiveCancellation(for kind: DecisionKind) -> Bool {
    switch kind {
    case .cancel, .stop, .reject, .rerun, .recover: true
    default: false
    }
  }

  static func evidenceProducer(for producer: DecisionProducer) -> EvidenceProducer {
    switch producer {
    case .policy: return .runtime
    case let .agent(sessionId): return .director(sessionId: sessionId)
    case let .human(principal): return .human(principal: principal)
    }
  }
}
