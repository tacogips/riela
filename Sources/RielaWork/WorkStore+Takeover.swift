import Foundation
import RielaCore
import RielaSQLite

public struct OrphanFenceResult: Equatable, Sendable {
  public var predecessor: Attempt
  public var evidence: OwnerLossEvidence
  public var task: WorkTask
  public var fenceEvidenceId: EvidenceID

  public init(predecessor: Attempt, evidence: OwnerLossEvidence, task: WorkTask, fenceEvidenceId: EvidenceID) {
    self.predecessor = predecessor
    self.evidence = evidence
    self.task = task
    self.fenceEvidenceId = fenceEvidenceId
  }
}

public extension WorkStore {
  func fenceOrphan(taskId: TaskID, now: Date, producer: DecisionProducer) throws -> OrphanFenceResult {
    let database = try openWritable()
    return try database.transaction { database in
      var task = try requiredTask(taskId, in: database)
      guard let leaseRow = try database.query(
        "SELECT attempt_id, task_id, session_id, token_digest, fence, heartbeat_at, expires_at, host_id FROM work_leases WHERE task_id = ? LIMIT 1",
        bindings: [.text(taskId.rawValue)]
      ).first else {
        throw WorkStoreError("task '\(taskId.rawValue)' has no lease")
      }
      let lease = try decodeLease(leaseRow)
      guard lease.expiresAt < now else {
        throw WorkStoreError("lease for task '\(taskId.rawValue)' has not expired (expires \(Self.timestamp(lease.expiresAt)))")
      }
      var predecessor = try requiredAttempt(lease.attemptId, in: database)
      guard predecessor.taskId == taskId,
            [.prepared, .running, .terminal].contains(predecessor.state) else {
        throw WorkStoreError("expired lease does not belong to a live attempt")
      }
      let nextFence = max(task.fence, lease.fence) + 1
      let evidence = OwnerLossEvidence(
        attemptId: predecessor.id, lastHeartbeatAt: lease.heartbeatAt,
        expiredAt: lease.expiresAt, fence: nextFence, forcedBy: producer
      )
      predecessor.state = .reconciled
      predecessor.outcome = AttemptOutcome(sessionStatus: .failed, failureKind: .leaseLost)
      predecessor.supersededByFence = nextFence
      predecessor.launch?.phase = .fenced
      predecessor.launch?.updatedAt = now
      try replaceAttempt(predecessor, in: database)
      try database.execute("DELETE FROM work_leases WHERE attempt_id = ?", bindings: [.text(predecessor.id.rawValue)])
      task.fence = nextFence
      task.version += 1
      try updateTask(task, expectedVersion: task.version - 1, in: database)
      let evidenceId = EvidenceID("lease-fence-\(UUID().uuidString.lowercased())")
      let encodedEvidence = try JSONCanonical.encode(evidence)
      let value = try JSONDecoder().decode(JSONValue.self, from: encodedEvidence)
      guard case let .object(payload) = value else { throw WorkStoreError("owner loss evidence is not a JSON object") }
      try insertEvidence(Evidence(
        id: evidenceId, taskId: taskId, attemptId: predecessor.id, kind: .leaseFence,
        producedBy: Self.evidenceProducer(for: producer), payloadRef: .inline(payload), createdAt: now
      ), in: database)
      return OrphanFenceResult(predecessor: predecessor, evidence: evidence, task: task, fenceEvidenceId: evidenceId)
    }
  }

  func recordAnswer(
    taskId: TaskID, questionId: String, payload: JSONObject, producer: DecisionProducer,
    decisionId: DecisionID, now: Date
  ) throws -> WorkTask {
    let database = try openWritable()
    return try database.transaction { database in
      if let existing = try storedDecision(decisionId, in: database) {
        guard case let .answer(answer) = existing.kind,
              existing.taskId == taskId, answer.questionId == questionId,
              answer.payload == payload, answer.answeredBy == producer else {
          throw WorkStoreError("decision '\(decisionId.rawValue)' conflicts with an already recorded answer")
        }
        return try requiredTask(taskId, in: database)
      }
      let task = try requiredTask(taskId, in: database)
      guard task.state == .waiting else { throw WorkStoreError("task '\(taskId.rawValue)' is not waiting for an answer") }
      guard let packet = try latestHandover(taskId: taskId, in: database),
            case let .userInputRequired(question) = packet.reason,
            question.id == questionId,
            try hasNoSuccessor(packet.id, in: database) else {
        throw WorkStoreError("latest handover does not contain unanswered question '\(questionId)'")
      }
      if let schema = question.answerSchema {
        let candidate = RuntimeOutputCandidate(source: .inlineCandidate, payload: payload)
        let result = try DefaultWorkflowOutputValidator().validate(
          candidate, contract: WorkflowOutputContract(schema: schema, requiredObject: true)
        )
        guard result.status == .accepted else {
          throw WorkStoreError("answer does not match the question's answerSchema: \(result.reason ?? "invalid payload")")
        }
      }
      let answer = HandoverAnswer(questionId: questionId, payload: payload, answeredBy: producer, answeredAt: now)
      let decision = Decision(
        id: decisionId, taskId: taskId, attemptId: packet.fromAttemptId, producer: producer,
        kind: .answer(answer), reason: "Answer handover '\(packet.id.rawValue)' question '\(questionId)'", createdAt: now
      )
      let evidenceId = EvidenceID("handover-answer-\(UUID().uuidString.lowercased())")
      let evidence = Evidence(
        id: evidenceId, taskId: taskId, attemptId: packet.fromAttemptId, kind: .handoverAnswer,
        producedBy: Self.evidenceProducer(for: producer), causedBy: [],
        payloadRef: .inline(["questionId": .string(questionId), "answer": .object(payload)]), createdAt: now
      )
      try insertDecision(decision, in: database)
      try insertEvidence(evidence, in: database)
      try enqueuePendingReservation(PendingAttemptReservation(
        id: UUID().uuidString.lowercased(), taskId: taskId, decisionId: decisionId,
        predecessorAttemptId: packet.fromAttemptId,
        entry: .takeover(fromAttemptId: packet.fromAttemptId, handoverId: packet.id)
      ), now: now, in: database)
      var updated = task
      updated.state = .scheduled
      updated.version += 1
      try updateTask(updated, expectedVersion: task.version, in: database)
      return updated
    }
  }

  func latestAnswer(handoverId: HandoverID) throws -> HandoverAnswer? {
    let database = try openWritable()
    return try latestAnswer(handoverId: handoverId, in: database)
  }

  func requestTakeover(
    taskId: TaskID, placement: TakeoverPlacement, producer: DecisionProducer,
    decisionId: DecisionID, now: Date
  ) throws -> WorkTask {
    let database = try openWritable()
    return try database.transaction { database in
      let task = try requiredTask(taskId, in: database)
      guard !task.state.isTerminal else {
        throw WorkStoreError("task '\(taskId.rawValue)' is \(task.state.rawValue) and cannot be taken over")
      }
      guard let packet = try latestHandover(taskId: taskId, in: database),
            try hasNoSuccessor(packet.id, in: database) else {
        throw WorkStoreError("task '\(taskId.rawValue)' has no unclaimed handover")
      }
      if case let .userInputRequired(question) = packet.reason,
         try latestAnswer(handoverId: packet.id, in: database) == nil {
        throw WorkStoreError("handover \(packet.id.rawValue) needs an answer: riela task answer \(taskId.rawValue) --question \(question.id) …")
      }
      if let pending = try database.query(
        "SELECT request_id FROM work_pending_reservations WHERE task_id = ? AND consumed_attempt_id IS NULL AND json_extract(entry_record, '$.kind') = 'takeover' LIMIT 1",
        bindings: [.text(taskId.rawValue)]
      ).first, pending["request_id"] != nil {
        return task
      }
      let decision = Decision(
        id: decisionId, taskId: taskId, attemptId: packet.fromAttemptId, producer: producer,
        kind: .takeover(handoverId: packet.id, placement: placement),
        reason: "Take over handover '\(packet.id.rawValue)'", createdAt: now
      )
      try insertDecision(decision, in: database)
      try enqueuePendingReservation(PendingAttemptReservation(
        id: UUID().uuidString.lowercased(), taskId: taskId, decisionId: decisionId,
        predecessorAttemptId: packet.fromAttemptId,
        entry: .takeover(fromAttemptId: packet.fromAttemptId, handoverId: packet.id)
      ), now: now, in: database)
      var updated = task
      updated.state = .scheduled
      updated.version += 1
      try updateTask(updated, expectedVersion: task.version, in: database)
      return updated
    }
  }

  private func latestHandover(taskId: TaskID, in database: SQLiteDatabase) throws -> HandoverPacket? {
    guard let row = try database.query(
      "SELECT json(record) AS record, digest FROM work_handovers WHERE task_id = ? ORDER BY created_at DESC, handover_id DESC LIMIT 1",
      bindings: [.text(taskId.rawValue)]
    ).first,
    let record = row["record"], let digest = row["digest"] else { return nil }
    let packet = try JSONCanonical.decoder().decode(HandoverPacket.self, from: Data(record.utf8))
    guard packet.digest == digest, packet.digest == (try packet.canonicalDigest()) else {
      throw WorkStoreError("handover '\(packet.id.rawValue)' failed canonical digest verification")
    }
    return packet
  }

  private func hasNoSuccessor(_ handoverId: HandoverID, in database: SQLiteDatabase) throws -> Bool {
    guard let row = try database.query(
      "SELECT successor_attempt_id FROM work_handovers WHERE handover_id = ? LIMIT 1",
      bindings: [.text(handoverId.rawValue)]
    ).first else { return false }
    return row["successor_attempt_id"] == nil
  }

  private func questionId(of packet: HandoverPacket) -> String? {
    guard case let .userInputRequired(question) = packet.reason else { return nil }
    return question.id
  }

  private func latestAnswer(handoverId: HandoverID, in database: SQLiteDatabase) throws -> HandoverAnswer? {
    guard let row = try database.query(
      "SELECT task_id, json(record) AS record, digest FROM work_handovers WHERE handover_id = ? LIMIT 1",
      bindings: [.text(handoverId.rawValue)]
    ).first, let taskId = row["task_id"], let record = row["record"], let digest = row["digest"] else { return nil }
    let packet = try JSONCanonical.decoder().decode(HandoverPacket.self, from: Data(record.utf8))
    guard packet.id == handoverId, packet.taskId.rawValue == taskId,
          packet.digest == digest, packet.digest == (try packet.canonicalDigest()) else {
      throw WorkStoreError("handover '\(handoverId.rawValue)' failed canonical digest verification")
    }
    guard let questionId = questionId(of: packet) else { return nil }
    let decisions = try decodeDecisionRows(Decision.self, from: database.query(
      """
      SELECT json(decision.record) AS record
      FROM work_decisions AS decision
      JOIN work_handovers AS handover ON handover.task_id = decision.task_id
      WHERE handover.handover_id = ? AND decision.task_id = ? AND decision.attempt_id = ?
        AND decision.kind = 'answer' AND decision.created_at >= handover.created_at
      ORDER BY decision.created_at DESC, decision.decision_id DESC
      """,
      bindings: [.text(handoverId.rawValue), .text(taskId), .text(packet.fromAttemptId.rawValue)]
    ))
    for decision in decisions {
      if case let .answer(answer) = decision.kind, answer.questionId == questionId,
         decision.reason.contains(handoverId.rawValue) { return answer }
    }
    return nil
  }
}

struct TakeoverReservationContext {
  var pendingHandover: HandoverID?
  var packet: HandoverPacket?
  var predecessor: Attempt?
}

extension WorkStore {
  static func decisionKind(for entry: AttemptEntry, pendingDecision: Decision? = nil) -> DecisionKind {
    switch entry {
    case .start: return .start
    case .resume, .director: return .resume
    case let .rerunFromStep(stepId): return .rerun(fromStepId: stepId)
    case let .recoverFromGate(gateId): return .recover(fromGateId: gateId)
    case let .takeover(_, handoverId):
      if let pendingDecision, case let .takeover(id, placement) = pendingDecision.kind, id == handoverId {
        return .takeover(handoverId: id, placement: placement)
      }
      return .takeover(handoverId: handoverId, placement: TakeoverPlacement(hostId: "local"))
    }
  }

  static func answerDecision(_ decision: Decision, matches entry: AttemptEntry) -> Bool {
    guard case .answer = decision.kind,
          case let .takeover(fromAttemptId, handoverId) = entry else { return false }
    return decision.attemptId == fromAttemptId
      && decision.reason.contains(handoverId.rawValue)
  }

  func reservationHandoverContext(
    for request: AttemptReservationRequest, task: WorkTask, in database: SQLiteDatabase
  ) throws -> TakeoverReservationContext {
    guard request.entry != .director else { return TakeoverReservationContext(pendingHandover: nil, packet: nil, predecessor: nil) }
    let pending = try pendingHandoverId(taskId: task.id, in: database)
    guard case let .takeover(fromAttemptId, handoverId) = request.entry else {
      return TakeoverReservationContext(pendingHandover: pending, packet: nil, predecessor: nil)
    }
    guard pending == handoverId else { throw WorkStoreError("takeover handover must be the latest unclaimed handover") }
    guard let row = try database.query(
      "SELECT json(record) AS record, digest, successor_attempt_id FROM work_handovers WHERE handover_id = ? AND task_id = ? LIMIT 1",
      bindings: [.text(handoverId.rawValue), .text(task.id.rawValue)]
    ).first, let record = row["record"], let digest = row["digest"] else {
      throw WorkStoreError("takeover handover '\(handoverId.rawValue)' was not found for task '\(task.id.rawValue)'")
    }
    let packet = try JSONCanonical.decoder().decode(HandoverPacket.self, from: Data(record.utf8))
    guard packet.digest == digest, packet.digest == (try packet.canonicalDigest()) else {
      throw WorkStoreError("handover '\(handoverId.rawValue)' failed canonical digest verification")
    }
    guard packet.taskId == task.id, packet.fromAttemptId == fromAttemptId, row["successor_attempt_id"] == nil,
          request.entryStepId == packet.contract.resumeStepId else {
      throw WorkStoreError("takeover handover does not match its predecessor, successor state, or resume step")
    }
    let predecessor = try requiredAttempt(fromAttemptId, in: database)
    guard predecessor.taskId == task.id, predecessor.state == .reconciled else {
      throw WorkStoreError("takeover predecessor must be reconciled work on the same task")
    }
    return TakeoverReservationContext(pendingHandover: nil, packet: packet, predecessor: predecessor)
  }

  func reservationDecisionMatches(_ decision: Decision, entry: AttemptEntry) -> Bool {
    Self.requestedEntry(for: decision.kind, predecessorAttemptId: decision.attemptId) == entry
      || Self.answerDecision(decision, matches: entry)
  }

  static func isTakeoverDecision(_ decision: Decision, matching entry: AttemptEntry) -> Bool {
    if case let .takeover(storedId, _) = decision.kind,
       case let .takeover(_, requestedId) = entry { return storedId == requestedId }
    return answerDecision(decision, matches: entry)
  }

  func pendingHandoverId(taskId: TaskID, in database: SQLiteDatabase) throws -> HandoverID? {
    guard let row = try database.query(
      "SELECT handover_id, successor_attempt_id FROM work_handovers WHERE task_id = ? ORDER BY created_at DESC, handover_id DESC LIMIT 1",
      bindings: [.text(taskId.rawValue)]
    ).first,
    row["successor_attempt_id"] == nil,
    let handoverId = row["handover_id"] else { return nil }
    return HandoverID(rawValue: handoverId)
  }
}
