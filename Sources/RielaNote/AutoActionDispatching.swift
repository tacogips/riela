import Foundation
import RielaSQLite

private let maximumAutoActionDispatchAttempts = 3

public struct NoteAutoActionEvent: Codable, Equatable, Sendable {
  public var trigger: NoteAutoActionTrigger
  public var notebookId: String?
  public var noteId: String?
  public var noteBodyMarkdown: String?
  public var originatingActionId: String?

  public init(
    trigger: NoteAutoActionTrigger,
    notebookId: String? = nil,
    noteId: String? = nil,
    noteBodyMarkdown: String? = nil,
    originatingActionId: String? = nil
  ) {
    self.trigger = trigger
    self.notebookId = notebookId
    self.noteId = noteId
    self.noteBodyMarkdown = noteBodyMarkdown
    self.originatingActionId = originatingActionId
  }
}

public struct AutoActionDispatchRecord: Codable, Equatable, Sendable {
  public var action: AutoAction
  public var event: NoteAutoActionEvent

  public init(action: AutoAction, event: NoteAutoActionEvent) {
    self.action = action
    self.event = event
  }
}

public protocol AutoActionDispatching: Sendable {
  func dispatch(
    _ record: AutoActionDispatchRecord,
    completion: @escaping @Sendable (AutoActionDispatchOutcome) -> Void
  ) throws
}

public enum AutoActionDispatchOutcome: Equatable, Sendable {
  case succeeded
  case failed(String)
}

public enum NoteAutoActionDiagnosticCode: String, Codable, Equatable, Sendable {
  case filterEvaluationFailed = "filter-evaluation-failed"
}

public struct NoteAutoActionDiagnostic: Codable, Equatable, Sendable {
  public var code: NoteAutoActionDiagnosticCode
  public var actionId: String
  public var trigger: NoteAutoActionTrigger
  public var message: String

  public init(
    code: NoteAutoActionDiagnosticCode,
    actionId: String,
    trigger: NoteAutoActionTrigger,
    message: String
  ) {
    self.code = code
    self.actionId = actionId
    self.trigger = trigger
    self.message = message
  }
}

public protocol NoteAutoActionFilterDiagnosticRecording: Sendable {
  func record(_ diagnostic: NoteAutoActionDiagnostic)
}

struct QueuedAutoActionDispatch: Sendable {
  var dispatchId: String
  var record: AutoActionDispatchRecord
}

public extension NoteService {
  func listAutoActions() throws -> [AutoAction] {
    try driver.withDatabase { database in
      try database.query(
        """
        SELECT action_id, trigger, workflow_id,
          CASE WHEN filter_json IS NULL THEN NULL ELSE json(filter_json) END AS filter_json,
          enabled, position, created_at
        FROM auto_actions
        ORDER BY trigger, position, action_id
        """
      ).map(autoAction(from:))
    }
  }

  @discardableResult
  func configureAutoAction(
    actionId: String,
    trigger: NoteAutoActionTrigger,
    workflowId: String,
    filterJSON: String? = nil,
    enabled: Bool = true,
    position: Int = 0
  ) throws -> AutoAction {
    try validateAutoActionFilterJSON(filterJSON)
    return try driver.withDatabase { database in
      try database.transaction { db in
        try db.execute(
          """
          INSERT INTO auto_actions (
            action_id, trigger, workflow_id, filter_json, enabled, position, created_at
          ) VALUES (?, ?, ?, jsonb(?), ?, ?, ?)
          ON CONFLICT(action_id) DO UPDATE SET
            trigger = excluded.trigger,
            workflow_id = excluded.workflow_id,
            filter_json = excluded.filter_json,
            enabled = excluded.enabled,
            position = excluded.position
          """,
          bindings: [
            .text(actionId),
            .text(trigger.rawValue),
            .text(workflowId),
            .optionalText(filterJSON),
            .int(enabled ? 1 : 0),
            .int(Int64(position)),
            .text(NoteStoreClock.system.now())
          ]
        )
        return try requireAutoAction(actionId: actionId, in: db)
      }
    }
  }

  func deleteAutoAction(actionId: String) throws {
    try driver.withDatabase { database in
      try database.transaction { db in
        _ = try requireAutoAction(actionId: actionId, in: db)
        try db.execute("DELETE FROM auto_actions WHERE action_id = ?", bindings: [.text(actionId)])
      }
    }
  }

  func dispatchAutoActions(for event: NoteAutoActionEvent) {
    guard autoActionDispatcher != nil else {
      return
    }
    let queued = (try? driver.withDatabase { database in
      try database.transaction { db in
        try enqueueAutoActions(for: event, in: db)
      }
    }) ?? []
    dispatchQueuedAutoActions(queued)
  }

  func listAutoActionDispatchAttempts(
    status: AutoActionDispatchStatus? = nil
  ) throws -> [AutoActionDispatchAttempt] {
    try driver.withDatabase { database in
      let whereClause = status == nil ? "" : "WHERE status = ?"
      let bindings = status.map { [SQLiteValue.text($0.rawValue)] } ?? []
      return try database.query(
        """
        SELECT dispatch_id, action_id, action_trigger, workflow_id,
          CASE WHEN filter_json IS NULL THEN NULL ELSE json(filter_json) END AS filter_json,
          action_enabled, action_position, action_created_at,
          CASE WHEN event_json IS NULL THEN NULL ELSE json(event_json) END AS event_json,
          status, attempt_count, last_error, created_at, updated_at
        FROM auto_action_dispatches
        \(whereClause)
        ORDER BY created_at, dispatch_id
        """,
        bindings: bindings
      ).map(autoActionDispatchAttempt(from:))
    }
  }

  @discardableResult
  func retryPendingAutoActionDispatches(limit: Int = 50) throws -> Int {
    guard autoActionDispatcher != nil else {
      return 0
    }
    let queued = try driver.withDatabase { database in
      try database.query(
        """
        SELECT dispatch_id, action_id, action_trigger, workflow_id,
          CASE WHEN filter_json IS NULL THEN NULL ELSE json(filter_json) END AS filter_json,
          action_enabled, action_position, action_created_at,
          CASE WHEN event_json IS NULL THEN NULL ELSE json(event_json) END AS event_json,
          status, attempt_count, last_error, created_at, updated_at
        FROM auto_action_dispatches
        WHERE status = ? AND attempt_count < ?
        ORDER BY created_at, dispatch_id
        LIMIT ?
        """,
        bindings: [
          .text(AutoActionDispatchStatus.pending.rawValue),
          .int(Int64(maximumAutoActionDispatchAttempts)),
          .int(Int64(limit))
        ]
      ).map { try queuedAutoActionDispatch(from: $0) }
    }
    dispatchQueuedAutoActions(queued)
    return queued.count
  }

  func recoverInterruptedAutoActionDispatches() throws {
    try driver.withDatabase { database in
      try database.execute(
        """
        UPDATE auto_action_dispatches
        SET status = ?,
          last_error = ?,
          updated_at = ?
        WHERE status = ? AND attempt_count < ?
        """,
        bindings: [
          .text(AutoActionDispatchStatus.pending.rawValue),
          .text("auto-action dispatch was interrupted before completion"),
          .text(NoteStoreClock.system.now()),
          .text(AutoActionDispatchStatus.inFlight.rawValue),
          .int(Int64(maximumAutoActionDispatchAttempts))
        ]
      )
    }
  }
}

extension NoteService {
  func enqueueAutoActions(
    for event: NoteAutoActionEvent,
    in database: SQLiteDatabase
  ) throws -> [QueuedAutoActionDispatch] {
    guard autoActionDispatcher != nil, event.originatingActionId == nil else {
      return []
    }
    let actions = try matchingAutoActions(for: event, in: database)
    var queued: [QueuedAutoActionDispatch] = []
    for action in actions {
      let dispatchId = makeNoteId(prefix: "auto-action-dispatch")
      let now = NoteStoreClock.system.now()
      try database.execute(
        """
        INSERT INTO auto_action_dispatches (
          dispatch_id, action_id, action_trigger, workflow_id, filter_json,
          action_enabled, action_position, action_created_at, event_json,
          status, attempt_count, created_at, updated_at
        ) VALUES (?, ?, ?, ?, jsonb(?), ?, ?, ?, jsonb(?), ?, 0, ?, ?)
        """,
        bindings: [
          .text(dispatchId),
          .text(action.actionId),
          .text(action.trigger.rawValue),
          .text(action.workflowId),
          .optionalText(action.filterJSON),
          .int(action.enabled ? 1 : 0),
          .int(Int64(action.position)),
          .text(action.createdAt),
          .text(try autoActionEventJSON(event)),
          .text(AutoActionDispatchStatus.pending.rawValue),
          .text(now),
          .text(now)
        ]
      )
      queued.append(QueuedAutoActionDispatch(
        dispatchId: dispatchId,
        record: AutoActionDispatchRecord(action: action, event: event)
      ))
    }
    return queued
  }

  func dispatchQueuedAutoActions(_ queued: [QueuedAutoActionDispatch]) {
    guard let autoActionDispatcher else {
      return
    }
    for dispatch in queued {
      do {
        guard try beginAutoActionDispatchAttempt(dispatchId: dispatch.dispatchId) else {
          continue
        }
        try autoActionDispatcher.dispatch(dispatch.record) { outcome in
          switch outcome {
          case .succeeded:
            try? markAutoActionDispatchDispatched(dispatchId: dispatch.dispatchId)
          case .failed(let message):
            try? recordAutoActionDispatchFailure(dispatchId: dispatch.dispatchId, error: message)
          }
        }
      } catch {
        try? recordAutoActionDispatchFailure(dispatchId: dispatch.dispatchId, error: "\(error)")
      }
    }
  }
}

private extension NoteService {
  func matchingAutoActions(for event: NoteAutoActionEvent) throws -> [AutoAction] {
    try driver.withDatabase { database in
      try matchingAutoActions(for: event, in: database)
    }
  }

  func matchingAutoActions(for event: NoteAutoActionEvent, in database: SQLiteDatabase) throws -> [AutoAction] {
    let actions = try database.query(
      """
      SELECT action_id, trigger, workflow_id,
        CASE WHEN filter_json IS NULL THEN NULL ELSE json(filter_json) END AS filter_json,
        enabled, position, created_at
      FROM auto_actions
      WHERE enabled = 1 AND trigger = ?
      ORDER BY position, action_id
      """,
      bindings: [.text(event.trigger.rawValue)]
    ).map(autoAction(from:))
    var matching: [AutoAction] = []
    for action in actions {
      do {
        if try autoAction(action, matches: event, in: database) {
          matching.append(action)
        }
      } catch {
        autoActionDiagnosticRecorder?.record(NoteAutoActionDiagnostic(
          code: .filterEvaluationFailed,
          actionId: action.actionId,
          trigger: action.trigger,
          message: "skipped auto action because filter_json could not be evaluated: \(error)"
        ))
      }
    }
    return matching
  }

  func beginAutoActionDispatchAttempt(dispatchId: String) throws -> Bool {
    try driver.withDatabase { database in
      let changedRows = try database.executeAndReturnChangedRowCount(
        """
        UPDATE auto_action_dispatches
        SET attempt_count = attempt_count + 1,
          status = ?,
          last_error = NULL,
          updated_at = ?
        WHERE dispatch_id = ? AND status = ? AND attempt_count < ?
        """,
        bindings: [
          .text(AutoActionDispatchStatus.inFlight.rawValue),
          .text(NoteStoreClock.system.now()),
          .text(dispatchId),
          .text(AutoActionDispatchStatus.pending.rawValue),
          .int(Int64(maximumAutoActionDispatchAttempts))
        ]
      )
      return changedRows == 1
    }
  }

  func recordAutoActionDispatchFailure(dispatchId: String, error: String) throws {
    try driver.withDatabase { database in
      try database.execute(
        """
        UPDATE auto_action_dispatches
        SET status = ?,
          last_error = ?,
          updated_at = ?
        WHERE dispatch_id = ? AND status = ?
        """,
        bindings: [
          .text(AutoActionDispatchStatus.pending.rawValue),
          .text(error),
          .text(NoteStoreClock.system.now()),
          .text(dispatchId),
          .text(AutoActionDispatchStatus.inFlight.rawValue)
        ]
      )
    }
  }

  func markAutoActionDispatchDispatched(dispatchId: String) throws {
    try driver.withDatabase { database in
      try database.execute(
        """
        UPDATE auto_action_dispatches
        SET status = ?,
          last_error = NULL,
          updated_at = ?
        WHERE dispatch_id = ? AND status = ?
        """,
        bindings: [
          .text(AutoActionDispatchStatus.dispatched.rawValue),
          .text(NoteStoreClock.system.now()),
          .text(dispatchId),
          .text(AutoActionDispatchStatus.inFlight.rawValue)
        ]
      )
    }
  }
}

private func autoActionEventJSON(_ event: NoteAutoActionEvent) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let data = try encoder.encode(event)
  guard let json = String(data: data, encoding: .utf8) else {
    throw NoteServiceError.invalidInput("auto action event JSON must be UTF-8")
  }
  return json
}

private func autoActionEvent(from json: String) throws -> NoteAutoActionEvent {
  guard let data = json.data(using: .utf8) else {
    throw NoteServiceError.invalidRow("auto action event JSON is not UTF-8")
  }
  return try JSONDecoder().decode(NoteAutoActionEvent.self, from: data)
}

private func queuedAutoActionDispatch(from row: SQLiteRow) throws -> QueuedAutoActionDispatch {
  let attempt = try autoActionDispatchAttempt(from: row)
  return QueuedAutoActionDispatch(dispatchId: attempt.dispatchId, record: attempt.record)
}

private func autoActionDispatchAttempt(from row: SQLiteRow) throws -> AutoActionDispatchAttempt {
  guard let dispatchId = row["dispatch_id"],
        let actionId = row["action_id"],
        let triggerText = row["action_trigger"],
        let trigger = NoteAutoActionTrigger(rawValue: triggerText),
        let workflowId = row["workflow_id"],
        let enabledText = row["action_enabled"],
        let positionText = row["action_position"],
        let position = Int(positionText),
        let actionCreatedAt = row["action_created_at"],
        let eventJSON = row["event_json"],
        let statusText = row["status"],
        let status = AutoActionDispatchStatus(rawValue: statusText),
        let attemptCountText = row["attempt_count"],
        let attemptCount = Int(attemptCountText),
        let createdAt = row["created_at"],
        let updatedAt = row["updated_at"] else {
    throw NoteServiceError.invalidRow("auto action dispatch row is missing required fields")
  }
  let action = AutoAction(
    actionId: actionId,
    trigger: trigger,
    workflowId: workflowId,
    filterJSON: row["filter_json"] ?? nil,
    enabled: enabledText == "1",
    position: position,
    createdAt: actionCreatedAt
  )
  return AutoActionDispatchAttempt(
    dispatchId: dispatchId,
    record: AutoActionDispatchRecord(action: action, event: try autoActionEvent(from: eventJSON)),
    status: status,
    attemptCount: attemptCount,
    lastError: row["last_error"] ?? nil,
    createdAt: createdAt,
    updatedAt: updatedAt
  )
}

private struct AutoActionFilter: Decodable {
  var noteTags: [String]?
  var notebookKindTag: String?
}

private func validateAutoActionFilterJSON(_ filterJSON: String?) throws {
  guard let filterJSON else {
    return
  }
  guard let filterData = filterJSON.data(using: .utf8) else {
    throw NoteServiceError.invalidInput("auto action filter JSON must be UTF-8")
  }
  do {
    _ = try JSONDecoder().decode(AutoActionFilter.self, from: filterData)
  } catch {
    throw NoteServiceError.invalidInput("invalid auto action filter JSON: \(error)")
  }
}

private func autoAction(_ action: AutoAction, matches event: NoteAutoActionEvent, in database: SQLiteDatabase) throws -> Bool {
  guard let filterJSON = action.filterJSON else {
    return true
  }
  guard let filterData = filterJSON.data(using: .utf8) else {
    return false
  }
  let filter = try JSONDecoder().decode(AutoActionFilter.self, from: filterData)
  if let requiredNoteTags = filter.noteTags, !requiredNoteTags.isEmpty {
    guard let noteId = event.noteId else {
      return false
    }
    let noteTags = try noteTagNames(noteId: noteId, in: database)
    guard Set(requiredNoteTags).isSubset(of: Set(noteTags)) else {
      return false
    }
  }
  if let notebookKindTag = filter.notebookKindTag {
    guard let notebookId = try eventNotebookId(event, in: database) else {
      return false
    }
    guard try notebookTagNames(notebookId: notebookId, in: database).contains(notebookKindTag) else {
      return false
    }
  }
  return true
}

private func eventNotebookId(_ event: NoteAutoActionEvent, in database: SQLiteDatabase) throws -> String? {
  if let notebookId = event.notebookId {
    return notebookId
  }
  guard let noteId = event.noteId else {
    return nil
  }
  let rows = try database.query(
    "SELECT notebook_id FROM notes WHERE note_id = ? LIMIT 1",
    bindings: [.text(noteId)]
  )
  return rows.first?["notebook_id"] ?? nil
}

private func noteTagNames(noteId: String, in database: SQLiteDatabase) throws -> [String] {
  try database.query(
    """
    SELECT t.name
    FROM note_tags nt
    INNER JOIN tags t ON t.tag_id = nt.tag_id
    WHERE nt.note_id = ?
    ORDER BY t.name
    """,
    bindings: [.text(noteId)]
  ).compactMap { $0["name"] }
}

private func notebookTagNames(notebookId: String, in database: SQLiteDatabase) throws -> [String] {
  try database.query(
    """
    SELECT t.name
    FROM notebook_tags nt
    INNER JOIN tags t ON t.tag_id = nt.tag_id
    WHERE nt.notebook_id = ?
    ORDER BY t.name
    """,
    bindings: [.text(notebookId)]
  ).compactMap { $0["name"] }
}

func requireAutoAction(actionId: String, in database: SQLiteDatabase) throws -> AutoAction {
  let rows = try database.query(
    """
    SELECT action_id, trigger, workflow_id,
      CASE WHEN filter_json IS NULL THEN NULL ELSE json(filter_json) END AS filter_json,
      enabled, position, created_at
    FROM auto_actions
    WHERE action_id = ?
    LIMIT 1
    """,
    bindings: [.text(actionId)]
  )
  guard let row = rows.first else {
    throw NoteServiceError.notFound("auto action not found: \(actionId)")
  }
  return try autoAction(from: row)
}

private func autoAction(from row: SQLiteRow) throws -> AutoAction {
  guard let actionId = row["action_id"],
        let triggerText = row["trigger"],
        let trigger = NoteAutoActionTrigger(rawValue: triggerText),
        let workflowId = row["workflow_id"],
        let positionText = row["position"],
        let position = Int(positionText),
        let createdAt = row["created_at"] else {
    throw NoteServiceError.invalidRow("auto action row is missing required fields")
  }
  return AutoAction(
    actionId: actionId,
    trigger: trigger,
    workflowId: workflowId,
    filterJSON: row["filter_json"] ?? nil,
    enabled: row["enabled"] == "1",
    position: position,
    createdAt: createdAt
  )
}
