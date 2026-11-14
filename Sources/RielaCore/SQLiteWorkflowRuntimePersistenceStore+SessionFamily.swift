import Foundation
import RielaSQLite

public extension SQLiteWorkflowRuntimePersistenceStore {
  /// Returns the canonical snapshots sharing the target session's root.
  /// Missing stores, tables, and target rows have no known family members.
  func sessionFamilyIds(of sessionId: String) throws -> [String] {
    guard isSafeId(sessionId) else {
      throw WorkflowRuntimePersistenceStoreError.invalidSessionId(sessionId)
    }
    guard FileManager.default.fileExists(atPath: Self.defaultDatabasePath(rootDirectory: rootDirectory)) else {
      return []
    }
    let db = try openDatabase(readOnly: true)
    let tableRows = try mapRuntimeSQLiteError {
      try db.query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'workflow_runtime_snapshots' LIMIT 1",
        bindings: []
      )
    }
    guard !tableRows.isEmpty else {
      return []
    }
    let rows = try mapRuntimeSQLiteError {
      try db.query(
        """
        SELECT workflow_execution_id
        FROM workflow_runtime_snapshots
        WHERE root_session_id = (
          SELECT root_session_id
          FROM workflow_runtime_snapshots
          WHERE workflow_execution_id = ?
        )
        ORDER BY created_at, workflow_execution_id
        """,
        bindings: [.text(sessionId)]
      )
    }
    return rows.compactMap { $0["workflow_execution_id"] }
  }

  /// Loads only the requested snapshots, skipping rows that disappeared.
  func loadFamily(ids: [String]) throws -> [WorkflowRuntimePersistenceSnapshot] {
    var snapshots: [WorkflowRuntimePersistenceSnapshot] = []
    for id in ids {
      do {
        snapshots.append(try load(sessionId: id))
      } catch let error as WorkflowRuntimePersistenceStoreError {
        if case .notFound = error { continue }
        throw error
      }
    }
    return snapshots
  }
}
