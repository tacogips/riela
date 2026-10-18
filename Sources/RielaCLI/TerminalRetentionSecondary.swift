import Foundation
import RielaCore
import RielaSQLite

/// Exact runtime-owned copies only. Never follows paths embedded in payloads.
enum TerminalRetentionSecondary {
  static func decorate(_ supplied: [TerminalRetentionSession], paths: TerminalRetentionPaths) throws -> [TerminalRetentionSession] {
    var rows = Dictionary(uniqueKeysWithValues: supplied.map { ($0.id, $0) })
    for row in supplied {
      let file = try paths.artifactSnapshot(row.id)
      let directory = URL(fileURLWithPath: file).deletingLastPathComponent()
      if FileManager.default.fileExists(atPath: directory.path) {
        let children = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        if children.contains(where: { $0 != "runtime-snapshot.json" }) { rows[row.id]?.protection = "unmanagedSessionArtifacts" }
        guard let iterator = FileManager.default.enumerator(at: directory,
          includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
          throw TerminalRetentionError.unsafePath
        }
        var bytes = row.payloadBytes
        for case let entry as URL in iterator {
          _ = try TerminalRetentionPaths.checked(entry.path)
          let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
          guard values.isSymbolicLink != true else { throw TerminalRetentionError.unsafePath }
          if values.isRegularFile == true { bytes = try TerminalRetentionMetadata.adding(bytes, Int64(values.fileSize ?? 0)) }
        }
        rows[row.id]?.payloadBytes = bytes
      }
    }
    let artifactDB = try artifactDatabase(paths)
    if let artifactDB, try artifactDB.tableExists("workflow_messages") {
      for row in try artifactDB.query("""
        SELECT workflow_execution_id AS id,
          sum(length(CAST(payload_json AS BLOB))+length(CAST(artifact_refs_json AS BLOB))) AS bytes
        FROM workflow_messages GROUP BY workflow_execution_id
        """) {
        if let id = row["id"], let prior = rows[id], let size = row["bytes"].flatMap(Int64.init) {
          rows[id]?.payloadBytes = try TerminalRetentionMetadata.adding(prior.payloadBytes, size)
        }
      }
    }
    for path in try paths.memoryDatabases() {
      let db = try SQLiteDatabase.open(path: path, mode: .strictReadOnly, options: .readOnlyDefault)
      guard try db.tableExists("memory_metadata"), try db.tableExists("memory_entries") else { continue }
      for row in try db.query("""
        SELECT json_extract(e.payload_json,'$.sessionId') AS id FROM memory_entries e
        WHERE json_extract(e.payload_json,'$.source')='riela-node-manager'
          AND EXISTS(SELECT 1 FROM memory_entries r, json_each(r.related_record_ids_json) relation
            WHERE relation.value=e.record_id AND r.record_id<>e.record_id)
        """) {
        if let id = row["id"], rows[id] != nil { rows[id]?.protection = "journalHasDurableReferences" }
      }
      if try db.tableExists("memory_files") {
        for row in try db.query("""
          SELECT json_extract(e.payload_json,'$.sessionId') AS id FROM memory_entries e
          JOIN memory_files f ON f.record_id=e.record_id
          WHERE json_extract(e.payload_json,'$.source')='riela-node-manager'
          """) {
          if let id = row["id"], rows[id] != nil { rows[id]?.protection = "journalHasExternalAttachments" }
        }
      }
      if try db.tableExists("memory_evolution") {
        for row in try db.query("""
          SELECT json_extract(e.payload_json,'$.sessionId') AS id FROM memory_entries e
          JOIN memory_evolution v ON v.record_id=e.record_id AND v.version>1
          WHERE json_extract(e.payload_json,'$.source')='riela-node-manager'
          """) {
          if let id = row["id"], rows[id] != nil { rows[id]?.protection = "journalHasEditedHistory" }
        }
      }
      for row in try db.query("""
        SELECT json_extract(payload_json,'$.sessionId') AS id, workflow_id,
          sum(length(CAST(payload_json AS BLOB))) AS bytes FROM memory_entries
        WHERE json_extract(payload_json,'$.source')='riela-node-manager'
          AND json_extract(payload_json,'$.direction') IN ('inbox','outbox')
        GROUP BY id, workflow_id
        """) {
        if let id = row["id"], let prior = rows[id], prior.workflowId == row["workflow_id"], let bytes = row["bytes"].flatMap(Int64.init) {
          rows[id]?.payloadBytes = try TerminalRetentionMetadata.adding(prior.payloadBytes, bytes)
        }
      }
    }
    return rows.values.sorted { $0.id < $1.id }
  }

  static func clean(ids: [String], workflows: [String: String], paths: TerminalRetentionPaths) throws {
    for path in try paths.memoryDatabases() {
      let db = try SQLiteDatabase.open(path: path, options: .init(enableWAL: false))
      guard try db.tableExists("memory_metadata"), try db.tableExists("memory_entries") else { continue }
      _ = try db.query("PRAGMA secure_delete=ON")
      var removed = 0
      try db.transaction { db in
        for id in ids {
          guard let workflow = workflows[id] else { throw TerminalRetentionError.changedFamily }
          let predicate = """
            workflow_id=? AND json_extract(payload_json,'$.workflowId')=?
              AND json_extract(payload_json,'$.sessionId')=?
              AND json_extract(payload_json,'$.source')='riela-node-manager'
              AND json_extract(payload_json,'$.direction') IN ('inbox','outbox')
            """
          let bindings: [SQLiteValue] = [.text(workflow), .text(workflow), .text(id)]
          // Recheck ownership under this database's write transaction, including
          // recovery after a crash. A prior runtime-store check cannot freeze memory.
          var protections = ["EXISTS(SELECT 1 FROM memory_entries r, json_each(r.related_record_ids_json) relation WHERE relation.value=memory_entries.record_id AND r.record_id<>memory_entries.record_id)"]
          if try db.tableExists("memory_files") {
            protections.append("EXISTS(SELECT 1 FROM memory_files f WHERE f.record_id=memory_entries.record_id)")
          }
          if try db.tableExists("memory_evolution") {
            protections.append("EXISTS(SELECT 1 FROM memory_evolution v WHERE v.record_id=memory_entries.record_id AND v.version>1)")
          }
          let protection = protections.joined(separator: " OR ")
          guard try db.query("SELECT record_id FROM memory_entries WHERE \(predicate) AND (\(protection)) LIMIT 1",
            bindings: bindings).isEmpty else { throw TerminalRetentionError.secondaryProtected(id) }
          let selection = "SELECT record_id FROM memory_entries WHERE \(predicate)"
          if try db.tableExists("memory_evolution") {
            try db.execute("DELETE FROM memory_evolution WHERE record_id IN (\(selection))", bindings: bindings)
          }
          removed += try db.executeAndReturnChangedRowCount("DELETE FROM memory_entries WHERE record_id IN (\(selection))", bindings: bindings)
        }
      }
      if removed > 0 { try reclaim(db) }
    }
    if let db = try artifactDatabase(paths, writable: true) {
      _ = try db.query("PRAGMA secure_delete=ON")
      try db.transaction { db in
        for id in ids { try deleteMessages(id: id, db: db) }
      }
      try reclaim(db)
    }
    for id in ids {
      let path = try paths.artifactSnapshot(id)
      let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
      if FileManager.default.fileExists(atPath: directory),
         try FileManager.default.contentsOfDirectory(atPath: directory).contains(where: { $0 != "runtime-snapshot.json" }) {
        throw TerminalRetentionError.secondaryProtected(id)
      }
      if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
    }
  }

  static func deleteMessages(id: String, db: SQLiteDatabase) throws {
    for table in ["workflow_message_payload_index", "workflow_messages"] where try db.tableExists(table) {
      try db.execute("DELETE FROM \(table) WHERE workflow_execution_id=?", bindings: [.text(id)])
    }
  }

  static func reclaim(_ db: SQLiteDatabase) throws {
    _ = try db.query("PRAGMA secure_delete=ON")
    try checkpoint(db)
    try db.execute("VACUUM")
    try checkpoint(db)
  }

  private static func checkpoint(_ db: SQLiteDatabase) throws {
    let result = try db.query("PRAGMA wal_checkpoint(TRUNCATE)")
    guard result.first?["busy"] != "1" else { throw TerminalRetentionError.reclamationBusy }
  }

  private static func artifactDatabase(_ paths: TerminalRetentionPaths, writable: Bool = false) throws -> SQLiteDatabase? {
    let path = try TerminalRetentionPaths.checkedDatabase(SQLiteWorkflowMessageLog.defaultDatabasePath(rootDirectory: paths.artifactRoot))
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let db = try SQLiteDatabase.open(path: path, mode: writable ? .readWriteCreate : .strictReadOnly, options: writable ? .writableDefault : .readOnlyDefault)
    guard try db.tableExists("workflow_messages") else { throw TerminalRetentionError.foreignDatabase }
    return db
  }
}
