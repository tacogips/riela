import Foundation
import RielaCore
import RielaGraphQL

extension RielaCLIApplication {
  func runScopedCommand(_ command: ScopedCommand) async -> CLICommandResult {
    if command.kind == .bot, let action = BotClientAction(rawValue: command.options.command ?? ""),
      action == .activity || action == .answer {
      return await BotActivityCommands(writer: sessionInspectionCommand.followRecordWriter)
        .run(action, options: command.options)
    }
    return await scopedCommandRunner.run(command)
  }
}

private struct BotActivityCommands {
  let writer: (@Sendable (String) -> Void)?

  func run(_ action: BotClientAction, options: CLICommandOptions) async -> CLICommandResult {
    do {
      let parsed = try ParsedBotOptions(options.arguments)
      let service = try parsed.service()
      if action == .answer {
        return try answer(options, parsed: parsed, service: service)
      }
      return try await activity(options, parsed: parsed, service: service)
    } catch let issue as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: issue.message)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: String(describing: error))
    }
  }

  private func answer(_ options: CLICommandOptions, parsed: ParsedBotOptions, service: BotsService) throws -> CLICommandResult {
    guard let requestId = options.target, !requestId.isEmpty else {
      throw CLIUsageError("bot answer requires a request id")
    }
    guard options.output == .text || options.output == .json else {
      throw CLIUsageError("bot answer --output must be json or text")
    }
    let payload = try service.answer(requestId: requestId, optionId: parsed.option, decline: parsed.decline)
    let output = options.output == .json ? try jsonString(payload) : "\(payload.status.rawValue)\n"
    return CLICommandResult(exitCode: .success, stdout: output)
  }

  private func activity(
    _ options: CLICommandOptions, parsed: ParsedBotOptions, service: BotsService
  ) async throws -> CLICommandResult {
    let sessionId: String
    switch (options.target, parsed.session) {
    case let (nil, id?) where !id.isEmpty:
      sessionId = id
    case let (id?, nil) where !id.isEmpty:
      sessionId = try service.activitySessionId(botId: id)
    default:
      throw CLIUsageError("bot activity requires a bot id or --session <id>")
    }
    var cursor = parsed.after ?? 0
    let limit = min(BotActivityPage.maximumLimit, max(1, parsed.limit ?? BotActivityPage.defaultLimit))
    var first = true
    var buffered = ""
    while !Task.isCancelled {
      let page: BotActivityPage
      do {
        page = try await service.activity(
          sessionId: sessionId, afterSequence: cursor, limit: limit,
          waitMs: parsed.follow ? BotActivityPage.maximumWaitMs : 0
        )
      } catch is CancellationError {
        break
      }
      let ended = page.sessionStatus == "unknown"
        || (WorkflowSessionStatus(rawValue: page.sessionStatus)?.isTerminal == true && page.state?.currentExecutionId == nil)
      if first || !page.events.isEmpty || (ended && options.output == .json) {
        let output = try render(page, format: options.output, includeSource: first)
        if parsed.follow, let writer {
          writer(output)
        } else {
          buffered += output
        }
      }
      first = false
      if !parsed.follow || (ended && page.events.count < limit) {
        break
      }
      cursor = page.lastSequence
      // A busy server can downgrade a wait to a replay. Avoid spinning on an empty page.
      if page.events.isEmpty {
        do {
          try await Task.sleep(for: .milliseconds(250))
        } catch is CancellationError {
          break
        }
      }
    }
    return CLICommandResult(exitCode: .success, stdout: buffered)
  }

  private func render(_ page: BotActivityPage, format: WorkflowOutputFormat, includeSource: Bool) throws -> String {
    switch format {
    case .json:
      return try jsonString(page)
    case .jsonl:
      return try page.events.map { try jsonString($0) }.joined()
    case .text, .table:
      var lines: [String] = []
      if includeSource { lines.append("activitySource: \(page.activitySource)") }
      if page.truncated {
        lines.append("(earlier events were trimmed; state follows)")
        if let state = page.state { lines += stateLines(state) }
      }
      lines += page.events.map(eventLine)
      return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
  }

  private func stateLines(_ state: ActivityState) -> [String] {
    let plans = state.plans.flatMap(\.entries).map { "  [\($0.status)] \($0.content)" }
    let terminalToolStatuses = ["completed", "failed", "interrupted"]
    let tools = state.toolCalls.filter { !terminalToolStatuses.contains($0.status ?? "") }
      .map { "  \($0.title ?? $0.toolCallId)" }
    return ["Plan:"] + plans + ["Open tool calls:"] + tools + ["Pending requests:"] + state.pendingRequestIds.map { "  \($0)" }
  }

  private func eventLine(_ event: ActivityEvent) -> String {
    let time = RoutineStore.timestamp(event.at).dropFirst(11).prefix(8)
    let summary = ["text", "title", "reason", "status", "stepId"].lazy.compactMap { key -> String? in
      guard case let .string(value)? = event.payload[key] else { return nil }
      return value
    }.first ?? ""
    let line = summary.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(160)
    return "\(event.seq) \(time) \(event.kind.rawValue)" + (line.isEmpty ? "" : " \(line)")
  }
}
