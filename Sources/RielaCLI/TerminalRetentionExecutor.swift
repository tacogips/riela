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
  var reclamation: [RetentionReclamationResult]
  var deferredFamilyCount: Int = 0
  var deferredCompaction: Bool = false
  var remainingDatabaseBytes: Int64?
}

struct TerminalRetentionCategoryPolicy: Equatable, Sendable {
  var maxAge: TimeInterval?
  var maxBytes: Int64?
}

enum TerminalRetentionMessageMode: Equatable, Sendable {
  case followResults
  case keepForever
  case independent(TerminalRetentionCategoryPolicy)
}

struct TerminalRetentionPolicyReport: Equatable, Sendable {
  var results: RetentionCategoryReport
  var messages: RetentionCategoryReport
  var orphanLocks: SessionExecutionLockRegistry.OrphanLockRemovalResult?
  var reclamation: [RetentionReclamationResult]
}

struct TerminalRetentionExecutor {
  var clock: () -> Date = Date.init
  // Deterministic fault/race injection; production uses the no-op default.
  var beforeTransaction: () throws -> Void = {}
  var beforeSecondaryCleanup: () throws -> Void = {}
  var beforeFinalCompaction: () throws -> Void = {}
  // One reclaimer for every SQLite file this executor touches, so callers can inject free-space probes.
  var reclaimer = RetentionSQLiteReclaimer()

  private struct OrphanMessageSet {
    var id: String
    var workflowId: String
    var createdAt: Date
    var bytes: Int64
  }

  private enum MessageCandidate {
    case family(TerminalRetentionFamily)
    case orphan(OrphanMessageSet)

    var date: Date {
      switch self {
      case .family(let value): value.updatedAt
      case .orphan(let value): value.createdAt
      }
    }

    var id: String {
      switch self {
      case .family(let value): value.rootId
      case .orphan(let value): value.id
      }
    }

    var bytes: Int64 {
      switch self {
      case .family(let value): value.messageBytes
      case .orphan(let value): value.bytes
      }
    }
  }

  func runPolicy(paths: TerminalRetentionPaths, keepWorkflowIds: Set<String>,
                 results: TerminalRetentionCategoryPolicy?, resultsState: RielaRetentionCategoryState,
                 messages: TerminalRetentionMessageMode, messagesState: RielaRetentionCategoryState,
                 dryRun: Bool, reclamationMode: RetentionReclamationMode = .automatic,
                 familyLimit: Int = 500) throws -> TerminalRetentionPolicyReport {
    let path = try TerminalRetentionPaths.checkedDatabase(
      CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: paths.sessionRoot))
    guard FileManager.default.fileExists(atPath: path) else {
      return .init(results: .inactive(resultsState), messages: .inactive(messagesState), orphanLocks: nil, reclamation: [])
    }
    let db = try SQLiteDatabase.open(path: path, mode: dryRun ? .strictReadOnly : .readWriteCreate,
      options: dryRun ? .readOnlyDefault : .writableDefault)
    guard try db.tableExists("workflow_runtime_snapshots") || db.tableExists("cli_workflow_sessions") else {
      throw TerminalRetentionError.foreignDatabase
    }
    guard familyLimit > 0 else { throw TerminalRetentionPlanError.invalidPolicyOrMetadata }
    let now = clock()
    let original = try metadata(db, paths: paths)
    var resultReport = results.map { policy in
      makeCategoryReport(state: resultsState, policy: policy, before: 0)
    } ?? .inactive(resultsState)
    var messageReport: RetentionCategoryReport
    if case .independent(let policy) = messages {
      messageReport = makeCategoryReport(state: messagesState, policy: policy, before: 0)
    } else {
      messageReport = .inactive(messagesState)
    }
    guard !dryRun else {
      if let results {
        let plan = try TerminalRetentionPlan.make(sessions: original, scope: .allExcept(keepWorkflowIds), now: now,
          maxAge: results.maxAge, maxBytes: results.maxBytes, bytes: .results, familyLimit: familyLimit)
        resultReport = try dryResultReport(plan: plan, policy: results, state: resultsState,
          familyLimit: familyLimit, db: db, paths: paths)
      }
      if case .independent(let policy) = messages {
        let plan = try TerminalRetentionPlan.make(sessions: original, scope: .allExcept([]), now: now,
          maxAge: policy.maxAge, maxBytes: policy.maxBytes, bytes: .messages, familyLimit: familyLimit)
        let orphans = try orphanMessageSets(db)
        messageReport = messagesReport(plan: plan, orphans: orphans, policy: policy, state: messagesState,
          now: now, familyLimit: familyLimit, dryRun: true)
      }
      return .init(results: resultReport, messages: messageReport, orphanLocks: nil, reclamation: [])
    }
    try ensureTombstones(db)
    try ensureMessageRetentionTombstones(db)
    try ensureSessionRetentionTriggers(db)
    let locks = SessionExecutionLockRegistry(sessionStoreRoot: paths.sessionRoot)
    var reclamations: [RetentionReclamationResult] = []
    var protected: [String: String] = [:]
    var pendingBudget = familyLimit, deferredPending = 0
    protected.merge(try finishPending(db: db, locks: locks, paths: paths, workflows: [],
      remainingFamilies: &pendingBudget, deferred: &deferredPending, mode: reclamationMode)) { _, new in new }

    if let policy = results {
      let plan = try TerminalRetentionPlan.make(sessions: original, scope: .allExcept(keepWorkflowIds), now: now,
        maxAge: policy.maxAge, maxBytes: policy.maxBytes, bytes: .results, familyLimit: familyLimit)
      resultReport = report(plan: plan, state: resultsState, policy: policy, dryRun: false)
      resultReport.protected = reasonCounts(plan.protected, extra: protected)
      let admitted = Array(plan.selected.prefix(pendingBudget))
      for family in admitted {
        let acquired = acquire(family.ids, locks: locks, allowMessagesRetired: true)
        guard acquired.ok else {
          protected[family.rootId] = acquired.reason ?? "executionLocked"
          continue
        }
        defer { for id in family.ids { locks.release(sessionId: id) } }
        try beforeTransaction()
        do {
          try db.transaction { transactionDB in
            let current = try metadata(transactionDB, paths: paths)
            let currentPlan = try TerminalRetentionPlan.make(sessions: current, scope: .allExcept(keepWorkflowIds), now: now,
              maxAge: policy.maxAge, maxBytes: policy.maxBytes, bytes: .results, familyLimit: familyLimit)
            guard currentPlan.selected.contains(family),
                  current.filter({ family.ids.contains($0.id) }) == original.filter({ family.ids.contains($0.id) }) else {
              throw TerminalRetentionError.changedFamily
            }
            _ = try transactionDB.query("PRAGMA secure_delete=ON")
            for id in family.ids {
              guard let row = current.first(where: { $0.id == id }) else { throw TerminalRetentionError.changedFamily }
              try insertResultsTombstone(id: id, row: row, family: family, paths: paths, now: now, db: transactionDB)
              if case .followResults = messages { try TerminalRetentionSecondary.deleteMessages(id: id, db: transactionDB) }
              try deleteResultRows(id, db: transactionDB)
            }
            try deleteNestedInvocationRows(parentIds: family.ids, db: transactionDB)
            try deleteFamilyPayloads(rootId: family.rootId, db: transactionDB)
          }
        } catch TerminalRetentionError.changedFamily {
          protected[family.rootId] = "changedDuringAdmission"
          continue
        }
        resultReport.removedCount += 1
        resultReport.removedBytes = try TerminalRetentionMetadata.adding(resultReport.removedBytes, family.payloadBytes)
        if case .followResults = messages {
          messageReport.removedCount += 1
          messageReport.removedBytes = try TerminalRetentionMetadata.adding(messageReport.removedBytes, family.messageBytes)
        }
        reclamations += try cleanupPolicyFamily(family, db: db, paths: paths,
          mode: reclamationMode, protected: &protected)
      }
      let final = try TerminalRetentionPlan.make(sessions: metadata(db, paths: paths), scope: .allExcept(keepWorkflowIds), now: now,
        maxAge: policy.maxAge, maxBytes: policy.maxBytes, bytes: .results, familyLimit: familyLimit)
      let pending = try pendingRows(db)
      var pendingBytes: Int64 = 0
      for row in pending {
        pendingBytes = try TerminalRetentionMetadata.adding(pendingBytes, row["payload_bytes"].flatMap(Int64.init) ?? 0)
      }
      resultReport.remainingBytes = try TerminalRetentionMetadata.adding(final.beforeBytes, pendingBytes)
      resultReport.capAchieved = policy.maxBytes.map { resultReport.remainingBytes <= $0 && pending.isEmpty } ?? nil
      resultReport.pendingCleanupCount = pending.count
      resultReport.workLimitReached = plan.workLimitReached || deferredPending > 0 || admitted.count < plan.selected.count
      resultReport.selectedBytes = admitted.reduce(0) { $0 + $1.payloadBytes }
      resultReport.selectedCount = admitted.count
      resultReport.protected = reasonCounts(plan.protected, extra: protected)
      resultReport.protectedFamilies = protectedList(plan.protected, extra: protected)
    }

    if case .independent(let policy) = messages {
      let sessionsNow = try metadata(db, paths: paths)
      let plan = try TerminalRetentionPlan.make(sessions: sessionsNow, scope: .allExcept([]), now: now,
        maxAge: policy.maxAge, maxBytes: policy.maxBytes, bytes: .messages, familyLimit: familyLimit)
      let orphans = try orphanMessageSets(db)
      messageReport = messagesReport(plan: plan, orphans: orphans, policy: policy, state: messagesState,
        now: now, familyLimit: familyLimit, dryRun: false)
      let candidates = selectMessageCandidates(plan: plan, orphans: orphans, policy: policy, now: now, familyLimit: familyLimit)
      for candidate in candidates.values {
        switch candidate {
        case .family(let family):
          let acquired = acquire(family.ids, locks: locks, allowMessagesRetired: false)
          guard acquired.ok else { addProtection(acquired.reason ?? "executionLocked", family.rootId, to: &messageReport); continue }
          defer { for id in family.ids { locks.release(sessionId: id) } }
          do {
            try db.transaction { transactionDB in
              let current = try metadata(transactionDB, paths: paths)
              let currentPlan = try TerminalRetentionPlan.make(sessions: current, scope: .allExcept([]), now: now,
                maxAge: policy.maxAge, maxBytes: policy.maxBytes, bytes: .messages, familyLimit: familyLimit)
              guard currentPlan.eligible.contains(where: { sameFamily($0, family) }),
                    current.filter({ family.ids.contains($0.id) }) == sessionsNow.filter({ family.ids.contains($0.id) }) else {
                throw TerminalRetentionError.changedFamily
              }
              _ = try transactionDB.query("PRAGMA secure_delete=ON")
              for id in family.ids {
                guard let row = current.first(where: { $0.id == id }) else { throw TerminalRetentionError.changedFamily }
                try transactionDB.execute("INSERT OR REPLACE INTO session_message_retention_tombstones VALUES(?,?,?,?)",
                  bindings: [.text(id), .text(row.workflowId), .text(Self.timestamp(now)), .int(row.messageBytes)])
                try TerminalRetentionSecondary.deleteMessages(id: id, db: transactionDB)
              }
            }
            messageReport.removedCount += 1
            messageReport.removedBytes = try TerminalRetentionMetadata.adding(messageReport.removedBytes, family.messageBytes)
          } catch TerminalRetentionError.changedFamily { addProtection("changedDuringAdmission", family.rootId, to: &messageReport) }
        case .orphan(let orphan):
          do {
            try locks.acquire(sessionId: orphan.id, allowRetired: true, allowMessagesRetired: true)
          } catch {
            addProtection("executionLocked", orphan.id, to: &messageReport)
            continue
          }
          defer { locks.release(sessionId: orphan.id) }
          try db.transaction { transactionDB in
            guard try !transactionDB.query("SELECT 1 FROM session_retention_tombstones WHERE session_id=? LIMIT 1",
              bindings: [.text(orphan.id)]).isEmpty else { throw TerminalRetentionError.changedFamily }
            try TerminalRetentionSecondary.deleteMessages(id: orphan.id, db: transactionDB)
          }
          messageReport.removedCount += 1
          messageReport.orphanSessionCount += 1
          messageReport.removedBytes = try TerminalRetentionMetadata.adding(messageReport.removedBytes, orphan.bytes)
        }
      }
      let remainingSessions = try metadata(db, paths: paths)
      let remainingFamilies = try TerminalRetentionPlan.make(sessions: remainingSessions, scope: .allExcept([]), now: now,
        maxAge: policy.maxAge, maxBytes: policy.maxBytes, bytes: .messages, familyLimit: familyLimit)
      let remainingOrphans = try orphanMessageSets(db)
      messageReport.remainingBytes = remainingFamilies.beforeBytes + remainingOrphans.reduce(0) { $0 + $1.bytes }
      messageReport.beforeBytes = plan.beforeBytes + orphans.reduce(0) { $0 + $1.bytes }
      messageReport.capAchieved = policy.maxBytes.map { messageReport.remainingBytes <= $0 } ?? nil
      messageReport.workLimitReached = candidates.workLimitReached
      messageReport.protectedFamilies = protectedList(plan.protected, extra: [:])
      messageReport.selectedCount = candidates.values.count
      messageReport.selectedBytes = candidates.values.reduce(0) { $0 + $1.bytes }
    }
    // The runtime database itself is reclaimed once by finalize(), after orphan-lock cleanup.
    return .init(results: resultReport, messages: messageReport, orphanLocks: nil, reclamation: reclamations)
  }

  func finalize(paths: TerminalRetentionPaths, report: inout TerminalRetentionPolicyReport,
                mode: RetentionReclamationMode, dryRun: Bool, orphanLockLimit: Int = 2000) {
    let locks = SessionExecutionLockRegistry(sessionStoreRoot: paths.sessionRoot)
    let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: paths.sessionRoot)
    let removal = removeOrphanLocks(locks, path: path, limit: orphanLockLimit, dryRun: dryRun)
    report.orphanLocks = removal
    guard !dryRun else { return }
    report.reclamation.append(reclaimer.reclaim(databasePath: path, mode: mode))
  }

  // Close this shared read connection before the final reclaim measures files.
  private func removeOrphanLocks(
    _ locks: SessionExecutionLockRegistry, path: String, limit: Int, dryRun: Bool
  ) -> SessionExecutionLockRegistry.OrphanLockRemovalResult {
    let lockDatabase = try? SQLiteDatabase.open(path: path, mode: .strictReadOnly, options: .readOnlyDefault)
    return locks.removeOrphanLocks(limit: limit, dryRun: dryRun) { id in
      guard let db = lockDatabase else { return false }
      if try db.tableExists("session_retention_tombstones"),
         try !db.query("SELECT 1 FROM session_retention_tombstones WHERE session_id=? LIMIT 1", bindings: [.text(id)]).isEmpty { return false }
      for (table, column) in [("cli_workflow_sessions", "session_id"), ("workflow_runtime_snapshots", "workflow_execution_id")] where try db.tableExists(table) {
        if try !db.query("SELECT 1 FROM \(table) WHERE \(column)=? LIMIT 1", bindings: [.text(id)]).isEmpty { return true }
      }
      return false
    }
  }

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
        pendingCleanupCount: 0, beforePayloadBytes: 0, remainingPayloadBytes: 0, capAchieved: true, reclamation: [])
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
      capAchieved: plan.beforeBytes - selected.reduce(Int64(0)) { $0 + $1.payloadBytes } <= maxPayloadBytes,
      reclamation: [])
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
                .text(paths.artifactRoot ?? ""), .text(paths.memoryRoot ?? ""), .int(row.payloadBytes)])
            try TerminalRetentionSecondary.deleteMessages(id: id, db: db)
            if try db.tableExists("workflow_runtime_executions") {
              try db.execute("DELETE FROM workflow_runtime_executions WHERE workflow_execution_id=?", bindings: [.text(id)])
            }
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
              try deleteNestedInvocationRows(childId: id, db: db)
            }
          }
          try deleteNestedInvocationRows(parentIds: family.ids, db: db)
          try deleteFamilyPayloads(rootId: family.rootId, db: db)
        }
      } catch TerminalRetentionError.changedFamily {
        report.protectedFamilies[family.rootId] = "changedDuringAdmission"
        continue
      }
      report.removedSessionCount += family.ids.count
      try beforeSecondaryCleanup()
      do { report.reclamation += try cleanup(ids: family.ids, db: db, paths: paths, mode: .manual) } catch TerminalRetentionError.secondaryProtected {
        report.protectedFamilies[family.rootId] = "secondaryOwnershipChanged"
      }
    }
    // Only explicitly bounded work may defer compaction. Every deleted byte is
    // securely zeroed and checkpointed before returning, even when compaction waits.
    let outstanding = try TerminalRetentionPlan.make(sessions: metadata(db, paths: paths), workflows: workflows,
      now: now, retentionHours: retentionHours, maxPayloadBytes: maxPayloadBytes)
    let hasPendingCleanup = !(try pendingRows(db)).filter { workflows.contains($0["workflow_id"] ?? "") }.isEmpty
    report.deferredCompaction = maxFamilies != nil && (!outstanding.selected.isEmpty || hasPendingCleanup)
    if report.deferredCompaction {
      try TerminalRetentionSecondary.checkpointArtifacts(paths)
      try TerminalRetentionSecondary.checkpoint(db)
    } else {
      try beforeFinalCompaction()
      if let artifacts = try TerminalRetentionSecondary.reclaimArtifacts(paths, mode: .manual, reclaimer: reclaimer) {
        report.reclamation.append(artifacts)
      }
      report.reclamation.append(reclaimer.reclaim(databasePath: path, mode: .manual))
    }
    let final = try TerminalRetentionPlan.make(sessions: metadata(db, paths: paths), workflows: workflows, now: now,
      retentionHours: retentionHours, maxPayloadBytes: maxPayloadBytes)
    report.remainingPayloadBytes = final.beforeBytes
    report.pendingCleanupCount = 0
    for row in try pendingRows(db) where workflows.contains(row["workflow_id"] ?? "") {
      report.pendingCleanupCount += 1
      report.remainingPayloadBytes = try TerminalRetentionMetadata.adding(report.remainingPayloadBytes, row["payload_bytes"].flatMap(Int64.init) ?? 0)
    }
    report.remainingDatabaseBytes = try paths.databaseBytes()
    report.capAchieved = report.remainingPayloadBytes <= maxPayloadBytes && report.pendingCleanupCount == 0
    return report
  }

  private func makeCategoryReport(state: RielaRetentionCategoryState, policy: TerminalRetentionCategoryPolicy,
                                  before: Int64) -> RetentionCategoryReport {
    .init(state: state, policy: .init(maxAgeDays: policy.maxAge.map { Int($0 / 86_400) }, maxTotalBytes: policy.maxBytes),
      selectedCount: 0, removedCount: 0, selectedBytes: 0, removedBytes: 0, beforeBytes: before,
      remainingBytes: before, capAchieved: policy.maxBytes.map { before <= $0 }, protected: [:],
      protectedFamilies: [], pendingCleanupCount: 0, workLimitReached: false, orphanSessionCount: 0)
  }

  private func report(plan: TerminalRetentionPlan, state: RielaRetentionCategoryState,
                      policy: TerminalRetentionCategoryPolicy, dryRun: Bool) -> RetentionCategoryReport {
    var value = makeCategoryReport(state: state, policy: policy, before: plan.beforeBytes)
    value.selectedCount = plan.selected.count
    value.selectedBytes = plan.selected.reduce(0) { $0 + $1.payloadBytes }
    value.remainingBytes = plan.projectedRemainingBytes
    value.capAchieved = policy.maxBytes.map { plan.projectedRemainingBytes <= $0 }
    value.protected = reasonCounts(plan.protected, extra: [:])
    value.protectedFamilies = plan.protected.prefix(50).map {
      RetentionProtectedFamily(rootId: $0.rootId, reason: $0.protection ?? "unknown")
    }
    value.workLimitReached = plan.workLimitReached
    if dryRun { value.removedCount = 0; value.removedBytes = 0 }
    return value
  }

  private func messagesReport(plan: TerminalRetentionPlan, orphans: [OrphanMessageSet],
                              policy: TerminalRetentionCategoryPolicy, state: RielaRetentionCategoryState,
                              now: Date, familyLimit: Int, dryRun: Bool) -> RetentionCategoryReport {
    let candidates = selectMessageCandidates(plan: plan, orphans: orphans, policy: policy, now: now, familyLimit: familyLimit)
    let before = plan.beforeBytes + orphans.reduce(0) { $0 + $1.bytes }
    let selectedBytes = candidates.values.reduce(0) { $0 + $1.bytes }
    var value = makeCategoryReport(state: state, policy: policy, before: before)
    value.selectedCount = candidates.values.count
    value.selectedBytes = selectedBytes
    value.remainingBytes = max(0, before - selectedBytes)
    value.capAchieved = policy.maxBytes.map { value.remainingBytes <= $0 }
    value.protected = reasonCounts(plan.protected, extra: [:])
    value.protectedFamilies = plan.protected.prefix(50).map {
      RetentionProtectedFamily(rootId: $0.rootId, reason: $0.protection ?? "unknown")
    }
    value.workLimitReached = candidates.workLimitReached
    if dryRun { value.removedCount = 0; value.removedBytes = 0 }
    return value
  }

  private func selectMessageCandidates(plan: TerminalRetentionPlan, orphans: [OrphanMessageSet],
                                       policy: TerminalRetentionCategoryPolicy, now: Date,
                                       familyLimit: Int) -> (values: [MessageCandidate], workLimitReached: Bool) {
    let families: [MessageCandidate] = plan.eligible.map { .family($0) }
    let orphanCandidates: [MessageCandidate] = orphans.map { .orphan($0) }
    let candidates = (families + orphanCandidates).sorted {
      $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
    }
    let initial = plan.beforeBytes + orphans.reduce(0) { $0 + $1.bytes }
    var remaining = initial
    var selected: [MessageCandidate] = []
    var limitReached = false
    let cutoff = policy.maxAge.map { now.addingTimeInterval(-$0) }
    for candidate in candidates where (cutoff.map { candidate.date <= $0 } ?? false) || (policy.maxBytes.map { remaining > $0 } ?? false) {
      guard selected.count < familyLimit else { limitReached = true; break }
      selected.append(candidate)
      remaining = max(0, remaining - candidate.bytes)
    }
    return (selected, limitReached)
  }

  private func orphanMessageSets(_ db: SQLiteDatabase) throws -> [OrphanMessageSet] {
    guard try db.tableExists("workflow_messages"), try db.tableExists("session_retention_tombstones"),
          try db.tableColumnNames("workflow_messages").contains("created_at") else { return [] }
    return try db.query("""
      SELECT m.workflow_execution_id AS id, t.workflow_id, max(m.created_at) AS created_at,
        sum(length(CAST(m.payload_json AS BLOB))+length(CAST(m.artifact_refs_json AS BLOB))) AS bytes
      FROM workflow_messages m JOIN session_retention_tombstones t ON t.session_id=m.workflow_execution_id
      GROUP BY m.workflow_execution_id,t.workflow_id ORDER BY id
      """).compactMap { row in
        guard let id = row["id"], let workflow = row["workflow_id"], let created = row["created_at"].flatMap(TerminalRetentionMetadata.date),
              let bytes = row["bytes"].flatMap(Int64.init), bytes >= 0 else { return nil }
        return OrphanMessageSet(id: id, workflowId: workflow, createdAt: created, bytes: bytes)
      }
  }

  private func dryResultReport(plan: TerminalRetentionPlan, policy: TerminalRetentionCategoryPolicy,
                               state: RielaRetentionCategoryState, familyLimit: Int,
                               db: SQLiteDatabase, paths: TerminalRetentionPaths) throws -> RetentionCategoryReport {
    let pending = try db.tableExists("session_retention_tombstones") ? pendingRows(db) : []
    let recoverableRoots = Set(pending.filter {
      $0["artifact_root"] == (paths.artifactRoot ?? "") && $0["memory_root"] == (paths.memoryRoot ?? "")
    }.compactMap { $0["root_id"] })
    let available = max(0, familyLimit - min(familyLimit, recoverableRoots.count))
    let admitted = Array(plan.selected.prefix(available))
    var value = report(plan: plan, state: state, policy: policy, dryRun: true)
    value.selectedCount = admitted.count
    value.selectedBytes = admitted.reduce(0) { $0 + $1.payloadBytes }
    value.remainingBytes = plan.beforeBytes - value.selectedBytes
    for row in pending {
      let bytes = row["payload_bytes"].flatMap(Int64.init) ?? 0
      value.beforeBytes = try TerminalRetentionMetadata.adding(value.beforeBytes, bytes)
      value.remainingBytes = try TerminalRetentionMetadata.adding(value.remainingBytes, bytes)
    }
    value.pendingCleanupCount = pending.count
    value.workLimitReached = plan.workLimitReached || recoverableRoots.count > familyLimit || admitted.count < plan.selected.count
    value.capAchieved = policy.maxBytes.map { value.remainingBytes <= $0 && pending.isEmpty }
    return value
  }

  private func cleanupPolicyFamily(_ family: TerminalRetentionFamily, db: SQLiteDatabase,
                                   paths: TerminalRetentionPaths, mode: RetentionReclamationMode,
                                   protected: inout [String: String]) throws -> [RetentionReclamationResult] {
    do {
      try beforeSecondaryCleanup()
      return try cleanup(ids: family.ids, db: db, paths: paths, mode: mode)
    } catch TerminalRetentionError.secondaryProtected {
      protected[family.rootId] = "secondaryOwnershipChanged"
    } catch TerminalRetentionError.reclamationBusy {
      protected[family.rootId] = "reclamationBusy"
    }
    return []
  }

  private func acquire(_ ids: [String], locks: SessionExecutionLockRegistry,
                       allowMessagesRetired: Bool) -> (ok: Bool, reason: String?) {
    var acquired: [String] = []
    do {
      for id in ids {
        try locks.acquire(sessionId: id, allowMessagesRetired: allowMessagesRetired)
        acquired.append(id)
      }
      return (true, nil)
    } catch SessionExecutionLockError.messagesRetired {
      for id in acquired { locks.release(sessionId: id) }
      return (false, "messagesAlreadyRetired")
    } catch {
      for id in acquired { locks.release(sessionId: id) }
      return (false, "executionLocked")
    }
  }

  private func insertResultsTombstone(id: String, row: TerminalRetentionSession, family: TerminalRetentionFamily,
                                      paths: TerminalRetentionPaths, now: Date, db: SQLiteDatabase) throws {
    try db.execute("""
      INSERT INTO session_retention_tombstones(session_id,workflow_id,root_id,pruned_at,artifact_root,memory_root,payload_bytes,cleanup_pending)
      VALUES(?,?,?,?,?,?,?,1)
      """, bindings: [.text(id), .text(row.workflowId), .text(family.rootId), .text(Self.timestamp(now)),
        .text(paths.artifactRoot ?? ""), .text(paths.memoryRoot ?? ""), .int(row.payloadBytes)])
  }

  private func deleteResultRows(_ id: String, db: SQLiteDatabase) throws {
    if try db.tableExists("workflow_runtime_executions") {
      try db.execute("DELETE FROM workflow_runtime_executions WHERE workflow_execution_id=?", bindings: [.text(id)])
    }
    if try db.tableExists("workflow_runtime_snapshots") {
      try db.execute("DELETE FROM workflow_runtime_snapshots WHERE workflow_execution_id=?", bindings: [.text(id)])
    }
    if try db.tableExists("cli_workflow_sessions") {
      try db.execute("DELETE FROM cli_workflow_sessions WHERE session_id=?", bindings: [.text(id)])
    }
    if try db.tableExists("loop_baselines") { try db.execute("DELETE FROM loop_baselines WHERE session_id=?", bindings: [.text(id)]) }
    if try db.tableExists("workflow_nested_invocations") { try deleteNestedInvocationRows(childId: id, db: db) }
  }

  private func deleteNestedInvocationRows(childId: String, db: SQLiteDatabase) throws {
    let hasInvocationKey = try db.tableColumnNames("workflow_nested_invocations").contains("invocation_key")
    let keys = hasInvocationKey ? try db.query("SELECT invocation_key FROM workflow_nested_invocations WHERE json_extract(reservation_json,'$.childSnapshot.session.sessionId')=?",
      bindings: [.text(childId)]).compactMap { $0["invocation_key"] } : []
    if try db.tableExists("workflow_nested_invocation_refs") {
      for key in keys { try db.execute("DELETE FROM workflow_nested_invocation_refs WHERE invocation_key=?", bindings: [.text(key)]) }
    }
    try db.execute("DELETE FROM workflow_nested_invocations WHERE json_extract(reservation_json,'$.childSnapshot.session.sessionId')=?",
      bindings: [.text(childId)])
  }

  private func deleteNestedInvocationRows(parentIds: [String], db: SQLiteDatabase) throws {
    guard !parentIds.isEmpty, try db.tableExists("workflow_nested_invocations") else { return }
    let hasInvocationKey = try db.tableColumnNames("workflow_nested_invocations").contains("invocation_key")
    let placeholders = Array(repeating: "?", count: parentIds.count).joined(separator: ",")
    let bindings = parentIds.map(SQLiteValue.text)
    let keys = hasInvocationKey ? try db.query(
      "SELECT invocation_key FROM workflow_nested_invocations WHERE json_extract(reservation_json,'$.parentSessionId') IN (\(placeholders))",
      bindings: bindings
    ).compactMap { $0["invocation_key"] } : []
    if try db.tableExists("workflow_nested_invocation_refs") {
      for key in keys {
        try db.execute("DELETE FROM workflow_nested_invocation_refs WHERE invocation_key=?", bindings: [.text(key)])
      }
    }
    try db.execute(
      "DELETE FROM workflow_nested_invocations WHERE json_extract(reservation_json,'$.parentSessionId') IN (\(placeholders))",
      bindings: bindings
    )
  }

  private func deleteFamilyPayloads(rootId: String, db: SQLiteDatabase) throws {
    if try db.tableExists("workflow_runtime_payloads") {
      try db.execute("DELETE FROM workflow_runtime_payloads WHERE root_session_id=?", bindings: [.text(rootId)])
    }
    if try db.tableExists("workflow_nested_invocation_refs"), try db.tableExists("session_retention_tombstones") {
      try db.execute("DELETE FROM workflow_nested_invocation_refs WHERE root_session_id=?", bindings: [.text(rootId)])
    }
  }

  private func sameFamily(_ lhs: TerminalRetentionFamily, _ rhs: TerminalRetentionFamily) -> Bool {
    lhs.ids == rhs.ids && lhs.rootId == rhs.rootId && lhs.updatedAt == rhs.updatedAt
      && lhs.payloadBytes == rhs.payloadBytes && lhs.messageBytes == rhs.messageBytes && lhs.protection == rhs.protection
  }

  private func reasonCounts(_ families: [TerminalRetentionFamily], extra: [String: String]) -> [String: Int] {
    var counts: [String: Int] = [:]
    for family in families { counts[family.protection ?? "unknown", default: 0] += 1 }
    for reason in extra.values { counts[reason, default: 0] += 1 }
    return counts
  }

  private func protectedList(_ families: [TerminalRetentionFamily], extra: [String: String]) -> [RetentionProtectedFamily] {
    var values = families.compactMap { family -> RetentionProtectedFamily? in
      guard let reason = family.protection else { return nil }
      return .init(rootId: family.rootId, reason: reason)
    }
    values += extra.map { rootId, reason in RetentionProtectedFamily(rootId: rootId, reason: reason) }
    return Array(values.sorted { $0.rootId < $1.rootId }.prefix(50))
  }

  private func addProtection(_ reason: String, _ rootId: String, to report: inout RetentionCategoryReport) {
    report.protected[reason, default: 0] += 1
    if report.protectedFamilies.count < 50 { report.protectedFamilies.append(.init(rootId: rootId, reason: reason)) }
  }

  private func metadata(_ db: SQLiteDatabase, paths: TerminalRetentionPaths) throws -> [TerminalRetentionSession] {
    var sessions = try TerminalRetentionSecondary.decorate(TerminalRetentionMetadata.sessions(db), paths: paths)
    if try db.tableExists("session_retention_tombstones") {
      let mismatched = try db.query("""
        SELECT session_id FROM session_retention_tombstones
        WHERE cleanup_pending=1 AND (artifact_root<>? OR memory_root<>?)
        """, bindings: [.text(paths.artifactRoot ?? ""), .text(paths.memoryRoot ?? "")])
        .compactMap { $0["session_id"] }
      let ids = Set(mismatched)
      for index in sessions.indices where ids.contains(sessions[index].id) {
        sessions[index].protection = "pendingRootsMismatch"
      }
    }
    return sessions
  }

  private func pendingRows(_ db: SQLiteDatabase) throws -> [SQLiteRow] {
    try db.query("""
      SELECT root.workflow_id,t.root_id,t.payload_bytes,t.artifact_root,t.memory_root
      FROM session_retention_tombstones t
      JOIN session_retention_tombstones root ON root.session_id=t.root_id
      WHERE t.cleanup_pending=1
      """)
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
                             deferred: inout Int, mode: RetentionReclamationMode = .manual) throws -> [String: String] {
    var protected: [String: String] = [:]
    let rows = try db.query("""
      SELECT t.session_id,t.root_id,root.workflow_id,t.artifact_root,t.memory_root FROM session_retention_tombstones t
      JOIN session_retention_tombstones root ON root.session_id=t.root_id
      WHERE t.cleanup_pending=1 ORDER BY t.session_id
      """)
    var attemptedRoots: Set<String> = [], deferredRoots: Set<String> = []
    for row in rows where workflows.isEmpty || workflows.contains(row["workflow_id"] ?? "") {
      guard let id = row["session_id"] else { continue }
      guard row["artifact_root"] == (paths.artifactRoot ?? ""), row["memory_root"] == (paths.memoryRoot ?? "") else {
        protected[row["root_id"] ?? id] = "pendingRootsMismatch"
        continue
      }
      guard let root = row["root_id"] else { throw TerminalRetentionError.pendingRootsMismatch }
      if !attemptedRoots.contains(root) {
        guard remainingFamilies > 0 else { deferredRoots.insert(root); continue }
        attemptedRoots.insert(root)
        remainingFamilies -= 1
      }
      do {
        try locks.acquire(sessionId: id, allowRetired: true, allowMessagesRetired: true)
      } catch {
        protected[root] = "executionLocked"
        continue
      }
      defer { locks.release(sessionId: id) }
      do {
        _ = try cleanup(ids: [id], db: db, paths: paths, mode: mode)
      } catch TerminalRetentionError.secondaryProtected {
        protected[root] = "secondaryOwnershipChanged"
      } catch TerminalRetentionError.reclamationBusy {
        protected[root] = "reclamationBusy"
      }
    }
    deferred += deferredRoots.count
    return protected
  }

  private func cleanup(ids: [String], db: SQLiteDatabase, paths: TerminalRetentionPaths,
                       mode: RetentionReclamationMode) throws -> [RetentionReclamationResult] {
    var workflows: [String: String] = [:]
    for id in ids {
      guard let row = try db.query("SELECT workflow_id,artifact_root,memory_root FROM session_retention_tombstones WHERE session_id=?",
        bindings: [.text(id)]).first, let workflow = row["workflow_id"],
        row["artifact_root"] == (paths.artifactRoot ?? ""), row["memory_root"] == (paths.memoryRoot ?? "") else {
        throw TerminalRetentionError.pendingRootsMismatch
      }
      workflows[id] = workflow
    }
    let reclamation = try TerminalRetentionSecondary.clean(ids: ids, workflows: workflows, paths: paths, mode: mode,
      reclaimer: reclaimer)
    try db.transaction { db in
      for id in ids {
        if try db.tableExists("workflow_runtime_executions") {
          try db.execute("DELETE FROM workflow_runtime_executions WHERE workflow_execution_id=?", bindings: [.text(id)])
        }
        if try db.tableExists("workflow_nested_invocations") {
          try deleteNestedInvocationRows(childId: id, db: db)
        }
        if let root = try db.query("SELECT root_id FROM session_retention_tombstones WHERE session_id=?",
          bindings: [.text(id)]).first?["root_id"] {
          try deleteFamilyPayloads(rootId: root, db: db)
        }
        try db.execute("UPDATE session_retention_tombstones SET cleanup_pending=0,payload_bytes=0 WHERE session_id=?",
          bindings: [.text(id)])
      }
      try deleteNestedInvocationRows(parentIds: ids, db: db)
    }
    return reclamation
  }

  private static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
