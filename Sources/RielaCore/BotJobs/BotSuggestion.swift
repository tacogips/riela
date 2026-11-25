import Foundation
import RielaSQLite

public struct BotSuggestionAction: Codable, Equatable, Sendable {
  public let workflowName: String
  public let input: JSONObject

  public init(workflowName: String, input: JSONObject = [:]) {
    self.workflowName = workflowName
    self.input = input
  }
}

public struct BotSuggestionDraft: Equatable, Sendable {
  public let title: String
  public let detail: String?
  public let action: BotSuggestionAction?

  public init(title: String, detail: String? = nil, action: BotSuggestionAction? = nil) {
    self.title = title
    self.detail = detail
    self.action = action
  }
}

public struct BotSuggestion: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable {
    case open, accepted, started, dismissed
  }

  public let suggestionId: String
  public let botId: String
  public let title: String
  public let detail: String?
  public let action: BotSuggestionAction?
  public let status: Status
  public let createdAt: String
  public let sourceSessionId: String?
  public let acceptedAt: String?
  public let acceptedBy: String?
  public let dismissedAt: String?
  public let dismissedBy: String?
  public let dismissReason: String?
  public let startedSessionId: String?
  public var origin: BotOrigin?

  public func withOrigin(_ origin: BotOrigin) -> Self {
    var copy = self
    copy.origin = origin
    return copy
  }

  public static func parseOutput(_ payload: JSONObject) throws -> [BotSuggestionDraft] {
    guard case let .array(suggestions) = payload["suggestions"] else {
      throw invalidOutput("Look-around output requires a suggestions array")
    }
    var drafts: [BotSuggestionDraft] = []
    for (index, suggestion) in suggestions.enumerated() {
      guard case let .object(fields) = suggestion, case let .string(title) = fields["title"] else {
        throw invalidOutput("Suggestion \(index + 1) requires a string title")
      }
      guard drafts.count < 20 else { continue }
      let detail: String?
      if case let .string(text) = fields["detail"] { detail = text } else { detail = nil }
      drafts.append(BotSuggestionDraft(
        title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)),
        detail: detail,
        action: parseAction(fields["action"])
      ))
    }
    return drafts
  }

  private static func parseAction(_ value: JSONValue?) -> BotSuggestionAction? {
    guard case let .object(fields) = value, case let .string(name) = fields["workflowName"] else { return nil }
    let workflowName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !workflowName.isEmpty else { return nil }
    switch fields["input"] {
    case let .object(input): return BotSuggestionAction(workflowName: workflowName, input: input)
    case nil: return BotSuggestionAction(workflowName: workflowName)
    default: return nil
    }
  }

  private static func invalidOutput(_ message: String) -> BotStoreError {
    BotStoreError(code: "look_around_output_invalid", message: message)
  }
}

extension BotStore {
  @discardableResult
  public func insertSuggestions(
    botId: String, drafts: [BotSuggestionDraft], sourceSessionId: String?, at date: Date
  ) throws -> [BotSuggestion] {
    guard !drafts.isEmpty else { return [] }
    let timestamp = RoutineStore.timestamp(date)
    return try write { database in
      try Self.requireJobBot(botId, in: database)
      return try drafts.map { draft in
        let suggestion = BotSuggestion(
          suggestionId: "sug-\(UUID().uuidString)", botId: botId,
          title: draft.title, detail: draft.detail, action: draft.action,
          status: .open, createdAt: timestamp, sourceSessionId: sourceSessionId,
          acceptedAt: nil, acceptedBy: nil, dismissedAt: nil, dismissedBy: nil,
          dismissReason: nil, startedSessionId: nil
        )
        let json = try Self.suggestionJSON(suggestion)
        try database.execute(
          "INSERT INTO bot_suggestions (suggestion_id, bot_id, record_json, created_at) VALUES (?, ?, jsonb(?), ?)",
          bindings: [.text(suggestion.suggestionId), .text(botId), .text(json), .text(timestamp)]
        )
        return suggestion
      }
    }
  }

  public func suggestions(botId: String, status: BotSuggestion.Status? = nil) throws -> [BotSuggestion] {
    let filter = status == nil ? "" : " AND status = ?"
    var bindings: [SQLiteValue] = [.text(botId)]
    if let status { bindings.append(.text(status.rawValue)) }
    return try read { database in
      try database.query(
        """
        SELECT json(record_json) AS record_json FROM bot_suggestions
        WHERE bot_id = ?\(filter) ORDER BY created_at DESC, suggestion_id ASC
        """,
        bindings: bindings
      ).map(Self.decodeSuggestion)
    } ?? []
  }

  @discardableResult
  public func acceptSuggestion(suggestionId: String, by actor: String, at date: Date) throws -> BotSuggestion {
    try transitionSuggestion(suggestionId, from: .open, to: .accepted, fields: [
      "acceptedAt": .string(RoutineStore.timestamp(date)), "acceptedBy": .string(actor)
    ])
  }

  @discardableResult
  public func dismissSuggestion(
    suggestionId: String, by actor: String, reason: String?, at date: Date
  ) throws -> BotSuggestion {
    try transitionSuggestion(suggestionId, from: .open, to: .dismissed, fields: [
      "dismissedAt": .string(RoutineStore.timestamp(date)), "dismissedBy": .string(actor),
      "dismissReason": reason.map(JSONValue.string) ?? .null
    ])
  }

  @discardableResult
  public func markSuggestionStarted(suggestionId: String, sessionId: String) throws -> BotSuggestion {
    try transitionSuggestion(suggestionId, from: .accepted, to: .started, fields: [
      "startedSessionId": .string(sessionId)
    ])
  }

  private func transitionSuggestion(
    _ suggestionId: String, from: BotSuggestion.Status, to: BotSuggestion.Status, fields: JSONObject
  ) throws -> BotSuggestion {
    var patch = fields
    patch["status"] = .string(to.rawValue)
    let json = try Self.suggestionJSON(patch)
    return try write { database in
      let changed = try database.executeAndReturnChangedRowCount(
        """
        UPDATE bot_suggestions SET record_json = jsonb_patch(record_json, jsonb(?))
        WHERE suggestion_id = ? AND status = ?
        """,
        bindings: [.text(json), .text(suggestionId), .text(from.rawValue)]
      )
      guard let row = try database.query(
        "SELECT json(record_json) AS record_json FROM bot_suggestions WHERE suggestion_id = ?",
        bindings: [.text(suggestionId)]
      ).first else {
        throw BotStoreError(code: "suggestion_not_found", message: "Suggestion '\(suggestionId)' was not found")
      }
      guard changed == 1 else {
        throw BotStoreError(
          code: "suggestion_already_decided", message: "Suggestion '\(suggestionId)' must be \(from.rawValue)"
        )
      }
      return try Self.decodeSuggestion(row)
    }
  }

  private static func suggestionJSON(_ value: some Encodable) throws -> String {
    guard let json = String(bytes: try JSONEncoder().encode(value), encoding: .utf8) else {
      throw BotStoreError(code: "suggestion_invalid", message: "Suggestion could not be encoded as UTF-8 JSON")
    }
    return json
  }

  private static func decodeSuggestion(_ row: SQLiteRow) throws -> BotSuggestion {
    guard let json = row["record_json"] else {
      throw BotStoreError(code: "suggestion_invalid", message: "Suggestion row is missing its JSON")
    }
    return try JSONDecoder().decode(BotSuggestion.self, from: Data(json.utf8))
  }
}
