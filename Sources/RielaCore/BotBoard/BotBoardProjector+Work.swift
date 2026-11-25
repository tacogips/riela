import Foundation

extension BotBoardProjector {
  struct SessionFamily {
    let input: BotBoardSessionInput

    init(_ input: BotBoardSessionInput) {
      self.input = input
    }

    var root: WorkflowSession { input.session }
    var sessions: [WorkflowSession] { [root] + input.descendants }

    var lastActivityAt: Date {
      let dates = sessions.map { session in
        max(session.updatedAt, activity(for: session)?.lastEventAt ?? session.updatedAt)
      }
      return dates.max() ?? root.updatedAt
    }

    var humanSuspend: SuspendRecord? {
      sessions.filter { $0.status == .suspended }.compactMap(\.suspend)
        .filter { $0.reasonKind == .userInputRequired || $0.reasonKind == .userPresenceRequired }
        .max { ($0.suspendedAt, $0.stepId) < ($1.suspendedAt, $1.stepId) }
    }

    var limited: ActivityStop? {
      guard root.status.isTerminal || root.status == .suspended,
        let stop = input.activity?.lastStop, stop.limited else { return nil }
      return stop
    }

    var terminalAt: Date? {
      guard root.status.isTerminal else { return nil }
      return root.failedAt ?? root.updatedAt
    }

    private var focusedSession: WorkflowSession {
      guard !root.status.isTerminal else { return root }
      let active = input.descendants.filter { $0.status == .running }
      return active.max { lhs, rhs in
        (max(lhs.updatedAt, activity(for: lhs)?.lastEventAt ?? lhs.updatedAt), lhs.sessionId)
          < (max(rhs.updatedAt, activity(for: rhs)?.lastEventAt ?? rhs.updatedAt), rhs.sessionId)
      } ?? root
    }

    private func activity(for session: WorkflowSession) -> ActivityState? {
      session.sessionId == root.sessionId ? input.activity : input.descendantActivities[session.sessionId]
    }

    func project(_ input: BotBoardInput) -> Projection {
      let group = self.group
      var item = BotBoardItem(
        itemKind: "session", itemId: root.sessionId, group: group, title: root.workflowId,
        status: root.status.rawValue, origin: input.origin
      )
      applyExecution(to: &item, now: input.now, endedAt: terminalAt)
      item.lastActivityAt = lastActivityAt
      item.pendingRequests = Self.orderedRequests(self.input.pendingRequests)
      item.question = Self.question(humanSuspend?.question)
      if group == .needsYou {
        item.answerPath = item.pendingRequests.isEmpty ? item.question.map { _ in "task" } : "bot"
        item.bumpedAt = [item.pendingRequests.first?.createdAt, humanSuspend?.suspendedAt].compactMap { $0 }.max()
      } else {
        item.bumpedAt = terminalAt
      }
      if group == .waiting {
        if let limited {
          applyLimit(limited, to: &item)
        } else {
          item.waitingReason = root.suspend?.reasonKind.rawValue
        }
      }
      if root.status.isTerminal {
        item.lastResult = resultLine(redact: input.redact)
      }
      return Projection(item: item, terminalAt: terminalAt, failureAt: root.status == .failed ? terminalAt : nil)
    }

    private var group: BotBoardGroup {
      if !input.pendingRequests.isEmpty || humanSuspend != nil { return .needsYou }
      switch root.status {
      case .running: return .inProgress
      case .suspended: return .waiting
      case .created: return .planned
      case .completed, .failed, .cancelled: return limited == nil ? .closed : .waiting
      }
    }

    func resultLine(redact: (String) -> String) -> String {
      lastResultLine(session: root, finalMessageLine: input.finalMessageLine ?? input.activity?.lastMessageLine, redact: redact)
    }

    func applyExecution(to item: inout BotBoardItem, now: Date, endedAt: Date?) {
      let focus = focusedSession
      let activity = activity(for: focus)
      let stepId = activity?.currentStepId ?? focus.currentStepId ?? focus.suspend?.stepId
      let execution = focus.executions.last(where: { $0.executionId == activity?.currentExecutionId })
        ?? focus.executions.last(where: { $0.stepId == stepId })
        ?? focus.executions.last(where: { $0.status == .running })
      item.sessionId = root.sessionId
      item.workflowId = focus.workflowId
      item.stepId = stepId ?? execution?.stepId
      item.nodeId = activity?.currentNodeId ?? execution?.nodeId
      item.backend = activity?.backend ?? execution?.backend?.rawValue
      item.model = activity?.reportedModel ?? activity?.requestedModel
        ?? (focus.sessionId == root.sessionId ? input.requestedModel : nil)
      item.startedAt = root.createdAt
      item.elapsedMs = SessionBackendActivityClassifier.ageMs(from: root.createdAt, to: endedAt ?? now)
      item.activitySource = activity?.source ?? "session"
      item.checklist = activity?.plans ?? []
      let tool = activity?.toolCalls.filter { $0.status == "pending" || $0.status == "inProgress" }
        .max { ($0.updatedAt, $0.toolCallId) < ($1.updatedAt, $1.toolCallId) }
      item.doingNow = tool?.title ?? item.stepId
    }

    static func question(_ handover: HandoverQuestion?) -> BotBoardQuestion? {
      handover.map { BotBoardQuestion(questionId: $0.id, text: $0.text, optionIds: $0.options.map(\.id)) }
    }

    static func orderedRequests(_ requests: [BotBoardPendingRequest]) -> [BotBoardPendingRequest] {
      requests.sorted { lhs, rhs in
        lhs.createdAt == rhs.createdAt ? lhs.requestId < rhs.requestId : lhs.createdAt > rhs.createdAt
      }
    }
  }

  static func project(_ task: BotBoardTaskInput, attempts: [SessionFamily], input: BotBoardInput) -> Projection {
    let latest = attempts.last
    let terminal = ["succeeded", "failed", "cancelled", "superseded"].contains(task.state)
    let requests = SessionFamily.orderedRequests(attempts.flatMap(\.input.pendingRequests))
    let handover = terminal ? nil : latest?.humanSuspend
    let question = task.question ?? SessionFamily.question(handover?.question)
    let limited = !terminal || task.state == "failed" ? latest?.limited : nil
    let group = taskGroup(task.state, needsYou: !requests.isEmpty || question != nil || handover != nil, latest: latest, limited: limited != nil)
    var item = BotBoardItem(
      itemKind: "task", itemId: task.taskId, group: group, title: task.title, status: task.state, origin: input.origin
    )
    latest?.applyExecution(to: &item, now: input.now, endedAt: terminal ? task.updatedAt : latest?.terminalAt)
    item.lastActivityAt = max(task.updatedAt, attempts.map(\.lastActivityAt).max() ?? task.updatedAt)
    item.pendingRequests = requests
    item.question = question
    if group == .needsYou {
      item.answerPath = requests.isEmpty ? "task" : "bot"
      let taskDecisionAt = task.question != nil || task.state == "needsDecision" ? task.updatedAt : nil
      item.bumpedAt = [requests.first?.createdAt, handover?.suspendedAt, taskDecisionAt].compactMap { $0 }.max()
    } else if terminal {
      item.bumpedAt = task.updatedAt
    }
    if group == .waiting {
      if let limited {
        applyLimit(limited, to: &item)
      } else {
        item.waitingReason = task.waitReason ?? latest?.root.suspend?.reasonKind.rawValue
      }
    }
    if terminal {
      item.lastResult = latest?.resultLine(redact: input.redact)
    }
    return Projection(item: item, terminalAt: terminal ? task.updatedAt : nil, failureAt: task.state == "failed" ? task.updatedAt : nil)
  }

  private static func taskGroup(_ state: String, needsYou: Bool, latest: SessionFamily?, limited: Bool) -> BotBoardGroup {
    if needsYou || state == "needsDecision" { return .needsYou }
    if state == "running" || state == "verifying" { return .inProgress }
    if limited || state == "waiting" { return .waiting }
    switch state {
    case "draft", "ready", "scheduled":
      if latest?.root.status == .running { return .inProgress }
      if latest?.root.status == .suspended { return .waiting }
      return .planned
    case "succeeded", "failed", "cancelled", "superseded":
      return .closed
    default:
      return .waiting
    }
  }

  private static func applyLimit(_ stop: ActivityStop, to item: inout BotBoardItem) {
    item.status = "limited"
    item.waitingReason = "limited"
    item.limitedResetAt = stop.limitedResetAt
  }
}
