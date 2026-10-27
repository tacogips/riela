import Foundation
import RielaCore
import RielaMemory
import RielaSQLite
import RielaWorkflowRegistry

private struct StorageCompactCounts: Codable {
  var memoryRecords = 0
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
}

private struct StorageCompactEstimate {
  var counts = StorageCompactCounts()
  var bytes: Int64 = 0
  var hasWork = false
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
      if parsed.output == "json" { return CLICommandResult(exitCode: .success, stdout: json + "\n") }
      let lines = report.stores.map { store in
        let converted = store.converted.memoryRecords + store.converted.sessions + store.converted.cliRecords + store.converted.nestedInvocations
        let reclaimed = store.reclamation.reduce(0) { $0 + $1.reclaimedBytes }
        return "\(store.kind): \(store.path), converted \(converted), reclaimed \(reclaimed) bytes"
      }
      return CLICommandResult(exitCode: .success,
        stdout: "Storage compact (\(report.dryRun ? "dry run" : "applied"))\n" + lines.joined(separator: "\n") + "\n")
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
          let conversion = try RielaMemoryStore(rootDirectory: memoryRoot).convertLegacyHistory(memoryId: id, maxRecords: options.maxBatch)
          counts.memoryRecords = conversion.converted
          remaining = remaining || conversion.remaining > 0
        }
        if kind == "session" {
          try convertSessionStores(root: sessionRoot, runtimeRoot: runtimeRoot, options: options,
            otherSessionRoots: otherSessionRoots, working: working, counts: &counts,
            reconciled: &reconciled, prune: &prune, reclamation: &reclamation, workRemaining: &remaining)
        }
      } else {
        let estimate = try dryRunEstimate(path: path, kind: kind, runtimeRoot: runtimeRoot,
          sessionRoot: sessionRoot, maxBatch: options.maxBatch)
        counts = estimate.counts
        convertedBytes = estimate.bytes
        remaining = remaining || estimate.hasWork
      }
      if options.apply {
        convertedBytes = max(0, before - fileBytes(path))
        let result = reclaimer.reclaim(databasePath: path, mode: .manual)
        reclamation.append(result)
        if result.action == .incrementalVacuum, result.reusableFreeBytes > 0 { remaining = true }
        if result.action == .deferredInsufficientSpace {
          let available = reclaimer.freeSpace(URL(fileURLWithPath: path).deletingLastPathComponent().path) ?? 0
          let required = result.fileBytesBefore * 2 + (256 << 20)
          warnings.append("\(path): full VACUUM requires \(required) free bytes; \(available) available. " +
            "Alternative: run `VACUUM INTO '/path/on/another-volume/compact.sqlite'` using a SQLite build that supports it, validate the copy, then atomically replace the database while holding the store lock.")
        }
      }
      reports.append(StorageCompactStoreReport(path: path, kind: kind, converted: counts, convertedBytes: convertedBytes,
        reconciled: reconciled, prune: prune, reclamation: reclamation))
    }
    return StorageCompactReport(dryRun: !options.apply, stores: reports, workRemaining: remaining, warnings: warnings)
  }

  private func storePaths(sessionDB: String, memoryRoot: String,
                          options: ParsedStorageCommandArguments) -> [(String, String)] {
    var storePaths = [(sessionDB, "session")]
    if let items = try? FileManager.default.contentsOfDirectory(atPath: memoryRoot) {
      storePaths += items.filter { $0.hasSuffix(".sqlite") }.map { (memoryRoot + "/" + $0, "memory") }
    }
    for (root, kind) in [(options.cacheRoot, "cache"), (options.kvRoot, "kv")] {
      guard let root, let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
      storePaths += items.filter { $0.hasSuffix(".sqlite") }.map { (root + "/" + $0, kind) }
    }
    return storePaths
  }

  private func convertSessionStores(root: String, runtimeRoot: String, options: ParsedStorageCommandArguments,
                                    otherSessionRoots: [String], working: String,
                                    counts: inout StorageCompactCounts,
                                    reconciled: inout [SessionNestedInvocationVerdict],
                                    prune: inout StorageCompactPruneReport,
                                    reclamation: inout [RetentionReclamationResult],
                                    workRemaining: inout Bool) throws {
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot)
    let cli = CLIWorkflowSessionStore(rootDirectory: root)
    let lock = SessionExecutionLockRegistry(sessionStoreRoot: root)
    let legacy = try runtime.legacyInlineSessionIds(limit: options.maxBatch)
    if legacy.count == options.maxBatch { workRemaining = true }
    for id in legacy {
      do { try lock.acquire(sessionId: id) } catch SessionExecutionLockError.alreadyRunning {
        workRemaining = true
        continue
      }
      do {
        if try runtime.convertLegacySession(sessionId: id) { counts.sessions += 1 }
        lock.release(sessionId: id)
      } catch { lock.release(sessionId: id); throw error }
    }
    let cliIds = try cli.legacyFullRecordIds(limit: options.maxBatch)
    if cliIds.count == options.maxBatch { workRemaining = true }
    for id in cliIds {
      do { try lock.acquire(sessionId: id) } catch SessionExecutionLockError.alreadyRunning {
        workRemaining = true
        continue
      }
      do {
        if try cli.convertLegacyRecord(sessionId: id) { counts.cliRecords += 1 }
        lock.release(sessionId: id)
      } catch { lock.release(sessionId: id); throw error }
    }
    let nested = try runtime.legacyEmbeddedNestedInvocationKeys(limit: options.maxBatch)
    if nested.count == options.maxBatch { workRemaining = true }
    for key in nested where try runtime.convertLegacyNestedInvocation(invocationKey: key) {
      counts.nestedInvocations += 1
    }
    reconciled = try SessionAbandonedInvocationReconciler(registry: lock).run(sessionStoreRoot: root,
      abandonedAfter: TimeInterval(options.abandonedAfterHours * 3600), apply: true)
    if reconciled.contains(where: { $0.verdict == "live" || $0.verdict == "skipped" }) { workRemaining = true }
    let defaultRetention = try WorkflowDefinitionHistoryConfiguration.resolve(
      homeDirectory: CLIRuntimeEnvironment.homeDirectory(), projectDirectory: working,
      environment: CLIRuntimeEnvironment.mergedProcessEnvironment())
    let definitions = WorkflowDefinitionStore(rootDirectory: root, defaultHistoryRetention: defaultRetention)
    let foreignRuntimeRoots = ([root] + otherSessionRoots).map { canonicalRuntimeStoreRoot(sessionStoreRoot: $0) }
    let pins = try definitions.backfillPinsAndApplyRetention(foreignSessionStoreRoots: foreignRuntimeRoots,
      defaultHistoryRetention: defaultRetention)
    counts.definitionPins = pins.pinsInserted
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
      prune = .configured(target)
      reclamation.append(contentsOf: target.reclamation.map { report in
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
    if retention.hasFailure { workRemaining = true }
  }

  private func dryRunEstimate(path: String, kind: String, runtimeRoot: String,
                              sessionRoot: String, maxBatch: Int) throws -> StorageCompactEstimate {
    var result = StorageCompactEstimate()
    if kind == "session" {
      let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot)
      result.counts.sessions = try runtime.legacyInlineSessionIds(limit: maxBatch).count
      result.counts.cliRecords = try CLIWorkflowSessionStore(rootDirectory: sessionRoot).legacyFullRecordIds(limit: maxBatch).count
      result.counts.nestedInvocations = try runtime.legacyEmbeddedNestedInvocationKeys(limit: maxBatch).count
      result.bytes = try estimateSessionBytes(path: path)
      result.hasWork = result.counts.sessions > 0 || result.counts.cliRecords > 0 || result.counts.nestedInvocations > 0
    } else {
      let database = try SQLiteDatabase.open(path: path, mode: .strictReadOnlyWithImmutableFallback, options: .readOnlyDefault)
      if kind == "memory", try database.tableExists("memory_evolution") {
        let sql = "SELECT count(DISTINCT e.record_id) AS count FROM memory_evolution e " +
          "LEFT JOIN memory_history_heads h ON h.key=CAST(e.record_id AS TEXT) WHERE h.key IS NULL"
        result.counts.memoryRecords = Int(try database.query(sql).first?["count"] ?? "0") ?? 0
        result.bytes = Int64(try database.query("SELECT coalesce(sum(length(CAST(reverse_delta_json AS BLOB))),0) AS bytes FROM memory_evolution").first?["bytes"] ?? "0") ?? 0
      }
      result.bytes += try freePageBytes(database)
      result.hasWork = result.counts.memoryRecords > 0
    }
    return result
  }

  private func fileBytes(_ path: String) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
  }

  private func estimateSessionBytes(path: String) throws -> Int64 {
    let database = try SQLiteDatabase.open(path: path, mode: .strictReadOnlyWithImmutableFallback, options: .readOnlyDefault)
    var bytes: Int64 = 0
    if try database.tableExists("workflow_runtime_snapshots") {
      bytes += Int64(try database.query("SELECT coalesce(sum(length(session_json)),0) AS bytes FROM workflow_runtime_snapshots WHERE json_type(session_json,'$.executions')='array'").first?["bytes"] ?? "0") ?? 0
    }
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
