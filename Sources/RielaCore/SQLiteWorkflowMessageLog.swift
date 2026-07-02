import Foundation
import RielaSQLite

public enum SQLiteWorkflowMessageLogError: Error, Equatable, Sendable {
  case openFailed(String)
  case sqliteFailed(String)
  case jsonBUnavailable
  case invalidJSON(String)
}

public struct SQLiteWorkflowMessageLog: Sendable {
  public struct PayloadScalarFilter: Equatable, Sendable {
    public var key: String
    public var value: JSONValue

    public init(key: String, value: JSONValue) {
      self.key = key
      self.value = value
    }
  }

  public var databasePath: String

  public init(databasePath: String) {
    self.databasePath = databasePath
  }

  public static func defaultDatabasePath(rootDirectory: String) -> String {
    URL(fileURLWithPath: rootDirectory, isDirectory: true)
      .appendingPathComponent("runtime-message-log.sqlite")
      .path
  }

  public func replaceMessages(for workflowExecutionId: String, with messages: [WorkflowMessageRecord]) throws {
    let db = try openDatabase()
    try prepareSchema(in: db)
    try db.transaction { database in
      try replaceMessages(for: workflowExecutionId, with: messages, in: database)
    }
  }

  public func upsertMessages(_ messages: [WorkflowMessageRecord]) throws {
    let db = try openDatabase()
    try prepareSchema(in: db)
    try db.transaction { database in
      try upsertMessages(messages, in: database)
    }
  }

  func replaceMessages(
    for workflowExecutionId: String,
    with messages: [WorkflowMessageRecord],
    in db: SQLiteDatabase
  ) throws {
    try deleteMessages(db, workflowExecutionId: workflowExecutionId)
    for message in messages {
      try insertMessage(db, message)
      try insertPayloadIndexRows(db, message)
    }
  }

  func upsertMessages(_ messages: [WorkflowMessageRecord], in db: SQLiteDatabase) throws {
    for message in messages {
      try upsertMessage(db, message)
      try deletePayloadIndexRows(db, message)
      try insertPayloadIndexRows(db, message)
    }
  }

  func prepareSchema(in db: SQLiteDatabase) throws {
    try ensureSchema(db)
  }

  public func listMessages(
    workflowExecutionId: String,
    toStepId: String? = nil,
    fromStepId: String? = nil,
    payloadScalarFilter: PayloadScalarFilter? = nil
  ) throws -> [WorkflowMessageRecord] {
    let db = try openDatabase(readOnly: true)
    try ensureJSONBAvailable(db)
    return try listMessages(
      workflowExecutionId: workflowExecutionId,
      toStepId: toStepId,
      fromStepId: fromStepId,
      payloadScalarFilter: payloadScalarFilter,
      in: db
    )
  }

  func listMessages(
    workflowExecutionId: String,
    toStepId: String? = nil,
    fromStepId: String? = nil,
    payloadScalarFilter: PayloadScalarFilter? = nil,
    in db: SQLiteDatabase
  ) throws -> [WorkflowMessageRecord] {
    var sql = """
      SELECT m.communication_id, m.workflow_execution_id, m.from_step_id, m.to_step_id,
        m.routing_scope, m.delivery_kind, m.source_step_execution_id,
        m.transition_condition, json(m.payload_json) AS payload_json,
        json(m.artifact_refs_json) AS artifact_refs_json,
        m.lifecycle_status, m.created_order, m.created_at
      FROM workflow_messages m
      """
    var bindings: [SQLiteValue] = []
    if let payloadScalarFilter {
      sql += """

        INNER JOIN workflow_message_payload_index p
          ON p.workflow_execution_id = m.workflow_execution_id
          AND p.communication_id = m.communication_id
          AND p.key = ?
        """
      bindings.append(.text(payloadScalarFilter.key))
    }
    sql += " WHERE m.workflow_execution_id = ?"
    bindings.append(.text(workflowExecutionId))
    if let toStepId {
      sql += " AND m.to_step_id = ?"
      bindings.append(.text(toStepId))
    }
    if let fromStepId {
      sql += " AND m.from_step_id = ?"
      bindings.append(.text(fromStepId))
    }
    if let payloadScalarFilter {
      let scalarPredicate = try scalarFilterPredicate(payloadScalarFilter.value, bindings: &bindings)
      sql += " AND \(scalarPredicate)"
    }
    sql += " ORDER BY m.created_order, m.communication_id"
    return try mapSQLiteError {
      try db.query(sql, bindings: bindings)
    }.map(messageRecord(from:))
  }

  public func jsonPathStringValues(workflowExecutionId: String, path: String) throws -> [String] {
    let db = try openDatabase(readOnly: true)
    try ensureJSONBAvailable(db)
    return try mapSQLiteError {
      try db.query(
        """
        SELECT ifnull(json_extract(payload_json, ?), '') AS value
        FROM workflow_messages
        WHERE workflow_execution_id = ?
        ORDER BY created_order, communication_id
        """,
        bindings: [.text(path), .text(workflowExecutionId)]
      )
    }.compactMap { row in
      let value = row["value"] ?? ""
      return value.isEmpty ? nil : value
    }
  }

  private func openDatabase(readOnly: Bool = false) throws -> SQLiteDatabase {
    do {
      return try SQLiteDatabase.open(
        path: databasePath,
        mode: readOnly ? .readOnly : .readWriteCreate,
        options: readOnly ? .readOnlyDefault : .writableDefault
      )
    } catch let error as SQLiteError where error.operation == .open {
      throw SQLiteWorkflowMessageLogError.openFailed(error.message)
    } catch let error as SQLiteError {
      throw mapSQLiteError(error)
    }
  }

  private func ensureSchema(_ db: SQLiteDatabase) throws {
    try ensureJSONBAvailable(db)
    try mapSQLiteError {
      try db.execute(
      """
      CREATE TABLE IF NOT EXISTS workflow_messages (
        workflow_execution_id TEXT NOT NULL,
        communication_id TEXT NOT NULL,
        from_step_id TEXT,
        to_step_id TEXT,
        routing_scope TEXT NOT NULL,
        delivery_kind TEXT NOT NULL,
        source_step_execution_id TEXT NOT NULL,
        transition_condition TEXT,
        payload_json BLOB NOT NULL CHECK (json_valid(payload_json, 8)),
        artifact_refs_json BLOB NOT NULL CHECK (json_valid(artifact_refs_json, 8)),
        lifecycle_status TEXT NOT NULL,
        created_order INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY (workflow_execution_id, communication_id)
      )
      """
      )
      try db.execute(
      """
      CREATE TABLE IF NOT EXISTS workflow_message_payload_index (
        workflow_execution_id TEXT NOT NULL,
        communication_id TEXT NOT NULL,
        key TEXT NOT NULL,
        value_type TEXT NOT NULL,
        string_value TEXT,
        number_value REAL,
        bool_value INTEGER,
        PRIMARY KEY (workflow_execution_id, communication_id, key)
      )
      """
      )
      try db.execute("CREATE INDEX IF NOT EXISTS idx_workflow_messages_inbox ON workflow_messages (workflow_execution_id, to_step_id, lifecycle_status, created_order, communication_id)")
      try db.execute("CREATE INDEX IF NOT EXISTS idx_workflow_messages_outbox ON workflow_messages (workflow_execution_id, from_step_id, created_order, communication_id)")
      try db.execute("CREATE INDEX IF NOT EXISTS idx_workflow_messages_source_exec ON workflow_messages (source_step_execution_id, created_order)")
      try db.execute("CREATE INDEX IF NOT EXISTS idx_workflow_message_payload_string ON workflow_message_payload_index (workflow_execution_id, key, string_value, communication_id)")
      try db.execute("CREATE INDEX IF NOT EXISTS idx_workflow_message_payload_number ON workflow_message_payload_index (workflow_execution_id, key, number_value, communication_id)")
      try db.execute("CREATE INDEX IF NOT EXISTS idx_workflow_message_payload_bool ON workflow_message_payload_index (workflow_execution_id, key, bool_value, communication_id)")
    }
  }

  private func ensureJSONBAvailable(_ db: SQLiteDatabase) throws {
    do {
      try db.requireJSONBAvailable()
    } catch let error as SQLiteError where error.operation == .jsonBUnavailable {
      throw SQLiteWorkflowMessageLogError.jsonBUnavailable
    } catch let error as SQLiteError {
      throw mapSQLiteError(error)
    }
  }

  private func deleteMessages(_ db: SQLiteDatabase, workflowExecutionId: String) throws {
    try mapSQLiteError {
      try db.execute(
        "DELETE FROM workflow_message_payload_index WHERE workflow_execution_id = ?",
        bindings: [.text(workflowExecutionId)]
      )
      try db.execute(
        "DELETE FROM workflow_messages WHERE workflow_execution_id = ?",
        bindings: [.text(workflowExecutionId)]
      )
    }
  }

  private func deletePayloadIndexRows(_ db: SQLiteDatabase, _ message: WorkflowMessageRecord) throws {
    try mapSQLiteError {
      try db.execute(
        """
        DELETE FROM workflow_message_payload_index
        WHERE workflow_execution_id = ? AND communication_id = ?
        """,
        bindings: [.text(message.workflowExecutionId), .text(message.communicationId)]
      )
    }
  }

  private func insertMessage(_ db: SQLiteDatabase, _ message: WorkflowMessageRecord) throws {
    try mapSQLiteError {
      try db.execute(
      """
      INSERT INTO workflow_messages (
        workflow_execution_id, communication_id, from_step_id, to_step_id,
        routing_scope, delivery_kind, source_step_execution_id, transition_condition,
        payload_json, artifact_refs_json, lifecycle_status, created_order, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, jsonb(?), jsonb(?), ?, ?, ?)
      """,
      bindings: try messageBindings(message)
      )
    }
  }

  private func upsertMessage(_ db: SQLiteDatabase, _ message: WorkflowMessageRecord) throws {
    try mapSQLiteError {
      try db.execute(
      """
      INSERT INTO workflow_messages (
        workflow_execution_id, communication_id, from_step_id, to_step_id,
        routing_scope, delivery_kind, source_step_execution_id, transition_condition,
        payload_json, artifact_refs_json, lifecycle_status, created_order, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, jsonb(?), jsonb(?), ?, ?, ?)
      ON CONFLICT(workflow_execution_id, communication_id) DO UPDATE SET
        from_step_id = excluded.from_step_id,
        to_step_id = excluded.to_step_id,
        routing_scope = excluded.routing_scope,
        delivery_kind = excluded.delivery_kind,
        source_step_execution_id = excluded.source_step_execution_id,
        transition_condition = excluded.transition_condition,
        payload_json = excluded.payload_json,
        artifact_refs_json = excluded.artifact_refs_json,
        lifecycle_status = excluded.lifecycle_status,
        created_order = excluded.created_order,
        created_at = excluded.created_at
      """,
      bindings: try messageBindings(message)
      )
    }
  }

  private func messageBindings(_ message: WorkflowMessageRecord) throws -> [SQLiteValue] {
    [
      .text(message.workflowExecutionId),
      .text(message.communicationId),
      .optionalText(message.fromStepId),
      .optionalText(message.toStepId),
      .text(message.routingScope.rawValue),
      .text(message.deliveryKind.rawValue),
      .text(message.sourceStepExecutionId),
      .optionalText(message.transitionCondition),
      .text(try jsonObjectString(message.payload)),
      .text(try jsonString(message.artifactRefs)),
      .text(message.lifecycleStatus.rawValue),
      .int(Int64(message.createdOrder)),
      .text(Self.dateString(message.createdAt))
    ]
  }

  private func insertPayloadIndexRows(_ db: SQLiteDatabase, _ message: WorkflowMessageRecord) throws {
    for (key, value) in message.payload {
      guard let scalar = SQLitePayloadScalar(value) else {
        continue
      }
      try mapSQLiteError {
        try db.execute(
        """
        INSERT INTO workflow_message_payload_index (
          workflow_execution_id, communication_id, key, value_type,
          string_value, number_value, bool_value
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        bindings: [
          .text(message.workflowExecutionId),
          .text(message.communicationId),
          .text(key),
          .text(scalar.valueType),
          .optionalText(scalar.stringValue),
          .optionalDouble(scalar.numberValue),
          .optionalInt(scalar.boolValue)
        ]
        )
      }
    }
  }

  private func scalarFilterPredicate(_ value: JSONValue, bindings: inout [SQLiteValue]) throws -> String {
    guard let scalar = SQLitePayloadScalar(value) else {
      throw SQLiteWorkflowMessageLogError.invalidJSON("payload scalar filters support string, number, bool, and null values only")
    }
    bindings.append(.text(scalar.valueType))
    switch scalar.value {
    case .null:
      return "p.value_type = ?"
    case .string:
      bindings.append(.optionalText(scalar.stringValue))
      return "p.value_type = ? AND p.string_value = ?"
    case .number:
      bindings.append(.optionalDouble(scalar.numberValue))
      return "p.value_type = ? AND p.number_value = ?"
    case .bool:
      bindings.append(.optionalInt(scalar.boolValue))
      return "p.value_type = ? AND p.bool_value = ?"
    }
  }

  private func messageRecord(from row: SQLiteRow) throws -> WorkflowMessageRecord {
    guard
      let communicationId = row["communication_id"],
      let workflowExecutionId = row["workflow_execution_id"],
      let routingScopeText = row["routing_scope"],
      let routingScope = WorkflowMessageRoutingScope(rawValue: routingScopeText),
      let deliveryKindText = row["delivery_kind"],
      let deliveryKind = WorkflowMessageDeliveryKind(rawValue: deliveryKindText),
      let sourceStepExecutionId = row["source_step_execution_id"],
      let payloadText = row["payload_json"],
      let artifactRefsText = row["artifact_refs_json"],
      let lifecycleStatusText = row["lifecycle_status"],
      let lifecycleStatus = WorkflowMessageLifecycleStatus(rawValue: lifecycleStatusText),
      let createdOrderText = row["created_order"],
      let createdOrder = Int(createdOrderText),
      let createdAtText = row["created_at"],
      let createdAt = Self.date(from: createdAtText)
    else {
      throw SQLiteWorkflowMessageLogError.sqliteFailed("workflow message row is missing required fields")
    }
    return WorkflowMessageRecord(
      communicationId: communicationId,
      workflowExecutionId: workflowExecutionId,
      fromStepId: nonEmpty(row.string("from_step_id")),
      toStepId: nonEmpty(row.string("to_step_id")),
      routingScope: routingScope,
      deliveryKind: deliveryKind,
      sourceStepExecutionId: sourceStepExecutionId,
      transitionCondition: nonEmpty(row.string("transition_condition")),
      payload: try jsonObject(from: payloadText),
      artifactRefs: try jsonArray(from: artifactRefsText),
      lifecycleStatus: lifecycleStatus,
      createdOrder: createdOrder,
      createdAt: createdAt
    )
  }

  private static func dateString(_ date: Date) -> String {
    dateFormatter.string(from: date)
  }

  private static func date(from text: String) -> Date? {
    dateFormatter.date(from: text)
  }
}

private let dateFormatter = LockedISO8601DateFormatter(fallbackFormatOptions: [.withInternetDateTime])

private struct SQLitePayloadScalar {
  enum Value {
    case null
    case string
    case number
    case bool
  }

  var value: Value
  var stringValue: String?
  var numberValue: Double?
  var boolValue: Int?

  init?(_ jsonValue: JSONValue) {
    switch jsonValue {
    case .null:
      value = .null
    case let .string(text):
      value = .string
      stringValue = text
    case let .integer(number):
      value = .number
      numberValue = Double(number)
    case let .number(number):
      value = .number
      numberValue = number
    case let .bool(bool):
      value = .bool
      boolValue = bool ? 1 : 0
    case .array, .object:
      return nil
    }
  }

  var valueType: String {
    switch value {
    case .null:
      return "null"
    case .string:
      return "string"
    case .number:
      return "number"
    case .bool:
      return "bool"
    }
  }
}

private func jsonObjectString(_ object: JSONObject) throws -> String {
  try jsonString(JSONValue.object(object))
}

private func jsonString<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let data = try encoder.encode(value)
  guard let text = String(data: data, encoding: .utf8) else {
    throw SQLiteWorkflowMessageLogError.invalidJSON("encoded JSON is not UTF-8")
  }
  return text
}

private func jsonObject(from text: String) throws -> JSONObject {
  let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  guard case let .object(object) = value else {
    throw SQLiteWorkflowMessageLogError.invalidJSON("workflow message payload must be a JSON object")
  }
  return object
}

private func jsonArray(from text: String) throws -> [String] {
  try JSONDecoder().decode([String].self, from: Data(text.utf8))
}

private func nonEmpty(_ value: String?) -> String? {
  guard let value, !value.isEmpty else {
    return nil
  }
  return value
}

private func mapSQLiteError<T>(_ body: () throws -> T) throws -> T {
  do {
    return try body()
  } catch let error as SQLiteError {
    throw mapSQLiteError(error)
  }
}

private func mapSQLiteError(_ error: SQLiteError) -> SQLiteWorkflowMessageLogError {
  if error.operation == .jsonBUnavailable {
    return .jsonBUnavailable
  }
  return .sqliteFailed(error.message)
}
