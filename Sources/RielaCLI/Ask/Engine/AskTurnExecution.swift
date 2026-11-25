import Foundation
import RielaCore
import RielaObservability

struct AskTurnExecution: Sendable {
  let host: AskHost
  let conversationId: String
  let turn: AskTurn
  let recorder: any WorkflowActivityRecording
  let tools: AskToolExecutor
  let context: JSONObject?
  let userMessage: String
  let node: AgentNodePayload
  let deadline: Date

  private var sessionId: String { AskActivityKey.sessionId(conversationId) }

  private struct Terminal {
    let status: AskTurnStatus
    let reason: ActivitySettleReason
    var error: AskTurnError?
    var answer: String?
  }

  func run(adapter injected: (any NodeAdapter)?) async throws {
    await recorder.stepStarted(
      sessionId: sessionId, executionId: turn.turnId, stepId: "ask", nodeId: "ask",
      backend: turn.backend, requestedModel: turn.model, at: host.now()
    )
    let terminal: Terminal
    do {
      try checkDeadline()
      let answer = try await withDeadline(adapter: injected)
      try Task.checkCancellation()
      terminal = Terminal(status: .completed, reason: .completed, answer: answer)
    } catch {
      terminal = failure(error)
    }

    // A cancelled task may be unable to acquire the SQLite writer. Own and await terminal persistence separately.
    try await Task { try await persist(terminal) }.value
  }

  private func withDeadline(adapter injected: (any NodeAdapter)?) async throws -> String {
    try await withThrowingTaskGroup(of: String.self) { group in
      let remaining = deadline.timeIntervalSince(host.now())
      guard remaining > 0 else { throw AdapterExecutionError(.timeout, "Ask turn deadline expired") }
      group.addTask {
        try await execute(adapter: injected)
      }
      group.addTask {
        try await Task.sleep(for: .seconds(remaining))
        throw AdapterExecutionError(.timeout, "Ask turn deadline expired")
      }
      group.addTask {
        try await heartbeat()
        throw CancellationError()
      }
      defer { group.cancelAll() }
      guard let answer = try await group.next() else { throw CancellationError() }
      return answer
    }
  }

  private func heartbeat() async throws {
    while true {
      try await Task.sleep(for: .seconds(5))
      let active = try host.store.touchAskTurn(
        conversationId: conversationId, turnId: turn.turnId, runnerId: turn.runnerId, now: host.now()
      )
      guard active else { return }
    }
  }

  private func execute(adapter injected: (any NodeAdapter)?) async throws -> String {
    guard let scratch = host.turnDirectory(conversationId: conversationId, turnId: turn.turnId) else {
      throw AskError(code: "ask_record_invalid", message: "Invalid Ask turn directory")
    }
    try FileManager.default.createDirectory(
      at: scratch.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { host.removeTurnArtifact(scratch) }

    var payload = node
    payload.workingDirectory = scratch.path
    let adapter = injected ?? host.makeAdapter(host.environment)
    let history = try host.store.askMessages(conversationId: conversationId).filter { $0.turnId != turn.turnId }
    if turn.toolTransport == .mcp {
      return try await executeMCP(adapter: adapter, node: payload, scratch: scratch, history: history)
    }
    return try await executeRounds(adapter: adapter, node: payload, history: history)
  }

  private func executeMCP(
    adapter: any NodeAdapter, node: AgentNodePayload, scratch: URL, history: [AskMessage]
  ) async throws -> String {
    try checkDeadline()
    let file = AskToolServerHandoff.redactionFile(for: scratch)
    try AskToolServerHandoff.writeRedactionValues(environment: host.environment, to: file)
    defer { host.removeTurnArtifact(file) }
    let server = try AskToolServerHandoff.makeServer(
      host: host, conversationId: conversationId, turnId: turn.turnId, valuesFile: file
    )
    let prompt = try AskPrompt.user(
      context: context, history: history, toolResults: [], message: userMessage, limits: host.limits, environment: host.environment
    )
    let output = try await adapter.execute(
      AdapterExecutionInput(node: node, promptText: prompt, systemPromptText: AskPrompt.mcpSystem, mcpServers: [server]),
      context: AdapterExecutionContext(deadline: deadline, backendEventHandler: recordBackendEvent)
    )
    try checkDeadline()
    guard output.completionPassed else {
      throw AdapterExecutionError(.providerError, "Ask backend did not complete")
    }
    return redact(reply(from: output))
  }

  private func executeRounds(adapter: any NodeAdapter, node: AgentNodePayload, history: [AskMessage]) async throws -> String {
    var toolResults: [AskPrompt.ToolResult] = []
    var answer = ""
    for roundIndex in 0..<max(0, host.limits.roundsPerTurn) {
      try checkDeadline()
      let prompt = try AskPrompt.user(
        context: context, history: history, toolResults: toolResults, message: userMessage,
        limits: host.limits, environment: host.environment
      )
      let output = try await adapter.execute(
        AdapterExecutionInput(node: node, promptText: prompt, systemPromptText: AskPrompt.system),
        context: AdapterExecutionContext(deadline: deadline, backendEventHandler: recordBackendEvent)
      )
      try checkDeadline()
      guard output.completionPassed else {
        throw AdapterExecutionError(.providerError, "Ask backend did not complete")
      }
      let round = AskRoundsProtocol.parse(reply(from: output))
      answer = redact(round.answerText)
      await recordAnswer(answer, roundIndex: roundIndex)
      if round.toolCalls.isEmpty { return answer }
      for (callIndex, call) in round.toolCalls.enumerated() {
        try checkDeadline()
        let result = await tools.execute(
          conversationId: conversationId, turnId: turn.turnId,
          toolCallId: "\(turn.turnId):\(roundIndex):\(callIndex)", name: call.name, arguments: call.arguments
        )
        try checkDeadline()
        try host.store.addAskReferences(conversationId: conversationId, turnId: turn.turnId, refs: result.refs)
        toolResults.append(AskPrompt.ToolResult(id: redact(call.id), name: redact(call.name), result: result))
      }
    }
    await record(.notice(severity: "warning", title: "round_limit", description: nil))
    return answer
  }

  private func checkDeadline() throws {
    try Task.checkCancellation()
    guard host.now() < deadline else { throw AdapterExecutionError(.timeout, "Ask turn deadline expired") }
  }

  private func reply(from output: AdapterExecutionOutput) -> String {
    for key in ["text", "replyText", "summary"] {
      if case let .string(text)? = output.payload[key] { return text }
    }
    return ""
  }

  private func recordAnswer(_ text: String, roundIndex: Int) async {
    guard !text.isEmpty else { return }
    let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    for (lineIndex, line) in lines.enumerated() {
      let id = "\(turn.turnId):\(roundIndex):\(lineIndex)"
      let chunk = lineIndex == lines.count - 1 ? String(line) : String(line) + "\n"
      await record(.message(messageId: id, text: chunk, replace: false))
    }
  }

  private func recordBackendEvent(_ event: AdapterBackendEvent) async {
    guard !Task.isCancelled else { return }
    switch event.activity {
    case let .message(id, text, replace) where turn.toolTransport == .mcp:
      await record(.message(messageId: id.map(redact), text: redact(text), replace: replace), at: event.at)
    case let .stop(reason, limited, resetAt) where turn.toolTransport == .mcp:
      await record(.stop(stopReason: redact(reason), limited: limited, limitedResetAt: resetAt), at: event.at)
    case let .thought(text):
      await record(.thought(text: redact(text)), at: event.at)
    case let .plan(id, entries):
      let clean = entries.map {
        AdapterActivityPlanEntry(content: redact($0.content), status: redact($0.status), priority: redact($0.priority))
      }
      await record(.plan(planId: redact(id), entries: clean), at: event.at)
    case let .planRemoved(id):
      await record(.planRemoved(planId: redact(id)), at: event.at)
    case let .usage(value):
      if case let .object(clean) = AskRedaction.apply(.object(value), environment: host.environment) {
        await record(.usage(clean), at: event.at)
      }
    default:
      break
    }
  }

  private func record(_ update: AdapterActivityUpdate, at: Date? = nil) async {
    await recorder.record(sessionId: sessionId, executionId: turn.turnId, update: update, at: at ?? host.now())
  }

  private func failure(_ error: Error) -> Terminal {
    if Task.isCancelled || error is CancellationError {
      return Terminal(status: .cancelled, reason: .cancelled)
    }
    if (error as? AdapterExecutionError)?.code == .timeout {
      return Terminal(status: .failed, reason: .timeout, error: .init(code: "ask_timeout", message: "Ask turn deadline expired"))
    }
    if let error = error as? AskError, error.code == "redaction_values_unavailable" {
      return Terminal(status: .failed, reason: .providerError, error: .init(code: error.code, message: error.message))
    }
    let description = (error as? AdapterExecutionError)?.message ?? String(describing: error)
    return Terminal(status: .failed, reason: .providerError, error: .init(code: "ask_provider_error", message: redact(description)))
  }

  private func persist(_ terminal: Terminal) async throws {
    do {
      let citations: [AskRef]
      if let answer = terminal.answer {
        let text = AskLimits.prefix(answer, utf8Limit: host.limits.assistantMessageBytes)
        let known = try host.store.askConversation(id: conversationId)?.knownRefs ?? []
        citations = AskCitations.extract(text: text, knownRefs: known)
      } else {
        citations = []
      }
      try host.store.finishAskTurn(
        conversationId: conversationId, turnId: turn.turnId, status: terminal.status, error: terminal.error,
        assistantText: terminal.answer, citations: citations, limits: host.limits,
        now: host.now(), activityReason: terminal.reason
      )
    } catch {
      let message = redact(String(describing: error))
      RielaStandardStreams.writeError("riela ask turn settlement: \(message)\n")
      do {
        try host.store.finishAskTurn(
          conversationId: conversationId, turnId: turn.turnId, status: .failed,
          error: .init(code: "ask_store_error", message: message), now: host.now(), activityReason: .providerError
        )
      } catch {
        RielaStandardStreams.writeError("riela ask turn settlement retry: \(redact(String(describing: error)))\n")
      }
      throw error
    }
  }

  private func redact(_ text: String) -> String {
    AskRedaction.text(text, environment: host.environment)
  }
}
