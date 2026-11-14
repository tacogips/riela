#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import RielaSQLite

func nestedCalleeRevision(
  workflow: WorkflowDefinition, nodePayloads: [String: AgentNodePayload]
) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let material = (try? encoder.encode(NestedCalleeRevisionMaterial(
    workflow: workflow,
    nodePayloads: nodePayloads
  ))) ?? Data()
  return "sha256:" + JSONCanonical.sha256Hex(material)
}

struct NestedCalleeRevisionMaterial: Codable {
  let workflow: WorkflowDefinition
  let nodePayloads: [String: AgentNodePayload]
}

private struct NestedCalleePayload: Codable {
  var workflow: WorkflowDefinition?
  var nodePayloads: [String: AgentNodePayload]?
}

/// Immutable identity and prepared child snapshot for one nested invocation.
/// A parent retry may reuse this value, but it must never substitute another
/// child session, branch, or prepared executable state.
public struct WorkflowNestedInvocationReservation: Codable, Equatable, Sendable {
  public var parentSessionId: String
  public var parentStepId: String
  public var resumeStepId: String
  public var sourceStepExecutionId: String
  public var branchId: String
  public var childSnapshot: WorkflowRuntimePersistenceSnapshot
  /// The exact hydrated callee material accepted before the child was
  /// reserved. Recovery executes this durable copy and must never resolve a
  /// mutable workflow ID again. Nil exists only to read pre-generation-4
  /// journals, which fail closed at recovery.
  public var calleeWorkflow: WorkflowDefinition?
  public var calleeNodePayloads: [String: AgentNodePayload]?
  public var calleeRevision: String?

  public init(
    parentSessionId: String,
    parentStepId: String,
    resumeStepId: String,
    sourceStepExecutionId: String,
    branchId: String,
    childSnapshot: WorkflowRuntimePersistenceSnapshot,
    calleeWorkflow: WorkflowDefinition? = nil,
    calleeNodePayloads: [String: AgentNodePayload]? = nil,
    calleeRevision: String? = nil
  ) {
    self.parentSessionId = parentSessionId
    self.parentStepId = parentStepId
    self.resumeStepId = resumeStepId
    self.sourceStepExecutionId = sourceStepExecutionId
    self.branchId = branchId
    self.childSnapshot = childSnapshot
    self.calleeWorkflow = calleeWorkflow
    self.calleeNodePayloads = calleeNodePayloads
    self.calleeRevision = calleeRevision
  }
}

public enum WorkflowNestedInvocationPhase: String, Codable, Equatable, Sendable {
  case prepared
  case childTerminal = "child_terminal"
  case delivered
  /// A child had reached a durable running checkpoint, so a later owner
  /// cannot prove that a non-idempotent node did not take effect. Recovery is
  /// deliberately operator-mediated rather than a silent relaunch.
  case recoveryRequired = "recovery_required"
}

public struct WorkflowNestedInvocationRecord: Codable, Equatable, Sendable {
  public var reservation: WorkflowNestedInvocationReservation
  public var childTerminalSnapshot: WorkflowRuntimePersistenceSnapshot?
  public var parentMessage: WorkflowMessageRecord?
  public var recoveryReason: String?

  public var phase: WorkflowNestedInvocationPhase {
    if recoveryReason != nil { return .recoveryRequired }
    if parentMessage != nil { return .delivered }
    if childTerminalSnapshot != nil { return .childTerminal }
    return .prepared
  }
}

public extension SQLiteWorkflowRuntimePersistenceStore {
  /// The canonical nested-publication boundary.  A parent route which already
  /// contains its accepted staged output, the immutable child intent/snapshot,
  /// and the parent's waiting checkpoint are made visible by one SQLite
  /// commit.  No caller may launch the child until this returns successfully.
  func commitNestedPublication(
    parentSnapshot: WorkflowRuntimePersistenceSnapshot,
    reservation: WorkflowNestedInvocationReservation
  ) throws {
    try validate(reservation)
    guard parentSnapshot.session.sessionId == reservation.parentSessionId else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested publication parent does not match reservation")
    }
    let database = try openDatabase()
    try database.transaction { db in
      let key = try nestedInvocationKey(reservation)
      if let existing = try nestedInvocationRecord(key: key, in: db) {
        guard existing.reservation == reservation else {
          throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested invocation reservation conflicts with durable identity")
        }
      } else {
        let now = Self.dateString(Date())
        try db.execute(
          """
          INSERT INTO workflow_nested_invocations (
            invocation_key, reservation_json, child_terminal_json,
            parent_message_json, created_at, updated_at
          ) VALUES (?, jsonb(?), NULL, NULL, ?, ?)
          """,
          bindings: [.text(key), .text(try encodedReservation(reservation, key: key, in: db)), .text(now), .text(now)]
        )
      }
      try save(reservation.childSnapshot, in: db)
      try save(parentSnapshot, in: db)
    }
  }

  /// Persists the prepared child before launch. The unique invocation key is
  /// parent/session execution/branch identity, so reopen races cannot allocate
  /// a second child session.
  @discardableResult
  func reserveNestedInvocation(
    _ reservation: WorkflowNestedInvocationReservation
  ) throws -> WorkflowNestedInvocationRecord {
    try validate(reservation)
    let database = try openDatabase()
    return try database.transaction { db in
      let key = try nestedInvocationKey(reservation)
      if let existing = try nestedInvocationRecord(key: key, in: db) {
        guard existing.reservation == reservation else {
          throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested invocation reservation conflicts with durable identity")
        }
        return existing
      }
      try save(reservation.childSnapshot, in: db)
      let now = Self.dateString(Date())
      try db.execute(
        """
        INSERT INTO workflow_nested_invocations (
          invocation_key, reservation_json, child_terminal_json,
          parent_message_json, created_at, updated_at
        ) VALUES (?, jsonb(?), NULL, NULL, ?, ?)
        """,
        bindings: [.text(key), .text(try encodedReservation(reservation, key: key, in: db)), .text(now), .text(now)]
      )
      return WorkflowNestedInvocationRecord(
        reservation: reservation, childTerminalSnapshot: nil, parentMessage: nil, recoveryReason: nil
      )
    }
  }

  /// Records the child terminal snapshot independently of parent delivery.
  /// A crash after this call is recoverable: the next owner sees a terminal
  /// child and only has to perform the fenced parent publication.
  @discardableResult
  func recordNestedChildTerminal(
    reservation: WorkflowNestedInvocationReservation,
    terminalSnapshot: WorkflowRuntimePersistenceSnapshot
  ) throws -> WorkflowNestedInvocationRecord {
    try validate(reservation)
    guard terminalSnapshot.session.sessionId == reservation.childSnapshot.session.sessionId,
          terminalSnapshot.session.status.isTerminal else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested child terminal snapshot is invalid")
    }
    let database = try openDatabase()
    return try database.transaction { db in
      let key = try nestedInvocationKey(reservation)
      guard var existing = try nestedInvocationRecord(key: key, in: db) else {
        throw WorkflowRuntimePersistenceStoreError.notFound("nested invocation reservation not found")
      }
      guard existing.reservation == reservation else {
        throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested invocation terminal conflicts with durable identity")
      }
      if let savedTerminal = existing.childTerminalSnapshot {
        guard savedTerminal == terminalSnapshot else {
          throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested child terminal conflicts with durable result")
        }
        return existing
      }
      try save(terminalSnapshot, in: db)
      try db.execute(
        "UPDATE workflow_nested_invocations SET child_terminal_json = jsonb(?), updated_at = ? WHERE invocation_key = ?",
        bindings: [.text(try encodedNestedSnapshot(terminalSnapshot, key: key, role: "terminal", in: db)), .text(Self.dateString(Date())), .text(key)]
      )
      existing.childTerminalSnapshot = terminalSnapshot
      return existing
    }
  }

  /// Fences the durable parent arrival. It can only run after the child
  /// terminal record exists and commits its receipt and parent message in the
  /// same SQLite transaction. Replays return the original receipt; changed
  /// payloads fail closed instead of creating a second arrival.
  @discardableResult
  func publishNestedParentMessage(
    reservation: WorkflowNestedInvocationReservation,
    input: WorkflowMessageAppendInput
  ) throws -> WorkflowNestedInvocationRecord {
    try validate(reservation)
    guard input.workflowExecutionId == reservation.parentSessionId,
          input.fromStepId == reservation.parentStepId,
          input.toStepId == reservation.resumeStepId,
          input.sourceStepExecutionId == reservation.sourceStepExecutionId else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested parent publication does not match its reservation")
    }
    let database = try openDatabase()
    return try database.transaction { db in
      let key = try nestedInvocationKey(reservation)
      guard var existing = try nestedInvocationRecord(key: key, in: db) else {
        throw WorkflowRuntimePersistenceStoreError.notFound("nested invocation reservation not found")
      }
      guard existing.recoveryReason == nil,
            existing.reservation == reservation, existing.childTerminalSnapshot != nil else {
        throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested parent publication requires a matching terminal child")
      }
      if let savedMessage = existing.parentMessage {
        guard nestedMessage(savedMessage, matches: input) else {
          throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested parent publication conflicts with durable receipt")
        }
        return existing
      }
      let rows = try db.query(
        "SELECT MAX(created_order) AS latest_order FROM workflow_messages WHERE workflow_execution_id = ?",
        bindings: [.text(input.workflowExecutionId)]
      )
      let nextOrder = (rows.first?["latest_order"].flatMap(Int.init) ?? 0) + 1
      let message = WorkflowMessageRecord(
        communicationId: "nested-" + key.prefix(32),
        workflowExecutionId: input.workflowExecutionId,
        fromStepId: input.fromStepId,
        toStepId: input.toStepId,
        routingScope: input.routingScope,
        deliveryKind: input.deliveryKind,
        sourceStepExecutionId: input.sourceStepExecutionId,
        transitionCondition: input.transitionCondition,
        payload: input.payload,
        artifactRefs: input.artifactRefs,
        lifecycleStatus: .delivered,
        createdOrder: nextOrder,
        createdAt: Date()
      )
      try SQLiteWorkflowMessageLog(databasePath: Self.defaultDatabasePath(rootDirectory: rootDirectory))
        .upsertMessages([message], in: db)
      try db.execute(
        "UPDATE workflow_nested_invocations SET parent_message_json = jsonb(?), updated_at = ? WHERE invocation_key = ?",
        bindings: [.text(try nestedJSON(message)), .text(Self.dateString(Date())), .text(key)]
      )
      existing.parentMessage = message
      return existing
    }
  }

  func nestedInvocationRecord(
    _ reservation: WorkflowNestedInvocationReservation
  ) throws -> WorkflowNestedInvocationRecord? {
    try validate(reservation)
    guard FileManager.default.fileExists(atPath: Self.defaultDatabasePath(rootDirectory: rootDirectory)) else { return nil }
    let db = try openDatabase(readOnly: true)
    guard try db.tableExists("workflow_nested_invocations") else { return nil }
    return try nestedInvocationRecord(key: nestedInvocationKey(reservation), in: db)
  }

  /// Returns the durable child reservations for one parent. Resume recovery
  /// uses this bounded parent-scoped view to reconcile a crash that occurred
  /// after parent routing advanced but before child delivery was acknowledged.
  func nestedInvocationRecords(parentSessionId: String) throws -> [WorkflowNestedInvocationRecord] {
    guard isSafeId(parentSessionId),
          FileManager.default.fileExists(atPath: Self.defaultDatabasePath(rootDirectory: rootDirectory)) else {
      return []
    }
    let db = try openDatabase(readOnly: true)
    guard try db.tableExists("workflow_nested_invocations") else { return [] }
    let rows = try db.query(
      """
      SELECT json(reservation_json) AS reservation_json,
        invocation_key,
        CASE WHEN child_terminal_json IS NULL THEN NULL ELSE json(child_terminal_json) END AS child_terminal_json,
        CASE WHEN parent_message_json IS NULL THEN NULL ELSE json(parent_message_json) END AS parent_message_json,
        recovery_reason
      FROM workflow_nested_invocations
      WHERE json_extract(reservation_json, '$.parentSessionId') = ?
      ORDER BY invocation_key
      """,
      bindings: [.text(parentSessionId)]
    )
    return try rows.map { row in
      guard let reservationJSON = row["reservation_json"] else {
        throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested invocation record is missing its reservation")
      }
      return WorkflowNestedInvocationRecord(
        reservation: try decodedReservation(reservationJSON, key: row["invocation_key"] ?? "", in: db),
        childTerminalSnapshot: try row["child_terminal_json"].map { try decodedNestedSnapshot($0, key: row["invocation_key"] ?? "", role: "terminal", in: db) },
        parentMessage: try row["parent_message_json"].map { try nestedDecode(WorkflowMessageRecord.self, $0) },
        recoveryReason: row["recovery_reason"]
      )
    }
  }

  /// Fences an unresolved in-flight nested effect. Once recorded, neither a
  /// restarted worker nor a second reopen may launch the reserved child until
  /// explicit reconciliation establishes a terminal receipt.
  @discardableResult
  func requireNestedInvocationRecovery(
    reservation: WorkflowNestedInvocationReservation,
    reason: String
  ) throws -> WorkflowNestedInvocationRecord {
    try validate(reservation)
    guard !reason.isEmpty else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested recovery reason is empty")
    }
    let database = try openDatabase()
    return try database.transaction { db in
      let key = try nestedInvocationKey(reservation)
      guard var existing = try nestedInvocationRecord(key: key, in: db) else {
        throw WorkflowRuntimePersistenceStoreError.notFound("nested invocation reservation not found")
      }
      guard existing.reservation == reservation, existing.parentMessage == nil else {
        throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested recovery state conflicts with durable receipt")
      }
      if let existingReason = existing.recoveryReason {
        guard existingReason == reason else {
          throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested recovery reason conflicts with durable state")
        }
        return existing
      }
      try db.execute(
        "UPDATE workflow_nested_invocations SET recovery_reason = ?, updated_at = ? WHERE invocation_key = ?",
        bindings: [.text(reason), .text(Self.dateString(Date())), .text(key)]
      )
      existing.recoveryReason = reason
      return existing
    }
  }

  /// Looks up a reservation by its immutable invocation identity. Callers
  /// recording terminal state must use the originally persisted reservation,
  /// rather than reconstructing a prepared child snapshot after it has run.
  func nestedInvocationRecord(
    parentSessionId: String,
    sourceStepExecutionId: String,
    branchId: String
  ) throws -> WorkflowNestedInvocationRecord? {
    guard [parentSessionId, sourceStepExecutionId, branchId].allSatisfy(isSafeId),
          FileManager.default.fileExists(atPath: Self.defaultDatabasePath(rootDirectory: rootDirectory)) else {
      return nil
    }
    let db = try openDatabase(readOnly: true)
    guard try db.tableExists("workflow_nested_invocations") else { return nil }
    return try nestedInvocationRecord(
      key: nestedInvocationKey(
        parentSessionId: parentSessionId,
        sourceStepExecutionId: sourceStepExecutionId,
        branchId: branchId
      ),
      in: db
    )
  }

  /// Fences aggregate fanout delivery after every persisted branch has reached
  /// a terminal snapshot. The single durable receipt is copied to every
  /// branch record in the source wave, so a reopened runner can recover from
  /// any branch record without publishing a second join arrival.
  @discardableResult
  func publishFanoutParentMessage(
    parentSessionId: String,
    sourceStepExecutionId: String,
    input: WorkflowMessageAppendInput
  ) throws -> [WorkflowNestedInvocationRecord] {
    guard [parentSessionId, sourceStepExecutionId].allSatisfy(isSafeId),
          input.workflowExecutionId == parentSessionId,
          input.sourceStepExecutionId == sourceStepExecutionId else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed("fanout parent publication identity is invalid")
    }
    let database = try openDatabase()
    return try database.transaction { db in
      let records = try fanoutNestedInvocationRecords(
        parentSessionId: parentSessionId,
        sourceStepExecutionId: sourceStepExecutionId,
        in: db
      )
      guard !records.isEmpty else {
        guard case let .object(join)? = input.payload["fanoutJoin"],
              join["branches"] == .array([]), join["dispatchedBranchIds"] == .array([]),
              join["allBranchesCompleted"] == .bool(true) else {
          throw WorkflowRuntimePersistenceStoreError.notFound("fanout nested invocation reservations not found")
        }
        let key = fanoutReceiptKey(parentSessionId: parentSessionId, sourceStepExecutionId: sourceStepExecutionId)
        let log = SQLiteWorkflowMessageLog(databasePath: Self.defaultDatabasePath(rootDirectory: rootDirectory))
        let prior = try log.listMessages(workflowExecutionId: parentSessionId, toStepId: input.toStepId,
          fromStepId: input.fromStepId, in: db).first { $0.communicationId == "nested-" + key.prefix(32) }
        if let prior {
          guard nestedMessage(prior, matches: input) else {
            throw WorkflowRuntimePersistenceStoreError.sqliteFailed("empty fanout publication conflicts with durable receipt")
          }
        } else {
          _ = try makeNestedParentMessage(key: key, input: input, in: db)
        }
        return []
      }
      guard records.allSatisfy({ $0.record.childTerminalSnapshot != nil && $0.record.recoveryReason == nil }) else {
        throw WorkflowRuntimePersistenceStoreError.sqliteFailed("fanout parent publication requires terminal snapshots for every branch")
      }
      if let saved = records.compactMap(\.record.parentMessage).first {
        guard nestedMessage(saved, matches: input),
              records.allSatisfy({ $0.record.parentMessage == saved }) else {
          throw WorkflowRuntimePersistenceStoreError.sqliteFailed("fanout parent publication conflicts with durable receipt")
        }
        return records.map(\.record)
      }
      let message = try makeNestedParentMessage(key: fanoutReceiptKey(parentSessionId: parentSessionId, sourceStepExecutionId: sourceStepExecutionId), input: input, in: db)
      let now = Self.dateString(Date())
      for record in records {
        try db.execute(
          "UPDATE workflow_nested_invocations SET parent_message_json = jsonb(?), updated_at = ? WHERE invocation_key = ?",
          bindings: [.text(try nestedJSON(message)), .text(now), .text(record.key)]
        )
      }
      return records.map { record in
        var updated = record.record
        updated.parentMessage = message
        return updated
      }
    }
  }

  private func validate(_ reservation: WorkflowNestedInvocationReservation) throws {
    let identifiers = [
      reservation.parentSessionId, reservation.parentStepId, reservation.resumeStepId,
      reservation.sourceStepExecutionId, reservation.branchId,
      reservation.childSnapshot.session.sessionId
    ]
    guard identifiers.allSatisfy(isSafeId),
          reservation.childSnapshot.session.parentSessionId == reservation.parentSessionId,
          reservation.childSnapshot.session.status == .created else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested invocation reservation is invalid")
    }
    if let callee = reservation.calleeWorkflow {
      guard callee.workflowId == reservation.childSnapshot.session.workflowId,
            callee.entryStepId == reservation.childSnapshot.session.entryStepId,
            let revision = reservation.calleeRevision,
            revision == nestedCalleeRevision(workflow: callee, nodePayloads: reservation.calleeNodePayloads ?? [:]) else {
        throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested invocation has an invalid immutable callee snapshot")
      }
    }
  }

  private func nestedInvocationKey(_ reservation: WorkflowNestedInvocationReservation) throws -> String {
    nestedInvocationKey(
      parentSessionId: reservation.parentSessionId,
      sourceStepExecutionId: reservation.sourceStepExecutionId,
      branchId: reservation.branchId
    )
  }

  private func nestedInvocationKey(
    parentSessionId: String,
    sourceStepExecutionId: String,
    branchId: String
  ) -> String {
    let material = [parentSessionId, sourceStepExecutionId, branchId].flatMap { value -> [UInt8] in
      let bytes = Array(value.utf8)
      let count = UInt64(bytes.count).bigEndian
      return withUnsafeBytes(of: count) { Array($0) } + bytes
    }
    return JSONCanonical.sha256Hex(Data(material))
  }

  private func fanoutReceiptKey(parentSessionId: String, sourceStepExecutionId: String) -> String {
    let material = [parentSessionId, sourceStepExecutionId, "fanout-join"].flatMap { value -> [UInt8] in
      let bytes = Array(value.utf8)
      let count = UInt64(bytes.count).bigEndian
      return withUnsafeBytes(of: count) { Array($0) } + bytes
    }
    return JSONCanonical.sha256Hex(Data(material))
  }

  private func fanoutNestedInvocationRecords(
    parentSessionId: String,
    sourceStepExecutionId: String,
    in db: SQLiteDatabase
  ) throws -> [(key: String, record: WorkflowNestedInvocationRecord)] {
    let rows = try db.query(
      """
      SELECT invocation_key, json(reservation_json) AS reservation_json,
        CASE WHEN child_terminal_json IS NULL THEN NULL ELSE json(child_terminal_json) END AS child_terminal_json,
        CASE WHEN parent_message_json IS NULL THEN NULL ELSE json(parent_message_json) END AS parent_message_json,
        recovery_reason
      FROM workflow_nested_invocations
      WHERE json_extract(reservation_json, '$.parentSessionId') = ?
        AND json_extract(reservation_json, '$.sourceStepExecutionId') = ?
        AND json_extract(reservation_json, '$.branchId') LIKE 'fanout-%'
      ORDER BY invocation_key
      """,
      bindings: [.text(parentSessionId), .text(sourceStepExecutionId)]
    )
    return try rows.compactMap { row in
      guard let key = row["invocation_key"], let reservationJSON = row["reservation_json"] else { return nil }
      return (
        key,
        WorkflowNestedInvocationRecord(
          reservation: try decodedReservation(reservationJSON, key: key, in: db),
          childTerminalSnapshot: try row["child_terminal_json"].map { try decodedNestedSnapshot($0, key: key, role: "terminal", in: db) },
          parentMessage: try row["parent_message_json"].map { try nestedDecode(WorkflowMessageRecord.self, $0) },
          recoveryReason: row["recovery_reason"]
        )
      )
    }
  }

  private func makeNestedParentMessage(
    key: String,
    input: WorkflowMessageAppendInput,
    in db: SQLiteDatabase
  ) throws -> WorkflowMessageRecord {
    let rows = try db.query(
      "SELECT MAX(created_order) AS latest_order FROM workflow_messages WHERE workflow_execution_id = ?",
      bindings: [.text(input.workflowExecutionId)]
    )
    let nextOrder = (rows.first?["latest_order"].flatMap(Int.init) ?? 0) + 1
    let message = WorkflowMessageRecord(
      communicationId: "nested-" + key.prefix(32),
      workflowExecutionId: input.workflowExecutionId,
      fromStepId: input.fromStepId,
      toStepId: input.toStepId,
      routingScope: input.routingScope,
      deliveryKind: input.deliveryKind,
      sourceStepExecutionId: input.sourceStepExecutionId,
      transitionCondition: input.transitionCondition,
      payload: input.payload,
      artifactRefs: input.artifactRefs,
      lifecycleStatus: .delivered,
      createdOrder: nextOrder,
      createdAt: Date()
    )
    try SQLiteWorkflowMessageLog(databasePath: Self.defaultDatabasePath(rootDirectory: rootDirectory))
      .upsertMessages([message], in: db)
    return message
  }

  func nestedInvocationRecord(
    key: String,
    in db: SQLiteDatabase
  ) throws -> WorkflowNestedInvocationRecord? {
    let rows = try db.query(
      """
      SELECT json(reservation_json) AS reservation_json,
        CASE WHEN child_terminal_json IS NULL THEN NULL ELSE json(child_terminal_json) END AS child_terminal_json,
        CASE WHEN parent_message_json IS NULL THEN NULL ELSE json(parent_message_json) END AS parent_message_json,
        recovery_reason
      FROM workflow_nested_invocations WHERE invocation_key = ? LIMIT 1
      """,
      bindings: [.text(key)]
    )
    guard let row = rows.first, let reservationJSON = row["reservation_json"] else { return nil }
    return WorkflowNestedInvocationRecord(
      reservation: try decodedReservation(reservationJSON, key: key, in: db),
      childTerminalSnapshot: try row["child_terminal_json"].map { try decodedNestedSnapshot($0, key: key, role: "terminal", in: db) },
      parentMessage: try row["parent_message_json"].map { try nestedDecode(WorkflowMessageRecord.self, $0) },
      recoveryReason: row["recovery_reason"]
    )
  }

  private func nestedMessage(_ message: WorkflowMessageRecord, matches input: WorkflowMessageAppendInput) -> Bool {
    message.workflowExecutionId == input.workflowExecutionId && message.fromStepId == input.fromStepId &&
      message.toStepId == input.toStepId && message.routingScope == input.routingScope &&
      message.deliveryKind == input.deliveryKind && message.sourceStepExecutionId == input.sourceStepExecutionId &&
      message.transitionCondition == input.transitionCondition && message.payload == input.payload &&
      message.artifactRefs == input.artifactRefs
  }

  func encodedReservation(
    _ reservation: WorkflowNestedInvocationReservation,
    key: String,
    in db: SQLiteDatabase
  ) throws -> String {
    let references = try persistNestedReferences(reservation.childSnapshot, invocationKey: key, role: "reservation", in: db)
    var value = try nestedJSONObject(reservation)
    let oldCalleeReferences = try db.query(
      "DELETE FROM workflow_nested_invocation_refs WHERE invocation_key=? AND role='callee' RETURNING root_session_id,digest",
      bindings: [.text(key)]
    )
    for row in oldCalleeReferences {
      if let rootId = row["root_session_id"], let digest = row["digest"] {
        try releasePayloadIfUnreferenced(rootId: rootId, digest: digest, in: db)
      }
    }
    if reservation.calleeWorkflow != nil || reservation.calleeNodePayloads != nil {
      let material = NestedCalleePayload(workflow: reservation.calleeWorkflow, nodePayloads: reservation.calleeNodePayloads)
      let payload = try nestedJSON(material)
      let rootId = reservation.childSnapshot.session.rootSessionId ?? reservation.childSnapshot.session.sessionId
      let digest = try insertNestedPayload(payload, ordinal: -1, rootId: rootId, invocationKey: key, role: "callee", in: db)
      value.removeValue(forKey: "calleeWorkflow")
      value.removeValue(forKey: "calleeNodePayloads")
      value["calleeDigest"] = .string(digest)
    }
    value["childSnapshot"] = .object(["session": .object(try nestedSessionStub(reservation.childSnapshot.session))])
    value["childSnapshotStorage"] = .string("refs")
    value["childSnapshotRef"] = .object(references)
    return try nestedJSON(value)
  }

  func encodedNestedSnapshot(
    _ snapshot: WorkflowRuntimePersistenceSnapshot,
    key: String,
    role: String,
    in db: SQLiteDatabase
  ) throws -> String {
    let references = try persistNestedReferences(snapshot, invocationKey: key, role: role, in: db)
    var value = try nestedJSONObject(snapshot)
    value["session"] = .object(try nestedSessionStub(snapshot.session))
    value["childSnapshotStorage"] = .string("refs")
    value["childSnapshotRef"] = .object(references)
    return try nestedJSON(value)
  }

  private func decodedReservation(_ json: String, key: String, in db: SQLiteDatabase) throws -> WorkflowNestedInvocationReservation {
    var value = try nestedJSONObject(from: json)
    if case let .string(digest)? = value["calleeDigest"] {
      let rows = try db.query(
        """
        SELECT json(p.bytes) AS payload
        FROM workflow_nested_invocation_refs AS r
        JOIN workflow_runtime_payloads AS p ON p.root_session_id=r.root_session_id AND p.digest=r.digest
        WHERE r.invocation_key=? AND r.role='callee' AND r.digest=? LIMIT 1
        """,
        bindings: [.text(key), .text(digest)]
      )
      guard let payload = rows.first?["payload"], nestedDigest(payload) == digest else {
        throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested callee payload is missing")
      }
      let material = try nestedDecode(NestedCalleePayload.self, payload)
      if let workflow = material.workflow { value["calleeWorkflow"] = try nestedJSONValue(workflow) }
      if let nodePayloads = material.nodePayloads { value["calleeNodePayloads"] = try nestedJSONValue(nodePayloads) }
      value.removeValue(forKey: "calleeDigest")
    }
    guard value["childSnapshotStorage"] == .string("refs"), let reference = value["childSnapshotRef"] else {
      return try nestedDecode(WorkflowNestedInvocationReservation.self, json)
    }
    value["childSnapshot"] = try hydratedNestedSnapshot(reference, key: key, role: "reservation", in: db)
    value.removeValue(forKey: "childSnapshotStorage")
    value.removeValue(forKey: "childSnapshotRef")
    return try nestedDecode(WorkflowNestedInvocationReservation.self, nestedJSON(value))
  }

  private func decodedNestedSnapshot(_ json: String, key: String, role: String, in db: SQLiteDatabase) throws -> WorkflowRuntimePersistenceSnapshot {
    let value = try nestedJSONObject(from: json)
    guard value["childSnapshotStorage"] == .string("refs"), let reference = value["childSnapshotRef"] else {
      return try nestedDecode(WorkflowRuntimePersistenceSnapshot.self, json)
    }
    let hydrated = try hydratedNestedSnapshot(reference, key: key, role: role, in: db)
    guard case let .object(object) = hydrated else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested snapshot hydration failed")
    }
    return try nestedDecode(WorkflowRuntimePersistenceSnapshot.self, nestedJSON(object))
  }

  private func hydratedNestedSnapshot(_ referenceValue: JSONValue, key: String, role: String, in db: SQLiteDatabase) throws -> JSONValue {
    guard case let .object(reference) = referenceValue,
          case let .string(headerDigest)? = reference["headerDigest"],
          case let .array(executionDigests)? = reference["executionDigests"] else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested snapshot reference is malformed")
    }
    let rows = try db.query(
      """
      SELECT r.ordinal, json(p.bytes) AS payload
      FROM workflow_nested_invocation_refs AS r
      JOIN workflow_runtime_payloads AS p ON p.root_session_id=r.root_session_id AND p.digest=r.digest
      WHERE r.invocation_key=? AND r.role=?
      """,
      bindings: [.text(key), .text(role)]
    )
    var payloads: [Int: String] = [:]
    for row in rows {
      if let ordinal = row["ordinal"].flatMap(Int.init), let payload = row["payload"] { payloads[ordinal] = payload }
    }
    guard let headerJSON = payloads[-1], nestedDigest(headerJSON) == headerDigest else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested snapshot header payload is missing")
    }
    var snapshot = try nestedJSONObject(from: headerJSON)
    guard case var .object(session)? = snapshot["session"] else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested snapshot session header is malformed")
    }
    var executions: [JSONValue] = []
    for (ordinal, digestValue) in executionDigests.enumerated() {
      guard case let .string(digest) = digestValue,
            let payload = payloads[ordinal], nestedDigest(payload) == digest,
            let data = payload.data(using: .utf8) else {
        throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested execution payload is missing")
      }
      executions.append(try JSONDecoder().decode(JSONValue.self, from: data))
    }
    session["executions"] = .array(executions)
    snapshot["session"] = .object(session)
    if reference["rootOutputDigest"] != nil, let payload = payloads[executionDigests.count], let data = payload.data(using: .utf8) {
      snapshot["rootOutput"] = try JSONDecoder().decode(JSONValue.self, from: data)
    }
    if let payload = payloads[executionDigests.count + 1], let data = payload.data(using: .utf8) {
      snapshot["diagnostics"] = try JSONDecoder().decode(JSONValue.self, from: data)
    }
    if reference["loopEvidenceDigest"] != nil, let payload = payloads[executionDigests.count + 2], let data = payload.data(using: .utf8) {
      snapshot["loopEvidence"] = try JSONDecoder().decode(JSONValue.self, from: data)
    }
    return .object(snapshot)
  }

  private func nestedSessionStub(_ session: WorkflowSession) throws -> JSONObject {
    let value = try nestedJSONObject(session)
    let keys = ["sessionId", "workflowId", "status", "parentSessionId", "rootSessionId"]
    return value.filter { keys.contains($0.key) }
  }

  private func nestedJSONObject<T: Encodable>(_ value: T) throws -> JSONObject {
    try nestedJSONObject(from: nestedJSON(value))
  }

  private func nestedJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(nestedJSON(value).utf8))
  }

  private func nestedJSONObject(from json: String) throws -> JSONObject {
    guard let data = json.data(using: .utf8) else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested snapshot JSON is malformed")
    }
    return try JSONDecoder().decode(JSONObject.self, from: data)
  }
}

private func nestedJSON<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  return String(bytes: try encoder.encode(value), encoding: .utf8) ?? "{}"
}

private func nestedDecode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  return try decoder.decode(T.self, from: Data(json.utf8))
}

private func nestedDigest(_ value: String) -> String {
  JSONCanonical.sha256Hex(Data(value.utf8))
}
