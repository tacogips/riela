import Foundation
import RielaSQLite
import RielaMemory

public enum WorkflowDefinitionOperation: String, Codable, Equatable, Sendable {
  case seed
  case `import`
  case forceUpdate
  case updatePrompt
  case update
  case restore
  case undo
  case redo
}

public enum WorkflowDefinitionActorKind: String, Codable, Equatable, Sendable {
  case user
  case cli
  case api
  case improvementNode
}

public struct WorkflowDefinitionActor: Codable, Equatable, Sendable {
  public var kind: WorkflowDefinitionActorKind
  public var id: String?

  public init(kind: WorkflowDefinitionActorKind, id: String? = nil) {
    self.kind = kind
    self.id = id
  }
}

public enum WorkflowDefinitionEvidenceKind: String, Codable, Equatable, Sendable {
  case session
  case stepExecution
  case review
}

public struct WorkflowDefinitionEvidenceRef: Codable, Equatable, Sendable {
  public var kind: WorkflowDefinitionEvidenceKind
  public var id: String

  public init(kind: WorkflowDefinitionEvidenceKind, id: String) {
    self.kind = kind
    self.id = id
  }

  public static func parse(_ token: String) throws -> Self {
    guard let separator = token.firstIndex(of: ":"), separator != token.startIndex else {
      throw WorkflowDefinitionStoreError(code: .invalidEvidence, message: "evidence must use kind:id")
    }
    let kindText = String(token[..<separator])
    let id = String(token[token.index(after: separator)...])
    guard let kind = WorkflowDefinitionEvidenceKind(rawValue: kindText), !id.isEmpty else {
      throw WorkflowDefinitionStoreError(code: .invalidEvidence, message: "invalid definition evidence reference")
    }
    return Self(kind: kind, id: id)
  }
}

/// The current head of one workflow with its version and document bytes.
public struct WorkflowDefinitionCurrent: Equatable, Sendable {
  public var head: WorkflowDefinitionHead
  public var version: WorkflowDefinitionVersion
  public var document: Data
}

public enum WorkflowDefinitionApprovalState: String, Codable, Equatable, Sendable {
  case applied
}

public struct WorkflowDefinitionDiffEntry: Codable, Equatable, Sendable {
  public enum Operation: String, Codable, Equatable, Sendable {
    case add
    case remove
    case replace
  }

  public var path: String
  public var op: Operation
  public var before: JSONValue?
  public var after: JSONValue?

  public init(path: String, op: Operation, before: JSONValue? = nil, after: JSONValue? = nil) {
    self.path = path
    self.op = op
    self.before = before
    self.after = after
  }
}

public struct WorkflowDefinitionOverwrittenChanges: Codable, Equatable, Sendable {
  public var sinceVersionId: String
  public var auditIds: [String]
  public var diff: [WorkflowDefinitionDiffEntry]

  public init(sinceVersionId: String, auditIds: [String], diff: [WorkflowDefinitionDiffEntry]) {
    self.sinceVersionId = sinceVersionId
    self.auditIds = auditIds
    self.diff = diff
  }
}

public struct WorkflowDefinitionHead: Codable, Equatable, Sendable {
  public var workflowName: String
  public var currentVersionId: String
  public var lastFileVersionId: String
  public var revision: Int
  public var sourceDirectory: String
  public var sourceScope: String
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    workflowName: String,
    currentVersionId: String,
    lastFileVersionId: String,
    revision: Int,
    sourceDirectory: String,
    sourceScope: String,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.workflowName = workflowName
    self.currentVersionId = currentVersionId
    self.lastFileVersionId = lastFileVersionId
    self.revision = revision
    self.sourceDirectory = sourceDirectory
    self.sourceScope = sourceScope
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct WorkflowDefinitionVersion: Codable, Equatable, Sendable {
  public var versionId: String
  public var workflowName: String
  public var parentVersionId: String?
  public var documentDigest: String
  public var operation: WorkflowDefinitionOperation
  public var sourceDirectory: String
  public var sourceScope: String
  public var provenance: String
  public var actor: WorkflowDefinitionActor
  public var createdAt: Date

  public init(
    versionId: String,
    workflowName: String,
    parentVersionId: String?,
    documentDigest: String,
    operation: WorkflowDefinitionOperation,
    sourceDirectory: String,
    sourceScope: String,
    provenance: String,
    actor: WorkflowDefinitionActor,
    createdAt: Date
  ) {
    self.versionId = versionId
    self.workflowName = workflowName
    self.parentVersionId = parentVersionId
    self.documentDigest = documentDigest
    self.operation = operation
    self.sourceDirectory = sourceDirectory
    self.sourceScope = sourceScope
    self.provenance = provenance
    self.actor = actor
    self.createdAt = createdAt
  }
}

public struct WorkflowDefinitionAuditRecord: Codable, Equatable, Sendable {
  public var auditId: String
  public var createdOrder: Int
  public var workflowName: String
  public var operation: WorkflowDefinitionOperation
  public var versionId: String
  public var previousVersionId: String?
  public var targetNodeId: String?
  public var targetField: String?
  public var beforeDigest: String?
  public var afterDigest: String
  public var diff: [WorkflowDefinitionDiffEntry]
  public var reason: String
  public var evidence: [WorkflowDefinitionEvidenceRef]
  public var actor: WorkflowDefinitionActor
  public var approvalState: WorkflowDefinitionApprovalState
  public var overwrittenChanges: WorkflowDefinitionOverwrittenChanges?
  public var createdAt: Date
  public var retained: Bool

  public init(
    auditId: String,
    createdOrder: Int,
    workflowName: String,
    operation: WorkflowDefinitionOperation,
    versionId: String,
    previousVersionId: String?,
    targetNodeId: String?,
    targetField: String?,
    beforeDigest: String?,
    afterDigest: String,
    diff: [WorkflowDefinitionDiffEntry],
    reason: String,
    evidence: [WorkflowDefinitionEvidenceRef],
    actor: WorkflowDefinitionActor,
    approvalState: WorkflowDefinitionApprovalState,
    overwrittenChanges: WorkflowDefinitionOverwrittenChanges?,
    createdAt: Date,
    retained: Bool = true
  ) {
    self.auditId = auditId
    self.createdOrder = createdOrder
    self.workflowName = workflowName
    self.operation = operation
    self.versionId = versionId
    self.previousVersionId = previousVersionId
    self.targetNodeId = targetNodeId
    self.targetField = targetField
    self.beforeDigest = beforeDigest
    self.afterDigest = afterDigest
    self.diff = diff
    self.reason = reason
    self.evidence = evidence
    self.actor = actor
    self.approvalState = approvalState
    self.overwrittenChanges = overwrittenChanges
    self.createdAt = createdAt
    self.retained = retained
  }
}

public struct WorkflowDefinitionSource: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Equatable, Sendable {
    case store
    case file
  }

  public var kind: Kind
  public var workflowName: String
  public var versionId: String?
  public var storeRoot: String?
  public var digest: String
  public var sourcePath: String?
  public var sourceScope: String?

  public init(
    kind: Kind,
    workflowName: String,
    versionId: String? = nil,
    storeRoot: String? = nil,
    digest: String,
    sourcePath: String? = nil,
    sourceScope: String? = nil
  ) {
    self.kind = kind
    self.workflowName = workflowName
    self.versionId = versionId
    self.storeRoot = storeRoot
    self.digest = digest
    self.sourcePath = sourcePath
    self.sourceScope = sourceScope
  }
}

public struct WorkflowDefinitionWrite: Sendable {
  public var workflowName: String
  public var operation: WorkflowDefinitionOperation
  public var documentData: Data
  public var documentDigest: String
  public var sourceDirectory: String
  public var sourceScope: String
  public var provenance: String
  public var actor: WorkflowDefinitionActor
  public var reason: String
  public var evidence: [WorkflowDefinitionEvidenceRef]
  public var targetNodeId: String?
  public var targetField: String?
  public var diff: [WorkflowDefinitionDiffEntry]
  public var overwrittenChanges: WorkflowDefinitionOverwrittenChanges?
  public var expectedCurrentVersionId: String?
  public var historyRetention: Int?

  public init(
    workflowName: String,
    operation: WorkflowDefinitionOperation,
    documentData: Data,
    documentDigest: String,
    sourceDirectory: String,
    sourceScope: String,
    provenance: String,
    actor: WorkflowDefinitionActor,
    reason: String,
    evidence: [WorkflowDefinitionEvidenceRef] = [],
    targetNodeId: String? = nil,
    targetField: String? = nil,
    diff: [WorkflowDefinitionDiffEntry] = [],
    overwrittenChanges: WorkflowDefinitionOverwrittenChanges? = nil,
    expectedCurrentVersionId: String? = nil,
    historyRetention: Int? = nil
  ) {
    self.workflowName = workflowName
    self.operation = operation
    self.documentData = documentData
    self.documentDigest = documentDigest
    self.sourceDirectory = sourceDirectory
    self.sourceScope = sourceScope
    self.provenance = provenance
    self.actor = actor
    self.reason = reason
    self.evidence = evidence
    self.targetNodeId = targetNodeId
    self.targetField = targetField
    self.diff = diff
    self.overwrittenChanges = overwrittenChanges
    self.expectedCurrentVersionId = expectedCurrentVersionId
    self.historyRetention = historyRetention
  }
}

public enum WorkflowDefinitionCommitOutcome: Equatable, Sendable {
  case created(WorkflowDefinitionVersion, WorkflowDefinitionAuditRecord)
  case alreadyRegistered(WorkflowDefinitionHead)
}

public struct WorkflowDefinitionStoreError: Error, Equatable, CustomStringConvertible, Sendable {
  public enum Code: String, Sendable {
    case missingReason
    case headExists
    case headMissing
    case staleHead
    case versionNotFound
    case versionNotRetained
    case invalidEvidence
    case storeUnavailable
  }

  public var code: Code
  public var message: String

  public init(code: Code, message: String) {
    self.code = code
    self.message = message
  }

  public var description: String { message }
}

public struct WorkflowDefinitionStore: Sendable {
  public static let defaultHistoryRetention = 10
  public var rootDirectory: String
  private let now: @Sendable () -> Date

  public init(rootDirectory: String, now: @escaping @Sendable () -> Date = Date.init) {
    self.rootDirectory = rootDirectory
    self.now = now
  }

  public func head(workflowName: String) throws -> WorkflowDefinitionHead? {
    let database = try openDatabase()
    return try readHead(workflowName: workflowName, in: database)
  }

  public func version(versionId: String) throws -> WorkflowDefinitionVersion? {
    let database = try openDatabase()
    let rows = try database.query("SELECT * FROM definition_versions WHERE version_id = ?", bindings: [.text(versionId)])
    return try rows.first.map(mapVersion)
  }

  public func blob(digest: String) throws -> Data? {
    let database = try openDatabase()
    guard let versionId = try database.query("SELECT version_id FROM definition_versions WHERE document_digest = ? LIMIT 1", bindings: [.text(digest)]).first?["version_id"] else { return nil }
    return try document(versionId: versionId)
  }

  public func document(versionId: String) throws -> Data? {
    let database = try openDatabase()
    guard let workflowName = try database.query("SELECT workflow_name FROM definition_versions WHERE version_id = ?", bindings: [.text(versionId)]).first?["workflow_name"],
          let number = try historyVersion(versionId, in: database) else {
      if try knownDroppedVersion(versionId, in: database) {
        throw WorkflowDefinitionStoreError(code: .versionNotRetained, message: "definition version \(versionId) is not retained")
      }
      return nil
    }
    return try history(in: database).value(key: workflowName, version: number, currentHeadValue: nil)
  }

  public func current(workflowName: String) throws -> WorkflowDefinitionCurrent? {
    let database = try openDatabase()
    return try database.transaction(begin: "BEGIN DEFERRED") { transaction in
      guard let head = try readHead(workflowName: workflowName, in: transaction),
            let version = try readVersion(versionId: head.currentVersionId, in: transaction),
            let document = try readBlob(digest: version.documentDigest, in: transaction) else {
        return nil
      }
      return WorkflowDefinitionCurrent(head: head, version: version, document: document)
    }
  }

  public func history(workflowName: String, nodeId: String? = nil, limit: Int? = nil) throws -> [WorkflowDefinitionAuditRecord] {
    let database = try openDatabase()
    var sql = "SELECT * FROM definition_change_audit WHERE workflow_name = ?"
    var bindings: [SQLiteValue] = [.text(workflowName)]
    if let nodeId {
      sql += " AND target_node_id = ?"
      bindings.append(.text(nodeId))
    }
    sql += " ORDER BY created_order DESC"
    if let limit {
      sql += " LIMIT ?"
      bindings.append(.int(Int64(max(0, limit))))
    }
    return try database.query(sql, bindings: bindings).map(mapAudit)
  }

  public func auditRecords(workflowName: String, afterVersionId: String) throws -> [WorkflowDefinitionAuditRecord] {
    let database = try openDatabase()
    let rows = try database.query(
      """
      SELECT audit.* FROM definition_change_audit AS audit
      JOIN definition_change_audit AS origin
        ON origin.workflow_name = audit.workflow_name AND origin.version_id = ?
      WHERE audit.workflow_name = ? AND audit.created_order > origin.created_order
      ORDER BY audit.created_order ASC
      """,
      bindings: [.text(afterVersionId), .text(workflowName)]
    )
    return try rows.map(mapAudit)
  }

  public func commit(_ write: WorkflowDefinitionWrite) throws -> WorkflowDefinitionCommitOutcome {
    guard !write.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw WorkflowDefinitionStoreError(code: .missingReason, message: "definition changes require a non-empty reason")
    }
    guard write.evidence.allSatisfy({ !$0.id.isEmpty }) else {
      throw WorkflowDefinitionStoreError(code: .invalidEvidence, message: "definition evidence ids must not be empty")
    }
    guard JSONCanonical.sha256Hex(write.documentData) == write.documentDigest else {
      throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "definition document digest or UTF-8 encoding is invalid")
    }
    let database = try openDatabase()
    return try database.transaction { transaction in
      let previousHead = try readHead(workflowName: write.workflowName, in: transaction)
      if write.expectedCurrentVersionId == nil, let previousHead {
        return .alreadyRegistered(previousHead)
      }
      if write.expectedCurrentVersionId != nil, previousHead == nil {
        throw WorkflowDefinitionStoreError(code: .headMissing, message: "definition head does not exist")
      }
      if let expected = write.expectedCurrentVersionId,
         expected != previousHead?.currentVersionId {
        throw WorkflowDefinitionStoreError(code: .staleHead, message: "definition head changed; expected \(expected)")
      }

      let now = Date(timeIntervalSince1970: (self.now().timeIntervalSince1970 * 1_000).rounded() / 1_000)
      let timestamp = try canonicalDate(now)
      let engine = try history(in: transaction)
      let previousDocument = try previousHead.flatMap { try readBlob(digest: try readVersion(versionId: $0.currentVersionId, in: transaction)!.documentDigest, in: transaction) }
      let oldVersionRows = try transaction.query("SELECT history_version FROM definition_versions WHERE workflow_name = ? AND version_id IN (?, ?)",
        bindings: [.text(write.workflowName), .text(previousHead?.currentVersionId ?? ""), .text(previousHead?.lastFileVersionId ?? "")])
      var pins = Set(oldVersionRows.compactMap { $0["history_version"].flatMap(Int64.init) })
      let pinRows = try transaction.query("SELECT history_version FROM definition_version_pins WHERE workflow_name = ?", bindings: [.text(write.workflowName)])
      pins.formUnion(pinRows.compactMap { $0["history_version"].flatMap(Int64.init) })
      let recent = try transaction.query("""
        SELECT DISTINCT version.history_version FROM definition_change_audit AS audit
        JOIN definition_versions AS version ON version.version_id = audit.previous_version_id
        WHERE audit.workflow_name = ? AND audit.created_at > ?
        """, bindings: [.text(write.workflowName), .text(canonicalDate(self.now().addingTimeInterval(-24 * 60 * 60)))])
      pins.formUnion(recent.compactMap { $0["history_version"].flatMap(Int64.init) })
      let state = try transaction.query("SELECT value FROM definition_store_state WHERE key = 'retention'").first?["value"]
      let retention = state == "pendingBackfill" ? 0 : (write.historyRetention ?? Self.defaultHistoryRetention)
      let engineResult = try engine.write(key: write.workflowName, value: write.documentData,
        currentHeadValue: previousDocument, expectedRevision: Int64(previousHead?.revision ?? 0), force: false,
        retainedGenerations: retention, defaultRetainedGenerations: Self.defaultHistoryRetention, pins: pins)
      guard engineResult.outcome == .written else {
        if let previousHead { return .alreadyRegistered(previousHead) }
        throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "definition history rejected initial document")
      }
      let versionId = "defv-\(UUID().uuidString.lowercased())"
      let auditId = "defa-\(UUID().uuidString.lowercased())"
      try transaction.execute(
        """
        INSERT INTO definition_versions(
          version_id, workflow_name, parent_version_id, document_digest, operation,
          source_directory, source_scope, provenance, actor_kind, actor_id, created_at, history_version
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        bindings: [.text(versionId), .text(write.workflowName), .optionalText(previousHead?.currentVersionId),
                   .text(write.documentDigest), .text(write.operation.rawValue), .text(write.sourceDirectory),
                   .text(write.sourceScope), .text(write.provenance), .text(write.actor.kind.rawValue),
                   .optionalText(write.actor.id), .text(timestamp), .int(engineResult.version)]
      )
      let previousVersion = try previousHead.flatMap { try readVersion(versionId: $0.currentVersionId, in: transaction) }
      let diffJSON = try canonicalString(write.diff)
      let evidenceJSON = try canonicalString(write.evidence)
      let overwrittenJSON = try write.overwrittenChanges.map(canonicalString)
      try transaction.execute(
        """
        INSERT INTO definition_change_audit(
          audit_id, workflow_name, operation, version_id, previous_version_id,
          target_node_id, target_field, before_digest, after_digest, diff_json,
          reason, evidence_refs_json, actor_kind, actor_id, approval_state,
          overwritten_changes_json, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        bindings: [.text(auditId), .text(write.workflowName), .text(write.operation.rawValue), .text(versionId),
                   .optionalText(previousHead?.currentVersionId), .optionalText(write.targetNodeId),
                   .optionalText(write.targetField), .optionalText(previousVersion?.documentDigest),
                   .text(write.documentDigest), .text(diffJSON), .text(write.reason), .text(evidenceJSON),
                   .text(write.actor.kind.rawValue), .optionalText(write.actor.id),
                   .text(WorkflowDefinitionApprovalState.applied.rawValue), .optionalText(overwrittenJSON), .text(timestamp)]
      )
      let fileOperation = [.seed, .`import`, .forceUpdate].contains(write.operation)
      let lastFileVersionId = fileOperation ? versionId : previousHead?.lastFileVersionId ?? versionId
      let createdAt = try previousHead.map { try canonicalDate($0.createdAt) } ?? timestamp
      try transaction.execute(
        """
        INSERT INTO definition_heads(
          workflow_name, current_version_id, last_file_version_id, revision,
          source_directory, source_scope, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(workflow_name) DO UPDATE SET
          current_version_id = excluded.current_version_id,
          last_file_version_id = excluded.last_file_version_id,
          revision = excluded.revision,
          source_directory = excluded.source_directory,
          source_scope = excluded.source_scope,
          updated_at = excluded.updated_at
        """,
        bindings: [.text(write.workflowName), .text(versionId), .text(lastFileVersionId),
                   .int(engineResult.revision), .text(write.sourceDirectory),
                   .text(write.sourceScope), .text(createdAt), .text(timestamp)]
      )
      let version = WorkflowDefinitionVersion(
        versionId: versionId, workflowName: write.workflowName, parentVersionId: previousHead?.currentVersionId,
        documentDigest: write.documentDigest, operation: write.operation, sourceDirectory: write.sourceDirectory,
        sourceScope: write.sourceScope, provenance: write.provenance, actor: write.actor, createdAt: now
      )
      let orderRows = try transaction.query(
        "SELECT created_order FROM definition_change_audit WHERE audit_id = ?", bindings: [.text(auditId)]
      )
      guard let order = orderRows.first?["created_order"].flatMap(Int.init) else {
        throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "definition audit order was not assigned")
      }
      let audit = WorkflowDefinitionAuditRecord(
        auditId: auditId, createdOrder: order, workflowName: write.workflowName, operation: write.operation,
        versionId: versionId, previousVersionId: previousHead?.currentVersionId, targetNodeId: write.targetNodeId,
        targetField: write.targetField, beforeDigest: previousVersion?.documentDigest, afterDigest: write.documentDigest,
        diff: write.diff, reason: write.reason, evidence: write.evidence, actor: write.actor,
        approvalState: .applied, overwrittenChanges: write.overwrittenChanges, createdAt: now
      )
      try withGuardedDelete(transaction) {
        for dropped in engineResult.droppedVersions {
          try transaction.execute("DELETE FROM definition_versions WHERE workflow_name = ? AND history_version = ?", bindings: [.text(write.workflowName), .int(dropped)])
        }
        try transaction.execute("""
          DELETE FROM definition_change_audit WHERE workflow_name = ?
            AND version_id NOT IN (SELECT version_id FROM definition_versions)
            AND (previous_version_id IS NULL
              OR previous_version_id NOT IN (SELECT version_id FROM definition_versions))
          """, bindings: [.text(write.workflowName)])
      }
      return .created(version, audit)
    }
  }

  private func openDatabase() throws -> SQLiteDatabase {
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: rootDirectory)
    let database = try persistence.openDatabase()
    try persistence.prepareSchema(in: database)
    try WorkflowDefinitionStoreSchema.create(in: database)
    return database
  }

  private func history(in database: SQLiteDatabase) throws -> VersionedHistoryStore {
    VersionedHistoryStore(tablePrefix: "definition", headStorage: .stored,
      sql: SQLiteDatabaseHistoryExecutor(database: database),
      now: now, withGuardedDelete: { body in
        try database.execute("INSERT INTO definition_retention_guard(id) VALUES (1)")
        defer { try? database.execute("DELETE FROM definition_retention_guard WHERE id = 1") }
        try body()
      })
  }

  private func withGuardedDelete(_ database: SQLiteDatabase, body: () throws -> Void) throws {
    try database.execute("INSERT INTO definition_retention_guard(id) VALUES (1)")
    defer { try? database.execute("DELETE FROM definition_retention_guard WHERE id = 1") }
    try body()
  }

  private func historyVersion(_ versionId: String, in database: SQLiteDatabase) throws -> Int64? {
    try database.query("SELECT history_version FROM definition_versions WHERE version_id = ?", bindings: [.text(versionId)])
      .first?["history_version"].flatMap(Int64.init)
  }

  private func knownDroppedVersion(_ versionId: String, in database: SQLiteDatabase) throws -> Bool {
    let rows = try database.query("SELECT 1 FROM definition_change_audit WHERE version_id = ? LIMIT 1", bindings: [.text(versionId)])
    return !rows.isEmpty
  }

  private func readHead(workflowName: String, in database: SQLiteDatabase) throws -> WorkflowDefinitionHead? {
    let rows = try database.query("SELECT * FROM definition_heads WHERE workflow_name = ?", bindings: [.text(workflowName)])
    guard let row = rows.first else { return nil }
    return WorkflowDefinitionHead(
      workflowName: row.string("workflow_name"), currentVersionId: row.string("current_version_id"),
      lastFileVersionId: row.string("last_file_version_id"), revision: try integer(row, "revision"),
      sourceDirectory: row.string("source_directory"), sourceScope: row.string("source_scope"),
      createdAt: try date(row.string("created_at")), updatedAt: try date(row.string("updated_at"))
    )
  }

  private func readVersion(versionId: String, in database: SQLiteDatabase) throws -> WorkflowDefinitionVersion? {
    let rows = try database.query("SELECT * FROM definition_versions WHERE version_id = ?", bindings: [.text(versionId)])
    return try rows.first.map(mapVersion)
  }

  private func readBlob(digest: String, in database: SQLiteDatabase) throws -> Data? {
    guard let row = try database.query("SELECT workflow_name, history_version FROM definition_versions WHERE document_digest = ? LIMIT 1", bindings: [.text(digest)]).first,
          let version = row["history_version"].flatMap(Int64.init) else { return nil }
    return try history(in: database).value(key: row.string("workflow_name"), version: version, currentHeadValue: nil)
  }

  private func mapVersion(_ row: SQLiteRow) throws -> WorkflowDefinitionVersion {
    guard let operation = WorkflowDefinitionOperation(rawValue: row.string("operation")),
          let actorKind = WorkflowDefinitionActorKind(rawValue: row.string("actor_kind")) else {
      throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "stored definition version contains an unknown enum value")
    }
    return WorkflowDefinitionVersion(
      versionId: row.string("version_id"), workflowName: row.string("workflow_name"),
      parentVersionId: row["parent_version_id"], documentDigest: row.string("document_digest"),
      operation: operation, sourceDirectory: row.string("source_directory"), sourceScope: row.string("source_scope"),
      provenance: row.string("provenance"), actor: WorkflowDefinitionActor(kind: actorKind, id: row["actor_id"]),
      createdAt: try date(row.string("created_at"))
    )
  }

  private func mapAudit(_ row: SQLiteRow) throws -> WorkflowDefinitionAuditRecord {
    guard let operation = WorkflowDefinitionOperation(rawValue: row.string("operation")),
          let actorKind = WorkflowDefinitionActorKind(rawValue: row.string("actor_kind")),
          let approval = WorkflowDefinitionApprovalState(rawValue: row.string("approval_state")) else {
      throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "stored definition audit contains an unknown enum value")
    }
    return WorkflowDefinitionAuditRecord(
      auditId: row.string("audit_id"), createdOrder: try integer(row, "created_order"), workflowName: row.string("workflow_name"),
      operation: operation, versionId: row.string("version_id"), previousVersionId: row["previous_version_id"],
      targetNodeId: row["target_node_id"], targetField: row["target_field"], beforeDigest: row["before_digest"],
      afterDigest: row.string("after_digest"), diff: try decode([WorkflowDefinitionDiffEntry].self, row.string("diff_json")),
      reason: row.string("reason"), evidence: try decode([WorkflowDefinitionEvidenceRef].self, row.string("evidence_refs_json")),
      actor: WorkflowDefinitionActor(kind: actorKind, id: row["actor_id"]), approvalState: approval,
      overwrittenChanges: try row["overwritten_changes_json"].map { try decode(WorkflowDefinitionOverwrittenChanges.self, $0) },
      createdAt: try date(row.string("created_at"))
    )
  }

  private func integer(_ row: SQLiteRow, _ key: String) throws -> Int {
    guard let value = row[key].flatMap(Int.init) else {
      throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "stored definition row has invalid \(key)")
    }
    return value
  }

  private func canonicalDate(_ value: Date) throws -> String {
    let data = try JSONCanonical.encode(value)
    return try JSONDecoder().decode(String.self, from: data)
  }

  private func date(_ value: String) throws -> Date {
    try JSONCanonical.decoder().decode(Date.self, from: JSONEncoder().encode(value))
  }

  private func canonicalString<T: Encodable>(_ value: T) throws -> String {
    guard let string = String(bytes: try JSONCanonical.encode(value), encoding: .utf8) else {
      throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "canonical JSON is not valid UTF-8")
    }
    return string
  }

  private func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
    try JSONCanonical.decoder().decode(type, from: Data(value.utf8))
  }
}
