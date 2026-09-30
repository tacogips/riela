import Foundation
import RielaCore
import RielaSQLite

public extension WorkStore {
  private func handoverReadOnlyIfPresent() throws -> SQLiteDatabase? {
    guard FileManager.default.fileExists(atPath: databasePath) else { return nil }
    let db = try SQLiteDatabase.open(
      path: databasePath,
      mode: immutableReadOnly ? .strictReadOnlyWithImmutableFallback : .readOnly,
      options: .readOnlyDefault
    )
    guard try db.tableExists("work_handovers") else { return nil }
    return db
  }

  func saveHandover(_ packet: HandoverPacket) throws {
    guard packet.digest == (try packet.canonicalDigest()) else {
      throw WorkStoreError("handover '\(packet.id.rawValue)' digest does not match its canonical record")
    }
    let bytes = try JSONCanonical.encode(packet)
    guard let json = String(bytes: bytes, encoding: .utf8) else { throw WorkStoreError("canonical handover JSON is not UTF-8") }
    let db = try openWritable()
    try db.execute(
      """
      INSERT INTO work_handovers (handover_id, task_id, from_attempt_id, successor_attempt_id, digest, record, created_at)
      VALUES (?, ?, ?, NULL, ?, jsonb(?), ?)
      ON CONFLICT(handover_id) DO UPDATE SET record = excluded.record, digest = excluded.digest
      """,
      bindings: [.text(packet.id.rawValue), .text(packet.taskId.rawValue), .text(packet.fromAttemptId.rawValue),
                 .text(packet.digest), .text(json), .text(Self.timestamp(packet.createdAt))]
    )
  }

  func loadHandover(id: HandoverID) throws -> HandoverPacket? {
    guard let db = try handoverReadOnlyIfPresent() else { return nil }
    guard let row = try db.query(
      "SELECT json(record) AS record, digest FROM work_handovers WHERE handover_id = ?",
      bindings: [.text(id.rawValue)]
    ).first, let record = row["record"] else { return nil }
    return try decodeCanonicalHandover(record: record, digest: row["digest"])
  }

  func latestHandover(taskId: TaskID) throws -> HandoverPacket? {
    guard let db = try handoverReadOnlyIfPresent() else { return nil }
    guard let row = try db.query(
      "SELECT json(record) AS record, digest FROM work_handovers WHERE task_id = ? ORDER BY created_at DESC, handover_id DESC LIMIT 1",
      bindings: [.text(taskId.rawValue)]
    ).first, let record = row["record"] else { return nil }
    return try decodeCanonicalHandover(record: record, digest: row["digest"])
  }

  func listHandovers(taskId: TaskID) throws -> [HandoverPacket] {
    guard let db = try handoverReadOnlyIfPresent() else { return [] }
    let rows = try db.query("SELECT json(record) AS record, digest FROM work_handovers WHERE task_id = ? ORDER BY created_at ASC, handover_id ASC",
                            bindings: [.text(taskId.rawValue)])
    return try rows.compactMap { row in
      guard let record = row["record"] else { return nil }
      return try decodeCanonicalHandover(record: record, digest: row["digest"])
    }
  }

  func attachSuccessor(handoverId: HandoverID, attemptId: AttemptID) throws {
    let db = try openWritable()
    try db.transaction { db in
      let changed = try db.executeAndReturnChangedRowCount(
        "UPDATE work_handovers SET successor_attempt_id = ? WHERE handover_id = ? AND successor_attempt_id IS NULL",
        bindings: [.text(attemptId.rawValue), .text(handoverId.rawValue)]
      )
      if changed == 0 {
        guard let existing = try db.query("SELECT successor_attempt_id FROM work_handovers WHERE handover_id = ?",
                                         bindings: [.text(handoverId.rawValue)]).first?["successor_attempt_id"] else {
          throw WorkStoreError("handover '\(handoverId.rawValue)' was not found")
        }
        guard existing == attemptId.rawValue else { throw WorkStoreError("handover already has a different successor attempt") }
      }
    }
  }

  func recordSinkRefs(handoverId: HandoverID, refs: [HandoverSinkRef]) throws {
    let data = try JSONCanonical.encode(refs)
    guard let json = String(bytes: data, encoding: .utf8) else { throw WorkStoreError("canonical sink references are not UTF-8") }
    let db = try openWritable()
    let changed = try db.executeAndReturnChangedRowCount(
      "UPDATE work_handovers SET record = jsonb_set(record, '$.sinks', jsonb(?)) WHERE handover_id = ?",
      bindings: [.text(json), .text(handoverId.rawValue)]
    )
    guard changed == 1 else { throw WorkStoreError("handover '\(handoverId.rawValue)' was not found") }
  }

  func tasksAwaitingHandover(traits: [HostTrait]? = nil) throws -> [TaskHandoverSummary] {
    guard let db = try handoverReadOnlyIfPresent() else { return [] }
    let rows = try db.query(
      """
      SELECT h.task_id, h.handover_id, json(h.record) AS record, h.digest
      FROM work_handovers h
      JOIN work_tasks t ON t.task_id = h.task_id
      WHERE h.successor_attempt_id IS NULL
        AND t.state NOT IN ('succeeded', 'failed', 'cancelled', 'superseded')
        AND NOT EXISTS (
          SELECT 1 FROM work_handovers newer
          WHERE newer.task_id = h.task_id
            AND (newer.created_at > h.created_at
              OR (newer.created_at = h.created_at AND newer.handover_id > h.handover_id))
        )
      ORDER BY h.created_at ASC, h.handover_id ASC
      """
    )
    let available = traits.map(Set.init)
    var result: [TaskHandoverSummary] = []
    for row in rows {
      guard let task = row["task_id"], let id = row["handover_id"], let record = row["record"] else { continue }
      let packet = try decodeCanonicalHandover(record: record, digest: row["digest"])
      let required: [HostTrait]
      let reasonKind: String
      let question: HandoverQuestion?
      switch packet.reason {
      case let .userInputRequired(value): required = []; reasonKind = "userInputRequired"; question = value
      case let .userPresenceRequired(value): required = value.traits; reasonKind = "userPresenceRequired"; question = nil
      case .ownerLost: required = []; reasonKind = "ownerLost"; question = nil
      case .inactivity: required = []; reasonKind = "inactivity"; question = nil
      case .operatorMove: required = []; reasonKind = "operatorMove"; question = nil
      }
      if let available, !Set(required).isSubset(of: available) { continue }
      let answered = try db.query("SELECT json(record) AS record FROM work_decisions WHERE task_id = ?",
                                  bindings: [.text(task)]).contains { row in
        guard let raw = row["record"], let decision = try? decode(Decision.self, json: raw) else { return false }
        if case let .answer(answer) = decision.kind { return answer.questionId == question?.id && decision.createdAt >= packet.createdAt }
        return false
      }
      result.append(TaskHandoverSummary(taskId: TaskID(task), handoverId: HandoverID(id), reasonKind: reasonKind,
                                        requiredTraits: required, needsAnswer: question != nil && !answered,
                                        questionText: question?.text, createdAt: packet.createdAt))
    }
    return result
  }

  func sealHandoverRecords(
    packet: HandoverPacket,
    decision: Decision,
    evidence: [Evidence],
    predecessorOutcome: AttemptOutcome,
    expectedTaskVersion: Int,
    now: Date
  ) throws -> WorkTask {
    let db = try openWritable()
    return try db.transaction { db in
      let task = try requiredTask(packet.taskId, in: db)
      guard task.version == expectedTaskVersion else { throw WorkStoreError.versionConflict(taskId: task.id, expected: expectedTaskVersion) }
      guard decision.taskId == packet.taskId, decision.attemptId == packet.fromAttemptId,
            case .handover = decision.kind else { throw WorkStoreError("handover decision does not match packet") }
      var storedPacket = packet
      if storedPacket.digest.isEmpty { storedPacket = try storedPacket.sealed() }
      guard storedPacket.digest == (try storedPacket.canonicalDigest()) else {
        throw WorkStoreError("handover '\(storedPacket.id.rawValue)' digest does not match its canonical record")
      }
      let bytes = try JSONCanonical.encode(storedPacket)
      guard let json = String(bytes: bytes, encoding: .utf8) else { throw WorkStoreError("canonical handover JSON is not UTF-8") }
      try db.execute(
        "INSERT INTO work_handovers (handover_id, task_id, from_attempt_id, digest, record, created_at) VALUES (?, ?, ?, ?, jsonb(?), ?)",
        bindings: [.text(storedPacket.id.rawValue), .text(storedPacket.taskId.rawValue), .text(storedPacket.fromAttemptId.rawValue),
                   .text(storedPacket.digest), .text(json), .text(Self.timestamp(now))]
      )
      try insertDecision(decision, in: db)
      for item in evidence { try insertEvidence(item, in: db) }
      var predecessor = try requiredAttempt(packet.fromAttemptId, in: db)
      if predecessor.state != .reconciled {
        predecessor.state = .reconciled
        predecessor.outcome = predecessorOutcome
        try replaceAttempt(predecessor, in: db)
      }
      try db.execute("DELETE FROM work_leases WHERE attempt_id = ?", bindings: [.text(packet.fromAttemptId.rawValue)])
      var updated = task
      updated.state = .waiting
      updated.version = expectedTaskVersion + 1
      try updateTask(updated, expectedVersion: expectedTaskVersion, in: db)
      return updated
    }
  }

  private func decodeCanonicalHandover(record: String, digest: String?) throws -> HandoverPacket {
    let packet = try JSONCanonical.decoder().decode(HandoverPacket.self, from: Data(record.utf8))
    guard let digest, packet.digest == digest, packet.digest == (try packet.canonicalDigest()) else {
      throw WorkStoreError("handover '\(packet.id.rawValue)' failed canonical digest verification")
    }
    return packet
  }
}
