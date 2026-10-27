import Foundation
import RielaSQLite

/// Small, transactionally maintained ID projections. Payload changes by older
/// writers invalidate the projection through database triggers; a later startup
/// backfills only missing projections, never trusting a stale high-water mark.
public enum SQLiteWorkflowStartupIdentities {
  public enum Source: Sendable {
    case cli, runtime
    var table: String { self == .cli ? "cli_workflow_sessions" : "workflow_runtime_snapshots" }
    var id: String { self == .cli ? "session_id" : "workflow_execution_id" }
    var payload: String { self == .cli ? "record_json" : "session_json" }
    var sessionPath: String { self == .cli ? "$.session" : "$" }
    var projection: String {
      self == .cli ? "cli_startup_identities" : "runtime_startup_identities"
    }
  }

  public struct Identity: Sendable {
    public var sessionId: String
    public var workflowId: String
    public var executionIds: [String]
  }

  public enum MetadataError: Error { case incompatibleSchema, invalidProjection, staleProjection }

  private static func triggers(_ source: Source) -> [(String, String)] {
    let base = source.projection
    return [
      (base + "_insert", "AFTER INSERT"),
      (base + "_update", "AFTER UPDATE OF \(source.id), \(source.payload)"),
      (base + "_delete", "AFTER DELETE")
    ].map { name, event in
      let ids =
        event == "AFTER INSERT"
        ? "NEW.\(source.id)"
        : event == "AFTER DELETE" ? "OLD.\(source.id)" : "OLD.\(source.id), NEW.\(source.id)"
      return (
        name,
        "CREATE TRIGGER \(name) \(event) ON \(source.table) BEGIN DELETE FROM \(base) WHERE session_id IN (\(ids)); END"
      )
    }
  }

  private static func validSchema(_ db: SQLiteDatabase, source: Source) throws -> Bool {
    guard try db.tableExists(source.projection) else { return false }
    let rows = try db.query(
      "SELECT version FROM workflow_startup_identity_schema WHERE name=?",
      bindings: [.text(source.projection)])
    guard rows.count == 1, rows[0]["version"] == "1" else { throw MetadataError.incompatibleSchema }
    return true
  }

  /// Installs invalidation before accepting any projection. Missing or altered
  /// triggers mean the intervening writer lineage is unknown: rebuild all IDs.
  public static func ensureSchema(_ db: SQLiteDatabase, source: Source) throws {
    try savepoint(db, name: source.projection + "_schema") { try installSchema(db, source: source) }
  }

  private static func savepoint<T>(_ db: SQLiteDatabase, name: String, body: () throws -> T) throws
    -> T {
    try db.execute("SAVEPOINT \(name)")
    do {
      let value = try body()
      try db.execute("RELEASE \(name)")
      return value
    } catch {
      try? db.execute("ROLLBACK TO \(name)")
      try? db.execute("RELEASE \(name)")
      throw error
    }
  }

  private static func installSchema(_ db: SQLiteDatabase, source: Source) throws {
    try db.execute(
      "CREATE TABLE IF NOT EXISTS workflow_startup_identity_schema (name TEXT PRIMARY KEY, version INTEGER NOT NULL)"
    )
    let existed = try validSchema(db, source: source)
    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS \(source.projection) (
        session_id TEXT PRIMARY KEY, workflow_id TEXT NOT NULL,
        execution_ids_json TEXT NOT NULL
          CHECK(json_valid(execution_ids_json) AND json_type(execution_ids_json)='array'))
      """
    )
    if !existed {
      try db.execute(
        "INSERT INTO workflow_startup_identity_schema(name,version) VALUES (?,1)",
        bindings: [.text(source.projection)])
    }
    var intact = existed
    for (name, sql) in triggers(source) {
      let rows = try db.query(
        "SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?", bindings: [.text(name)])
      if rows.first?["sql"] != sql { intact = false }
    }
    if !intact {
      try db.execute("DELETE FROM \(source.projection)")
      for (name, sql) in triggers(source) {
        try db.execute("DROP TRIGGER IF EXISTS \(name)")
        try db.execute(sql)
      }
    }
  }

  /// Read-only readiness check: PK-only anti-join never visits payload columns.
  public static func isPrepared(_ db: SQLiteDatabase, source: Source) throws -> Bool {
    guard try db.tableExists(source.table) else { return true }
    guard try validSchema(db, source: source) else { return false }
    for (name, sql) in triggers(source) {
      let rows = try db.query(
        "SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?", bindings: [.text(name)])
      if rows.first?["sql"] != sql { return false }
    }
    return try db.query(
      "SELECT 1 AS missing FROM \(source.table) AS s WHERE NOT EXISTS (SELECT 1 FROM \(source.projection) AS i WHERE i.session_id=s.\(source.id)) LIMIT 1"
    ).isEmpty
  }

  public static func backfill(_ db: SQLiteDatabase, source: Source) throws {
    try ensureSchema(db, source: source)
    // Only legacy/invalidated rows visit JSON. Return compact ID arrays, never
    // materialize entire execution objects or unrelated outputs in Swift.
    let executionIDsExpression: String
    if source.projection == "runtime_startup_identities" {
      executionIDsExpression = """
        CASE WHEN json_type(s.session_json, '$.\(SQLiteWorkflowRuntimePersistenceStore.executionStorageMarkerKey)') = 'text' THEN
          COALESCE((SELECT json_group_array(ordered.execution_id) FROM (
                      SELECT e.execution_id FROM workflow_runtime_executions AS e
                      WHERE e.workflow_execution_id = s.workflow_execution_id ORDER BY e.ordinal
                    ) AS ordered), '[]')
        ELSE COALESCE((SELECT json_group_array(json_extract(e.value, '$.executionId'))
                       FROM json_each(s.session_json, '$.executions') AS e), '[]') END
        """
    } else {
      executionIDsExpression = """
        COALESCE((SELECT json_group_array(json_extract(e.value, '$.executionId'))
                  FROM json_each(s.\(source.payload), '\(source.sessionPath).executions') AS e), '[]')
        """
    }
    let rows = try db.query(
      """
      SELECT s.\(source.id) AS session_id, s.workflow_id AS workflow_id,
        \(executionIDsExpression) AS execution_ids
      FROM \(source.table) AS s WHERE NOT EXISTS
        (SELECT 1 FROM \(source.projection) AS i WHERE i.session_id=s.\(source.id))
      """
    )
    for row in rows {
      guard let sessionId = row["session_id"], let workflowId = row["workflow_id"],
        let text = row["execution_ids"], let data = text.data(using: .utf8)
      else { throw MetadataError.invalidProjection }
      let ids = try JSONDecoder().decode([String].self, from: data)
      try save(db, source: source, sessionId: sessionId, workflowId: workflowId, executionIds: ids)
    }
  }

  public static func save(
    _ db: SQLiteDatabase, source: Source, sessionId: String, workflowId: String,
    executionIds: [String]
  ) throws {
    let data = try JSONEncoder().encode(executionIds)
    guard let text = String(data: data, encoding: .utf8) else {
      throw MetadataError.invalidProjection
    }
    try db.execute(
      "INSERT INTO \(source.projection)(session_id,workflow_id,execution_ids_json) VALUES (?,?,?) ON CONFLICT(session_id) DO UPDATE SET workflow_id=excluded.workflow_id,execution_ids_json=excluded.execution_ids_json",
      bindings: [.text(sessionId), .text(workflowId), .text(text)])
  }

  public static func load(_ db: SQLiteDatabase, source: Source) throws -> [Identity] {
    try savepoint(db, name: source.projection + "_read") {
      guard try isPrepared(db, source: source) else { throw MetadataError.staleProjection }
      return try db.query(
        "SELECT session_id,workflow_id,execution_ids_json FROM \(source.projection) ORDER BY session_id"
      ).map { row in
        guard let sessionId = row["session_id"], let workflowId = row["workflow_id"],
          let text = row["execution_ids_json"], let data = text.data(using: .utf8)
        else { throw MetadataError.invalidProjection }
        return Identity(
          sessionId: sessionId, workflowId: workflowId,
          executionIds: try JSONDecoder().decode([String].self, from: data))
      }
    }
  }
}
