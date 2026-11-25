import Foundation
import RielaGraphQL

extension ScopedParityCommandRunner {
  func performRemoteMemory(
    _ verb: BotMemoryClientAction, args: ParsedBotMemoryArguments, remote: SelectedBotRemote, options: CLICommandOptions
  ) async throws -> CLICommandResult {
    try remote.requireSingle()
    let parsed = args.options
    guard parsed.memoryRoot == nil else { throw CLIUsageError("--memory-root is local-only") }
    let provider = remote.provider
    switch verb {
    case .show, .export:
      let payload = try await provider.botMemory(botId: args.botId, remote: remote.selector)
      if verb == .export, let output = parsed.out {
        try Data(payload.markdown.utf8).write(
          to: URL(fileURLWithPath: output), options: parsed.force ? .atomic : .withoutOverwriting
        )
        return CLICommandResult(exitCode: .success)
      }
      return try renderBot(payload, options: options, text: payload.markdown)
    case .edit:
      guard let file = parsed.file else { throw CLIUsageError("bot memory edit requires --file") }
      let input = UpdateBotMemoryInput(
        botId: args.botId, markdown: try String(contentsOfFile: file, encoding: .utf8),
        reason: parsed.reason, remote: remote.selector
      )
      return try renderRemoteMemoryChange(await provider.updateBotMemory(input: input), options: options)
    case .history:
      let limit = parsed.limit ?? 50
      guard limit > 0 else { throw CLIUsageError("bot memory history --limit must be positive") }
      let payload = try await provider.botMemoryHistory(botId: args.botId, limit: limit, remote: remote.selector)
      return try renderBot(payload, options: options, text: payload.changes.map(botMemoryChangeText).joined())
    case .diff:
      guard let changeId = args.changeId else { throw CLIUsageError("bot memory diff requires a change id") }
      let payload = try await provider.botMemoryDiff(botId: args.botId, changeId: changeId, remote: remote.selector)
      return try renderBot(payload, options: options, text: botMemoryDiffText(payload.diffs))
    case .undo:
      let input = UndoBotMemoryChangeInput(botId: args.botId, changeId: args.changeId, remote: remote.selector)
      return try renderRemoteMemoryChange(await provider.undoBotMemoryChange(input: input), options: options)
    }
  }
}

func renderRemoteMemoryChange(_ payload: BotMemoryChangePayload, options: CLICommandOptions) throws -> CLICommandResult {
  try renderBot(payload, options: options, text: botMemoryChangeText(payload.change))
}
