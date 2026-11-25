import ArgumentParser
import Foundation
import RielaCore
import RielaGraphQL

struct ParsedBotOptions: ParsableArguments, Sendable {
  @Option var id: String?
  @Option var name: String?
  @Option var purpose: String?
  @Option var persona: String?
  @Option var backend: String?
  @Option var model: String?
  @Option var provider: String?
  @Option var workspace: String?
  @Option var memoryUpkeep: String?
  @Option var lookAround: String?
  @Option var permissionWaitMs: Int?
  @Option var item: String?
  @Option var position: Int?
  @Option var until: String?
  @Option(name: .customLong("for")) var duration: String?
  @Option var groupBy: String?
  @OptionGroup var location: ParsedBotLocation
  @Option var session: String?
  @Option var after: Int?
  @Option var limit: Int?
  @Flag var follow = false
  @Option var option: String?
  @Flag var decline = false
  @Option var file: String?
  @Option var out: String?
  @Flag var force = false
  @Option var reason: String?
  @Option var text: String?
  @Option var topic: String?
  @Option var task: String?
  @Flag var fromFindings = false
  @Option var memoryRoot: String?

  init() {}

  init(_ arguments: [String]) throws {
    do {
      self = try Self.parse(arguments)
    } catch {
      throw CLIUsageError(Self.message(for: error))
    }
  }

  func service() throws -> BotsService {
    try location.service()
  }

  func recordInput(botId: String? = nil) throws -> BotRecordInput {
    var input = BotRecordInput()
    input.id = id
    input.botId = botId
    input.name = name
    input.purpose = purpose
    input.personaId = persona
    input.defaultBackend = backend
    input.defaultModel = model
    input.providerInstanceId = provider
    input.workspace = workspace
    input.permissionWaitMs = permissionWaitMs
    input.memoryUpkeep = try schedule(memoryUpkeep)
    input.lookAround = try schedule(lookAround)
    return input
  }

  private func schedule(_ value: String?) throws -> BotJobSchedule? {
    guard let value else { return nil }
    guard let schedule = BotJobSchedule(rawValue: value) else {
      throw CLIUsageError("Bot schedules must be off, nightly or weekly")
    }
    return schedule
  }

  func listState(_ action: BotClientAction, botId: String, now: Date) throws -> SetBotListStateInput {
    var input = SetBotListStateInput(botId: botId)
    if let item {
      let parts = item.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2, ["session", "task"].contains(parts[0]), !parts[1].isEmpty else {
        throw CLIUsageError("--item must be session:<id> or task:<id>")
      }
      input.itemKind = String(parts[0])
      input.itemId = String(parts[1])
    }
    switch action {
    case .pin, .unpin:
      input.pinned = action == .pin
    case .move:
      guard let position else { throw CLIUsageError("bot move requires --position") }
      input.manualOrder = position
    case .snooze:
      input.snoozedUntil = try snoozeTimestamp(now: now)
    case .unsnooze:
      input.clearSnooze = true
    case .settle, .unsettle:
      input.settled = action == .settle
    default:
      throw CLIUsageError("Unsupported bot list state action")
    }
    return input
  }

  private func snoozeTimestamp(now: Date) throws -> String {
    if let until, duration == nil { return until }
    let units: [Character: Double] = ["s": 1, "m": 60, "h": 3_600, "d": 86_400]
    guard until == nil, let duration, let suffix = duration.last, let scale = units[suffix],
      let amount = Int(duration.dropLast()), amount > 0, amount <= Int(Int32.max) / Int(scale) else {
      throw CLIUsageError("bot snooze requires --until <ISO-8601> or --for <duration>, such as 2h")
    }
    return RoutineStore.timestamp(now.addingTimeInterval(Double(amount) * scale))
  }
}

struct ParsedBotLocation: ParsableArguments, Sendable {
  @Option var sessionStore: String?
  @Option var scope: String?
  @Option(name: .customLong("working-dir")) var workingDirectory: String?
  @Option var output: String?
  @OptionGroup var remotes: ParsedRemoteSelector

  func service() throws -> BotsService {
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    let workingDirectory = workingDirectory ?? FileManager.default.currentDirectoryPath
    guard let scope = WorkflowScope(rawValue: scope ?? "auto") else {
      throw CLIUsageError("bot --scope must be auto, project or user")
    }
    return BotsService(
      workingDirectory: workingDirectory,
      sessionStoreRoot: CLIWorkflowSessionStore.resolveRootDirectory(
        sessionStore: sessionStore, scope: scope, workingDirectory: workingDirectory, environment: environment
      ),
      environment: environment
    )
  }
}

extension ScopedParityCommandRunner {
  func botResult(options: CLICommandOptions) async -> CLICommandResult {
    do {
      guard options.output == .json || options.output == .text else {
        throw CLIUsageError("bot --output must be json or text")
      }
      guard let action = BotClientAction(rawValue: options.command ?? "list") else {
        throw CLIUsageError("Unknown bot action '\(options.command ?? "")'")
      }
      switch action {
      case .memory: return try await performBotMemory(options)
      case .job: return try await performBotJob(options)
      case .suggestion: return try await performBotSuggestion(options)
      default: break
      }
      let parsed = try ParsedBotOptions(options.arguments)
      let service = try parsed.service()
      let remote = try parsed.location.remotes.client(for: service, transport: remoteTransport)
      if action == .create || action == .list {
        guard options.target == nil else { throw CLIUsageError("bot \(action.rawValue) does not accept a positional id") }
        return try await performBotCollection(action, parsed: parsed, service: service, remote: remote, options: options)
      }
      guard let botId = options.target, !botId.isEmpty else {
        throw CLIUsageError("bot \(action.rawValue) requires a bot id")
      }
      if let remote {
        return try await performRemoteBotAction(action, botId: botId, parsed: parsed, remote: remote, options: options)
      }
      return try performBotAction(action, botId: botId, parsed: parsed, service: service, options: options)
    } catch let issue as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: issue.message)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: String(describing: error))
    }
  }

  private func performBotCollection(
    _ action: BotClientAction, parsed: ParsedBotOptions, service: BotsService,
    remote: SelectedBotRemote?, options: CLICommandOptions
  ) async throws -> CLICommandResult {
    if action == .create {
      var input = try parsed.recordInput()
      if let remote {
        input.remote = remote.selector
        return try renderBotMutation(await remote.provider.createBot(input: input), options: options)
      }
      return try renderBotMutation(service.create(input), options: options)
    }
    guard let grouping = BotListGrouping(rawValue: parsed.groupBy ?? "none") else {
      throw CLIUsageError("bot --group-by must be none or workspace")
    }
    let payload: BotListPayload
    if let remote {
      payload = try await remote.provider.bots(filter: BotFilter(groupBy: grouping, remote: remote.selector))
    } else {
      payload = try service.overview(groupBy: grouping)
    }
    return try renderBot(payload, options: options, text: botListText(payload, grouping: grouping))
  }

  private func performBotAction(
    _ action: BotClientAction, botId: String, parsed: ParsedBotOptions,
    service: BotsService, options: CLICommandOptions
  ) throws -> CLICommandResult {
    let record: BotRecord
    switch action {
    case .show:
      let detail = try service.detail(botId: botId, memoryRoot: parsed.memoryRoot)
      return try renderBot(detail, options: options, text: botDetailText(detail))
    case .feedback:
      guard (parsed.session != nil) != (parsed.task != nil) else {
        throw CLIUsageError("bot feedback requires exactly one of --session or --task")
      }
      let input = CaptureBotFeedbackInput(
        botId: botId, sessionId: parsed.session, taskId: parsed.task,
        text: parsed.text, topic: parsed.topic, fromFindings: parsed.fromFindings
      )
      return try renderBotMemoryChange(service.captureFeedback(input, explicitRoot: parsed.memoryRoot), options: options)
    case .update:
      guard parsed.id == nil else { throw CLIUsageError("bot update cannot change the bot id") }
      return try renderBotMutation(service.update(parsed.recordInput(botId: botId)), options: options)
    case .pause, .resume:
      record = try service.store.setPaused(botId: botId, paused: action == .pause)
    case .remove:
      record = try service.remove(botId: botId)
    default:
      let change = try parsed.listState(action, botId: botId, now: service.now())
      record = try service.setListState(change)
    }
    return try renderBotMutation(BotMutationPayload(bot: record, origin: service.origin(service.now())), options: options)
  }
}

func renderBotMutation(_ payload: BotMutationPayload, options: CLICommandOptions) throws -> CLICommandResult {
  let bot = payload.bot
  let text = "\(bot.botId)  \(bot.name)" + (bot.paused ? "  paused" : "") + remoteHostText(payload.origin)
  var result = try renderBot(payload, options: options, text: text)
  result.stderr = payload.warnings.map { $0 + "\n" }.joined()
  return result
}

func renderBot<T: Encodable>(
  _ value: T, options: CLICommandOptions, text: @autoclosure () -> String
) throws -> CLICommandResult {
  CLICommandResult(
    exitCode: .success, stdout: options.output == .json ? try jsonString(BotSurfaceJSON.value(value)) : text()
  )
}

private func botListText(_ payload: BotListPayload, grouping: BotListGrouping) -> String {
  guard !payload.bots.isEmpty else { return "[]\n" }
  let showHost = payload.bots.contains { $0.origin.remote != "local" }
  return payload.bots.map { row in
    let host = showHost ? "  \(row.origin.remote)" : ""
    if row.origin.connection == "disconnected" {
      let time = row.origin.observedAt == .distantPast ? "unknown" : RoutineStore.timestamp(row.origin.observedAt)
      return "\(row.bot.botId)\(host)  disconnected (last seen \(time))"
    }
    let counts = row.counts
    let group = grouping == .workspace ? "  \(row.workspaceGroup)" : ""
    let work = row.inProgress.map(botItemText).joined(separator: ", ")
    let activity = row.lastActivityAt.map(RoutineStore.timestamp) ?? "-"
    let state = row.bot.paused ? "  paused" : ""
    return "\(row.bot.botId)\(host)  \(row.section.rawValue)\(group)  needs:\(counts.needsYou) working:\(counts.working) "
      + "waiting:\(counts.waiting) planned:\(counts.planned)  \(activity)  \(row.lastResult ?? work)\(state)"
  }.joined(separator: "\n") + "\n"
}

func botDetailText(_ detail: BotDetailPayload) -> String {
  let board = detail.board
  let groups = [
    ("Needs you", board.needsYou), ("In progress", board.inProgress), ("Waiting", board.waiting),
    ("Planned", board.planned), ("Closed (\(board.closedTotal))", board.closed)
  ]
  var lines = ["\(detail.bot.botId)  \(detail.bot.name)" + remoteHostText(detail.origin)]
  for (title, items) in groups {
    lines.append(title)
    lines += items.map { "  " + botItemText($0) }
  }
  lines.append("Routines")
  lines += detail.routines.map { routine in
    "  \(routine.name)  \(routine.status)  \(routine.nextRunAt.map(RoutineStore.timestamp) ?? "-")"
  }
  lines.append("Jobs")
  lines += detail.jobs.map { job in
    "  " + [job.job.rawValue, job.schedule.rawValue, job.lastRun?.status.rawValue, job.lastRun?.detail]
      .compactMap { $0 }.joined(separator: "  ")
  }
  lines.append("Suggestions")
  lines += detail.suggestions.map { "  " + botSuggestionText($0) }
  let memory = detail.memory
  let lastChange = memory.lastChangedAt ?? "-"
  lines.append("Memory  \(memory.instructionCount) instructions  \(memory.noteCount) notes  last change \(lastChange)")
  return lines.joined(separator: "\n") + "\n"
}

private func botItemText(_ item: BotBoardItem) -> String {
  let elapsed = item.elapsedMs.map { "\($0 / 1_000)s" }
  return [item.title, item.stepId, item.nodeId, item.backend, item.model, elapsed, item.waitingReason, item.lastResult]
    .compactMap { $0 }.joined(separator: "  ")
}
