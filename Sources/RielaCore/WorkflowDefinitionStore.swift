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
  case prune
  case purgeHistory

  /// Retention operations record history removal; they never create a version.
  public var isRetention: Bool { self == .prune || self == .purgeHistory }
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

public enum WorkflowDefinitionHeadMoveDirection: String, Codable, Equatable, Sendable {
  case undo
  case redo
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
  public var defaultHistoryRetention: Int

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
    historyRetention: Int? = nil,
    defaultHistoryRetention: Int = WorkflowDefinitionStore.defaultHistoryRetention
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
    self.defaultHistoryRetention = defaultHistoryRetention
  }
}

public enum WorkflowDefinitionCommitOutcome: Equatable, Sendable {
  case created(WorkflowDefinitionVersion, WorkflowDefinitionAuditRecord)
  case alreadyRegistered(WorkflowDefinitionHead)
}

public struct WorkflowDefinitionRetentionReport: Codable, Equatable, Sendable {
  public var pinsInserted: Int
  public var versionsDropped: Int
  public var auditRowsDropped: Int
  public var freedBytes: Int64
  public var state: String

  public init(pinsInserted: Int, versionsDropped: Int, auditRowsDropped: Int, freedBytes: Int64, state: String) {
    self.pinsInserted = pinsInserted
    self.versionsDropped = versionsDropped
    self.auditRowsDropped = auditRowsDropped
    self.freedBytes = freedBytes
    self.state = state
  }
}

public struct WorkflowDefinitionStoreError: Error, Equatable, CustomStringConvertible, Sendable {
  public enum Code: String, Sendable {
    case missingReason
    case headExists
    case headMissing
    case staleHead
    case versionNotFound
    case versionNotRetained = "definition_version_not_retained"
    case nothingToUndo = "nothing_to_undo"
    case nothingToRedo = "nothing_to_redo"
    case staleRevision = "stale_revision"
    case invalidEvidence
    case invalidRetention
    case storeUnavailable
  }

  public var code: Code
  public var message: String
  public var versionId: String?
  public var retainedVersionIds: [String]?
  public var retainedGenerations: Int?

  public init(code: Code, message: String, versionId: String? = nil, retainedVersionIds: [String]? = nil, retainedGenerations: Int? = nil) {
    self.code = code
    self.message = message
    self.versionId = versionId
    self.retainedVersionIds = retainedVersionIds
    self.retainedGenerations = retainedGenerations
  }

  public var description: String { message }
}

public struct WorkflowDefinitionStore: Sendable {
  public static let defaultHistoryRetention = 10
  public var rootDirectory: String
  let now: @Sendable () -> Date
  let defaultHistoryRetention: Int
  var pinBackfillStatementObserver: (@Sendable (String) -> Void)?

  public init(rootDirectory: String, defaultHistoryRetention: Int = WorkflowDefinitionStore.defaultHistoryRetention,
              now: @escaping @Sendable () -> Date = Date.init) {
    self.rootDirectory = rootDirectory
    self.defaultHistoryRetention = defaultHistoryRetention
    self.now = now
    self.pinBackfillStatementObserver = nil
  }

  public func head(workflowName: String) throws -> WorkflowDefinitionHead? {
    let database = try openDatabase()
    return try readHead(workflowName: workflowName, in: database)
  }

  public func version(versionId: String) throws -> WorkflowDefinitionVersion? {
    let database = try openDatabase()
    let rows = try database.query("SELECT * FROM definition_versions WHERE version_id = ?", bindings: [.text(versionId)])
    if rows.isEmpty, try knownDroppedVersion(versionId, in: database) {
      throw try notRetainedError(versionId, database: database)
    }
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
        throw try notRetainedError(versionId, database: database)
      }
      return nil
    }
    do { return try history(in: database).value(key: workflowName, version: number, currentHeadValue: nil) } catch let error as VersionedHistoryError where error.code == "version_not_retained" {
      throw try notRetainedError(versionId, database: database)
    }
  }

  public func current(workflowName: String) throws -> WorkflowDefinitionCurrent? {
    let database = try openDatabase()
    return try database.transaction(begin: "BEGIN DEFERRED") { transaction in
      guard let head = try readHead(workflowName: workflowName, in: transaction),
            let version = try readVersion(versionId: head.currentVersionId, in: transaction),
            let document = try document(versionId: head.currentVersionId, in: transaction) else {
        return nil
      }
      return WorkflowDefinitionCurrent(head: head, version: version, document: document)
    }
  }

  public func history(workflowName: String, nodeId: String? = nil, limit: Int? = nil) throws -> [WorkflowDefinitionAuditRecord] {
    let database = try openDatabase()
    var sql = "SELECT audit.*, EXISTS(SELECT 1 FROM definition_versions version WHERE version.version_id = audit.version_id) AS retained FROM definition_change_audit audit WHERE audit.workflow_name = ?"
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
      SELECT audit.*, EXISTS(SELECT 1 FROM definition_versions retained_version
        WHERE retained_version.version_id = audit.version_id) AS retained FROM definition_change_audit AS audit
      JOIN definition_change_audit AS origin
        ON origin.workflow_name = audit.workflow_name AND origin.version_id = ?
          AND origin.operation NOT IN (?, ?)
      WHERE audit.workflow_name = ? AND audit.created_order > origin.created_order
        AND audit.operation NOT IN (?, ?)
      ORDER BY audit.created_order ASC
      """,
      bindings: [.text(afterVersionId), .text(WorkflowDefinitionOperation.prune.rawValue),
        .text(WorkflowDefinitionOperation.purgeHistory.rawValue), .text(workflowName),
        .text(WorkflowDefinitionOperation.prune.rawValue), .text(WorkflowDefinitionOperation.purgeHistory.rawValue)]
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
    let requestedRetention = write.historyRetention ?? write.defaultHistoryRetention
    guard (0...10_000).contains(requestedRetention) else {
      throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "definition history retention must be between 0 and 10000")
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
      try releaseStalePins(workflowName: write.workflowName, in: transaction)
      let previousDocument: Data? = nil
      var pins = try WorkflowDefinitionHistorySchema.protectedHistoryVersions(in: transaction, workflowName: write.workflowName,
        currentVersionId: previousHead?.currentVersionId ?? "", lastFileVersionId: previousHead?.lastFileVersionId ?? "",
        cutoff: canonicalDate(now.addingTimeInterval(-24 * 60 * 60)), now: timestamp)
      let state = try transaction.query("SELECT value FROM definition_store_state WHERE key = 'retention'").first?["value"]
      if state == "pendingBackfill" {
        let existingVersions = try transaction.query("SELECT version FROM definition_history_versions WHERE key = ?",
          bindings: [.text(write.workflowName)])
        pins.formUnion(existingVersions.compactMap { $0["version"].flatMap(Int64.init) })
      }
      let engineResult = try engine.write(key: write.workflowName, value: write.documentData,
        currentHeadValue: previousDocument, expectedRevision: Int64(previousHead?.revision ?? 0), force: true,
        retainedGenerations: write.historyRetention,
        defaultRetainedGenerations: write.defaultHistoryRetention, pins: pins)
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
      try transaction.execute("""
        INSERT INTO definition_version_identities(version_id, workflow_name, history_version, created_at)
        VALUES(?,?,?,?)
        """, bindings: [.text(versionId), .text(write.workflowName), .int(engineResult.version), .text(timestamp)])
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
      try WorkflowDefinitionHistorySchema.deleteDroppedVersionsAndOrphanAudit(
        engineResult.droppedVersions, workflowName: write.workflowName, in: transaction)
      return .created(version, audit)
    }
  }

  public func retentionState() throws -> String {
    let database = try openDatabase()
    return try database.query("SELECT value FROM definition_store_state WHERE key = 'retention'").first?["value"] ?? "active"
  }

  public func backfillPinsAndApplyRetention(
    foreignSessionStoreRoots: [String],
    defaultHistoryRetention: Int,
    batchSize: Int = 250
  ) throws -> WorkflowDefinitionRetentionReport {
    guard (0...10_000).contains(defaultHistoryRetention) else {
      throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "definition history retention must be between 0 and 10000")
    }
    guard (1...10_000).contains(batchSize) else {
      throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "definition pin batch size must be between 1 and 10000")
    }
    let database = try openDatabase()
    let insertedBefore = try count("definition_version_pins", in: database)
    for root in foreignSessionStoreRoots {
      try backfillPins(from: root, into: database, batchSize: batchSize)
    }
    try WorkflowDefinitionHistorySchema.backfillSameStorePinsForMaintenance(in: database, batchSize: batchSize)
    return try database.transaction { transaction in
      let insertedAfter = try count("definition_version_pins", in: transaction)
      let beforeVersions = try count("definition_versions", in: transaction)
      let beforeAudit = try count("definition_change_audit", in: transaction)
      let bytesBefore = try historyBytes(in: transaction)
      try applyRetention(defaultHistoryRetention, in: transaction)
      let afterVersions = try count("definition_versions", in: transaction)
      let afterAudit = try count("definition_change_audit", in: transaction)
      let bytesAfter = try historyBytes(in: transaction)
      try transaction.execute("INSERT OR REPLACE INTO definition_store_state(key, value) VALUES ('retention', 'active')")
      return WorkflowDefinitionRetentionReport(
        pinsInserted: insertedAfter - insertedBefore,
        versionsDropped: beforeVersions - afterVersions,
        auditRowsDropped: beforeAudit - afterAudit,
        freedBytes: max(0, bytesBefore - bytesAfter),
        state: "active"
      )
    }
  }

  public func moveHead(
    workflowName: String,
    direction: WorkflowDefinitionHeadMoveDirection,
    reason: String,
    expectedRevision: Int64?,
    expectedVersionId: String?,
    evidence: [WorkflowDefinitionEvidenceRef],
    actorKind: String,
    actorId: String?
  ) throws -> WorkflowDefinitionCommitOutcome {
    try moveHeadWithRevision(workflowName: workflowName, direction: direction, reason: reason,
      expectedRevision: expectedRevision, expectedVersionId: expectedVersionId,
      evidence: evidence, actorKind: actorKind, actorId: actorId).outcome
  }

  public func moveHeadWithRevision(
    workflowName: String,
    direction: WorkflowDefinitionHeadMoveDirection,
    reason: String,
    expectedRevision: Int64?,
    expectedVersionId: String?,
    evidence: [WorkflowDefinitionEvidenceRef],
    actorKind: String,
    actorId: String?
  ) throws -> (outcome: WorkflowDefinitionCommitOutcome, revision: Int) {
    guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw WorkflowDefinitionStoreError(code: .missingReason, message: "definition head changes require a non-empty reason")
    }
    guard evidence.allSatisfy({ !$0.id.isEmpty }) else {
      throw WorkflowDefinitionStoreError(code: .invalidEvidence, message: "definition evidence ids must not be empty")
    }
    let database = try openDatabase()
    return try database.transaction { transaction in
      guard let head = try readHead(workflowName: workflowName, in: transaction) else {
        throw WorkflowDefinitionStoreError(code: .headMissing, message: "definition head does not exist")
      }
      if let expectedRevision, expectedRevision != Int64(head.revision) {
        throw WorkflowDefinitionStoreError(code: .staleRevision, message: "stale_revision: expected head revision \(expectedRevision), actual \(head.revision)")
      }
      if let expectedVersionId, expectedVersionId != head.currentVersionId {
        throw WorkflowDefinitionStoreError(code: .staleHead, message: "definition head changed; expected \(expectedVersionId)")
      }
      guard let currentVersion = try readVersion(versionId: head.currentVersionId, in: transaction),
            let currentDocument = try document(versionId: head.currentVersionId, in: transaction) else {
        throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "definition head document is unavailable")
      }
      let engine = try history(in: transaction)
      let moved: VersionedHistoryHeadMove
      do {
        moved = try direction == .undo
          ? engine.undo(key: workflowName, currentHeadValue: currentDocument, expectedRevision: Int64(head.revision))
          : engine.redo(key: workflowName, currentHeadValue: currentDocument, expectedRevision: Int64(head.revision))
      } catch let error as VersionedHistoryError {
        switch error {
        case let .nothingToUndo(oldest): throw WorkflowDefinitionStoreError(code: .nothingToUndo, message: "nothing_to_undo: no older retained version before \(oldest)")
        case .nothingToRedo: throw WorkflowDefinitionStoreError(code: .nothingToRedo, message: "nothing_to_redo: no newer retained version")
        case let .staleRevision(expected, actual): throw WorkflowDefinitionStoreError(code: .staleRevision, message: "stale_revision: expected head revision \(expected), actual \(actual)")
        default: throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: error.code)
        }
      }
      guard let targetVersion = try transaction.query(
        "SELECT * FROM definition_versions WHERE workflow_name = ? AND history_version = ?",
        bindings: [.text(workflowName), .int(moved.toVersion)]
      ).first.map(mapVersion) else {
        throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "definition history points to a missing version")
      }
      let targetDigest = targetVersion.documentDigest
      let targetData = moved.value
      let diff = WorkflowDefinitionDiff.compute(beforeJSON: currentDocument, afterJSON: targetData)
      let auditId = "defa-\(UUID().uuidString.lowercased())"
      let timestamp = try canonicalDate(now())
      let actor = WorkflowDefinitionActorKind(rawValue: actorKind) ?? .api
      try transaction.execute("""
        INSERT INTO definition_change_audit(audit_id,workflow_name,operation,version_id,previous_version_id,
          target_node_id,target_field,before_digest,after_digest,diff_json,reason,evidence_refs_json,
          actor_kind,actor_id,approval_state,overwritten_changes_json,created_at)
        VALUES(?,?,?,?,?,NULL,NULL,?,?,?,?,?,?,?,'applied',NULL,?)
        """, bindings: [.text(auditId), .text(workflowName), .text(direction.rawValue), .text(targetVersion.versionId),
          .text(currentVersion.versionId), .text(currentVersion.documentDigest), .text(targetDigest),
          .text(try canonicalString(diff)), .text(reason.trimmingCharacters(in: .whitespacesAndNewlines)),
          .text(try canonicalString(evidence)), .text(actor.rawValue), .optionalText(actorId), .text(timestamp)])
      try transaction.execute("UPDATE definition_heads SET current_version_id=?, revision=?, updated_at=? WHERE workflow_name=?",
        bindings: [.text(targetVersion.versionId), .int(moved.revision), .text(timestamp), .text(workflowName)])
      guard let order = try transaction.query("SELECT created_order FROM definition_change_audit WHERE audit_id=?", bindings: [.text(auditId)]).first?[
        "created_order"].flatMap(Int.init) else {
        throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "definition audit order was not assigned")
      }
      let record = WorkflowDefinitionAuditRecord(auditId: auditId, createdOrder: order, workflowName: workflowName,
        operation: direction == .undo ? .undo : .redo, versionId: targetVersion.versionId,
        previousVersionId: currentVersion.versionId, targetNodeId: nil, targetField: nil,
        beforeDigest: currentVersion.documentDigest, afterDigest: targetDigest, diff: diff,
        reason: reason.trimmingCharacters(in: .whitespacesAndNewlines), evidence: evidence,
        actor: WorkflowDefinitionActor(kind: actor, id: actorId), approvalState: .applied,
        overwrittenChanges: nil, createdAt: now())
      return (.created(targetVersion, record), Int(moved.revision))
    }
  }

  func openDatabase() throws -> SQLiteDatabase {
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: rootDirectory)
    let database = try persistence.openDatabase()
    try persistence.prepareSchema(in: database)
    try WorkflowDefinitionStoreSchema.create(in: database)
    return database
  }

  func history(in database: SQLiteDatabase) throws -> VersionedHistoryStore {
    VersionedHistoryStore(tablePrefix: "definition", headStorage: .stored,
      sql: SQLiteDatabaseHistoryExecutor(database: database),
      now: now, withGuardedDelete: { body in try WorkflowDefinitionHistorySchema.withGuardedDelete(database, body: body) })
  }

  private func count(_ table: String, in database: SQLiteDatabase) throws -> Int {
    try database.query("SELECT COUNT(*) AS count FROM \(table)").first?["count"].flatMap(Int.init) ?? 0
  }

  private func historyBytes(in database: SQLiteDatabase) throws -> Int64 {
    try database.query("SELECT COALESCE(SUM(length(blob)), 0) AS bytes FROM definition_history_versions")
      .first?["bytes"].flatMap(Int64.init) ?? 0
  }

  private func applyRetention(_ retention: Int, in database: SQLiteDatabase) throws {
    let workflows = try database.query("SELECT workflow_name,current_version_id,last_file_version_id FROM definition_heads")
    for row in workflows {
      let name = row.string("workflow_name")
      try releaseStalePins(workflowName: name, in: database)
      guard let currentId = row["current_version_id"] else { continue }
      let currentTime = now()
      let pins = try WorkflowDefinitionHistorySchema.protectedHistoryVersions(in: database, workflowName: name,
        currentVersionId: currentId, lastFileVersionId: row.string("last_file_version_id"),
        cutoff: canonicalDate(currentTime.addingTimeInterval(-24 * 60 * 60)), now: canonicalDate(currentTime))
      let saved = try database.query("SELECT retained_generations FROM definition_history_heads WHERE key = ?", bindings: [.text(name)])
        .first?["retained_generations"].flatMap(Int.init)
      let result = try history(in: database).applyRetention(key: name, currentHeadValue: nil,
        retainedGenerations: saved ?? retention, pins: pins)
      try WorkflowDefinitionHistorySchema.deleteDroppedVersionsAndOrphanAudit(result.dropped,
        workflowName: name, in: database)
      if saved == nil {
        try database.execute("UPDATE definition_history_heads SET retained_generations = NULL WHERE key = ?", bindings: [.text(name)])
      }
    }
  }

  private func backfillPins(from root: String, into database: SQLiteDatabase, batchSize: Int) throws {
    let path = WorkflowDefinitionPins.normalizedDatabasePath(rootDirectory: root)
    guard FileManager.default.fileExists(atPath: path) else { return }
    let foreign = try SQLiteDatabase.open(path: path, mode: .strictReadOnly, options: .readOnlyDefault)
    let localPath = WorkflowDefinitionPins.normalizedDatabasePath(rootDirectory: rootDirectory)
    let sources = [
      ("workflow_runtime_snapshots", "workflow_execution_id", "session_json", "$.definitionSource"),
      ("cli_workflow_sessions", "session_id", "record_json", "$.session.definitionSource")
    ]
    for (table, idColumn, jsonColumn, sourcePath) in sources where try foreign.tableExists(table) {
      var cursor: Int64 = 0
      while true {
        let createdAt = table == "workflow_runtime_snapshots" ? "created_at" : "coalesce(json_extract(record_json,'$.session.createdAt'),updated_at)"
        let sql = """
          SELECT rowid, \(idColumn) AS session_id, \(createdAt) AS created_at,
            json_extract(\(jsonColumn), '\(sourcePath).kind') AS kind,
            json_extract(\(jsonColumn), '\(sourcePath).workflowName') AS workflow_name,
            json_extract(\(jsonColumn), '\(sourcePath).versionId') AS version_id,
            json_extract(\(jsonColumn), '\(sourcePath).storeRoot') AS store_root
          FROM \(table) WHERE rowid>? AND json_extract(\(jsonColumn), '\(sourcePath).kind')='store'
          ORDER BY rowid LIMIT \(batchSize)
          """
        pinBackfillStatementObserver?(sql)
        let rows = try foreign.query(sql, bindings: [.int(cursor)])
        guard let last = rows.last else { break }
        cursor = Int64(last["rowid"] ?? "0") ?? cursor
        try database.transaction { transaction in
          for row in rows {
            guard let workflowName = row["workflow_name"], let versionId = row["version_id"],
                  row["store_root"] == nil || WorkflowDefinitionPins.normalizedDatabasePath(rootDirectory: row["store_root"] ?? "") == localPath,
                  let number = try historyVersion(versionId, in: transaction) else { continue }
            try transaction.execute("INSERT OR IGNORE INTO definition_version_pins(workflow_name,history_version,session_store_root,session_id,created_at) VALUES(?,?,?,?,?)",
              bindings: [.text(workflowName), .int(number), .text(WorkflowDefinitionPins.normalizedStoreRoot(rootDirectory: root)),
                .text(row.string("session_id")), .text(row.string("created_at"))])
          }
        }
        if rows.count < batchSize { break }
      }
    }
  }

  func releaseStalePins(workflowName: String, in database: SQLiteDatabase) throws {
    let pins = try database.query("SELECT session_store_root,session_id,created_at FROM definition_version_pins WHERE workflow_name=?",
      bindings: [.text(workflowName)])
    let ownRoot = WorkflowDefinitionPins.normalizedStoreRoot(rootDirectory: rootDirectory)
    let cutoff = try canonicalDate(now().addingTimeInterval(-24 * 60 * 60))
    let stale = pins.filter { $0.string("created_at") <= cutoff }
    let groups = Dictionary(grouping: stale) { WorkflowDefinitionPins.normalizedStoreRoot(rootDirectory: $0.string("session_store_root")) }
    for (sessionRoot, rows) in groups {
      if sessionRoot == ownRoot {
        let live = try sessionIdsExist(rows.map { $0.string("session_id") }, in: database)
        for row in rows where !live.contains(row.string("session_id")) {
          try removePin(row, workflowName: workflowName, in: database)
        }
        continue
      }
      let path = WorkflowDefinitionPins.normalizedDatabasePath(rootDirectory: sessionRoot)
      guard FileManager.default.fileExists(atPath: path) else {
        for row in rows { try removePin(row, workflowName: workflowName, in: database) }
        continue
      }
      let db: SQLiteDatabase
      do { db = try SQLiteDatabase.open(path: path, mode: .strictReadOnly, options: .readOnlyDefault) } catch { continue }
      let live: Set<String>
      do {
        live = try sessionIdsExist(rows.map { $0.string("session_id") }, in: db)
      } catch {
        continue
      }
      for row in rows where !live.contains(row.string("session_id")) {
        try removePin(row, workflowName: workflowName, in: database)
      }
    }
  }

  private func sessionIdsExist(_ sessionIds: [String], in database: SQLiteDatabase) throws -> Set<String> {
    guard !sessionIds.isEmpty else { return [] }
    let placeholders = Array(repeating: "?", count: sessionIds.count).joined(separator: ",")
    var found = Set<String>()
    if try database.tableExists("workflow_runtime_snapshots") {
      let rows = try database.query("SELECT workflow_execution_id AS session_id FROM workflow_runtime_snapshots WHERE workflow_execution_id IN (\(placeholders))",
        bindings: sessionIds.map(SQLiteValue.text))
      found.formUnion(rows.map { $0.string("session_id") })
    }
    if try database.tableExists("cli_workflow_sessions") {
      let rows = try database.query("SELECT session_id FROM cli_workflow_sessions WHERE session_id IN (\(placeholders))",
        bindings: sessionIds.map(SQLiteValue.text))
      found.formUnion(rows.map { $0.string("session_id") })
    }
    if try database.tableExists("session_retention_tombstones") {
      let rows = try database.query("SELECT session_id FROM session_retention_tombstones WHERE session_id IN (\(placeholders))",
        bindings: sessionIds.map(SQLiteValue.text))
      found.subtract(rows.map { $0.string("session_id") })
    }
    return found
  }

  private func removePin(_ row: SQLiteRow, workflowName: String, in database: SQLiteDatabase) throws {
    try database.execute("DELETE FROM definition_version_pins WHERE workflow_name=? AND session_store_root=? AND session_id=?",
      bindings: [.text(workflowName), .text(row.string("session_store_root")), .text(row.string("session_id"))])
  }

  private func historyVersion(_ versionId: String, in database: SQLiteDatabase) throws -> Int64? {
    try database.query("SELECT history_version FROM definition_versions WHERE version_id = ?", bindings: [.text(versionId)])
      .first?["history_version"].flatMap(Int64.init)
  }

  private func knownDroppedVersion(_ versionId: String, in database: SQLiteDatabase) throws -> Bool {
    let rows = try database.query("""
      SELECT 1 FROM definition_version_identities WHERE version_id=?
      UNION SELECT 1 FROM definition_change_audit WHERE version_id=? OR previous_version_id=?
      UNION SELECT 1 FROM definition_versions WHERE parent_version_id=? LIMIT 1
      """, bindings: [.text(versionId), .text(versionId), .text(versionId), .text(versionId)])
    return !rows.isEmpty
  }

  private func notRetainedError(_ versionId: String, database: SQLiteDatabase) throws -> WorkflowDefinitionStoreError {
    let owner = try database.query("""
      SELECT workflow_name FROM definition_version_identities WHERE version_id=?
      UNION SELECT workflow_name FROM definition_change_audit WHERE version_id=? OR previous_version_id=?
      UNION SELECT workflow_name FROM definition_versions WHERE version_id=? OR parent_version_id=? LIMIT 1
      """, bindings: [.text(versionId), .text(versionId), .text(versionId), .text(versionId), .text(versionId)])
      .first?["workflow_name"] ?? ""
    let rows = try database.query("SELECT version_id FROM definition_versions WHERE workflow_name=? ORDER BY history_version DESC",
      bindings: [.text(owner)])
    let retention = try database.query("SELECT retained_generations FROM definition_history_heads WHERE key = ?", bindings: [.text(owner)])
      .first?["retained_generations"].flatMap(Int.init) ?? defaultHistoryRetention
    let ids = rows.map { $0.string("version_id") }
    return WorkflowDefinitionStoreError(code: .versionNotRetained,
      message: "definition_version_not_retained: version \(versionId) is not retained; retained versions: [\(ids.joined(separator: ", "))]; retention: \(retention)",
      versionId: versionId, retainedVersionIds: ids, retainedGenerations: retention)
  }

  func readHead(workflowName: String, in database: SQLiteDatabase) throws -> WorkflowDefinitionHead? {
    let rows = try database.query("SELECT * FROM definition_heads WHERE workflow_name = ?", bindings: [.text(workflowName)])
    guard let row = rows.first else { return nil }
    return WorkflowDefinitionHead(
      workflowName: row.string("workflow_name"), currentVersionId: row.string("current_version_id"),
      lastFileVersionId: row.string("last_file_version_id"), revision: try integer(row, "revision"),
      sourceDirectory: row.string("source_directory"), sourceScope: row.string("source_scope"),
      createdAt: try date(row.string("created_at")), updatedAt: try date(row.string("updated_at"))
    )
  }

  func readVersion(versionId: String, in database: SQLiteDatabase) throws -> WorkflowDefinitionVersion? {
    let rows = try database.query("SELECT * FROM definition_versions WHERE version_id = ?", bindings: [.text(versionId)])
    return try rows.first.map(mapVersion)
  }

  private func document(versionId: String, in database: SQLiteDatabase) throws -> Data? {
    guard let row = try database.query("SELECT workflow_name,history_version FROM definition_versions WHERE version_id=?",
      bindings: [.text(versionId)]).first,
      let number = row["history_version"].flatMap(Int64.init) else { return nil }
    do { return try history(in: database).value(key: row.string("workflow_name"), version: number, currentHeadValue: nil) } catch let error as VersionedHistoryError where error.code == "version_not_retained" {
      throw try notRetainedError(versionId, database: database)
    }
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

  func mapAudit(_ row: SQLiteRow) throws -> WorkflowDefinitionAuditRecord {
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
      createdAt: try date(row.string("created_at")), retained: row["retained"] != "0"
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

  func canonicalString<T: Encodable>(_ value: T) throws -> String {
    guard let string = String(bytes: try JSONCanonical.encode(value), encoding: .utf8) else {
      throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "canonical JSON is not valid UTF-8")
    }
    return string
  }

  private func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
    try JSONCanonical.decoder().decode(type, from: Data(value.utf8))
  }
}
