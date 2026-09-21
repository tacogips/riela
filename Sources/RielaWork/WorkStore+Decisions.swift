import Foundation
import RielaSQLite

public extension WorkStore {
  /// Applies policy and human decisions through one optimistic, replay-safe
  /// transaction. The decision and its causal evidence commit with the task
  /// and attempt state, so no caller can bypass the shared transition table.
  func applyDecision(
    _ decision: Decision,
    expectedTaskVersion: Int,
    completion: CompletionVerdict,
    decisionEvidenceId: EvidenceID
  ) throws -> DecisionApplication {
    let database = try openWritable()
    return try database.transaction { database in
      if let existing = try storedDecision(decision.id, in: database) {
        guard existing == decision else {
          throw WorkStoreError("decision '\(decision.id.rawValue)' conflicts with an already applied decision")
        }
        let currentTask = try requiredTask(decision.taskId, in: database)
        let currentAttempt = try decision.attemptId.map { try requiredAttempt($0, in: database) }
        return DecisionApplication(
          task: currentTask,
          attempt: currentAttempt,
          requestedEntry: Self.requestedEntry(for: decision.kind)
        )
      }

      let task = try requiredTask(decision.taskId, in: database)
      guard task.version == expectedTaskVersion else {
        throw WorkStoreError.versionConflict(taskId: task.id, expected: expectedTaskVersion)
      }
      let attempt = try decision.attemptId.map { try requiredAttempt($0, in: database) }
      var application: DecisionApplication
      let requestsLiveCancellation: Bool
      if case .cancel = decision.kind, let attempt,
         attempt.state == .prepared || attempt.state == .running || attempt.state == .terminal {
        application = DecisionApplication(task: task, attempt: attempt)
        requestsLiveCancellation = true
      } else {
        do {
          application = try DecisionApplier.apply(decision, to: task, attempt: attempt, completion: completion)
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

  static func requestedEntry(for kind: DecisionKind) -> AttemptEntry? {
    switch kind {
    case .start: return .start
    case .resume: return .resume
    case let .rerun(stepId): return .rerunFromStep(stepId)
    case let .recover(gateId): return .recoverFromGate(gateId)
    default: return nil
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
