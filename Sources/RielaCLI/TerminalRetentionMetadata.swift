import Foundation
import RielaCore
import RielaSQLite

/// Reads SQL scalar metadata only, never decoding potentially large session payloads.
enum TerminalRetentionMetadata {
  static func sessions(_ db: SQLiteDatabase) throws -> [TerminalRetentionSession] {
    var sessions: [String: TerminalRetentionSession] = [:]
    let dates = DateDecoder()
    if try db.tableExists("workflow_runtime_snapshots") {
      for row in try db.query("""
        SELECT workflow_execution_id AS id, workflow_id, session_status AS status,
          parent_session_id AS parent_id, root_session_id AS root_id, updated_at,
          \(TerminalRetentionIndexes.runtimeBytes) AS bytes
        FROM \(TerminalRetentionIndexes.source("workflow_runtime_snapshots", in: db))
        """) { try merge(row, into: &sessions, dates: dates) }
    }
    if try db.tableExists("cli_workflow_sessions") {
      for row in try db.query("""
        SELECT session_id AS id, workflow_id, status,
          json_extract(record_json, '$.session.parentSessionId') AS parent_id,
          coalesce(json_extract(record_json, '$.session.rootSessionId'),session_id) AS root_id,
          updated_at, length(CAST(record_json AS BLOB)) AS bytes FROM \(TerminalRetentionIndexes.source("cli_workflow_sessions", in: db))
        """) { try merge(row, into: &sessions, dates: dates) }
    }
    if try db.tableExists("workflow_messages") {
      for row in try db.query("""
        SELECT workflow_execution_id AS id,
          sum(\(TerminalRetentionIndexes.messageBytes)) AS bytes
        FROM \(TerminalRetentionIndexes.source("workflow_messages", in: db)) GROUP BY workflow_execution_id
        """) {
        guard let id = row["id"], var session = sessions[id], let bytes = row["bytes"].flatMap(Int64.init) else { continue }
        session.payloadBytes = try adding(session.payloadBytes, bytes)
        sessions[id] = session
      }
    }
    if try db.tableExists("workflow_nested_invocations") {
      for row in try db.query("""
        SELECT \(TerminalRetentionIndexes.parent) AS parent,
          \(TerminalRetentionIndexes.child) AS child,
          \(TerminalRetentionIndexes.nestedBytes) AS bytes,
          \(TerminalRetentionIndexes.settled) AS settled
        FROM \(TerminalRetentionIndexes.source("workflow_nested_invocations", in: db))
        """) {
        let parent = row["parent"], child = row["child"]
        if let parent, let prior = sessions[parent], let bytes = row["bytes"].flatMap(Int64.init) {
          sessions[parent]?.payloadBytes = try adding(prior.payloadBytes, bytes)
        }
        let valid = parent.flatMap { sessions[$0] } != nil && child.flatMap { sessions[$0] } != nil
          && child.flatMap { sessions[$0]?.parentId } == parent && row["settled"] == "1"
        if !valid {
          for id in [parent, child].compactMap({ $0 }) where sessions[id] != nil {
            sessions[id]?.protection = "unsettledNestedInvocation"
          }
        }
      }
    }
    if try db.tableExists("loop_baselines") {
      for row in try db.query("SELECT session_id AS id FROM loop_baselines") {
        if let id = row["id"], sessions[id] != nil { sessions[id]?.protection = "loopBaseline" }
      }
    }
    if try db.tableExists("loop_concurrency_leases") {
      for row in try db.query("SELECT session_id AS id FROM loop_concurrency_leases") {
        if let id = row["id"], sessions[id] != nil { sessions[id]?.protection = "concurrencyLease" }
      }
    }
    // Work Runtime and specialist state has independent transactional ownership.
    // Until that ownership has a retention adapter, never delete its projections.
    for table in ["work_attempts", "specialist_dispatches"] where try db.tableExists(table) {
      let column = table == "work_attempts" ? "session_id" : "child_session_id"
      for row in try db.query("SELECT \(column) AS id FROM \(table)") {
        if let id = row["id"], sessions[id] != nil { sessions[id]?.protection = "externalRuntimeOwnership" }
      }
    }
    return sessions.values.sorted { $0.id < $1.id }
  }

  private static func merge(_ row: SQLiteRow, into sessions: inout [String: TerminalRetentionSession], dates: DateDecoder) throws {
    guard let id = row["id"], let workflow = row["workflow_id"], let status = row["status"],
          let root = row["root_id"], let bytes = row["bytes"].flatMap(Int64.init), bytes >= 0 else {
      throw TerminalRetentionPlanError.invalidPolicyOrMetadata
    }
    let parent = row["parent_id"], updated = row["updated_at"].flatMap(dates.date)
    if var existing = sessions[id] {
      if existing.workflowId != workflow || existing.parentId != parent || existing.rootId != root {
        existing.protection = "conflictingLineage"
      }
      existing.statuses.insert(status)
      existing.updatedAt = existing.updatedAt.flatMap { prior in updated.map { max(prior, $0) } }
      existing.payloadBytes = try adding(existing.payloadBytes, bytes)
      sessions[id] = existing
    } else {
      sessions[id] = .init(id: id, workflowId: workflow, parentId: parent, rootId: root,
                           statuses: [status], updatedAt: updated, payloadBytes: bytes)
    }
  }

  static func date(_ text: String) -> Date? { DateDecoder().date(text) }

  /// Invocation-local formatter objects; no timestamps or rows are cached.
  private struct DateDecoder {
    private let fractional: ISO8601DateFormatter
    private let whole: ISO8601DateFormatter

    init() {
      fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      whole = ISO8601DateFormatter()
      whole.formatOptions = [.withInternetDateTime]
    }

    func date(_ text: String) -> Date? {
      fractional.date(from: text) ?? whole.date(from: text)
    }
  }

  static func adding(_ left: Int64, _ right: Int64) throws -> Int64 {
    let result = left.addingReportingOverflow(right)
    guard right >= 0, !result.overflow else { throw TerminalRetentionPlanError.invalidPolicyOrMetadata }
    return result.partialValue
  }
}
