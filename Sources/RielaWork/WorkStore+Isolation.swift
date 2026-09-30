import Foundation
import RielaCore
import RielaSQLite

public extension WorkStore {
  /// Updates the durable isolation metadata for an attempt without replacing
  /// any concurrently written attempt fields.
  @discardableResult
  func updateAttemptIsolation(attemptId: AttemptID, isolation: IsolationRef) throws -> Bool {
    let database = try openWritable()
    let encoded = try JSONCanonical.encode(isolation)
    guard let value = String(data: encoded, encoding: .utf8) else {
      throw WorkStoreError("attempt isolation is not valid UTF-8 JSON")
    }
    let changed = try database.executeAndReturnChangedRowCount(
      "UPDATE work_attempts SET record = jsonb_set(record, '$.isolation', jsonb(?)) WHERE attempt_id = ? AND state IN ('prepared', 'running')",
      bindings: [.text(value), .text(attemptId.rawValue)]
    )
    return changed == 1
  }

  /// Clears the live-cancellation barrier for a director handover without
  /// reconciling the predecessor. The handover seal owns reconciliation.
  func acknowledgeHandoverCancellation(taskId: TaskID, attemptId: AttemptID) throws {
    let database = try openWritable()
    try database.transaction { database in
      guard let row = try database.query(
        "SELECT decision_id FROM work_cancellations WHERE task_id = ? AND attempt_id = ? AND acknowledged_at IS NULL",
        bindings: [.text(taskId.rawValue), .text(attemptId.rawValue)]
      ).first, let rawDecisionId = row["decision_id"] else {
        throw WorkStoreError("attempt has no pending handover cancellation")
      }
      let decisionId = DecisionID(rawDecisionId)
      guard let decision = try storedDecision(decisionId, in: database),
            decision.taskId == taskId, decision.attemptId == attemptId,
            case .handover = decision.kind else {
        throw WorkStoreError("pending cancellation is not the matching handover decision")
      }
      let changed = try database.executeAndReturnChangedRowCount(
        "UPDATE work_cancellations SET acknowledged_at = ?, terminal_status = 'failed' WHERE task_id = ? AND attempt_id = ? AND decision_id = ? AND acknowledged_at IS NULL",
        bindings: [
          .text(Self.timestamp(Date())), .text(taskId.rawValue), .text(attemptId.rawValue),
          .text(decisionId.rawValue)
        ]
      )
      guard changed == 1 else { throw WorkStoreError("handover cancellation acknowledgement raced") }
    }
  }
}
