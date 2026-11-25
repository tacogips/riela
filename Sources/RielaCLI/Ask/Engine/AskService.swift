import Foundation
import RielaCore

struct AskSendRequest: Sendable {
  var conversationId: String?
  var message: String
  var context: AskContext?
  var selection: AskSelection?
  var draftDefinition: JSONObject?
}

struct AskConversationSnapshot: Sendable {
  let conversation: AskConversation
  let messages: [AskMessage]
  let actions: [AskAction]
  let limits: AskLimits
  let warnings: [String]
}

struct AskActivityRead: Sendable {
  let page: ActivityPage
  let turnStatus: AskTurnStatus?
}

struct AskService: Sendable {
  private static let missingConversation = AskError(
    code: "ask_conversation_not_found", message: "Ask conversation was not found"
  )

  let host: AskHost
  let runtime: AskRuntime

  init(host: AskHost, runtime: AskRuntime = .shared) {
    self.host = host
    self.runtime = runtime
  }

  func send(_ request: AskSendRequest) async throws -> AskConversationSnapshot {
    try validate(request)
    let store = host.store
    let existing = try request.conversationId.map { try loadConversation(id: $0) }
    let stale = existing?.turn.map { isStale($0, at: host.now()) } ?? false
    if !stale { try checkAdmission(existing) }
    let context = request.context ?? existing?.context ?? AskContext()
    let selection = request.selection ?? existing?.selection ?? AskSelection()
    // Persist streamed text before the final store transaction.
    let recorder = SQLiteWorkflowActivityRecorder(
      sessionStoreRoot: store.sessionStoreRoot, limits: ActivityLimits(textFlushBytes: 1)
    )
    let tools = host.toolExecutor(recorder: recorder)
    let resolvedContext = try await tools.resolveContext(context)
    let scripted = try host.scriptingAdapter()
    let requiresAvailability = scripted == nil && host.requiresVendorAvailability
    let model = try resolve(selection, requiresAvailability: requiresAvailability)
    guard !requiresAvailability || model.backend != .officialCursorSDK else {
      throw AskError(
        code: "ask_provider_unsupported",
        message: "Ask Riela does not support \(model.backend.rawValue). The cloud agent cannot run read-only."
      )
    }
    if stale, let id = request.conversationId {
      try checkAdmission(currentConversation(id: id))
    }
    let transport = AskToolTransportSelection.select(
      backend: model.backend, rielaExecutablePath: host.rielaExecutablePath, environment: host.environment
    )
    let policy = try AskAgentPolicy.payload(resolved: model, transport: transport, workingDirectory: host.scratchRoot)
    let turn = AskTurn(
      backend: model.backend.rawValue, providerInstanceId: model.providerInstanceId, model: model.model,
      toolTransport: transport, limitedPolicy: policy.limitedPolicy, runnerId: runtime.runnerId,
      draftDefinition: request.draftDefinition
    )
    try Task.checkCancellation()
    let message = AskRedaction.text(request.message, environment: host.environment)
    let at = host.now()
    let started = if let id = request.conversationId {
      try store.beginAskTurn(
        conversationId: id, message: message, context: context, selection: selection, contextRef: resolvedContext?.ref,
        turn: turn, limits: host.limits, now: at, recordActivity: true
      )
    } else {
      try store.createAndBeginAskTurn(
        message: message, context: context, selection: selection, contextRef: resolvedContext?.ref,
        turn: turn, limits: host.limits, now: at
      )
    }
    guard let running = started.turn else {
      throw AskError(code: "ask_record_invalid", message: "Running turn was not stored")
    }
    let execution = AskTurnExecution(
      host: host, conversationId: started.conversationId, turn: running, recorder: recorder, tools: tools,
      context: resolvedContext?.summary, userMessage: message, node: policy.node,
      deadline: at.addingTimeInterval(TimeInterval(host.limits.turnDeadlineSeconds))
    )
    let response = Result { try snapshot(started, warnings: model.warnings.map { AskRedaction.text($0, environment: host.environment) }) }
    await runtime.start(conversationId: started.conversationId, turnId: running.turnId) {
      try await execution.run(adapter: scripted)
    }
    return try response.get()
  }

  func waitForTurn(conversationId: String) async {
    await runtime.wait(conversationId: conversationId)
  }

  func cancel(conversationId: String) async throws -> AskConversationSnapshot {
    let current = try currentConversation(id: conversationId)
    guard let turn = current.turn, turn.status == .running else { return try snapshot(current) }
    if try await !runtime.cancel(conversationId: conversationId, turnId: turn.turnId) {
      // Another process owns the turn: settle it in the store. The owner's
      // heartbeat sees the turn inactive and cancels its own task.
      _ = try host.store.finishAskTurn(
        conversationId: conversationId, turnId: turn.turnId, status: .cancelled, activityReason: .cancelled
      )
    }
    return try conversation(id: conversationId)
  }

  func conversation(id: String) throws -> AskConversationSnapshot {
    try snapshot(currentConversation(id: id))
  }

  func conversations() throws -> [AskConversation] {
    let initial = try host.store.askConversations()
    let recovered = try initial.map(recover).contains(true)
    let current = recovered ? try host.store.askConversations() : initial
    return current.map { $0.withoutDraft() }
  }

  func activity(
    conversationId: String, afterSequence: Int = 0, limit: Int = 200, waitMs: Int = 0,
    isStillAuthorized: @Sendable () async -> Bool = { true }
  ) async throws -> AskActivityRead {
    let wait = min(25_000, max(0, waitMs))
    let slot = wait > 0 && BotActivityWaiters.shared.acquire()
    defer { if slot { BotActivityWaiters.shared.release() } }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .milliseconds(slot ? wait : 0))
    let cursor = max(0, afterSequence)
    while true {
      try Task.checkCancellation()
      guard await isStillAuthorized() else {
        throw AskError(code: "activity_wait_revoked", message: "Activity access was revoked")
      }
      _ = try currentConversation(id: conversationId)
      let page = try await host.store.askActivityPage(conversationId: conversationId, afterSequence: cursor, limit: limit)
      let status = try host.store.askConversation(id: conversationId)?.turn?.status
      let remaining = clock.now.duration(to: deadline)
      if !page.events.isEmpty || (status != .running && page.state?.currentExecutionId == nil) || remaining <= .zero {
        return AskActivityRead(page: page, turnStatus: status)
      }
      try await clock.sleep(for: min(.milliseconds(250), remaining))
    }
  }

  func confirm(conversationId: String, actionId: String, decidedBy: String) async throws -> AskConversationSnapshot {
    _ = try await host.actionService().confirm(conversationId: conversationId, actionId: actionId, decidedBy: decidedBy)
    return try conversation(id: conversationId)
  }

  func dismiss(conversationId: String, actionId: String, decidedBy: String) throws -> AskConversationSnapshot {
    _ = try host.actionService().dismiss(conversationId: conversationId, actionId: actionId, decidedBy: decidedBy)
    return try conversation(id: conversationId)
  }

  func remove(conversationId: String) throws {
    _ = try currentConversation(id: conversationId)
    try host.store.removeAskConversation(id: conversationId)
  }

  private func validate(_ request: AskSendRequest) throws {
    guard !request.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AskError(code: "ask_message_empty", message: "Ask message is empty")
    }
    guard request.message.utf8.count <= host.limits.userMessageBytes else {
      throw AskError(code: "ask_message_too_large", message: "Ask message exceeds the byte limit")
    }
    if let draft = request.draftDefinition, try JSONEncoder().encode(draft).count > host.limits.draftDefinitionBytes {
      throw AskError(code: "ask_draft_too_large", message: "Ask draft exceeds the byte limit")
    }
  }

  private func checkAdmission(_ conversation: AskConversation?) throws {
    if conversation?.turn?.status == .running {
      throw AskError(code: "ask_turn_running", message: "An Ask turn is already running")
    }
    guard (conversation?.usage.turns ?? 0) < host.limits.turnsPerConversation else {
      throw AskError(code: "ask_budget_exceeded", message: "Conversation turn limit reached")
    }
  }

  private func resolve(_ selection: AskSelection, requiresAvailability: Bool) throws -> AskResolvedModel {
    do {
      return try AskModelSelection.resolve(
        settings: host.settings(), request: AskModelRequest(
          vendor: selection.vendor, providerInstanceId: selection.providerInstanceId, model: selection.model, effort: selection.effort
        ),
        catalog: ModelCatalogService(store: host.store, environment: host.environment).catalog(), environment: host.environment,
        requiresAvailability: requiresAvailability
      )
    } catch let error as AskSelectionError {
      throw AskError(code: error.code, message: AskRedaction.text(error.message, environment: host.environment))
    }
  }

  private func currentConversation(id: String) throws -> AskConversation {
    let current = try loadConversation(id: id)
    return try recover(current) ? loadConversation(id: id) : current
  }

  private func loadConversation(id: String) throws -> AskConversation {
    guard let conversation = try host.store.askConversation(id: id) else { throw Self.missingConversation }
    return conversation
  }

  private static let staleAfterSeconds: TimeInterval = 30

  private func isStale(_ turn: AskTurn, at: Date) -> Bool {
    turn.status == .running && turn.runnerId != runtime.runnerId
      && turn.heartbeatAt < RoutineStore.timestamp(at.addingTimeInterval(-Self.staleAfterSeconds))
  }

  private func recover(_ conversation: AskConversation) throws -> Bool {
    let at = host.now()
    guard let turn = conversation.turn, isStale(turn, at: at) else { return false }
    let id = conversation.conversationId
    let recovered = try host.store.failStaleAskTurn(
      conversationId: id, currentRunnerId: runtime.runnerId, staleAfterSeconds: Self.staleAfterSeconds, now: at, settleActivity: true
    )
    if recovered, let directory = host.turnDirectory(conversationId: id, turnId: turn.turnId) {
      if turn.toolTransport == .mcp {
        host.removeTurnArtifact(AskToolServerHandoff.redactionFile(for: directory))
      }
      host.removeTurnArtifact(directory)
    }
    // Another runner may have settled after the read and before our recovery transaction.
    return true
  }

  private func snapshot(_ conversation: AskConversation, warnings: [String] = []) throws -> AskConversationSnapshot {
    let id = conversation.conversationId
    return try AskConversationSnapshot(
      conversation: conversation.withoutDraft(), messages: host.store.askMessages(conversationId: id),
      actions: host.store.askActions(conversationId: id), limits: host.limits, warnings: warnings
    )
  }
}
