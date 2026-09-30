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
}
