import RielaSQLite

public struct SessionRollupSnapshotPage: Sendable {
  public var snapshots: [WorkflowRuntimePersistenceSnapshot]
  public var truncated: Bool
  public var limit: Int

  public init(
    snapshots: [WorkflowRuntimePersistenceSnapshot],
    truncated: Bool,
    limit: Int
  ) {
    self.snapshots = snapshots
    self.truncated = truncated
    self.limit = limit
  }
}

public extension SQLiteWorkflowRuntimePersistenceStore {
  static let defaultRollupSnapshotLimit = 1_000

  /// Loads the requested session and every snapshot in its persisted root tree
  /// through one short-lived read-only connection. Callers assemble the
  /// requested subtree in memory so a child request cannot accidentally render
  /// its siblings.
  func loadRollupSnapshots(sessionId: String) throws -> [WorkflowRuntimePersistenceSnapshot] {
    try loadRollupSnapshotPage(sessionId: sessionId).snapshots
  }

  /// Loads a bounded root-tree page. `truncated` is explicit so CLI and GraphQL
  /// callers never mistake a resource-limited projection for the complete tree.
  func loadRollupSnapshotPage(
    sessionId: String,
    limit: Int = Self.defaultRollupSnapshotLimit
  ) throws -> SessionRollupSnapshotPage {
    guard isSafeId(sessionId) else {
      throw WorkflowRuntimePersistenceStoreError.invalidSessionId(sessionId)
    }
    let boundedLimit = max(1, min(limit, Self.defaultRollupSnapshotLimit))
    let db = try openDatabase(readOnly: true, strictReadOnly: true)
    let columns = try mapRollupSQLiteError { try db.tableColumnNames("workflow_runtime_snapshots") }
    let loopEvidenceSelect = try loopEvidenceSelectExpression(db)
    let rows: [SQLiteRow]
    if columns.contains("root_session_id") {
      rows = try mapRollupSQLiteError {
        try db.query(
          """
          SELECT json(session_json) AS session_json,
            CASE WHEN root_output_json IS NULL THEN NULL ELSE json(root_output_json) END AS root_output_json,
            json(diagnostics_json) AS diagnostics_json,
            \(loopEvidenceSelect)
          FROM workflow_runtime_snapshots
          WHERE workflow_execution_id = ?
             OR root_session_id = COALESCE(
               (SELECT root_session_id FROM workflow_runtime_snapshots WHERE workflow_execution_id = ?),
               ?
             )
          ORDER BY CASE WHEN workflow_execution_id = ? THEN 0 ELSE 1 END,
            created_at,
            workflow_execution_id
          LIMIT ?
          """,
          bindings: [
            .text(sessionId),
            .text(sessionId),
            .text(sessionId),
            .text(sessionId),
            .int(Int64(boundedLimit + 1))
          ]
        )
      }
    } else {
      rows = try mapRollupSQLiteError {
        try db.query(
          """
          SELECT json(session_json) AS session_json,
            CASE WHEN root_output_json IS NULL THEN NULL ELSE json(root_output_json) END AS root_output_json,
            json(diagnostics_json) AS diagnostics_json,
            \(loopEvidenceSelect)
          FROM workflow_runtime_snapshots
          WHERE workflow_execution_id = ?
          LIMIT 1
          """,
          bindings: [.text(sessionId)]
        )
      }
    }
    guard !rows.isEmpty else {
      throw WorkflowRuntimePersistenceStoreError.notFound("runtime snapshot not found: \(sessionId)")
    }
    return SessionRollupSnapshotPage(
      snapshots: try rows.prefix(boundedLimit).map { try snapshot(from: $0, db: db) },
      truncated: rows.count > boundedLimit,
      limit: boundedLimit
    )
  }
}

private func mapRollupSQLiteError<T>(_ body: () throws -> T) throws -> T {
  do {
    return try body()
  } catch let error as SQLiteError {
    throw WorkflowRuntimePersistenceStoreError.sqliteFailed(error.message)
  }
}
