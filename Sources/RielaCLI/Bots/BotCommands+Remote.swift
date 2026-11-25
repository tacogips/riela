import Foundation
import RielaGraphQL

extension ScopedParityCommandRunner {
  func performRemoteBotAction(
    _ action: BotClientAction, botId: String, parsed: ParsedBotOptions,
    remote: SelectedBotRemote, options: CLICommandOptions
  ) async throws -> CLICommandResult {
    try remote.requireSingle()
    guard parsed.memoryRoot == nil else { throw CLIUsageError("--memory-root is local-only") }
    let provider = remote.provider
    let selector = remote.selector
    switch action {
    case .show:
      let detail = try await provider.bot(botId: botId, remote: selector)
      return try renderBot(detail, options: options, text: botDetailText(detail))
    case .feedback:
      guard (parsed.session != nil) != (parsed.task != nil) else {
        throw CLIUsageError("bot feedback requires exactly one of --session or --task")
      }
      let input = CaptureBotFeedbackInput(
        botId: botId, sessionId: parsed.session, taskId: parsed.task, text: parsed.text,
        topic: parsed.topic, fromFindings: parsed.fromFindings, remote: selector
      )
      let payload = try await provider.captureBotFeedback(input: input)
      return try renderRemoteMemoryChange(payload, options: options)
    case .update:
      guard parsed.id == nil else { throw CLIUsageError("bot update cannot change the bot id") }
      var input = try parsed.recordInput(botId: botId)
      input.remote = selector
      return try renderBotMutation(await provider.updateBot(input: input), options: options)
    case .pause, .resume:
      let input = SetBotPausedInput(botId: botId, paused: action == .pause, remote: selector)
      return try renderBotMutation(await provider.setBotPaused(input: input), options: options)
    case .remove:
      return try renderBotMutation(await provider.removeBot(input: RemoveBotInput(botId: botId, remote: selector)), options: options)
    default:
      var input = try parsed.listState(action, botId: botId, now: Date())
      input.remote = selector
      return try renderBotMutation(await provider.setBotListState(input: input), options: options)
    }
  }
}
