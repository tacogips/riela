import Foundation
import RielaSQLite

public struct ActivityRequestRecord: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable {
    case pending, answered, cancelled
  }

  public enum Resolution: String, Codable, Sendable {
    case user, timeout, policy, settlement
  }

  public let requestId: String
  public let sessionId: String
  public let executionId: String
  public let toolCallId: String?
  public let title: String?
  public let options: [AdapterPermissionOption]
  public let createdAt: Date
  public let expiresAt: Date
  public private(set) var status: Status
  public private(set) var outcomeOptionId: String?
  public private(set) var resolvedBy: Resolution?
  public private(set) var resolvedAt: Date?

  init(sessionId: String, executionId: String, request: AdapterPermissionRequest, at: Date, expiresAt: Date) {
    self.requestId = "req-" + UUID().uuidString
    self.sessionId = sessionId
    self.executionId = executionId
    self.toolCallId = request.toolCallId
    self.title = request.title
    self.options = request.options
    self.createdAt = at
    self.expiresAt = expiresAt
    self.status = .pending
  }

  private init(row: SQLiteRow) throws {
    guard let id = row["request_id"], let sessionId = row["session_id"], let executionId = row["execution_id"],
      let status = row["status"].flatMap(Status.init(rawValue:))
    else {
      throw BotStoreError(code: "activity_record_invalid", message: "Invalid activity permission request")
    }
    self.requestId = id
    self.sessionId = sessionId
    self.executionId = executionId
    self.toolCallId = row["tool_call_id"]
    self.title = row["title"]
    self.options = try ActivityJournal.decode([AdapterPermissionOption].self, column: "options_text", row: row)
    self.createdAt = try ActivityJournal.date(column: "created_at", row: row)
    self.expiresAt = try ActivityJournal.date(column: "expires_at", row: row)
    self.status = status
    self.outcomeOptionId = row["outcome_option_id"]
    self.resolvedBy = row["resolved_by"].flatMap(Resolution.init(rawValue:))
    self.resolvedAt = try row["resolved_at"].map { _ in try ActivityJournal.date(column: "resolved_at", row: row) }
  }

  var outcome: AdapterPermissionOutcome {
    guard status == .answered, let optionId = outcomeOptionId, options.contains(where: { $0.optionId == optionId }) else {
      return .cancelled
    }
    return .selected(optionId: optionId)
  }

  static func load(id: String, db: SQLiteDatabase) throws -> Self? {
    try db.query(
      "SELECT *, json(options_json) AS options_text FROM activity_requests WHERE request_id = ?",
      bindings: [.text(id)]
    ).first.map(Self.init(row:))
  }

  static func pending(sessionId: String, db: SQLiteDatabase) throws -> [Self] {
    try db.query(
      """
      SELECT *, json(options_json) AS options_text FROM activity_requests
      WHERE session_id = ? AND status = 'pending' ORDER BY created_at, request_id
      """, bindings: [.text(sessionId)]
    ).map(Self.init(row:))
  }

  func insert(db: SQLiteDatabase) throws -> ActivityEventDraft {
    try db.execute(
      """
      INSERT INTO activity_requests
        (request_id, session_id, execution_id, tool_call_id, title, options_json, status, created_at, expires_at)
      VALUES (?, ?, ?, ?, ?, jsonb(?), 'pending', ?, ?)
      """, bindings: [
        .text(requestId), .text(sessionId), .text(executionId), .optionalText(toolCallId), .optionalText(title),
        .text(try ActivityJournal.encode(options)), .text(RoutineStore.timestamp(createdAt)), .text(RoutineStore.timestamp(expiresAt))
      ]
    )
    var payload: JSONObject = [
      "requestId": .string(requestId),
      "options": .array(options.map { .object([
        "optionId": .string($0.optionId), "name": .string($0.name), "kind": .string($0.kind)
      ]) }),
      "expiresAt": .string(RoutineStore.timestamp(expiresAt))
    ]
    payload["toolCallId"] = toolCallId.map(JSONValue.string)
    payload["title"] = title.map(JSONValue.string)
    return .init(kind: .permissionRequested, payload: payload)
  }

  mutating func resolve(
    by resolution: Resolution, optionId: String? = nil, at: Date, db: SQLiteDatabase
  ) throws -> ActivityEventDraft {
    let finalStatus: Status = resolution == .user ? .answered : .cancelled
    let changed = try db.executeAndReturnChangedRowCount(
      """
      UPDATE activity_requests SET status = ?, outcome_option_id = ?, resolved_by = ?, resolved_at = ?
      WHERE request_id = ? AND status = 'pending'
      """, bindings: [
        .text(finalStatus.rawValue), .optionalText(optionId), .text(resolution.rawValue),
        .text(RoutineStore.timestamp(at)), .text(requestId)
      ]
    )
    guard changed == 1 else {
      throw BotStoreError(code: "request_already_resolved", message: "Permission request has already been resolved")
    }
    status = finalStatus
    outcomeOptionId = optionId
    resolvedBy = resolution
    resolvedAt = at
    var payload: JSONObject = [
      "requestId": .string(requestId),
      "outcome": .string(optionId == nil ? "cancelled" : "selected"),
      "resolvedBy": .string(resolution.rawValue)
    ]
    payload["optionId"] = optionId.map(JSONValue.string)
    return .init(kind: .permissionResolved, payload: payload)
  }
}

extension ActivityJournal {
  mutating func settle(
    executionId: String, reason: ActivitySettleReason, stepStatus: String, at: Date, db: SQLiteDatabase
  ) throws {
    guard state.currentExecutionId == executionId else { return }
    try finishMessageIfNeeded(executionId: executionId, at: at, db: db)
    let requests = try ActivityRequestRecord.pending(sessionId: sessionId, db: db).filter { $0.executionId == executionId }
    state.pendingRequestIds = requests.map(\.requestId)
    for var request in requests {
      let event = try request.resolve(by: .settlement, at: at, db: db)
      append([event], executionId: executionId, at: at)
    }
    let events = ActivityReducer.settle(state: &state, reason: reason, stepStatus: stepStatus, at: at)
    append(events, executionId: executionId, at: at)
  }
}

extension BotStore {
  public func answerActivityRequest(
    requestId: String, optionId: String? = nil, decline: Bool = false, now: Date = Date()
  ) throws -> ActivityRequestRecord {
    guard (optionId != nil) != decline else {
      throw BotStoreError(code: "request_answer_invalid", message: "Supply exactly one permission option or decline")
    }
    return try write { db in
      guard var request = try ActivityRequestRecord.load(id: requestId, db: db) else {
        throw BotStoreError(code: "request_not_found", message: "Permission request was not found")
      }
      if request.status == .answered {
        throw BotStoreError(code: "request_already_resolved", message: "Permission request has already been answered")
      }
      guard request.status == .pending, now < request.expiresAt else {
        throw BotStoreError(code: "request_expired", message: "Permission request has expired")
      }
      if let optionId, !request.options.contains(where: { $0.optionId == optionId }) {
        throw BotStoreError(code: "request_option_unknown", message: "Permission option was not offered")
      }
      var journal = try ActivityJournal(sessionId: request.sessionId, db: db)
      let event = try request.resolve(by: .user, optionId: optionId, at: now, db: db)
      journal.state.pendingRequestIds.removeAll { $0 == requestId }
      journal.append([event], executionId: request.executionId, at: now)
      try journal.save(in: db, at: now)
      return request
    }
  }
}
