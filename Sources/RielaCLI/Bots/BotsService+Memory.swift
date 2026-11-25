import Foundation
import RielaCore
import RielaGraphQL
import RielaWork

extension BotsService {
  func memoryWriter(explicitRoot: String? = nil) -> BotMemoryWriter {
    BotMemoryRuntime.writer(
      sessionStoreRoot: sessionStoreRoot,
      memoryRoot: BotMemoryRuntime.memoryRoot(explicit: explicitRoot, workingDirectory: workingDirectory, environment: environment),
      environment: environment, now: now
    )
  }

  func memory(botId: String) throws -> BotMemoryPayload {
    let writer = memoryWriter()
    let entries = try writer.entries(botId: botId)
    let changes = try writer.history(botId: botId, limit: 20)
    return BotMemoryPayload(
      botId: botId, markdown: BotMemoryMarkdown.render(entries: entries),
      summary: memorySummary(entries: entries, lastChange: changes.first), changes: changes, origin: origin(now())
    )
  }

  func memorySummary(botId: String, explicitRoot: String?) throws -> BotMemorySummary {
    let writer = memoryWriter(explicitRoot: explicitRoot)
    return try memorySummary(entries: writer.entries(botId: botId), lastChange: writer.history(botId: botId, limit: 1).first)
  }

  private func memorySummary(entries: [BotMemoryEntry], lastChange: BotMemoryChangeSet?) -> BotMemorySummary {
    let instructions = entries.filter { $0.kind == .instruction }.count
    return BotMemorySummary(instructionCount: instructions, noteCount: entries.count - instructions, lastChangedAt: lastChange?.createdAt)
  }

  func captureFeedback(_ input: CaptureBotFeedbackInput, explicitRoot: String? = nil) throws -> BotMemoryChangeSet {
    let (session, evidenceRef) = try feedbackSession(input)
    var changes: [BotMemoryProposedChange] = []
    let date = RoutineStore.timestamp(now())
    if let text = input.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
      changes.append(.add(BotMemoryEntry(
        kind: .instruction, topic: input.topic ?? "corrections", text: text,
        provenance: .init(source: .correction, ref: evidenceRef, capturedAt: date, actor: "feedback")
      )))
    }
    if input.fromFindings == true {
      changes += session.reviewFindings.map { finding in
        let line = finding.message.components(separatedBy: .newlines).first ?? ""
        return .add(BotMemoryEntry(
          kind: .note, topic: "review", text: String(line.prefix(500)),
          provenance: .init(source: .review, ref: evidenceRef, capturedAt: date, actor: "feedback")
        ))
      }
    }
    guard !changes.isEmpty else { throw BotStoreError(code: "feedback_empty", message: "No feedback or review findings to capture") }
    return try memoryWriter(explicitRoot: explicitRoot).apply(
      botId: input.botId, changes: changes, actor: "feedback", reason: "feedback", evidenceRefs: [evidenceRef]
    )
  }

  private func feedbackSession(_ input: CaptureBotFeedbackInput) throws -> (WorkflowSession, String) {
    let missing = BotStoreError(code: "feedback_item_not_found", message: "Feedback item does not belong to bot '\(input.botId)'")
    let notFinished = BotStoreError(code: "feedback_item_not_finished", message: "Feedback requires a finished item")
    let sessionId: String
    let evidenceRef: String
    switch (input.sessionId, input.taskId) {
    case (.some(let id), nil):
      sessionId = id
      evidenceRef = "session:\(id)"
    case (nil, .some(let id)):
      let work = WorkStore(rootDirectory: store.sessionStoreRoot)
      let taskId = TaskID(rawValue: id)
      guard let task = try work.loadTask(id: taskId), task.owner?.identity == "bot:\(input.botId)" else { throw missing }
      guard task.state.isTerminal else { throw notFinished }
      guard let linkedSessionId = try work.listAttempts(taskId: taskId).last?.sessionId else { throw missing }
      sessionId = linkedSessionId
      evidenceRef = "task:\(id)"
    default:
      throw BotStoreError(code: "feedback_item_invalid", message: "Feedback requires exactly one session or task")
    }
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.sessionStoreRoot)
    guard let session = try? runtime.loadStrictReadOnly(sessionId: sessionId).session,
          try store.link(forSession: session.rootSessionId ?? sessionId)?.botId == input.botId else { throw missing }
    guard session.status.isTerminal else { throw notFinished }
    return (session, evidenceRef)
  }
}
