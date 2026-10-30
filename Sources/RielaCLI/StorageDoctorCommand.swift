import Foundation
import RielaCore
import RielaMemory
import RielaSQLite
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct StorageDoctorPath {
  var path: String
  var kind: String
  var sessionRoot: String?
}

private struct StorageDoctorTable: Codable {
  var name: String
  var bytes: Int64
  var rows: Int64
  var estimated: Bool
}

private struct StorageDoctorMemory: Codable {
  var records: Int64
  var historyBytes: Int64
  var currentBytes: Int64
  var amplification: Double
  var maxVersionsPerRecord: Int64
  var legacyRecords: Int64
  var unreferencedAttachmentBytes: Int64
  var largestRecords: [[String: String]]
}

private struct StorageDoctorRecovery: Codable {
  var requiredFreeBytes: Int64
  var availableFreeBytes: Int64?
  var steps: String
}

private struct StorageDoctorReclaimable: Codable {
  var freePagesBytes: Int64
  var compactEstimateBytes: Int64
  var pruneEstimateBytes: Int64
  var remainingBytes: Int64
  var remainingBytesIsUpperBound: Bool
  var recovery: StorageDoctorRecovery?
}

private struct StorageDoctorParkedRow: Codable {
  var queue: String
  var key: String
  var error: String
}

private struct StorageDoctorMaintenance: Codable {
  var parkedCount: Int
  var parkedExamples: [StorageDoctorParkedRow]
  var busyCount: Int
  var failedCount: Int
  var queuesComplete: Bool
  var hint: String?
}

private struct StorageDoctorPayloadFragments: Codable {
  var fragmentRows: Int64
  var fragmentBytes: Int64
  var reducedPayloadRows: Int64
  var refRows: Int64
  var danglingRefRows: Int64
  var unreferencedPayloadRows: Int64
  var unreferencedPayloadBytes: Int64
}

private struct StorageDoctorSession: Codable {
  var sessions: Int64
  var legacyInlineSnapshots: Int64
  var legacyCLICopies: Int64
  var legacyCLICopyBytes: Int64
  var legacyNestedEmbeddedBytes: Int64
  var pruneBlocked: [String: Int]
  var abandonedCandidates: Int
  var largestSessions: [[String: String]]
  var maintenance: StorageDoctorMaintenance?
  var payloadFragments: StorageDoctorPayloadFragments?
}

private struct StorageDoctorDefinitions: Codable {
  var workflows: Int64
  var versions: Int64
  var versionsOverWindow: Int64
  var pins: Int64
  var retentionState: String
}

private struct StorageDoctorFile: Codable {
  var path: String
  var kind: String
  var fileBytes: Int64
  var walBytes: Int64
  var pageSize: Int64
  var pageCount: Int64
  var freePages: Int64
  var freeBytes: Int64
  var autoVacuum: String
  var schemaGeneration: Int64?
  var tables: [StorageDoctorTable]
  var memory: StorageDoctorMemory?
  var session: StorageDoctorSession?
  var definitions: StorageDoctorDefinitions?
  var reclaimable: StorageDoctorReclaimable
}

struct StorageDoctorCommandRunner {
  func run(_ arguments: [String]) -> CLICommandResult {
    do {
      let parsed = try ParsedStorageCommandArguments.parse(arguments)
      try parsed.validate(doctor: true, tokens: arguments)
      var warnings: [String] = []
      let files = try paths(parsed).compactMap { item -> StorageDoctorFile? in
        do {
          return try inspect(path: item.path, kind: item.kind, sessionRoot: item.sessionRoot, top: parsed.top,
            workingDirectory: parsed.workingDir ?? FileManager.default.currentDirectoryPath)
        } catch {
          warnings.append("\(item.path): \(error)")
          return nil
        }
      }
      guard !files.isEmpty else { throw StorageCommandError.noStores }
      if parsed.output == "json" {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(files)
        let output = String(data: encoded, encoding: .utf8) ?? "[]"
        return CLICommandResult(exitCode: .success, stdout: output + "\n", stderr: warnings.joined(separator: "\n"))
      }
      return CLICommandResult(exitCode: .success, stdout: files.map(text).joined(separator: "\n"), stderr: warnings.joined(separator: "\n"))
    } catch {
      return StorageCommandFailure.result(error, usagePath: ["doctor", "storage"])
    }
  }

  private func paths(_ options: ParsedStorageCommandArguments) throws -> [StorageDoctorPath] {
    let fm = FileManager.default
    let working = options.workingDir ?? fm.currentDirectoryPath
    var values: [StorageDoctorPath] = []
    let sessionRoots: [String]
    if let explicit = options.sessionStore {
      sessionRoots = [explicit]
    } else {
      var roots = [CLIWorkflowSessionStore.resolveRootDirectory(sessionStore: nil,
        scope: options.scope == "user" ? .user : .project, workingDirectory: working)]
      if options.scope == "auto" {
        let user = URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory()).appendingPathComponent(".riela/sessions").path
        if user != roots[0] { roots.append(user) }
      }
      sessionRoots = roots
    }
    for root in sessionRoots {
      let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root)
      if fm.fileExists(atPath: path) { values.append(.init(path: path, kind: "session", sessionRoot: root)) }
      let definitions = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root)
      if definitions != path, fm.fileExists(atPath: definitions) { values.append(.init(path: definitions, kind: "definitions", sessionRoot: root)) }
    }
    let memoryRoots: [String]
    if let explicit = options.memoryRoot {
      memoryRoots = [explicit]
    } else {
      var roots = [RielaMemoryStore.defaultRootDirectory(workingDirectory: working)]
      if options.scope == "auto" {
        let user = URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory())
          .appendingPathComponent(".riela/memory", isDirectory: true).path
        if user != roots[0] { roots.append(user) }
      }
      memoryRoots = roots
    }
    for memoryRoot in memoryRoots where fm.fileExists(atPath: memoryRoot) {
      if let items = try? fm.contentsOfDirectory(atPath: memoryRoot) {
        values += items.filter { $0.hasSuffix(".sqlite") }.map { StorageDoctorPath(path: memoryRoot + "/" + $0, kind: "memory", sessionRoot: nil) }
      }
    }
    for (root, kind) in [(options.cacheRoot, "cache"), (options.kvRoot, "kv")] {
      guard let root, let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
      values += items.filter { $0.hasSuffix(".sqlite") }.map { StorageDoctorPath(path: root + "/" + $0, kind: kind, sessionRoot: nil) }
    }
    return values
  }

  private func inspect(path: String, kind: String, sessionRoot: String?, top: Int, workingDirectory: String) throws -> StorageDoctorFile? {
    let mode: SQLiteOpenMode = kind == "memory" || kind == "cache" || kind == "kv"
      ? .strictReadOnly : .strictReadOnlyWithImmutableFallback
    let db = try SQLiteDatabase.open(path: path, mode: mode, options: .readOnlyDefault)
    let scalar: (String, String) throws -> Int64 = { sql, key in
      Int64(try db.query(sql).first?[key] ?? "0") ?? 0
    }
    let pageSize = try scalar("PRAGMA page_size", "page_size")
    let freePages = try scalar("PRAGMA freelist_count", "freelist_count")
    let pageCount = try scalar("PRAGMA page_count", "page_count")
    let vacuumValue = try scalar("PRAGMA auto_vacuum", "auto_vacuum")
    let tables = try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
    var tableReports: [StorageDoctorTable] = []
    do {
      let bytes = try db.query("SELECT name, SUM(pgsize) AS bytes FROM dbstat GROUP BY name")
      let map = Dictionary(uniqueKeysWithValues: bytes.compactMap { row -> (String, Int64)? in
        guard let name = row["name"], let size = row["bytes"].flatMap(Int64.init) else { return nil }
        return (name, size)
      })
      for table in tables.compactMap({ $0["name"] }) {
        let rows = try scalar("SELECT count(*) AS count FROM \"\(table)\"", "count")
        tableReports.append(.init(name: table, bytes: map[table] ?? 0, rows: rows, estimated: false))
      }
    } catch {
      for table in tables.compactMap({ $0["name"] }) {
        let rows = try scalar("SELECT count(*) AS count FROM \"\(table)\"", "count")
        let escapedTable = table.replacingOccurrences(of: "\"", with: "\"\"")
        let columns = try db.query("PRAGMA table_info(\"\(escapedTable)\")").compactMap { $0["name"] }
        let lengths = columns.map { column in
          let escapedColumn = column.replacingOccurrences(of: "\"", with: "\"\"")
          return "coalesce(length(CAST(\"\(escapedColumn)\" AS BLOB)),0)"
        }
        let expression = lengths.isEmpty ? "0" : lengths.joined(separator: "+")
        let bytes = try scalar("SELECT coalesce(sum(\(expression)),0) AS bytes FROM \"\(escapedTable)\"", "bytes")
        tableReports.append(.init(name: table, bytes: bytes, rows: rows, estimated: true))
      }
    }
    let memory = kind == "memory" ? try memoryReport(db, databasePath: path, top: top) : nil
    let target = sessionRoot.flatMap { retentionTarget(sessionRoot: $0, workingDirectory: workingDirectory) }
    let retention = try target.flatMap { target in
      try retentionReport(target: target, sessionRoot: sessionRoot ?? "", workingDirectory: workingDirectory)
    }
    let session = kind == "session" ? try sessionReport(db, root: sessionRoot ?? "", top: top,
      pruneBlocked: retention?.results.protected ?? [:], target: target) : nil
    let definitions = kind == "definitions" ? try definitionReport(db, workingDirectory: workingDirectory) : nil
    let file = fileSize(path), wal = fileSize(path + "-wal")
    let generation = kind == "session" ? try? scalar("PRAGMA user_version", "user_version") : nil
    let compactEstimate = freePages * pageSize + (kind == "session"
      ? (session?.legacyCLICopyBytes ?? 0) + (session?.legacyNestedEmbeddedBytes ?? 0)
      : kind == "memory" ? try legacyMemoryBytes(db) : 0)
    let pruneEstimate = (retention?.results.selectedBytes ?? 0) + (retention?.messages.selectedBytes ?? 0)
    let recovery: StorageDoctorRecovery? = (kind == "session" || kind == "definitions") && vacuumValue == 0
      ? StorageDoctorRecovery(requiredFreeBytes: 2 * (file + wal) + 268_435_456,
        availableFreeBytes: RetentionSQLiteReclaimer().freeSpace(URL(fileURLWithPath: path).deletingLastPathComponent().path),
        steps: "Freed pages are reused but the file cannot shrink; stop writers and run riela storage compact --apply " +
          "(or riela gc) once free space is at least requiredFreeBytes; otherwise follow the VACUUM INTO sequence " +
          "in docs/storage-doctor-and-compact.md.") : nil
    return StorageDoctorFile(path: path, kind: kind, fileBytes: file, walBytes: wal, pageSize: pageSize,
      pageCount: pageCount, freePages: freePages, freeBytes: freePages * pageSize,
      autoVacuum: ["none", "full", "incremental"][safe: Int(vacuumValue)] ?? "unknown",
      schemaGeneration: generation, tables: tableReports,
      memory: memory, session: session, definitions: definitions,
      reclaimable: .init(freePagesBytes: freePages * pageSize, compactEstimateBytes: compactEstimate,
        pruneEstimateBytes: pruneEstimate, remainingBytes: compactEstimate + pruneEstimate,
        remainingBytesIsUpperBound: true, recovery: recovery))
  }

  private func memoryReport(_ db: SQLiteDatabase, databasePath: String, top: Int) throws -> StorageDoctorMemory? {
    guard try db.tableExists("memory_entries") else { return nil }
    let count = try value(db, "SELECT count(*) AS value FROM memory_entries")
    let current = try value(db, "SELECT coalesce(sum(length(CAST(payload_json AS BLOB))+length(CAST(tags_json AS BLOB))+length(CAST(related_record_ids_json AS BLOB))),0) AS value FROM memory_entries")
    var history: Int64 = 0, maximum: Int64 = 0, legacy: Int64 = 0
    if try db.tableExists("memory_history_versions") {
      history += try value(db, "SELECT coalesce(sum(length(blob)),0) AS value FROM memory_history_versions")
      maximum = try value(db, "SELECT coalesce(max(n),0) AS value FROM (SELECT count(*) n FROM memory_history_versions GROUP BY key)")
    }
    if try db.tableExists("memory_history_heads") {
      legacy = try value(db, "SELECT count(*) AS value FROM memory_entries WHERE record_id NOT IN (SELECT CAST(key AS INTEGER) FROM memory_history_heads)")
    }
    if try db.tableExists("memory_evolution") {
      history += try value(db, "SELECT coalesce(sum(length(CAST(reverse_delta_json AS BLOB))),0) AS value FROM memory_evolution")
      maximum = max(maximum, try value(db, "SELECT coalesce(max(n),0) AS value FROM (SELECT count(*) n FROM memory_evolution GROUP BY record_id)"))
      legacy = try value(db, try db.tableExists("memory_history_heads")
        ? "SELECT count(*) AS value FROM (SELECT DISTINCT e.record_id FROM memory_evolution e LEFT JOIN memory_history_heads h ON h.key=CAST(e.record_id AS TEXT) WHERE h.key IS NULL)"
        : "SELECT count(DISTINCT record_id) AS value FROM memory_evolution")
    }
    var historyQueries: [String] = []
    if try db.tableExists("memory_history_versions") {
      historyQueries.append("SELECT key AS record_id, sum(length(blob)) AS history_bytes, count(*) AS versions FROM memory_history_versions GROUP BY key")
    }
    if try db.tableExists("memory_evolution") {
      historyQueries.append("SELECT CAST(record_id AS TEXT) AS record_id, sum(length(CAST(reverse_delta_json AS BLOB))) AS history_bytes, count(*) AS versions FROM memory_evolution GROUP BY record_id")
    }
    let largest: [[String: String]]
    if historyQueries.isEmpty { largest = [] } else {
      largest = try db.query("SELECT record_id, sum(history_bytes) AS history_bytes, sum(versions) AS versions FROM (" +
        historyQueries.joined(separator: " UNION ALL ") + ") GROUP BY record_id ORDER BY history_bytes DESC LIMIT \(top)")
      .map { row in ["recordId": row["record_id"] ?? "", "historyBytes": row["history_bytes"] ?? "0", "versions": row["versions"] ?? "0"] }
    }
    let attachmentBytes = try unreferencedAttachmentBytes(db, databasePath: databasePath)
    return StorageDoctorMemory(records: count, historyBytes: history, currentBytes: current,
      amplification: current == 0 ? 0 : Double(history) / Double(current), maxVersionsPerRecord: maximum,
      legacyRecords: legacy, unreferencedAttachmentBytes: attachmentBytes, largestRecords: largest)
  }

  private func sessionReport(_ db: SQLiteDatabase, root: String, top: Int,
                             pruneBlocked: [String: Int], target: RetentionTarget?) throws -> StorageDoctorSession? {
    guard try db.tableExists("workflow_runtime_snapshots") || db.tableExists("cli_workflow_sessions") else { return nil }
    let inline = try db.tableExists("workflow_runtime_snapshots")
      ? value(db, "SELECT count(*) AS value FROM workflow_runtime_snapshots WHERE json_type(session_json,'$.executions')='array'") : 0
    let copies = try db.tableExists("cli_workflow_sessions")
      ? value(db, "SELECT count(*) AS value FROM cli_workflow_sessions WHERE coalesce(json_extract(record_json,'$.sessionStorage'),'')!='canonical'") : 0
    let bytes = try db.tableExists("cli_workflow_sessions")
      ? value(db, "SELECT coalesce(sum(length(record_json)),0) AS value FROM cli_workflow_sessions WHERE coalesce(json_extract(record_json,'$.sessionStorage'),'')!='canonical'") : 0
    let nested = try db.tableExists("workflow_nested_invocations")
      ? value(db, "SELECT coalesce(sum(length(reservation_json)),0) AS value FROM workflow_nested_invocations WHERE coalesce(json_extract(reservation_json,'$.childSnapshotStorage'),'')!='refs'") : 0
    let nestedUnsettled = try SessionAbandonedInvocationReconciler(
      registry: SessionExecutionLockRegistry(sessionStoreRoot: root))
      .run(sessionStoreRoot: root, abandonedAfter: 24 * 3600, apply: false)
      .filter { $0.verdict == "abandoned" }.count
    let largest: [[String: String]]
    if try db.tableExists("workflow_runtime_snapshots") {
      largest = try db.query("SELECT workflow_execution_id AS session_id, length(CAST(session_json AS BLOB)) AS bytes FROM workflow_runtime_snapshots ORDER BY bytes DESC LIMIT \(top)")
        .map { ["sessionId": $0["session_id"] ?? "", "bytes": $0["bytes"] ?? "0"] }
    } else { largest = [] }
    return StorageDoctorSession(sessions: try db.tableExists("workflow_runtime_snapshots")
      ? value(db, "SELECT count(*) AS value FROM workflow_runtime_snapshots") : copies,
      legacyInlineSnapshots: inline, legacyCLICopies: copies, legacyCLICopyBytes: bytes,
      legacyNestedEmbeddedBytes: nested, pruneBlocked: pruneBlocked, abandonedCandidates: nestedUnsettled, largestSessions: largest,
      maintenance: target.flatMap { maintenanceReport(stateDirectory: $0.stateDirectory) },
      payloadFragments: try fragmentReport(db))
  }

  private func definitionReport(_ db: SQLiteDatabase, workingDirectory: String) throws -> StorageDoctorDefinitions? {
    guard try db.tableExists("definition_versions") else { return nil }
    let workflows = try db.tableExists("definition_heads")
      ? value(db, "SELECT count(*) AS value FROM definition_heads") : 0
    let versions = try value(db, "SELECT count(*) AS value FROM definition_versions")
    let pins = try db.tableExists("definition_version_pins")
      ? value(db, "SELECT count(*) AS value FROM definition_version_pins") : 0
    let state = try db.tableExists("definition_store_state")
      ? (try db.query("SELECT value FROM definition_store_state WHERE key='retention'").first?["value"] ?? "active") : "active"
    let retention = try WorkflowDefinitionHistoryConfiguration.resolve(
      homeDirectory: CLIRuntimeEnvironment.homeDirectory(), projectDirectory: workingDirectory,
      environment: CLIRuntimeEnvironment.mergedProcessEnvironment())
    let overWindow = try value(db, "SELECT coalesce(sum(max(n - \(retention), 0)),0) AS value " +
      "FROM (SELECT workflow_name, count(*) AS n FROM definition_versions GROUP BY workflow_name)")
    return StorageDoctorDefinitions(workflows: workflows, versions: versions, versionsOverWindow: overWindow,
      pins: pins, retentionState: state)
  }

  private func retentionTarget(sessionRoot: String, workingDirectory: String) -> RetentionTarget? {
    RetentionTargetResolver.resolve(scope: .all,
      homeDirectory: URL(fileURLWithPath: normalizedFilePath(CLIRuntimeEnvironment.homeDirectory())),
      projectDirectory: URL(fileURLWithPath: normalizedFilePath(workingDirectory)), explicitSessionStore: normalizedFilePath(sessionRoot),
      environment: CLIRuntimeEnvironment.mergedProcessEnvironment()).first {
        $0.sessionStoreRoot.map(normalizedFilePath) == normalizedFilePath(sessionRoot)
      }
  }

  private func retentionReport(target: RetentionTarget, sessionRoot: String,
                               workingDirectory: String) throws -> RielaRetentionTargetReport? {
    let scope: RielaGarbageCollectionScope
    switch target.kind {
    case .user: scope = .user
    case .project: scope = .project
    case .explicit: scope = .all
    }
    let request = RielaRetentionRequest(trigger: .manual,
      homeDirectory: URL(fileURLWithPath: normalizedFilePath(CLIRuntimeEnvironment.homeDirectory())),
      projectDirectory: URL(fileURLWithPath: normalizedFilePath(workingDirectory)), explicitSessionStore: normalizedFilePath(sessionRoot),
      environment: CLIRuntimeEnvironment.mergedProcessEnvironment(), scope: scope, dryRun: true)
    return try RielaRetentionService().run(request).targets.first {
      normalizedFilePath($0.root) == normalizedFilePath(target.root)
    }
  }

  private func maintenanceReport(stateDirectory: String) -> StorageDoctorMaintenance? {
    guard let cursor = StorageMaintenanceCursor.read(stateDirectory: stateDirectory) else { return nil }
    let names = ["snapshots", "cliRecords", "nested"]
    let queues = names.compactMap { cursor.queues[$0] }
    let parked = queues.reduce(0) { $0 + $1.parked.count + $1.parkedOverflow }
    let examples = names.flatMap { name in
      (cursor.queues[name]?.parked ?? []).map { StorageDoctorParkedRow(queue: name, key: $0.key, error: $0.error) }
    }
    return .init(parkedCount: parked, parkedExamples: Array(examples.prefix(5)),
      busyCount: queues.reduce(0) { $0 + $1.busy.count }, failedCount: queues.reduce(0) { $0 + $1.failed.count },
      queuesComplete: queues.allSatisfy(\.complete), hint: parked > 0 ? "run riela storage compact --apply" : nil)
  }

  private func fragmentReport(_ db: SQLiteDatabase) throws -> StorageDoctorPayloadFragments? {
    guard try db.tableExists("workflow_runtime_payload_refs") else { return nil }
    let child = "EXISTS (SELECT 1 FROM workflow_runtime_payload_refs f WHERE f.root_session_id=p.root_session_id AND f.digest=p.digest)"
    let unreferenced = """
      NOT EXISTS (SELECT 1 FROM workflow_runtime_executions e WHERE e.root_session_id=p.root_session_id AND e.payload_digest=p.digest)
      AND NOT EXISTS (SELECT 1 FROM workflow_nested_invocation_refs n WHERE n.root_session_id=p.root_session_id AND n.digest=p.digest)
      AND NOT EXISTS (SELECT 1 FROM workflow_runtime_payload_refs f WHERE f.root_session_id=p.root_session_id AND f.digest=p.digest)
      """
    return try .init(
      fragmentRows: value(db, "SELECT count(*) AS value FROM workflow_runtime_payloads p WHERE " + child),
      fragmentBytes: value(db, "SELECT coalesce(sum(byte_count),0) AS value FROM workflow_runtime_payloads p WHERE " + child),
      reducedPayloadRows: value(db, "SELECT count(*) AS value FROM (SELECT DISTINCT root_session_id,parent_digest FROM workflow_runtime_payload_refs)"),
      refRows: value(db, "SELECT count(*) AS value FROM workflow_runtime_payload_refs"),
      danglingRefRows: value(db, """
        SELECT count(*) AS value FROM workflow_runtime_payload_refs f WHERE
        NOT EXISTS (SELECT 1 FROM workflow_runtime_payloads p WHERE p.root_session_id=f.root_session_id AND p.digest=f.parent_digest)
        OR NOT EXISTS (SELECT 1 FROM workflow_runtime_payloads p WHERE p.root_session_id=f.root_session_id AND p.digest=f.digest)
        """),
      unreferencedPayloadRows: value(db, "SELECT count(*) AS value FROM workflow_runtime_payloads p WHERE " + unreferenced),
      unreferencedPayloadBytes: value(db, "SELECT coalesce(sum(byte_count),0) AS value FROM workflow_runtime_payloads p WHERE " + unreferenced))
  }

  private func legacyMemoryBytes(_ db: SQLiteDatabase) throws -> Int64 {
    guard try db.tableExists("memory_evolution") else { return 0 }
    return try value(db, "SELECT coalesce(sum(length(CAST(reverse_delta_json AS BLOB))),0) AS value FROM memory_evolution")
  }

  private func unreferencedAttachmentBytes(_ db: SQLiteDatabase, databasePath: String) throws -> Int64 {
    let root = URL(fileURLWithPath: databasePath).deletingLastPathComponent()
    let memoryId = URL(fileURLWithPath: databasePath).deletingPathExtension().lastPathComponent
    let candidates = [root.appendingPathComponent("files", isDirectory: true)
      .appendingPathComponent(memoryId, isDirectory: true)]
      .filter { FileManager.default.fileExists(atPath: $0.path) }
    guard !candidates.isEmpty else { return 0 }
    var references = Set(try db.tableExists("memory_evolution_attachments")
      ? db.query("SELECT path FROM memory_evolution_attachments").compactMap { $0["path"] }.map(normalizedFilePath) : [])
    if try db.tableExists("memory_files") {
      references.formUnion(try db.query("SELECT path FROM memory_files")
        .compactMap { $0["path"] }.map(normalizedFilePath))
    }
    for table in ["memory_entries", "memory_history_heads"] where try db.tableExists(table) {
      let jsonColumn = table == "memory_entries" ? "payload_json" : "record_json"
      guard try db.tableColumnNames(table).contains(jsonColumn) else { continue }
      references.formUnion(try db.query("SELECT jt.value AS path FROM \(table), json_tree(\(jsonColumn)) jt WHERE jt.type='text' AND jt.key='path'")
        .compactMap { $0["path"] }.map(normalizedFilePath))
    }
    var bytes: Int64 = 0
    for directory in candidates {
      guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { continue }
      for case let file as URL in enumerator {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, !references.contains(normalizedFilePath(file.path)) else { continue }
        bytes += Int64(values.fileSize ?? 0)
      }
    }
    return bytes
  }

  private func normalizedFilePath(_ path: String) -> String {
    let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
    guard let resolved = realpath(standardized, nil) else { return standardized }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  private func text(_ file: StorageDoctorFile) -> String {
    let details: String
    if let memory = file.memory {
      details = "  memory: records \(memory.records), history \(memory.historyBytes) bytes, " +
        "current \(memory.currentBytes) bytes, amplification \(memory.amplification), " +
        "max versions \(memory.maxVersionsPerRecord), legacy \(memory.legacyRecords), " +
        "orphan attachments \(memory.unreferencedAttachmentBytes) bytes, largest records \(memory.largestRecords)\n"
    } else if let session = file.session {
      details = "  sessions: \(session.sessions), inline legacy \(session.legacyInlineSnapshots), " +
        "CLI copies \(session.legacyCLICopies) (\(session.legacyCLICopyBytes) bytes), " +
        "nested embedded \(session.legacyNestedEmbeddedBytes) bytes, " +
        "abandoned candidates \(session.abandonedCandidates), prune blocked \(session.pruneBlocked), largest sessions \(session.largestSessions)\n"
    } else { details = "" }
    let reclaimable = file.reclaimable
    var extra = "  reclaimable: remaining \(reclaimable.remainingBytes) bytes (upper bound; " +
      "free pages \(reclaimable.freePagesBytes), compact \(reclaimable.compactEstimateBytes), prune \(reclaimable.pruneEstimateBytes))\n"
    if let recovery = reclaimable.recovery {
      extra += "  recovery: auto_vacuum=NONE; need \(recovery.requiredFreeBytes) free bytes, available \(recovery.availableFreeBytes.map(String.init) ?? "unknown"); \(recovery.steps)\n"
    }
    if let fragments = file.session?.payloadFragments {
      extra += "  fragments: \(fragments.fragmentRows) rows (\(fragments.fragmentBytes) bytes), refs \(fragments.refRows), " +
        "dangling refs \(fragments.danglingRefRows), unreferenced payloads \(fragments.unreferencedPayloadRows) " +
        "(\(fragments.unreferencedPayloadBytes) bytes)\n"
    }
    if let maintenance = file.session?.maintenance {
      extra += "  maintenance: parked \(maintenance.parkedCount), busy \(maintenance.busyCount), " +
        "failed \(maintenance.failedCount), complete \(maintenance.queuesComplete)" +
        (maintenance.hint.map { "; " + $0 } ?? "") + "\n"
    }
    return "\(file.kind): \(file.path)\n  bytes: \(file.fileBytes) (WAL \(file.walBytes))\n  pages: \(file.pageCount), free: \(file.freePages) (\(file.freeBytes) bytes), autoVacuum: \(file.autoVacuum)\n" + details +
      extra + file.tables.map { "  table \($0.name): \($0.rows) rows, \($0.bytes) bytes\($0.estimated ? " estimated" : "")" }.joined(separator: "\n") + "\n"
  }

  private func value(_ db: SQLiteDatabase, _ sql: String, bindings: [SQLiteValue] = []) throws -> Int64 {
    Int64(try db.query(sql, bindings: bindings).first?["value"] ?? "0") ?? 0
  }

  private func fileSize(_ path: String) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
  }
}

private enum StorageCommandError: Error { case noStores }

enum StorageCommandFailure {
  static func result(_ error: any Error, usagePath: [String]) -> CLICommandResult {
    if CLISubcommandHelp.isCleanExit(error) { return CLISubcommandHelp.result(path: usagePath) }
    let message = (error as? CLIUsageError)?.message ?? String(describing: error)
    let encodedMessage = (try? JSONEncoder().encode(message)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"storage command failed\""
    return CLICommandResult(exitCode: error is CLIUsageError ? .usage : .failure, stdout: "{\"error\":\(encodedMessage)}\n")
  }
}

private extension Collection where Indices: Collection, Index == Int {
  subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
