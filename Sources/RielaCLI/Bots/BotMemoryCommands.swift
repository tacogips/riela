import ArgumentParser
import Foundation
import RielaCore
import RielaGraphQL

enum BotMemoryClientAction: String, CaseIterable {
  case show, export, edit, history, diff, undo
}

struct ParsedBotMemoryArguments: ParsableArguments {
  @Argument var botId: String
  @Argument var changeId: String?
  @OptionGroup var options: ParsedBotOptions
}

extension ScopedParityCommandRunner {
  func performBotMemory(_ options: CLICommandOptions) async throws -> CLICommandResult {
    guard let verb = options.target.flatMap(BotMemoryClientAction.init(rawValue:)) else {
      throw CLIUsageError("bot memory requires show, export, edit, history, diff or undo")
    }
    let args: ParsedBotMemoryArguments
    do {
      args = try ParsedBotMemoryArguments.parse(options.arguments)
    } catch {
      throw CLIUsageError(ParsedBotMemoryArguments.message(for: error))
    }
    let parsed = args.options
    let service = try parsed.service()
    let botId = args.botId
    let changeId = args.changeId
    guard changeId == nil || verb == .diff || verb == .undo else {
      throw CLIUsageError("bot memory \(verb.rawValue) does not accept a change id")
    }

    if let remote = try parsed.location.remotes.client(for: service, transport: remoteTransport) {
      return try await performRemoteMemory(verb, args: args, remote: remote, options: options)
    }
    let writer = service.memoryWriter(explicitRoot: parsed.memoryRoot)
    switch verb {
    case .show, .export:
      let markdown = try BotMemoryMarkdown.render(entries: writer.entries(botId: botId))
      if verb == .export, let output = parsed.out {
        try Data(markdown.utf8).write(
          to: URL(fileURLWithPath: output), options: parsed.force ? .atomic : .withoutOverwriting
        )
        return CLICommandResult(exitCode: .success)
      }
      return try renderBot(["botId": botId, "markdown": markdown], options: options, text: markdown)
    case .edit:
      guard let file = parsed.file else { throw CLIUsageError("bot memory edit requires --file") }
      let markdown = try String(contentsOfFile: file, encoding: .utf8)
      let change = try writer.applyMarkdown(
        botId: botId, markdown: markdown, source: .user, actor: "cli", reason: parsed.reason ?? "edit"
      )
      return try renderBotMemoryChange(change, options: options)
    case .history:
      let limit = parsed.limit ?? 50
      guard limit > 0 else { throw CLIUsageError("bot memory history --limit must be positive") }
      let changes = try writer.history(botId: botId, limit: limit)
      return try renderBot(changes, options: options, text: changes.map(botMemoryChangeText).joined())
    case .diff:
      guard let changeId else { throw CLIUsageError("bot memory diff requires a change id") }
      let diffs = try writer.diff(botId: botId, changeId: changeId)
      return try renderBot(diffs, options: options, text: botMemoryDiffText(diffs))
    case .undo:
      return try renderBotMemoryChange(writer.undo(botId: botId, changeId: changeId, actor: "cli"), options: options)
    }
  }
}

func renderBotMemoryChange(_ change: BotMemoryChangeSet, options: CLICommandOptions) throws -> CLICommandResult {
  try renderBot(change, options: options, text: botMemoryChangeText(change))
}

func botMemoryChangeText(_ change: BotMemoryChangeSet) -> String {
  guard !change.changeId.isEmpty else { return "No memory changes.\n" }
  return "\(change.changeId)  \(change.createdAt)  \(change.actor.rawValue)  \(change.reason)  \(change.entries.count) entries\n"
}

func botMemoryDiffText(_ diffs: [BotMemoryEntryDiff]) -> String {
  diffs.map { diff in
    let changes = diff.changes.map { change in
      let before = change.beforeJSON.flatMap { String(bytes: $0, encoding: .utf8) }.map { "- " + $0 + "\n" } ?? ""
      let after = change.afterJSON.flatMap { String(bytes: $0, encoding: .utf8) }.map { "+ " + $0 + "\n" } ?? ""
      return "\(change.op) \(change.path)\n" + before + after
    }.joined()
    return "\(diff.entry.op.rawValue) entry \(diff.entry.recordId)\n" + changes
  }.joined()
}
