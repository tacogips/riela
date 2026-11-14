import Foundation
import RielaCore
import RielaSQLite

public extension WorkStore {
  /// Reclaims a director child before any workflow execution started. The
  /// caller must own the exact session's process lock until launch admission.
  func reissueReservedDirectorLaunch(
    attemptId: AttemptID,
    expectedTaskVersion: Int,
    now: Date = Date()
  ) throws -> AttemptReservation {
    let database = try openWritable()
    return try database.transaction { database in
      var attempt = try requiredAttempt(attemptId, in: database)
      let task = try requiredTask(attempt.taskId, in: database)
      guard task.version == expectedTaskVersion else {
        throw WorkStoreError.versionConflict(taskId: task.id, expected: expectedTaskVersion)
      }
      guard task.state == .running, attempt.entry == .director,
            attempt.state == .prepared, attempt.launch?.phase == .reserved,
            let judgedId = attempt.judgedAttemptId,
            try latestAttempt(for: task, in: database)?.id == attempt.id else {
        throw WorkStoreError("director child is not an unlaunched latest reservation")
      }
      let judged = try requiredAttempt(judgedId, in: database)
      guard judged.taskId == task.id, judged.entry != .director,
            judged.state == .reconciled,
            attempt.generation == judged.generation + 1 else {
        throw WorkStoreError("director child judged-work linkage is invalid")
      }
      try rejectPendingCancellation(for: attempt.id, in: database)
      let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: rootDirectory)
        .load(sessionId: attempt.sessionId, in: database)
      guard snapshot.session.sessionId == attempt.sessionId,
            snapshot.session.workflowId == task.director.agentWorkflow?.name,
            snapshot.session.status == .created, snapshot.session.executions.isEmpty,
            snapshot.rootOutput == nil, snapshot.loopEvidence == nil else {
        throw WorkStoreError("director child session has already started or changed")
      }
      let decisions = try decodeDecisionRows(Decision.self, from: database.query(
        "SELECT json(record) AS record FROM work_decisions WHERE attempt_id = ?",
        bindings: [.text(attempt.id.rawValue)]
      )).filter { $0.producer == .policy(rule: "director-child") && $0.kind == .resume }
      guard decisions.count == 1, let decision = decisions.first,
            let oldDigest = attempt.launch?.tokenDigest else {
        throw WorkStoreError("director child launch decision or token is missing")
      }
      let token = UUID().uuidString.lowercased()
      let digest = Self.launchTokenDigest(token)
      let changed = try database.executeAndReturnChangedRowCount(
        "UPDATE work_leases SET token_digest = ?, updated_at = ? WHERE attempt_id = ? AND task_id = ? AND session_id = ? AND token_digest = ?",
        bindings: [.text(digest), .text(Self.timestamp(now)), .text(attempt.id.rawValue),
                   .text(task.id.rawValue), .text(attempt.sessionId), .text(oldDigest)]
      )
      guard changed == 1 else { throw WorkStoreError("director child launch lease changed") }
      attempt.launch?.tokenDigest = digest
      attempt.launch?.updatedAt = now
      try replaceAttempt(attempt, in: database)
      return AttemptReservation(task: task, attempt: attempt, decision: decision, launchToken: token)
    }
  }
}
