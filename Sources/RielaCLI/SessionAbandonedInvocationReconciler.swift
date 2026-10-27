import Foundation
import RielaCore
import RielaSQLite

struct SessionNestedInvocationVerdict: Codable, Equatable {
  var invocationKey: String
  var parentSessionId: String?
  var childSessionId: String?
  var verdict: String
  var applied: Bool
  var reason: String?
}

struct SessionAbandonedInvocationReconciler {
  var registry: SessionExecutionLockRegistry
  var now: () -> Date = Date.init
  var beforeTransaction: () throws -> Void = {}

  func run(sessionStoreRoot: String, abandonedAfter: TimeInterval, apply: Bool,
           parentActivityOverrides: [String: Date] = [:]) throws -> [SessionNestedInvocationVerdict] {
    guard abandonedAfter >= 0 else { return [] }
    let databasePath = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: sessionStoreRoot)
    guard FileManager.default.fileExists(atPath: databasePath) else { return [] }
    let db = try SQLiteDatabase.open(path: databasePath, mode: apply ? .readWriteCreate : .strictReadOnly,
      options: apply ? .writableRuntimeStoreDefault : .readOnlyDefault)
    guard try db.tableExists("workflow_nested_invocations"), try db.tableColumnNames("workflow_nested_invocations").contains("abandoned_at") else {
      return []
    }
    let settled = try TerminalRetentionIndexes.settled(in: db)
    let rows = try db.query("""
      SELECT invocation_key, reservation_json,
        json_extract(reservation_json,'$.parentSessionId') AS parent_id,
        json_extract(reservation_json,'$.childSnapshot.session.sessionId') AS child_id,
        updated_at
      FROM workflow_nested_invocations
      WHERE abandoned_at IS NULL AND NOT \(settled)
      ORDER BY invocation_key
      """)
    return rows.map { row in
      guard let key = row["invocation_key"], let parent = row["parent_id"] else {
        return verdict(row["invocation_key"] ?? "", row["parent_id"], row["child_id"], "skipped",
          reason: "missing parentSessionId or invocationKey")
      }
      guard let updated = row["updated_at"].flatMap(TerminalRetentionMetadata.date) else {
        return verdict(key, parent, row["child_id"], "skipped", reason: "invalid updated_at")
      }
      return reconcile(row: row, key: key, parent: parent, child: row["child_id"], updatedAt: updated,
        db: db, sessionStoreRoot: sessionStoreRoot, abandonedAfter: abandonedAfter, apply: apply,
        parentActivityOverride: parentActivityOverrides[parent])
    }
  }

  private func reconcile(row: SQLiteRow, key: String, parent: String, child: String?, updatedAt: Date,
                         db: SQLiteDatabase, sessionStoreRoot: String, abandonedAfter: TimeInterval,
                         apply: Bool, parentActivityOverride: Date?) -> SessionNestedInvocationVerdict {
    let ids = Set([parent, child].compactMap { $0 }).sorted()
    var acquired: [String] = []
    do {
      for id in ids { try registry.acquire(sessionId: id, allowMessagesRetired: true); acquired.append(id) }
    } catch SessionExecutionLockError.alreadyRunning {
      for id in acquired { registry.release(sessionId: id) }
      return verdict(key, parent, child, "live")
    } catch {
      for id in acquired { registry.release(sessionId: id) }
      return verdict(key, parent, child, "skipped", reason: String(describing: error))
    }
    defer { for id in acquired { registry.release(sessionId: id) } }
    do {
      let cutoff = now().addingTimeInterval(-abandonedAfter)
      let parentStore = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot))
      guard let parentSnapshot = try? parentStore.load(sessionId: parent),
            [.completed, .failed, .cancelled].contains(parentSnapshot.session.status)
              || (parentActivityOverride != nil && parentSnapshot.session.status == .running) else {
        return verdict(key, parent, child, "skipped", reason: "parent is absent or nonterminal")
      }
      let parentActivity = parentActivityOverride ?? parentSnapshot.session.updatedAt
      guard updatedAt <= cutoff, parentActivity <= cutoff else {
        return verdict(key, parent, child, "recent")
      }
      var childSnapshot: WorkflowRuntimePersistenceSnapshot?
      if let child {
        do {
          childSnapshot = try parentStore.load(sessionId: child)
        } catch WorkflowRuntimePersistenceStoreError.notFound {
          childSnapshot = nil
        }
        if let status = childSnapshot?.session.status, ![.created, .completed, .failed, .cancelled].contains(status) {
          return verdict(key, parent, child, "skipped", reason: "child is nonterminal")
        }
      }
      guard apply else { return verdict(key, parent, child, "abandoned") }
      let settled = try TerminalRetentionIndexes.settled(in: db)
      try beforeTransaction()
      try db.transaction { transaction in
        let current = try transaction.query("""
          SELECT n.updated_at, p.session_status AS parent_status, p.updated_at AS parent_updated,
            c.session_status AS child_status
          FROM workflow_nested_invocations n
          LEFT JOIN workflow_runtime_snapshots p ON p.workflow_execution_id=json_extract(n.reservation_json,'$.parentSessionId')
          LEFT JOIN workflow_runtime_snapshots c ON c.workflow_execution_id=json_extract(n.reservation_json,'$.childSnapshot.session.sessionId')
          WHERE n.invocation_key=? AND n.abandoned_at IS NULL AND NOT \(settled)
          """, bindings: [.text(key)]).first
        let parentStatusIsEligible = current?["parent_status"].map { ["completed", "failed", "cancelled"].contains($0)
          || (parentActivityOverride != nil && $0 == "running") } ?? false
        let parentActivityToCheck = parentActivityOverride
          ?? current?["parent_updated"].flatMap(TerminalRetentionMetadata.date)
        guard let current, current["updated_at"] == row["updated_at"],
              parentStatusIsEligible, let parentActivityToCheck, parentActivityToCheck <= cutoff,
              let nestedUpdated = current["updated_at"].flatMap(TerminalRetentionMetadata.date), nestedUpdated <= cutoff,
              current["child_status"].map({ ["created", "completed", "failed", "cancelled"].contains($0) }) ?? true else {
          throw TerminalRetentionError.changedFamily
        }
        if apply {
          try transaction.execute("UPDATE workflow_nested_invocations SET abandoned_at=? WHERE invocation_key=? AND abandoned_at IS NULL",
            bindings: [.text(Self.timestamp(now())), .text(key)])
        }
      }
      if apply, var snapshot = childSnapshot, snapshot.session.status == .created, let child {
        let reason = "reservation abandoned; reconciled by riela session reconcile"
        snapshot.session.status = .cancelled
        snapshot.session.failureKind = .cancelled
        snapshot.session.failureReason = reason
        snapshot.session.failedAt = now()
        snapshot.session.updatedAt = now()
        let store = CLIWorkflowSessionStore(rootDirectory: sessionStoreRoot)
        do {
          var record = try store.load(sessionId: child)
          record.session = snapshot.session
          try store.save(record, runtimeSnapshot: snapshot)
        } catch CLIWorkflowSessionStoreError.notFound {
          try parentStore.save(snapshot)
        }
      }
      return verdict(key, parent, child, "abandoned", applied: apply)
    } catch {
      return verdict(key, parent, child, "skipped", reason: String(describing: error))
    }
  }

  private func verdict(_ key: String, _ parent: String?, _ child: String?, _ value: String,
                       applied: Bool = false, reason: String? = nil) -> SessionNestedInvocationVerdict {
    .init(invocationKey: key, parentSessionId: parent, childSessionId: child,
      verdict: value, applied: applied, reason: reason)
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
