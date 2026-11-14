import Foundation
import RielaCore
import RielaMemory
import RielaSQLite
import RielaWorkflowRegistry

private struct StorageCompactCounts: Codable {
  var memoryRecords = 0
  var orphanMemoryHistoryRows = 0
  var sessions = 0
  var cliRecords = 0
  var nestedInvocations = 0
  var definitionPins = 0
}

private enum StorageCompactPruneReport: Encodable {
  case notConfigured
  case configured(RielaRetentionTargetReport)

  func encode(to encoder: Encoder) throws {
    switch self {
    case .notConfigured:
      var container = encoder.container(keyedBy: StorageCompactCodingKey.self)
      try container.encode("notConfigured", forKey: .state)
    case .configured(let report): try report.encode(to: encoder)
    }
  }
}

private enum StorageCompactCodingKey: String, CodingKey { case state }

private struct StorageCompactStoreReport: Encodable {
  var path: String
  var kind: String
  var converted: StorageCompactCounts
  var convertedBytes: Int64
  var reconciled: [SessionNestedInvocationVerdict]
  var prune: StorageCompactPruneReport
  var reclamation: [RetentionReclamationResult]
}

private struct StorageCompactReport: Encodable {
  var dryRun: Bool
  var stores: [StorageCompactStoreReport]
  var workRemaining: Bool
  var warnings: [String]
  var skipped: [String] = []
}

private struct StorageCompactEstimate {
  var counts = StorageCompactCounts()
  var bytes: Int64 = 0
  var hasWork = false
}

private struct StorageCompactSessionState {
  var counts = StorageCompactCounts()
  var reconciled: [SessionNestedInvocationVerdict] = []
  var prune: StorageCompactPruneReport = .notConfigured
  var reclamation: [RetentionReclamationResult] = []
  var workRemaining = false
  var warnings: [String] = []
  var skipped: [String] = []
}

struct StorageCompactCommandRunner {
  var reclaimer = RetentionSQLiteReclaimer()

  func run(_ arguments: [String]) -> CLICommandResult {
    do {
      let tokens = Array(arguments.first == "compact" ? arguments.dropFirst() : arguments[...])
      if let first = arguments.first, first != "compact" { throw CLIUsageError("unknown storage command '\(first)'") }
      let parsed = try ParsedStorageCommandArguments.parse(tokens)
      try parsed.validate(doctor: false, tokens: tokens)
      let report = try execute(parsed)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let json = String(data: try encoder.encode(report), encoding: .utf8) ?? "{}"
      if parsed.output == "json" {
        let failed = !report.skipped.isEmpty || report.warnings.contains(where: { $0.hasPrefix("retention pass") || $0.hasPrefix("definition pins") }) || report.stores.flatMap(\.reclamation).contains {
          [.busy, .failed, .diskFull, .checkpointPending, .deferredLiveSessions].contains($0.action)
        }
        return CLICommandResult(exitCode: failed ? .failure : .success, stdout: json + "\n")
      }
      let lines = report.stores.map { store in
        let converted = store.converted.memoryRecords + store.converted.sessions + store.converted.cliRecords + store.converted.nestedInvocations
        let reclaimed = store.reclamation.reduce(0) { $0 + $1.reclaimedBytes }
        return "\(store.kind): \(store.path), converted \(converted), reclaimed \(reclaimed) bytes"
      }
      let failed = !report.skipped.isEmpty || report.warnings.contains(where: { $0.hasPrefix("retention pass") || $0.hasPrefix("definition pins") }) || report.stores.flatMap(\.reclamation).contains {
        [.busy, .failed, .diskFull, .checkpointPending, .deferredLiveSessions].contains($0.action)
      }
      return CLICommandResult(exitCode: failed ? .failure : .success,
        stdout: "Storage compact (\(report.dryRun ? "dry run" : "applied"))\n" + lines.joined(separator: "\n") +
          "\nwork remaining: \(report.workRemaining)\nwarnings: \(report.warnings)\nskipped: \(report.skipped)\n")
    } catch { return StorageCommandFailure.result(error) }
  }

  private func execute(_ options: ParsedStorageCommandArguments) throws -> StorageCompactReport {
    let working = options.workingDir ?? FileManager.default.currentDirectoryPath
    let scope = WorkflowScope(rawValue: options.scope) ?? .project
    let sessionRoot = CLIWorkflowSessionStore.resolveRootDirectory(sessionStore: options.sessionStore, scope: scope, workingDirectory: working)
    let runtimeRoot = canonicalRuntimeStoreRoot(sessionStoreRoot: sessionRoot)
    let sessionDB = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: sessionRoot)
    let memoryRoot = options.memoryRoot ?? RielaMemoryStore.defaultRootDirectory(workingDirectory: working)
    let storePaths = storePaths(sessionDB: sessionDB, memoryRoot: memoryRoot, options: options)
    var remaining = false
    var warnings: [String] = []
    var skipped: [String] = []
    var reports: [StorageCompactStoreReport] = []
    let otherSessionRoots = WorkflowDefinitionStoreSelection.candidateRoots(sessionStore: options.sessionStore,
      scope: scope, workingDirectory: working).filter { $0 != sessionRoot }
    let retentionRequest = RielaRetentionRequest(trigger: .manual,
      homeDirectory: URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory()),
      projectDirectory: URL(fileURLWithPath: working), explicitSessionStore: options.sessionStore,
      environment: CLIRuntimeEnvironment.mergedProcessEnvironment(),
      scope: options.scope == "user" ? .user : .project,
      overrides: RielaRetentionOverrides(resultsMaxAgeDays: options.resultsMaxAgeDays,
        resultsMaxTotalBytes: options.resultsMaxTotalBytes, messagesMaxAgeDays: options.messagesMaxAgeDays,
        messagesMaxTotalBytes: options.messagesMaxTotalBytes), dryRun: !options.apply)
    let dryRunRetention = options.apply ? nil : try RielaRetentionService().run(retentionRequest)
    for (path, kind) in storePaths where FileManager.default.fileExists(atPath: path) {
      var counts = StorageCompactCounts()
      var convertedBytes: Int64 = 0
      var reconciled: [SessionNestedInvocationVerdict] = []
      var reclamation: [RetentionReclamationResult] = []
      var prune: StorageCompactPruneReport = .notConfigured
      let before = fileBytes(path)
      if kind == "session", let target = dryRunRetention?.targets.first {
        if target.results.state != .notConfigured || target.messages.state != .notConfigured { prune = .configured(target) }
      }
      if options.apply {
        if kind == "memory", URL(fileURLWithPath: path).lastPathComponent.hasSuffix(".sqlite") {
          let file = URL(fileURLWithPath: path).lastPathComponent
          let id = String(file.dropLast(".sqlite".count))
          do {
            let conversion = try RielaMemoryStore(rootDirectory: memoryRoot).convertLegacyHistory(memoryId: id, maxRecords: options.maxBatch)
            counts.memoryRecords = conversion.converted
            counts.orphanMemoryHistoryRows = try sweepOrphanMemoryHistory(path: path)
            remaining = remaining || conversion.remaining > 0
          } catch {
            remaining = true
            skipped.append("memory store \(path): \(error)")
          }
        }
        if kind == "session" {
          var state = StorageCompactSessionState()
          try convertSessionStores(root: sessionRoot, runtimeRoot: runtimeRoot, options: options,
            otherSessionRoots: otherSessionRoots, working: working, state: &state)
          counts = state.counts
          reconciled = state.reconciled
          prune = state.prune
          reclamation = state.reclamation
          remaining = remaining || state.workRemaining
          warnings.append(contentsOf: state.warnings)
          skipped.append(contentsOf: state.skipped)
        }
      } else {
        let estimate = try dryRunEstimate(path: path, kind: kind, runtimeRoot: runtimeRoot,
          sessionRoot: sessionRoot, maxBatch: options.maxBatch)
        counts = estimate.counts
        convertedBytes = estimate.bytes
        remaining = remaining || estimate.hasWork
      }
      if options.apply {
        let result = reclaimer.reclaim(databasePath: path, mode: .manual,
          allowLiveSessions: options.allowLiveVacuum)
        convertedBytes = max(0, before - fileBytes(path))
        reclamation.append(result)
        if result.action == .checkpointPending {
          remaining = true
          warnings.append("\(path): WAL checkpoint is pending; close readers and retry reclamation")
        }
        if result.action == .incrementalVacuum, result.reusableFreeBytes > 0 { remaining = true }
        if result.action == .deferredInsufficientSpace {
          remaining = true
          let available = reclaimer.freeSpace(URL(fileURLWithPath: path).deletingLastPathComponent().path) ?? 0
          let required = result.fileBytesBefore * 2 + (256 << 20)
          warnings.append("\(path): full VACUUM requires \(required) free bytes; \(available) available. " +
            "Alternative: use SQLite VACUUM INTO to create and validate a destination copy, stop writers, " +
            "checkpoint and close the source, replace the database, and remove stale -wal/-shm files before reopening. " +
            "A cross-volume rename is not atomic.")
        }
        if result.action == .busy || result.action == .failed { remaining = true; warnings.append("\(path): \(result.warning ?? result.action.rawValue)") }
        if result.action == .deferredLiveSessions { remaining = true; warnings.append("\(path): live session lock prevents full VACUUM") }
      }
      reports.append(StorageCompactStoreReport(path: path, kind: kind, converted: counts, convertedBytes: convertedBytes,
        reconciled: reconciled, prune: prune, reclamation: reclamation))
    }
    return StorageCompactReport(dryRun: !options.apply, stores: reports, workRemaining: remaining, warnings: warnings, skipped: skipped)
  }

  private func storePaths(sessionDB: String, memoryRoot: String,
                          options: ParsedStorageCommandArguments) -> [(String, String)] {
    var storePaths = [(sessionDB, "session")]
    let definitionsPath = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: sessionRoot(options: options))
    if FileManager.default.fileExists(atPath: definitionsPath) { storePaths.append((definitionsPath, "definitions")) }
    if let items = try? FileManager.default.contentsOfDirectory(atPath: memoryRoot) {
      storePaths += items.filter { $0.hasSuffix(".sqlite") }.map { (memoryRoot + "/" + $0, "memory") }
    }
    for (root, kind) in [(options.cacheRoot, "cache"), (options.kvRoot, "kv")] {
      guard let root, let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
      storePaths += items.filter { $0.hasSuffix(".sqlite") }.map { (root + "/" + $0, kind) }
    }
    return storePaths
  }

  private func sessionRoot(options: ParsedStorageCommandArguments) -> String {
    CLIWorkflowSessionStore.resolveRootDirectory(sessionStore: options.sessionStore,
      scope: WorkflowScope(rawValue: options.scope) ?? .project,
      workingDirectory: options.workingDir ?? FileManager.default.currentDirectoryPath)
  }

  private func convertSessionStores(root: String, runtimeRoot: String, options: ParsedStorageCommandArguments,
                                    otherSessionRoots: [String], working: String,
                                    state: inout StorageCompactSessionState) throws {
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot)
    let cli = CLIWorkflowSessionStore(rootDirectory: root)
    let lock = SessionExecutionLockRegistry(sessionStoreRoot: root)
    let legacy = try runtime.legacyInlineSessionIds(limit: 10_000)
    var handled = 0
    for id in legacy {
      guard handled < options.maxBatch else { state.workRemaining = true; break }
      do {
        try lock.acquire(sessionId: id, allowMessagesRetired: true)
      } catch {
        state.workRemaining = true
        state.skipped.append("session \(id): \(error)")
        continue
      }
      do {
        if try runtime.convertLegacySession(sessionId: id) { state.counts.sessions += 1 }
        handled += 1
        lock.release(sessionId: id)
      } catch { lock.release(sessionId: id); state.workRemaining = true; state.skipped.append("session \(id): \(error)") }
    }
    let cliIds = try cli.legacyFullRecordIds(limit: 10_000)
    handled = 0
    for id in cliIds {
      guard handled < options.maxBatch else { state.workRemaining = true; break }
      do {
        try lock.acquire(sessionId: id, allowMessagesRetired: true)
      } catch {
        state.workRemaining = true
        state.skipped.append("session \(id): \(error)")
        continue
      }
      do {
        if try cli.convertLegacyRecord(sessionId: id) { state.counts.cliRecords += 1 }
        handled += 1
        lock.release(sessionId: id)
      } catch { lock.release(sessionId: id); state.workRemaining = true; state.skipped.append("session \(id): \(error)") }
    }
    let nested = try runtime.legacyEmbeddedNestedInvocationKeys(limit: 10_000)
    handled = 0
    for key in nested {
      guard handled < options.maxBatch else { state.workRemaining = true; break }
      do {
        if try runtime.convertLegacyNestedInvocation(invocationKey: key) { state.counts.nestedInvocations += 1 }
        handled += 1
      } catch { state.workRemaining = true; state.skipped.append("nested invocation \(key): \(error)") }
    }
    state.reconciled = try SessionAbandonedInvocationReconciler(registry: lock).run(sessionStoreRoot: root,
      abandonedAfter: TimeInterval(options.abandonedAfterHours * 3600), apply: true)
    if state.reconciled.contains(where: { $0.verdict == "live" || $0.verdict == "skipped" }) { state.workRemaining = true }
    let defaultRetention = try WorkflowDefinitionHistoryConfiguration.resolve(
      homeDirectory: CLIRuntimeEnvironment.homeDirectory(), projectDirectory: working,
      environment: CLIRuntimeEnvironment.mergedProcessEnvironment())
    let definitions = WorkflowDefinitionStore(rootDirectory: root, defaultHistoryRetention: defaultRetention)
    let foreignRuntimeRoots = ([root] + otherSessionRoots).map { canonicalRuntimeStoreRoot(sessionStoreRoot: $0) }
    if FileManager.default.fileExists(atPath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root)) {
      do {
        let pins = try definitions.backfillPinsAndApplyRetention(foreignSessionStoreRoots: foreignRuntimeRoots,
          defaultHistoryRetention: defaultRetention, batchSize: options.maxBatch)
        state.counts.definitionPins = pins.pinsInserted
      } catch { state.warnings.append("definition pins: \(error)"); state.workRemaining = true }
    }
    let request = RielaRetentionRequest(trigger: .manual,
      homeDirectory: URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory()),
      projectDirectory: URL(fileURLWithPath: working), explicitSessionStore: options.sessionStore,
      environment: CLIRuntimeEnvironment.mergedProcessEnvironment(),
      scope: options.scope == "user" ? .user : .project,
      overrides: RielaRetentionOverrides(resultsMaxAgeDays: options.resultsMaxAgeDays,
        resultsMaxTotalBytes: options.resultsMaxTotalBytes, messagesMaxAgeDays: options.messagesMaxAgeDays,
        messagesMaxTotalBytes: options.messagesMaxTotalBytes))
    let retention = try RielaRetentionService().run(request)
    if let target = retention.targets.first,
       target.results.state != .notConfigured || target.messages.state != .notConfigured {
      state.prune = .configured(target)
      state.reclamation.append(contentsOf: target.reclamation.map { report in
        RetentionReclamationResult(database: report.database,
          autoVacuum: report.autoVacuum,
          action: RetentionReclamationAction(rawValue: report.action) ?? .failed,
          fileBytesBefore: report.fileBytesBefore,
          fileBytesAfter: report.fileBytesAfter,
          reclaimedBytes: report.reclaimedBytes,
          reusableFreeBytes: report.reusableFreeBytes,
          warning: report.warning)
      })
    }
    if retention.hasFailure { state.workRemaining = true; state.warnings.append("retention pass reported failure") }
  }

  private func dryRunEstimate(path: String, kind: String, runtimeRoot: String,
                              sessionRoot: String, maxBatch: Int) throws -> StorageCompactEstimate {
    var result = StorageCompactEstimate()
    if kind == "session" {
      let database = try SQLiteDatabase.open(path: path, mode: .strictReadOnlyWithImmutableFallback, options: .readOnlyDefault)
      if try database.tableExists("workflow_runtime_snapshots") {
        let sql = "SELECT count(*) AS count FROM (SELECT 1 FROM workflow_runtime_snapshots " +
          "WHERE json_type(session_json,'$.executions')='array' LIMIT \(maxBatch))"
        result.counts.sessions = Int(try database.query(sql).first?["count"] ?? "0") ?? 0
      }
      if try database.tableExists("cli_workflow_sessions") {
        let sql = "SELECT count(*) AS count FROM (SELECT 1 FROM cli_workflow_sessions " +
          "WHERE json_extract(record_json,'$.sessionStorage') IS NOT 'canonical' LIMIT \(maxBatch))"
        result.counts.cliRecords = Int(try database.query(sql).first?["count"] ?? "0") ?? 0
      }
      if try database.tableExists("workflow_nested_invocations") {
        let sql = "SELECT count(*) AS count FROM (SELECT 1 FROM workflow_nested_invocations " +
          "WHERE json_extract(reservation_json,'$.childSnapshotStorage') IS NOT 'refs' LIMIT \(maxBatch))"
        result.counts.nestedInvocations = Int(try database.query(sql).first?["count"] ?? "0") ?? 0
      }
      result.bytes = try estimateSessionBytes(path: path)
      result.hasWork = result.counts.sessions > 0 || result.counts.cliRecords > 0 || result.counts.nestedInvocations > 0
    } else {
      let database = try SQLiteDatabase.open(path: path, mode: .strictReadOnly, options: .readOnlyDefault)
      if kind == "memory", try database.tableExists("memory_evolution") {
        let sql = "SELECT count(DISTINCT e.record_id) AS count FROM memory_evolution e " +
          "LEFT JOIN memory_history_heads h ON h.key=CAST(e.record_id AS TEXT) WHERE h.key IS NULL"
        result.counts.memoryRecords = Int(try database.query(sql).first?["count"] ?? "0") ?? 0
        result.bytes = Int64(try database.query("SELECT coalesce(sum(length(CAST(reverse_delta_json AS BLOB))),0) AS bytes FROM memory_evolution").first?["bytes"] ?? "0") ?? 0
      }
      if kind == "memory", try database.tableExists("memory_history_versions"),
         try database.tableExists("memory_entries") {
        result.counts.orphanMemoryHistoryRows = try countOrphanMemoryHistory(database)
      }
      result.bytes += try freePageBytes(database)
      result.hasWork = result.counts.memoryRecords > 0 || result.counts.orphanMemoryHistoryRows > 0
    }
    return result
  }

  private func countOrphanMemoryHistory(_ database: SQLiteDatabase) throws -> Int {
    let versions = try database.query("""
      SELECT count(*) AS count FROM memory_history_versions v
      WHERE NOT EXISTS (SELECT 1 FROM memory_entries e WHERE CAST(e.record_id AS TEXT)=v.key)
      """).first?["count"]
    let heads = try database.tableExists("memory_history_heads")
      ? database.query("""
        SELECT count(*) AS count FROM memory_history_heads h
        WHERE NOT EXISTS (SELECT 1 FROM memory_entries e WHERE CAST(e.record_id AS TEXT)=h.key)
        """).first?["count"] : "0"
    return (Int(versions ?? "0") ?? 0) + (Int(heads ?? "0") ?? 0)
  }

  private func sweepOrphanMemoryHistory(path: String) throws -> Int {
    let database = try SQLiteDatabase.open(path: path)
    guard try database.tableExists("memory_history_versions"), try database.tableExists("memory_entries") else { return 0 }
    let count = try countOrphanMemoryHistory(database)
    guard count > 0 else { return 0 }
    try database.transaction { db in
      try db.execute("""
        DELETE FROM memory_history_versions
        WHERE NOT EXISTS (SELECT 1 FROM memory_entries e WHERE CAST(e.record_id AS TEXT)=memory_history_versions.key)
        """)
      if try db.tableExists("memory_history_heads") {
        try db.execute("""
          DELETE FROM memory_history_heads
          WHERE NOT EXISTS (SELECT 1 FROM memory_entries e WHERE CAST(e.record_id AS TEXT)=memory_history_heads.key)
          """)
      }
    }
    return count
  }

  private func fileBytes(_ path: String) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
  }

  private func estimateSessionBytes(path: String) throws -> Int64 {
    let database = try SQLiteDatabase.open(path: path, mode: .strictReadOnlyWithImmutableFallback, options: .readOnlyDefault)
    var bytes: Int64 = 0
    if try database.tableExists("cli_workflow_sessions") {
      let sql = "SELECT coalesce(sum(length(record_json)),0) AS bytes FROM cli_workflow_sessions " +
        "WHERE json_extract(record_json,'$.sessionStorage') IS NOT 'canonical'"
      bytes += Int64(try database.query(sql).first?["bytes"] ?? "0") ?? 0
    }
    if try database.tableExists("workflow_nested_invocations") {
      let sql = "SELECT coalesce(sum(length(reservation_json)),0) AS bytes FROM workflow_nested_invocations " +
        "WHERE json_extract(reservation_json,'$.childSnapshotStorage') IS NOT 'refs'"
      bytes += Int64(try database.query(sql).first?["bytes"] ?? "0") ?? 0
    }
    return bytes + (try freePageBytes(database))
  }

  private func freePageBytes(_ database: SQLiteDatabase) throws -> Int64 {
    let pageSize = Int64(try database.query("PRAGMA page_size").first?["page_size"] ?? "0") ?? 0
    let pages = Int64(try database.query("PRAGMA freelist_count").first?["freelist_count"] ?? "0") ?? 0
    return pageSize * pages
  }
}
