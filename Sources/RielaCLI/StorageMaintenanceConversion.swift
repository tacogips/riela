import Foundation
import RielaCore
import RielaSQLite

struct StorageMaintenanceBudget: Equatable, Sendable {
  let conversions: Int
  let rowsExamined: Int
  let wallSeconds: TimeInterval
}

enum StorageMaintenanceProfile: Sendable {
  case runEnd, scheduled

  var total: StorageMaintenanceBudget {
    switch self {
    case .runEnd: .init(conversions: 16, rowsExamined: 256, wallSeconds: 2)
    case .scheduled: .init(conversions: 64, rowsExamined: 1024, wallSeconds: 10)
    }
  }

  var retryShare: StorageMaintenanceBudget {
    switch self {
    case .runEnd: .init(conversions: 8, rowsExamined: 128, wallSeconds: 1)
    case .scheduled: .init(conversions: 32, rowsExamined: 512, wallSeconds: 5)
    }
  }

  var vacuumPageCap: Int {
    switch self {
    case .runEnd: 4096
    case .scheduled: 65536
    }
  }
}

struct StorageMaintenancePassStats: Equatable, Sendable {
  var retryConversions = 0
  var retryRowsExamined = 0
  var forwardRowsExamined = 0
  var converted = 0
  var parked = 0
  var skippedBusy = 0
}

enum StorageMaintenanceConversion {
  private enum Kind: String, CaseIterable {
    case snapshots, cliRecords, nested

    var table: String {
      switch self {
      case .snapshots: "workflow_runtime_snapshots"
      case .cliRecords: "cli_workflow_sessions"
      case .nested: "workflow_nested_invocations"
      }
    }
    var key: String {
      switch self {
      case .snapshots: "workflow_execution_id"
      case .cliRecords: "session_id"
      case .nested: "invocation_key"
      }
    }
    var status: String {
      switch self {
      case .snapshots: "session_status"
      case .cliRecords: "status"
      case .nested: "NULL"
      }
    }
    var legacy: String {
      switch self {
      case .snapshots: "json_type(session_json,'$.executions')='array' AND json_type(session_json,'$._rielaExecutionStorage') IS NULL"
      case .cliRecords: "json_extract(record_json,'$.sessionStorage') IS NOT 'canonical'"
      case .nested: "json_type(reservation_json,'$.childSnapshotStorage') IS NULL"
      }
    }
  }

  static func run(sessionStoreRoot: String, stateDirectory: String, profile: StorageMaintenanceProfile,
                  now: @escaping () -> Date = Date.init,
                  observe: ((StorageMaintenancePassStats) -> Void)? = nil) -> [String] {
    var cursor = StorageMaintenanceCursor.read(stateDirectory: stateDirectory)
      ?? StorageMaintenanceCursor(queues: [:])
    for kind in Kind.allCases where cursor.queues[kind.rawValue] == nil {
      cursor.queues[kind.rawValue] = .init()
    }
    var stats = StorageMaintenancePassStats()
    var warnings: [String] = []
    defer { observe?(stats) }
    if Kind.allCases.allSatisfy({ kind in
      guard let queue = cursor.queues[kind.rawValue] else { return false }
      return queue.complete && queue.busy.isEmpty && queue.failed.isEmpty
    }) { return [] }
    let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: sessionStoreRoot)
    do {
      guard FileManager.default.fileExists(atPath: path) else {
        for kind in Kind.allCases { cursor.queues[kind.rawValue]?.complete = true }
        try cursor.write(stateDirectory: stateDirectory)
        return []
      }
      let db = try SQLiteDatabase.open(path: path, mode: .strictReadOnly, options: .readOnlyDefault)
      let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot))
      let cli = CLIWorkflowSessionStore(rootDirectory: sessionStoreRoot)
      let locks = SessionExecutionLockRegistry(sessionStoreRoot: sessionStoreRoot)
      let start = now()
      var attempted = Set<String>()
      func process(_ kind: Kind, _ key: String, _ retry: Bool) throws {
        guard var queue = cursor.queues[kind.rawValue] else { return }
        defer { cursor.queues[kind.rawValue] = queue }
        if retry { stats.retryRowsExamined += 1 } else { stats.forwardRowsExamined += 1 }
        guard !queue.parked.contains(where: { $0.key == key }) else { return }
        let rows = try db.query("SELECT (\(kind.legacy)) AS maintenance_legacy FROM \(kind.table) WHERE \(kind.key)=?", bindings: [.text(key)])
        guard let row = rows.first, row["maintenance_legacy"] == "1" else {
          queue.busy.removeAll { $0 == key }; queue.failed[key] = nil; return
        }
        func status(_ id: String) throws -> String? {
          if try db.tableExists("workflow_runtime_snapshots"),
             let value = try db.query("SELECT session_status FROM workflow_runtime_snapshots WHERE workflow_execution_id=?", bindings: [.text(id)]).first {
            return value["session_status"]
          }
          if try db.tableExists("cli_workflow_sessions") {
            return try db.query("SELECT status FROM cli_workflow_sessions WHERE session_id=?", bindings: [.text(id)]).first?["status"]
          }
          return nil
        }
        func familyIsTerminal(_ id: String) throws -> Bool {
          let hasSnapshots = try db.tableExists("workflow_runtime_snapshots")
          let hasCLI = try db.tableExists("cli_workflow_sessions")
          var root: String?
          if hasSnapshots {
            root = try db.query("SELECT root_session_id FROM workflow_runtime_snapshots WHERE workflow_execution_id=?",
              bindings: [.text(id)]).first?["root_session_id"]
          }
          if root == nil && hasCLI {
            root = try db.query("""
              SELECT coalesce(json_extract(record_json,'$.session.rootSessionId'),session_id) AS root
              FROM cli_workflow_sessions WHERE session_id=?
              """, bindings: [.text(id)]).first?["root"]
          }
          guard let root else { return true }
          if hasSnapshots {
            let rows = try db.query("""
              SELECT 1 AS found FROM workflow_runtime_snapshots WHERE root_session_id=?
                AND (session_status IS NULL OR session_status NOT IN ('completed','failed','cancelled')) LIMIT 1
              """, bindings: [.text(root)])
            if !rows.isEmpty { return false }
          }
          if hasCLI {
            let precedence = hasSnapshots ? "AND NOT EXISTS (SELECT 1 FROM workflow_runtime_snapshots s WHERE s.workflow_execution_id=c.session_id)" : ""
            let rows = try db.query("""
              SELECT 1 AS found FROM cli_workflow_sessions c
              WHERE coalesce(json_extract(c.record_json,'$.session.rootSessionId'),c.session_id)=?
                AND (c.status IS NULL OR c.status NOT IN ('completed','failed','cancelled')) \(precedence) LIMIT 1
              """, bindings: [.text(root)])
            if !rows.isEmpty { return false }
          }
          return true
        }
        func markBusy() {
          stats.skippedBusy += 1
          if !queue.busy.contains(key) {
            if queue.busy.count < 256 { queue.busy.append(key) } else { queue.rescanNeeded = true }
          }
          queue.failed[key] = nil
        }
        let ids: [String]
        if kind == .nested {
          let values = try db.query("SELECT \(TerminalRetentionIndexes.parent) AS parent, \(TerminalRetentionIndexes.child) AS child FROM \(kind.table) WHERE invocation_key=?", bindings: [.text(key)]).first
          guard let parent = values?["parent"] else {
            queue.busy.removeAll { $0 == key }; queue.failed[key] = nil; return
          }
          ids = [parent] + (values?["child"].map { [$0] } ?? [])
        } else { ids = [key] }
        for (index, id) in ids.enumerated() {
          let value = try status(id)
          if value == nil && kind == .nested && index > 0 { continue }
          guard let value, ["completed", "failed", "cancelled"].contains(value) else {
            queue.busy.removeAll { $0 == key }; queue.failed[key] = nil; return
          }
        }
        guard try familyIsTerminal(ids[0]) else { markBusy(); return }
        var acquired: [String] = []
        defer { for id in acquired { locks.release(sessionId: id) } }
        do {
          for id in Set(ids).sorted() {
            try locks.acquire(sessionId: id, allowMessagesRetired: true)
            acquired.append(id)
          }
          for (index, id) in ids.enumerated() {
            let value = try status(id)
            if value == nil && kind == .nested && index > 0 { continue }
            guard let value, ["completed", "failed", "cancelled"].contains(value) else {
              queue.busy.removeAll { $0 == key }; queue.failed[key] = nil; return
            }
          }
          guard try familyIsTerminal(ids[0]) else { markBusy(); return }
          let converted: Bool
          switch kind {
          case .snapshots: converted = try runtime.convertLegacySession(sessionId: key)
          case .cliRecords: converted = try cli.convertLegacyRecord(sessionId: key)
          case .nested: converted = try runtime.convertLegacyNestedInvocation(invocationKey: key)
          }
          queue.busy.removeAll { $0 == key }; queue.failed[key] = nil
          if converted { stats.converted += 1; if retry { stats.retryConversions += 1 } }
        } catch {
          if let lockError = error as? SessionExecutionLockError {
            switch lockError {
            case .alreadyRunning, .unavailable:
              markBusy()
              return
            case .retiredSession, .messagesRetired:
              queue.busy.removeAll { $0 == key }; queue.failed[key] = nil; return
            case .invalidSessionId: break
            }
          }
          queue.busy.removeAll { $0 == key }
          let count = (queue.failed[key] ?? 0) + 1
          let invalid: Bool
          if case .invalidSessionId = error as? SessionExecutionLockError { invalid = true } else { invalid = false }
          if invalid || count >= 3 || (queue.failed[key] == nil && queue.failed.count >= 256) {
            queue.failed[key] = nil
            var bytes = Array(String(describing: error).utf8.prefix(512))
            while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
            let detail = String(bytes: bytes, encoding: .utf8) ?? ""
            if queue.parked.count < 256 { queue.parked.append(.init(key: key, error: detail)) } else { queue.parkedOverflow += 1 }
            stats.parked += 1
            warnings.append("riela retention warning: legacy \(kind.rawValue) row \(key) parked after \(count) failed conversions: \(detail); run riela storage compact --apply")
          } else { queue.failed[key] = count }
        }
      }
      for busy in [true, false] {
        for kind in Kind.allCases {
          guard try db.tableExists(kind.table), let queue = cursor.queues[kind.rawValue] else { continue }
          let keys = busy ? queue.busy : queue.failed.keys.sorted()
          for key in keys {
            if stats.retryRowsExamined >= profile.retryShare.rowsExamined || stats.retryConversions >= profile.retryShare.conversions || now().timeIntervalSince(start) >= profile.retryShare.wallSeconds { break }
            let token = kind.rawValue + "\0" + key
            guard attempted.insert(token).inserted else { continue }
            try process(kind, key, true)
          }
        }
      }
      for (position, kind) in Kind.allCases.enumerated() {
        guard try db.tableExists(kind.table) else { cursor.queues[kind.rawValue]?.complete = true; continue }
        let reserved = Kind.allCases.dropFirst(position + 1).filter { cursor.queues[$0.rawValue]?.complete == false }.count
        var first = true
        while let queue = cursor.queues[kind.rawValue], !queue.complete {
          if !first && (stats.converted >= profile.total.conversions - reserved ||
            stats.retryRowsExamined + stats.forwardRowsExamined >= profile.total.rowsExamined ||
            now().timeIntervalSince(start) >= profile.total.wallSeconds) { break }
          let selection = "SELECT \(kind.key) AS k, \(kind.status) AS maintenance_status, " +
            "(\(kind.legacy)) AS maintenance_legacy FROM \(kind.table) WHERE \(kind.key)>? ORDER BY \(kind.key) LIMIT 1"
          let rows = try db.query(selection, bindings: [.text(queue.after ?? "")])
          guard let key = rows.first?["k"] else {
            cursor.queues[kind.rawValue]?.complete = !queue.rescanNeeded
            if queue.rescanNeeded { cursor.queues[kind.rawValue]?.after = nil; cursor.queues[kind.rawValue]?.rescanNeeded = false }
            break
          }
          first = false
          if attempted.insert(kind.rawValue + "\0" + key).inserted {
            try process(kind, key, false)
          } else { stats.forwardRowsExamined += 1 }
          cursor.queues[kind.rawValue]?.after = key
        }
      }
      try cursor.write(stateDirectory: stateDirectory)
    } catch {
      warnings.append("riela retention warning: legacy conversion: \(error)")
      do { try cursor.write(stateDirectory: stateDirectory) } catch {
        warnings.append("riela retention warning: legacy conversion cursor: \(error)")
      }
    }
    return warnings
  }
}
