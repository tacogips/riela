import Foundation
import RielaSQLite

extension BotStore {
  public func createAskConversation(
    context: AskContext, selection: AskSelection, firstMessage: String, limits: AskLimits = .standard, now: Date = Date()
  ) throws -> AskConversation {
    try write { db in
      try Self.createAskConversation(context: context, selection: selection, firstMessage: firstMessage, limits: limits, now: now, in: db)
    }
  }

  public func askConversations() throws -> [AskConversation] {
    try read { db in
      guard try db.tableExists("ask_conversations") else { return [] }
      return try Self.loadAskConversations(in: db)
    } ?? []
  }

  public func askConversation(id: String) throws -> AskConversation? {
    try read { db in
      guard try db.tableExists("ask_conversations") else { return nil }
      return try Self.loadAskConversation(id, in: db)
    } ?? nil
  }

  public func askMessages(conversationId: String) throws -> [AskMessage] {
    try read { db in
      guard try db.tableExists("ask_messages") else { return [] }
      return try db.query(
        "SELECT json(record_json) AS record_json FROM ask_messages WHERE conversation_id = ? ORDER BY seq",
        bindings: [.text(conversationId)]
      ).map(Self.decodeAskRecord)
    } ?? []
  }

  @discardableResult
  public func beginAskTurn(
    conversationId: String, message: String, context: AskContext? = nil, selection: AskSelection? = nil,
    contextRef: AskRef? = nil, turn: AskTurn, limits: AskLimits = .standard, now: Date = Date(),
    recordActivity: Bool = false
  ) throws -> AskConversation {
    try write { db in
      let record = try Self.requireAskConversation(conversationId, in: db)
      return try Self.beginAskTurn(record, message: message, context: context, selection: selection,
        contextRef: contextRef, turn: turn, limits: limits, now: now, recordActivity: recordActivity, in: db)
    }
  }

  public func createAndBeginAskTurn(
    message: String, context: AskContext, selection: AskSelection, contextRef: AskRef?, turn: AskTurn,
    limits: AskLimits = .standard, now: Date = Date()
  ) throws -> AskConversation {
    try write { db in
      let record = try Self.createAskConversation(
        context: context, selection: selection, firstMessage: message, limits: limits, now: now, in: db
      )
      return try Self.beginAskTurn(record, message: message, context: nil, selection: nil, contextRef: contextRef,
        turn: turn, limits: limits, now: now, recordActivity: true, in: db)
    }
  }

  @discardableResult
  public func finishAskTurn(
    conversationId: String, turnId: String, status: AskTurnStatus, error: AskTurnError? = nil,
    assistantText: String? = nil, citations: [AskRef] = [], limits: AskLimits = .standard, now: Date = Date(),
    activityReason: ActivitySettleReason? = nil
  ) throws -> Bool {
    guard status != .running else { return false }
    return try write { db in
      guard var record = try Self.loadAskConversation(conversationId, in: db),
        let turn = record.turn, turn.turnId == turnId, turn.status == .running
      else { return false }
      let at = RoutineStore.timestamp(now)
      Self.settleAskTurn(&record, status: status, error: error, at: at)
      if status == .completed {
        let text = assistantText ?? ""
        let capped = AskLimits.prefix(text, utf8Limit: limits.assistantMessageBytes)
        let reply = AskMessage(
          seq: record.usage.turns * 2, role: .assistant, text: capped, turnId: turnId,
          citations: citations, truncated: capped.utf8.count < text.utf8.count, createdAt: at
        )
        try Self.appendAskMessage(reply, conversationId: conversationId, limits: limits, in: db)
      }
      try Self.saveAskConversation(record, in: db)
      if let activityReason {
        try Self.settleAskActivity(conversationId, turnId: turnId, reason: activityReason, status: status, now: now, in: db)
      }
      return true
    }
  }

  public func addAskReferences(conversationId: String, turnId: String, refs: [AskRef]) throws {
    guard !refs.isEmpty else { return }
    try write { db in
      var record = try Self.requireAskConversation(conversationId, in: db)
      _ = try Self.requireRunningAskTurn(record, turnId: turnId)
      Self.mergeAskReferences(refs, into: &record)
      try Self.saveAskConversation(record, in: db)
    }
  }

  @discardableResult
  public func touchAskTurn(conversationId: String, turnId: String, runnerId: String, now: Date = Date()) throws -> Bool {
    try write { db in
      guard var record = try Self.loadAskConversation(conversationId, in: db),
        let turn = record.turn, turn.status == .running, turn.turnId == turnId, turn.runnerId == runnerId
      else { return false }
      let at = RoutineStore.timestamp(now)
      record.turn?.heartbeatAt = max(at, turn.heartbeatAt)
      try Self.saveAskConversation(record, in: db)
      return true
    }
  }

  @discardableResult
  public func failStaleAskTurn(
    conversationId: String, currentRunnerId: String, staleAfterSeconds: TimeInterval = 30, now: Date = Date(), settleActivity: Bool = false
  ) throws -> Bool {
    try write { db in
      let cutoff = RoutineStore.timestamp(now.addingTimeInterval(-staleAfterSeconds))
      guard var record = try Self.loadAskConversation(conversationId, in: db),
        let turn = record.turn, turn.status == .running, turn.runnerId != currentRunnerId, turn.heartbeatAt < cutoff
      else { return false }
      Self.settleAskTurn(
        &record, status: .failed, error: AskTurnError(code: "ask_interrupted", message: "Ask turn was interrupted"),
        at: RoutineStore.timestamp(now)
      )
      try Self.saveAskConversation(record, in: db)
      if settleActivity {
        try Self.settleAskActivity(conversationId, turnId: turn.turnId, reason: .processExit, status: .failed, now: now, in: db)
      }
      return true
    }
  }

  public func reserveAskToolCall(conversationId: String, turnId: String, limits: AskLimits = .standard) throws {
    try write { db in
      var record = try Self.requireAskConversation(conversationId, in: db)
      let turn = try Self.requireRunningAskTurn(record, turnId: turnId)
      guard turn.toolCalls < limits.toolCallsPerTurn, record.usage.toolCalls < limits.toolCallsPerConversation,
        turn.toolBytes < limits.toolBytesPerTurn, record.usage.toolBytes < limits.toolBytesPerConversation
      else {
        throw AskError(code: "budget_exceeded", message: "Tool budget exhausted")
      }
      record.turn?.toolCalls += 1
      record.usage.toolCalls += 1
      try Self.saveAskConversation(record, in: db)
    }
  }

  public func addAskToolBytes(conversationId: String, turnId: String, bytes: Int, limits: AskLimits = .standard) throws -> Bool {
    try write { db in
      var record = try Self.requireAskConversation(conversationId, in: db)
      let turn = try Self.requireRunningAskTurn(record, turnId: turnId)
      guard bytes >= 0, limits.toolBytesPerTurn >= turn.toolBytes, limits.toolBytesPerConversation >= record.usage.toolBytes,
        bytes <= limits.toolBytesPerTurn - turn.toolBytes, bytes <= limits.toolBytesPerConversation - record.usage.toolBytes
      else { return false }
      record.turn?.toolBytes += bytes
      record.usage.toolBytes += bytes
      try Self.saveAskConversation(record, in: db)
      return true
    }
  }

  public func removeAskConversation(id: String) throws {
    try write { db in
      let record = try Self.requireAskConversation(id, in: db)
      guard record.turn?.status != .running else { throw Self.askTurnRunning }
      try Self.deleteAskConversation(id, in: db)
    }
  }

  private static func createAskConversation(
    context: AskContext, selection: AskSelection, firstMessage: String, limits: AskLimits, now: Date, in db: SQLiteDatabase
  ) throws -> AskConversation {
    guard firstMessage.utf8.count <= limits.userMessageBytes else { throw Self.askMessageTooLarge }
    let at = RoutineStore.timestamp(now)
    let record = AskConversation(
      conversationId: "ask-\(UUID().uuidString.lowercased())", title: String(firstMessage.prefix(80)),
      context: context, selection: selection, createdAt: at, updatedAt: at
    )
    let existing = try Self.loadAskConversations(in: db).reversed()
    var overLimit = existing.count + 1 - max(0, limits.conversationsPerStore)
    for candidate in existing where overLimit > 0 && candidate.turn?.status != .running {
      try Self.deleteAskConversation(candidate.conversationId, in: db)
      overLimit -= 1
    }
    guard overLimit <= 0 else {
      throw AskError(code: "ask_budget_exceeded", message: "Conversation limit reached while conversations are in use")
    }
    try db.execute(
      "INSERT INTO ask_conversations (conversation_id, record_json, updated_at) VALUES (?, jsonb(?), ?)",
      bindings: [.text(record.conversationId), .text(try Self.askJSON(record)), .text(at)]
    )
    return record
  }

  private static func beginAskTurn(
    _ conversation: AskConversation, message: String, context: AskContext?, selection: AskSelection?, contextRef: AskRef?,
    turn: AskTurn, limits: AskLimits, now: Date, recordActivity: Bool, in db: SQLiteDatabase
  ) throws -> AskConversation {
    var record = conversation
    guard record.turn?.status != .running else { throw Self.askTurnRunning }
    guard record.usage.turns < limits.turnsPerConversation else {
      throw AskError(code: "ask_budget_exceeded", message: "Conversation turn limit reached")
    }
    guard message.utf8.count <= limits.userMessageBytes else { throw Self.askMessageTooLarge }
    record.usage.turns += 1
    let at = RoutineStore.timestamp(now)
    let running = AskTurn(
      turnId: "turn-\(record.usage.turns)", startedAt: at, backend: turn.backend,
      providerInstanceId: turn.providerInstanceId, model: turn.model, toolTransport: turn.toolTransport,
      limitedPolicy: turn.limitedPolicy, runnerId: turn.runnerId, heartbeatAt: at,
      draftDefinition: turn.draftDefinition
    )
    record.turn = running
    record.updatedAt = at
    if let context { record.context = context }
    if let selection { record.selection = selection }
    if let contextRef { Self.mergeAskReferences([contextRef], into: &record) }
    try Self.saveAskConversation(record, in: db)
    let user = AskMessage(
      seq: record.usage.turns * 2 - 1, role: .user, text: message, turnId: running.turnId,
      citations: [], truncated: false, createdAt: at
    )
    try Self.appendAskMessage(user, conversationId: record.conversationId, limits: limits, in: db)
    if recordActivity {
      let sessionId = AskActivityKey.sessionId(record.conversationId)
      var journal = try ActivityJournal(sessionId: sessionId, db: db)
      journal.state.source = "acp"
      let events = ActivityReducer.stepStarted(
        state: &journal.state, executionId: running.turnId, stepId: "ask", nodeId: "ask",
        backend: running.backend, requestedModel: running.model, at: now
      )
      journal.append(events, executionId: running.turnId, at: now)
      try journal.save(in: db, at: now)
    }
    return record
  }

  private static func mergeAskReferences(_ refs: [AskRef], into record: inout AskConversation) {
    var known = record.knownRefs ?? []
    var seen = Set(known)
    known.append(contentsOf: refs.filter { seen.insert($0).inserted })
    record.knownRefs = known
  }

  private static func settleAskActivity(
    _ conversationId: String, turnId: String, reason: ActivitySettleReason, status: AskTurnStatus, now: Date, in db: SQLiteDatabase
  ) throws {
    let sessionId = AskActivityKey.sessionId(conversationId)
    var journal = try ActivityJournal(sessionId: sessionId, db: db)
    guard journal.state.currentExecutionId == turnId else { return }
    let stop = ActivityReducer.apply(
      .stop(stopReason: reason.rawValue, limited: false, limitedResetAt: nil),
      to: &journal.state, executionId: turnId, at: now
    )
    journal.append(stop, executionId: turnId, at: now)
    let stepStatus = status == .completed ? "succeeded" : status.rawValue
    try journal.settle(executionId: turnId, reason: reason, stepStatus: stepStatus, at: now, db: db)
    try journal.save(in: db, at: now)
  }

  private static var askMessageTooLarge: AskError {
    AskError(code: "ask_message_too_large", message: "Ask message exceeds the byte limit")
  }

  private static var askTurnRunning: AskError {
    AskError(code: "ask_turn_running", message: "An Ask turn is already running")
  }

  static func requireRunningAskTurn(_ record: AskConversation, turnId: String) throws -> AskTurn {
    guard let turn = record.turn, turn.status == .running, turn.turnId == turnId else {
      throw AskError(code: "turn_not_running", message: "Ask turn is no longer running")
    }
    return turn
  }

  static func askJSON(_ record: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let json = String(data: try encoder.encode(record), encoding: .utf8) else {
      throw AskError(code: "ask_record_invalid", message: "Ask record could not be encoded as UTF-8 JSON")
    }
    return json
  }

  static func decodeAskRecord<Record: Decodable>(_ row: SQLiteRow) throws -> Record {
    guard let json = row["record_json"] else {
      throw AskError(code: "ask_record_invalid", message: "Ask record is missing its JSON")
    }
    return try JSONDecoder().decode(Record.self, from: Data(json.utf8))
  }

  static func requireAskConversation(_ id: String, in db: SQLiteDatabase) throws -> AskConversation {
    guard let record = try loadAskConversation(id, in: db) else {
      throw AskError(code: "ask_conversation_not_found", message: "Ask conversation was not found")
    }
    return record
  }

  private static func loadAskConversations(in db: SQLiteDatabase) throws -> [AskConversation] {
    try db.query(
      "SELECT json(record_json) AS record_json FROM ask_conversations ORDER BY updated_at DESC, conversation_id ASC"
    ).map(decodeAskRecord)
  }

  private static func loadAskConversation(_ id: String, in db: SQLiteDatabase) throws -> AskConversation? {
    try db.query(
      "SELECT json(record_json) AS record_json FROM ask_conversations WHERE conversation_id = ?", bindings: [.text(id)]
    ).first.map(decodeAskRecord)
  }

  private static func saveAskConversation(_ record: AskConversation, in db: SQLiteDatabase) throws {
    try db.execute(
      "UPDATE ask_conversations SET record_json = jsonb(?), updated_at = ? WHERE conversation_id = ?",
      bindings: [.text(try askJSON(record)), .text(record.updatedAt), .text(record.conversationId)]
    )
  }

  private static func settleAskTurn(_ record: inout AskConversation, status: AskTurnStatus, error: AskTurnError?, at: String) {
    record.turn?.status = status
    record.turn?.finishedAt = at
    record.turn?.error = error
    record.turn?.draftDefinition = nil
    record.updatedAt = at
  }

  private static func appendAskMessage(_ message: AskMessage, conversationId: String, limits: AskLimits, in db: SQLiteDatabase) throws {
    try db.execute(
      "INSERT INTO ask_messages (conversation_id, seq, record_json) VALUES (?, ?, jsonb(?))",
      bindings: [.text(conversationId), .int(Int64(message.seq)), .text(try askJSON(message))]
    )
    try db.execute(
      """
      DELETE FROM ask_messages WHERE conversation_id = ? AND seq IN (
        SELECT seq FROM ask_messages WHERE conversation_id = ? ORDER BY seq DESC LIMIT -1 OFFSET ?
      )
      """,
      bindings: [.text(conversationId), .text(conversationId), .int(Int64(max(0, limits.messagesPerConversation)))]
    )
  }

  private static func deleteAskConversation(_ id: String, in db: SQLiteDatabase) throws {
    try db.execute("DELETE FROM ask_messages WHERE conversation_id = ?", bindings: [.text(id)])
    // A claimed confirmation may still mutate its target after the conversation is removed.
    try db.execute(
      "DELETE FROM ask_actions WHERE conversation_id = ? AND status NOT IN (?, ?)",
      bindings: [.text(id), .text(AskActionStatus.confirmed.rawValue), .text(AskActionStatus.confirming.rawValue)]
    )
    try deleteActivity(sessionIds: [AskActivityKey.sessionId(id)], in: db)
    try db.execute("DELETE FROM ask_conversations WHERE conversation_id = ?", bindings: [.text(id)])
  }
}
