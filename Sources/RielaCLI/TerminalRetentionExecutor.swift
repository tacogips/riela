import Foundation
import RielaCore
import RielaSQLite

struct TerminalRetentionReport: Codable, Equatable {
  var dryRun: Bool
  var selectedFamilies: [String]
  var removedSessionCount: Int
  var protectedFamilies: [String: String]
  var pendingCleanupCount: Int
  var beforePayloadBytes: Int64
  var remainingPayloadBytes: Int64
  var capAchieved: Bool
  var deferredFamilyCount: Int = 0
}

struct TerminalRetentionExecutor {
  var clock: () -> Date = Date.init
  // Deterministic fault/race injection; production uses the no-op default.
  var beforeTransaction: () throws -> Void = {}
  var beforeSecondaryCleanup: () throws -> Void = {}

  func run(paths: TerminalRetentionPaths, workflows: Set<String>, retentionHours: Int,
           maxPayloadBytes: Int64, dryRun: Bool, maxFamilies: Int? = nil) throws -> TerminalRetentionReport {
    guard maxFamilies == nil || (1...10_000).contains(maxFamilies ?? 0) else {
      throw TerminalRetentionPlanError.invalidPolicyOrMetadata
    }
    _ = try TerminalRetentionPlan.make(sessions: [], workflows: workflows, now: clock(),
      retentionHours: retentionHours, maxPayloadBytes: maxPayloadBytes)
    let path = try TerminalRetentionPaths.checkedDatabase(CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: paths.sessionRoot))
    guard FileManager.default.fileExists(atPath: path) else {
      _ = try TerminalRetentionPlan.make(sessions: [], workflows: workflows, now: clock(),
        retentionHours: retentionHours, maxPayloadBytes: maxPayloadBytes)
      return .init(dryRun: dryRun, selectedFamilies: [], removedSessionCount: 0, protectedFamilies: [:],
        pendingCleanupCount: 0, beforePayloadBytes: 0, remainingPayloadBytes: 0, capAchieved: true)
    }
    let db = try SQLiteDatabase.open(path: path, mode: dryRun ? .strictReadOnly : .readWriteCreate, options: dryRun ? .readOnlyDefault : .writableDefault)
    guard try db.tableExists("workflow_runtime_snapshots") || db.tableExists("cli_workflow_sessions") else {
      throw TerminalRetentionError.foreignDatabase
    }
    if !dryRun { try TerminalRetentionIndexes.prepare(db) }
    let now = clock()
    let original = try metadata(db, paths: paths)
    let plan = try TerminalRetentionPlan.make(sessions: original, workflows: workflows, now: now,
      retentionHours: retentionHours, maxPayloadBytes: maxPayloadBytes)
    var remainingFamilies = maxFamilies ?? Int.max
    let selected = Array(plan.selected.prefix(remainingFamilies))
    var report = TerminalRetentionReport(dryRun: dryRun, selectedFamilies: selected.map(\.rootId),
      removedSessionCount: 0, protectedFamilies: Dictionary(uniqueKeysWithValues: plan.protected.map { ($0.rootId, $0.protection ?? "unknown") }),
      pendingCleanupCount: 0, beforePayloadBytes: plan.beforeBytes,
      remainingPayloadBytes: plan.beforeBytes - selected.reduce(Int64(0)) { $0 + $1.payloadBytes },
      capAchieved: plan.beforeBytes - selected.reduce(Int64(0)) { $0 + $1.payloadBytes } <= maxPayloadBytes)
    report.deferredFamilyCount = plan.selected.count - selected.count
    var pendingRoots: Set<String> = []
    if try db.tableExists("session_retention_tombstones") {
      for row in try pendingRows(db) where workflows.contains(row["workflow_id"] ?? "") {
        if let root = row["root_id"] { pendingRoots.insert(root) }
        let bytes = row["payload_bytes"].flatMap(Int64.init) ?? 0
        report.pendingCleanupCount += 1
        report.beforePayloadBytes = try TerminalRetentionMetadata.adding(report.beforePayloadBytes, bytes)
        report.remainingPayloadBytes = try TerminalRetentionMetadata.adding(report.remainingPayloadBytes, bytes)
      }
      report.capAchieved = report.remainingPayloadBytes <= maxPayloadBytes && report.pendingCleanupCount == 0
    }
    if dryRun {
      let available = max(0, remainingFamilies - min(remainingFamilies, pendingRoots.count))
      let admitted = Array(plan.selected.prefix(available))
      report.selectedFamilies = admitted.map(\.rootId)
      report.deferredFamilyCount = plan.selected.count - admitted.count + max(0, pendingRoots.count - remainingFamilies)
      report.remainingPayloadBytes = report.beforePayloadBytes - admitted.reduce(Int64(0)) { $0 + $1.payloadBytes }
      report.capAchieved = report.remainingPayloadBytes <= maxPayloadBytes && report.pendingCleanupCount == 0
      return report
    }
    try ensureTombstones(db)
    try ensureSessionRetentionTriggers(db)
    let locks = SessionExecutionLockRegistry(sessionStoreRoot: paths.sessionRoot)
    // Recover secondary copies left by a prior interrupted cleanup first.
    report.protectedFamilies.merge(try finishPending(db: db, locks: locks, paths: paths, workflows: workflows,
      remainingFamilies: &remainingFamilies, deferred: &report.deferredFamilyCount)) { _, new in new }
    let admitted = Array(plan.selected.prefix(remainingFamilies))
    report.selectedFamilies = admitted.map(\.rootId)
    // Pending recovery shares the same family budget with new admission.
    report.deferredFamilyCount += selected.count - admitted.count
    for family in admitted {
      var acquired: [String] = []
      defer { for id in acquired { locks.release(sessionId: id) } }
      do {
        for id in family.ids { try locks.acquire(sessionId: id); acquired.append(id) }
      } catch {
        report.protectedFamilies[family.rootId] = "executionLocked"
        continue
      }
      try beforeTransaction()
      do {
        try db.transaction { db in
          let current = try metadata(db, paths: paths)
          let currentPlan = try TerminalRetentionPlan.make(sessions: current, workflows: workflows, now: now,
            retentionHours: retentionHours, maxPayloadBytes: maxPayloadBytes)
          guard currentPlan.selected.contains(family),
                current.filter({ family.ids.contains($0.id) }) == original.filter({ family.ids.contains($0.id) }) else {
            throw TerminalRetentionError.changedFamily
          }
          _ = try db.query("PRAGMA secure_delete=ON")
          for id in family.ids {
            guard let row = current.first(where: { $0.id == id }) else { throw TerminalRetentionError.changedFamily }
            try db.execute("""
              INSERT INTO session_retention_tombstones(session_id,workflow_id,root_id,pruned_at,artifact_root,memory_root,payload_bytes,cleanup_pending)
              VALUES(?,?,?,?,?,?,?,1)
              """, bindings: [.text(id), .text(row.workflowId), .text(family.rootId), .text(Self.timestamp(now)),
                .text(paths.artifactRoot), .text(paths.memoryRoot), .int(row.payloadBytes)])
            try TerminalRetentionSecondary.deleteMessages(id: id, db: db)
            if try db.tableExists("workflow_runtime_snapshots") {
              try db.execute("DELETE FROM workflow_runtime_snapshots WHERE workflow_execution_id=?", bindings: [.text(id)])
            }
            if try db.tableExists("cli_workflow_sessions") {
              try db.execute("DELETE FROM cli_workflow_sessions WHERE session_id=?", bindings: [.text(id)])
            }
            if try db.tableExists("loop_baselines") {
              try db.execute("DELETE FROM loop_baselines WHERE session_id=?", bindings: [.text(id)])
            }
            if try db.tableExists("workflow_nested_invocations") {
              try db.execute("DELETE FROM workflow_nested_invocations WHERE json_extract(reservation_json,'$.childSnapshot.session.sessionId')=?", bindings: [.text(id)])
            }
          }
        }
      } catch TerminalRetentionError.changedFamily {
        report.protectedFamilies[family.rootId] = "changedDuringAdmission"
        continue
      }
      report.removedSessionCount += family.ids.count
      try beforeSecondaryCleanup()
      do { try cleanup(ids: family.ids, db: db, paths: paths) } catch TerminalRetentionError.secondaryProtected {
        report.protectedFamilies[family.rootId] = "secondaryOwnershipChanged"
      }
    }
    try TerminalRetentionSecondary.reclaimArtifacts(paths)
    try TerminalRetentionSecondary.reclaim(db)
    let final = try TerminalRetentionPlan.make(sessions: metadata(db, paths: paths), workflows: workflows, now: now,
      retentionHours: retentionHours, maxPayloadBytes: maxPayloadBytes)
    report.remainingPayloadBytes = final.beforeBytes
    report.pendingCleanupCount = 0
    for row in try pendingRows(db) where workflows.contains(row["workflow_id"] ?? "") {
      report.pendingCleanupCount += 1
      report.remainingPayloadBytes = try TerminalRetentionMetadata.adding(report.remainingPayloadBytes, row["payload_bytes"].flatMap(Int64.init) ?? 0)
    }
    report.capAchieved = report.remainingPayloadBytes <= maxPayloadBytes && report.pendingCleanupCount == 0
    return report
  }

  private func metadata(_ db: SQLiteDatabase, paths: TerminalRetentionPaths) throws -> [TerminalRetentionSession] {
    try TerminalRetentionSecondary.decorate(TerminalRetentionMetadata.sessions(db), paths: paths)
  }

  private func pendingRows(_ db: SQLiteDatabase) throws -> [SQLiteRow] {
    try db.query("SELECT root.workflow_id,t.root_id,t.payload_bytes FROM session_retention_tombstones t JOIN session_retention_tombstones root ON root.session_id=t.root_id WHERE t.cleanup_pending=1")
  }

  private func ensureTombstones(_ db: SQLiteDatabase) throws {
    try db.execute("""
      CREATE TABLE IF NOT EXISTS session_retention_tombstones(
        session_id TEXT PRIMARY KEY,workflow_id TEXT NOT NULL,root_id TEXT NOT NULL,pruned_at TEXT NOT NULL,
        artifact_root TEXT NOT NULL,memory_root TEXT NOT NULL,payload_bytes INTEGER NOT NULL,cleanup_pending INTEGER NOT NULL)
      """)
  }

  private func finishPending(db: SQLiteDatabase, locks: SessionExecutionLockRegistry,
                             paths: TerminalRetentionPaths, workflows: Set<String>, remainingFamilies: inout Int,
                             deferred: inout Int) throws -> [String: String] {
    var protected: [String: String] = [:]
    let rows = try db.query("""
      SELECT t.session_id,t.root_id,root.workflow_id,t.artifact_root,t.memory_root FROM session_retention_tombstones t
      JOIN session_retention_tombstones root ON root.session_id=t.root_id
      WHERE t.cleanup_pending=1 ORDER BY t.session_id
      """)
    var attemptedRoots: Set<String> = [], deferredRoots: Set<String> = []
    for row in rows where workflows.contains(row["workflow_id"] ?? "") {
      guard let id = row["session_id"], row["artifact_root"] == paths.artifactRoot, row["memory_root"] == paths.memoryRoot else {
        throw TerminalRetentionError.pendingRootsMismatch
      }
      guard let root = row["root_id"] else { throw TerminalRetentionError.pendingRootsMismatch }
      if !attemptedRoots.contains(root) {
        guard remainingFamilies > 0 else { deferredRoots.insert(root); continue }
        attemptedRoots.insert(root)
        remainingFamilies -= 1
      }
      try locks.acquire(sessionId: id, allowRetired: true)
      defer { locks.release(sessionId: id) }
      do { try cleanup(ids: [id], db: db, paths: paths) } catch TerminalRetentionError.secondaryProtected {
        protected[row["root_id"] ?? id] = "secondaryOwnershipChanged"
      }
    }
    deferred += deferredRoots.count
    return protected
  }

  private func cleanup(ids: [String], db: SQLiteDatabase, paths: TerminalRetentionPaths) throws {
    var workflows: [String: String] = [:]
    for id in ids {
      guard let row = try db.query("SELECT workflow_id,artifact_root,memory_root FROM session_retention_tombstones WHERE session_id=?",
        bindings: [.text(id)]).first, let workflow = row["workflow_id"],
        row["artifact_root"] == paths.artifactRoot, row["memory_root"] == paths.memoryRoot else {
        throw TerminalRetentionError.pendingRootsMismatch
      }
      workflows[id] = workflow
    }
    try TerminalRetentionSecondary.clean(ids: ids, workflows: workflows, paths: paths)
    try db.transaction { db in
      for id in ids { try db.execute("UPDATE session_retention_tombstones SET cleanup_pending=0,payload_bytes=0 WHERE session_id=?", bindings: [.text(id)]) }
    }
  }

  private static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
