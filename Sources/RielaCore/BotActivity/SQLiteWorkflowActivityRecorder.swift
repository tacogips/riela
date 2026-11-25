import Foundation

public actor SQLiteWorkflowActivityRecorder: WorkflowActivityRecording {
  struct TextBuffer {
    let executionId: String
    let kind: ActivityEventKind
    let messageId: String?
    let openedAt: Date
    let replacesMessage: Bool
    var text: String
  }

  let store: BotStore
  let limits: ActivityLimits
  let sleep: @Sendable (UInt64) async -> Void
  var buffers: [String: [TextBuffer]] = [:]
  var activeExecutions: [String: String] = [:]
  var lastTextFlush: [String: Date] = [:]
  private var loggedSessions: Set<String> = []

  public init(
    sessionStoreRoot: String, limits: ActivityLimits = .default,
    sleep: @escaping @Sendable (UInt64) async -> Void = ActivityLimits.sleep
  ) {
    self.store = BotStore(sessionStoreRoot: sessionStoreRoot)
    self.limits = limits
    self.sleep = sleep
  }

  public func stepStarted(
    sessionId: String, executionId: String, stepId: String, nodeId: String,
    backend: String?, requestedModel: String?, at: Date
  ) {
    do {
      let remaining = try store.write { db in
        var journal = try ActivityJournal(sessionId: sessionId, db: db)
        if journal.state.currentExecutionId == executionId { return buffers[sessionId] }
        if let previous = journal.state.currentExecutionId {
          flush(buffers[sessionId] ?? [], executionId: previous, into: &journal, at: at, final: true)
          try journal.settle(executionId: previous, reason: .processExit, stepStatus: "failed", at: at, db: db)
        }
        let events = ActivityReducer.stepStarted(
          state: &journal.state, executionId: executionId, stepId: stepId, nodeId: nodeId,
          backend: backend, requestedModel: requestedModel, at: at
        )
        journal.append(events, executionId: executionId, at: at)
        try journal.save(in: db, at: at, limits: limits)
        return nil
      }
      buffers[sessionId] = remaining
      if activeExecutions[sessionId] != executionId { lastTextFlush[sessionId] = at }
      activeExecutions[sessionId] = executionId
    } catch { log(error, sessionId: sessionId) }
  }

  public func record(sessionId: String, executionId: String, update: AdapterActivityUpdate, at: Date) {
    do {
      switch update {
      case let .message(messageId, text, replace):
        try recordText(sessionId: sessionId, buffer: .init(
          executionId: executionId, kind: .message, messageId: messageId, openedAt: at, replacesMessage: replace, text: text
        ))
      case let .thought(text):
        try recordText(sessionId: sessionId, buffer: .init(
          executionId: executionId, kind: .thought, messageId: nil, openedAt: at, replacesMessage: false, text: text
        ))
      default:
        let backend = try store.write { db -> String? in
          var journal = try ActivityJournal(sessionId: sessionId, db: db)
          guard journal.state.currentExecutionId == executionId else { return nil }
          flush(buffers[sessionId] ?? [], executionId: executionId, into: &journal, at: at, final: false)
          let events = ActivityReducer.apply(update, to: &journal.state, executionId: executionId, at: at)
          journal.append(events, executionId: executionId, at: at)
          try journal.save(in: db, at: at, limits: limits)
          return journal.state.backend
        }
        if buffers[sessionId]?.contains(where: { $0.executionId == executionId }) == true {
          lastTextFlush[sessionId] = at
        }
        discardBuffers(sessionId: sessionId, executionId: executionId)
        if let backend {
          try mergeCatalogReport(update, backend: backend, at: at)
        }
      }
    } catch { log(error, sessionId: sessionId) }
  }

  private func mergeCatalogReport(_ update: AdapterActivityUpdate, backend: String, at: Date) throws {
    switch update {
    case let .configOptions(options):
      try store.mergeReportedConfig(instanceId: backend, configOptions: options, at: at)
    case let .reportedModel(model):
      try store.mergeReportedConfig(instanceId: backend, reportedModel: model, at: at)
    default:
      break
    }
  }

  public func settle(
    sessionId: String, executionId: String, reason: ActivitySettleReason, stepStatus: String, at: Date
  ) async {
    if Task.isCancelled {
      // SQLite can abort a writer open for a cancelled task. Await cleanup using an uncancelled task.
      await Task {
        persistSettlement(sessionId: sessionId, executionId: executionId, reason: reason, stepStatus: stepStatus, at: at)
      }.value
      return
    }
    persistSettlement(sessionId: sessionId, executionId: executionId, reason: reason, stepStatus: stepStatus, at: at)
  }

  private func persistSettlement(
    sessionId: String, executionId: String, reason: ActivitySettleReason, stepStatus: String, at: Date
  ) {
    do {
      try store.write { db in
        var journal = try ActivityJournal(sessionId: sessionId, db: db)
        guard journal.state.currentExecutionId == executionId else { return }
        flush(buffers[sessionId] ?? [], executionId: executionId, into: &journal, at: at, final: true)
        try journal.settle(executionId: executionId, reason: reason, stepStatus: stepStatus, at: at, db: db)
        try journal.save(in: db, at: at, limits: limits)
      }
      discardBuffers(sessionId: sessionId, executionId: executionId)
      if activeExecutions[sessionId] == executionId {
        activeExecutions[sessionId] = nil
        lastTextFlush[sessionId] = nil
      }
    } catch { log(error, sessionId: sessionId) }
  }

  func discardBuffers(sessionId: String, executionId: String) {
    buffers[sessionId]?.removeAll { $0.executionId == executionId }
    if buffers[sessionId]?.isEmpty == true { buffers[sessionId] = nil }
  }

  func log(_ error: Error, sessionId: String) {
    guard loggedSessions.insert(sessionId).inserted else { return }
    // Store errors can include paths or backend-supplied data. Emit the error type only.
    let message = "riela activity recorder: session \(sessionId) (\(type(of: error)))\n"
    try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
  }
}
