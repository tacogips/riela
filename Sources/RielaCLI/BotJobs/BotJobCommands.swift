import ArgumentParser
import RielaCore
import RielaGraphQL

enum BotJobClientAction: String, CaseIterable {
  case run, list
}

enum BotSuggestionClientAction: String, CaseIterable {
  case list, accept, dismiss
}

struct ParsedBotJobArguments: ParsableArguments {
  @Argument var botId: String
  @Argument var jobKind: String?
  @Flag var force = false
  @Option var mockScenario: String?
  @Option var job: String?
  @Option var limit: Int?
  @OptionGroup var location: ParsedBotLocation
}

struct ParsedBotSuggestionArguments: ParsableArguments {
  @Argument var id: String
  @Option var status: String?
  @Flag var run = false
  @Option var mockScenario: String?
  @Option var reason: String?
  @OptionGroup var location: ParsedBotLocation
}

extension ScopedParityCommandRunner {
  func performBotJob(_ options: CLICommandOptions) async throws -> CLICommandResult {
    guard let verb = options.target.flatMap(BotJobClientAction.init(rawValue:)) else {
      throw CLIUsageError("bot job requires run or list")
    }
    let args = try parseBotJobArguments(ParsedBotJobArguments.self, options.arguments)
    let service = try args.location.service()
    let remote = try args.location.remotes.client(for: service, transport: remoteTransport)
    try remote?.requireSingle()
    guard remote == nil || args.mockScenario == nil else { throw CLIUsageError("--mock-scenario is local-only for bot jobs") }
    switch verb {
    case .run:
      guard args.job == nil, args.limit == nil else {
        throw CLIUsageError("bot job run accepts a positional job kind and no --job or --limit")
      }
      guard let job = args.jobKind.flatMap(BotJobKind.init(rawValue:)) else {
        throw CLIUsageError("bot job run requires upkeep or look-around")
      }
      let payload: BotJobPayload
      if let remote {
        let input = RunBotJobInput(botId: args.botId, job: job, force: args.force, remote: remote.selector)
        payload = try await remote.provider.runBotJob(input: input)
      } else {
        payload = try await service.runJob(botId: args.botId, job: job, force: args.force, mockScenarioPath: args.mockScenario)
      }
      let text = [payload.job.rawValue, payload.periodKey, payload.status.rawValue, payload.detail, payload.sessionId]
        .compactMap { $0 }.joined(separator: "  ")
      var result = try renderBot(payload, options: options, text: text + remoteHostText(payload.origin) + "\n")
      if payload.status == .failed {
        result.exitCode = .failure
        result.stderr = payload.detail ?? payload.status.rawValue
      }
      return result
    case .list:
      guard args.jobKind == nil, !args.force, args.mockScenario == nil else {
        throw CLIUsageError("bot job list accepts --job and --limit")
      }
      let job = args.job.flatMap(BotJobKind.init(rawValue:))
      guard args.job == nil || job != nil else {
        throw CLIUsageError("bot job list --job must be upkeep or look-around")
      }
      let limit = args.limit ?? 50
      guard limit > 0 else { throw CLIUsageError("bot job list --limit must be positive") }
      if let remote {
        let result = try await remote.provider.botJobHistory(botId: args.botId, job: job, limit: limit, remote: remote.selector)
        return try renderBot(result, options: options, text: result.runs.map(botJobRunText).joined())
      }
      let runs = try service.jobHistory(botId: args.botId, job: job, limit: limit)
      return try renderBot(runs, options: options, text: runs.map(botJobRunText).joined())
    }
  }

  func performBotSuggestion(_ options: CLICommandOptions) async throws -> CLICommandResult {
    guard let verb = options.target.flatMap(BotSuggestionClientAction.init(rawValue:)) else {
      throw CLIUsageError("bot suggestion requires list, accept or dismiss")
    }
    let args = try parseBotJobArguments(ParsedBotSuggestionArguments.self, options.arguments)
    let service = try args.location.service()
    let remote = try args.location.remotes.client(for: service, transport: remoteTransport)
    guard remote == nil || args.mockScenario == nil else { throw CLIUsageError("--mock-scenario is local-only for suggestions") }
    if verb == .list {
      guard !args.run, args.mockScenario == nil, args.reason == nil else {
        throw CLIUsageError("bot suggestion list accepts --status")
      }
      let status = args.status.flatMap(BotSuggestion.Status.init(rawValue:))
      guard args.status == nil || status != nil else {
        throw CLIUsageError("bot suggestion list --status must be open, accepted, started or dismissed")
      }
      if let remote {
        let result = try await remote.provider.botSuggestions(botId: args.id, status: status, remote: remote.selector)
        return try renderBot(result, options: options, text: result.suggestions.map { botSuggestionText($0) + "\n" }.joined())
      }
      let suggestions = try service.suggestions(botId: args.id, status: status)
      return try renderBot(suggestions, options: options, text: suggestions.map { botSuggestionText($0) + "\n" }.joined())
    }
    let validDecisionOptions = verb == .accept ? args.reason == nil : !args.run && args.mockScenario == nil
    guard args.status == nil, validDecisionOptions else {
      throw CLIUsageError("bot suggestion accept takes --run and dismiss takes --reason")
    }
    guard args.mockScenario == nil || args.run else {
      throw CLIUsageError("bot suggestion accept --mock-scenario requires --run")
    }
    try remote?.requireSingle()
    let input = DecideBotSuggestionInput(
      suggestionId: args.id, decision: verb == .accept ? .accept : .dismiss,
      run: args.run, reason: args.reason, remote: remote?.selector
    )
    if let remote {
      let result = try await remote.provider.decideBotSuggestion(input: input)
      return try renderBot(result, options: options, text: botSuggestionText(result.suggestion) + remoteHostText(result.origin) + "\n")
    }
    let suggestion = try await service.decideSuggestion(input, actor: "cli", mockScenarioPath: args.mockScenario)
    return try renderBot(suggestion, options: options, text: botSuggestionText(suggestion) + "\n")
  }
}

private func parseBotJobArguments<Arguments: ParsableArguments>(
  _ type: Arguments.Type, _ arguments: [String]
) throws -> Arguments {
  do {
    return try type.parse(arguments)
  } catch {
    throw CLIUsageError(type.message(for: error))
  }
}

private func botJobRunText(_ run: BotJobRun) -> String {
  [run.job.rawValue, run.periodKey, run.status.rawValue, run.finishedAt, run.detail, run.sessionId]
    .compactMap { $0 }.joined(separator: "  ") + "\n"
}

func botSuggestionText(_ suggestion: BotSuggestion) -> String {
  [suggestion.suggestionId, suggestion.status.rawValue, suggestion.title, suggestion.detail, suggestion.startedSessionId]
    .compactMap { $0 }.joined(separator: "  ")
}
