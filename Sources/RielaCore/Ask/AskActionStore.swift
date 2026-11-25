import Foundation
import RielaSQLite

extension BotStore {
  public func askActions(conversationId: String) throws -> [AskAction] {
    try read { db in
      guard try db.tableExists("ask_actions") else { return [] }
      return try db.query(
        """
        SELECT json(record_json) AS record_json FROM ask_actions WHERE conversation_id = ?
        ORDER BY json_extract(record_json, '$.createdAt'), action_id
        """, bindings: [.text(conversationId)]
      ).map(Self.decodeAskRecord)
    } ?? []
  }

  public func askAction(id: String) throws -> AskAction? {
    try read { db in
      guard try db.tableExists("ask_actions") else { return nil }
      return try Self.loadAskAction(id, in: db)
    } ?? nil
  }

  @discardableResult
  public func insertAskAction(_ action: AskAction, limits: AskLimits = .standard) throws -> AskAction {
    try write { db in
      let conversation = try Self.requireAskConversation(action.conversationId, in: db)
      _ = try Self.requireRunningAskTurn(conversation, turnId: action.turnId)
      guard action.status == .proposed, action.decidedAt == nil, action.decision == nil, action.decidedBy == nil, action.result == nil else {
        throw AskError(code: "action_target_invalid", message: "Only an undecided action can be proposed")
      }
      if action.kind == .applyWorkflow {
        try Self.replaceAskWorkflowProposals(with: action, in: db)
      }
      let count = try db.query(
        """
        SELECT COUNT(*) AS count FROM ask_actions
        WHERE conversation_id = ? AND status = ? AND json_extract(record_json, '$.turnId') = ?
        """, bindings: [.text(action.conversationId), .text(AskActionStatus.proposed.rawValue), .text(action.turnId)]
      ).first?["count"].flatMap(Int.init) ?? 0
      guard count < limits.actionsPerTurn else {
        throw AskError(code: "action_limit", message: "The turn has reached its proposed action limit")
      }
      var record = action
      record.actionId = "act-\(UUID().uuidString.lowercased())"
      try db.execute(
        "INSERT INTO ask_actions (action_id, conversation_id, record_json, status, updated_at) VALUES (?, ?, jsonb(?), ?, ?)",
        bindings: [
          .text(record.actionId), .text(record.conversationId), .text(try Self.askJSON(record)),
          .text(record.status.rawValue), .text(record.createdAt)
        ]
      )
      return record
    }
  }

  public func decideAskAction(
    conversationId: String, actionId: String, decision: AskActionDecision, decidedBy: String, now: Date = Date()
  ) throws -> AskAction {
    try write { db in
      guard decision != .replaced else {
        throw AskError(code: "action_target_invalid", message: "Only a new proposal can replace an action")
      }
      guard var record = try Self.loadAskAction(actionId, in: db), record.conversationId == conversationId else {
        throw Self.askActionNotFound
      }
      guard record.status == .proposed else { throw Self.askActionAlreadyDecided }
      let at = RoutineStore.timestamp(now)
      guard record.expiresAt > at else {
        throw AskError(code: "action_expired", message: "Ask action has expired")
      }
      record.status = decision == .confirm ? .confirming : .dismissed
      record.decidedAt = at
      record.decision = decision
      record.decidedBy = decidedBy
      guard try Self.updateAskAction(record, from: .proposed, at: at, in: db) else { throw Self.askActionAlreadyDecided }
      return record
    }
  }

  @discardableResult
  public func completeAskAction(actionId: String, result: AskActionResult, now: Date = Date()) throws -> AskAction {
    try write { db in
      guard var record = try Self.loadAskAction(actionId, in: db) else { throw Self.askActionNotFound }
      guard record.status == .confirming else { return record }
      record.status = result.ok ? .confirmed : .failed
      record.result = result
      guard try Self.updateAskAction(record, from: .confirming, at: RoutineStore.timestamp(now), in: db) else {
        throw Self.askActionAlreadyDecided
      }
      if !result.ok, try db.query(
        "SELECT 1 FROM ask_conversations WHERE conversation_id = ?", bindings: [.text(record.conversationId)]
      ).isEmpty {
        try db.execute("DELETE FROM ask_actions WHERE action_id = ?", bindings: [.text(record.actionId)])
      }
      return record
    }
  }

  private static func replaceAskWorkflowProposals(with action: AskAction, in db: SQLiteDatabase) throws {
    let proposals: [AskAction] = try db.query(
      """
      SELECT json(record_json) AS record_json FROM ask_actions
      WHERE conversation_id = ? AND status = ?
        AND json_extract(record_json, '$.turnId') = ? AND json_extract(record_json, '$.kind') = ?
      """, bindings: [.text(action.conversationId), .text(AskActionStatus.proposed.rawValue),
        .text(action.turnId), .text(AskActionKind.applyWorkflow.rawValue)]
    ).map(Self.decodeAskRecord)
    for var proposal in proposals {
      proposal.status = .dismissed
      proposal.decidedAt = action.createdAt
      proposal.decision = .replaced
      guard try Self.updateAskAction(proposal, from: .proposed, at: action.createdAt, in: db) else {
        throw Self.askActionAlreadyDecided
      }
    }
  }

  private static var askActionNotFound: AskError {
    AskError(code: "action_not_found", message: "Ask action was not found")
  }

  private static var askActionAlreadyDecided: AskError {
    AskError(code: "action_already_decided", message: "Ask action has already been decided")
  }

  private static func loadAskAction(_ id: String, in db: SQLiteDatabase) throws -> AskAction? {
    try db.query(
      "SELECT json(record_json) AS record_json FROM ask_actions WHERE action_id = ?", bindings: [.text(id)]
    ).first.map(decodeAskRecord)
  }

  private static func updateAskAction(
    _ action: AskAction, from status: AskActionStatus, at: String, in db: SQLiteDatabase
  ) throws -> Bool {
    try db.executeAndReturnChangedRowCount(
      "UPDATE ask_actions SET record_json = jsonb(?), status = ?, updated_at = ? WHERE action_id = ? AND conversation_id = ? AND status = ?",
      bindings: [
        .text(try askJSON(action)), .text(action.status.rawValue), .text(at),
        .text(action.actionId), .text(action.conversationId), .text(status.rawValue)
      ]
    ) == 1
  }
}
