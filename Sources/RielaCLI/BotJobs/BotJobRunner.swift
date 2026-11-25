import Foundation
import RielaCore
import RielaGraphQL

struct BotJobRunner {
  let service: BotsService
  var memoryRoot: String?
  var calendar = Calendar.current
  var mockScenarioPath: String?
  var nodeAdapter: (any NodeAdapter)?
  var workflowOverride: (@Sendable (TemporaryWorkflowPayload) -> TemporaryWorkflowPayload)?

  func run(botId: String, job: BotJobKind, force: Bool) async throws -> BotJobPayload {
    try Task.checkCancellation()
    let projection = try service.projection(botId: botId)
    var input = projection.input
    let bot = input.bot
    let store = service.store
    let now = service.now()
    let schedule = job.schedule(for: bot)
    let origin = service.origin(now)
    let lastSuccessAt = try store.lastSuccessfulJobRun(botId: botId, job: job)?.finishedAt.flatMap(botDate)
    let overview = BotBoardProjector.overviewRow(input)
    let jobSessionIds = try Set(store.links(botId: botId).filter { $0.source == "job" }.map(\.sessionId))
    input.sessions.removeAll { jobSessionIds.contains($0.session.sessionId) }
    let decision = try decision(
      job: job, force: force, schedule: schedule, input: input, overview: overview, lastSuccessAt: lastSuccessAt
    )
    let key: String
    let skipped: [String]
    switch decision {
    case .notDue(let reason):
      return .init(botId: botId, job: job, status: .notDue, detail: reason, origin: origin)
    case .skip(let period, let reason):
      try store.recordSkippedJobRuns(botId: botId, job: job, periodKeys: [period], reason: reason, at: now)
      return .init(botId: botId, job: job, periodKey: period, status: .skipped, detail: reason, origin: origin)
    case .run(let period, let catchUp):
      (key, skipped) = (period, catchUp)
    }

    let writer = service.memoryWriter(explicitRoot: memoryRoot)
    let prompt = try BotJobWorkflows.prompt(job: job, input: input, lastSuccessAt: lastSuccessAt, writer: writer)
    let builtIn = try BotJobWorkflows.make(job: job, bot: bot, prompt: prompt)
    let workflow = workflowOverride?(builtIn) ?? builtIn
    if job == .lookAround {
      try checkReadOnly(workflow)
    }
    let target = try jsonString(workflow)
    guard try store.claimJobRun(botId: botId, job: job, periodKey: key, sessionId: nil, at: now) else {
      return .init(botId: botId, job: job, periodKey: key, status: .notDue, detail: "claimed", origin: origin)
    }

    var status: BotJobPayload.Status = .failed
    var sessionId: String?
    var detail: String?
    var changeSet: BotMemoryChangeSet?
    var suggestions: [BotSuggestion]?
    do {
      try store.recordSkippedJobRuns(botId: botId, job: job, periodKeys: skipped, reason: "catch_up", at: now)
      let execution = try await execute(target: target, botId: botId, sourceRef: "\(job.rawValue):\(key)")
      sessionId = execution.sessionId
      guard execution.succeeded, let sessionId = execution.sessionId else {
        throw BotStoreError(code: execution.detail ?? "bot_job_run_failed", message: "Bot job workflow failed")
      }
      try Task.checkCancellation()
      if job == .upkeep {
        guard case let .string(markdown)? = execution.output["memoryMarkdown"] else {
          throw BotStoreError(code: "memory_markdown_invalid", message: "Upkeep output requires memoryMarkdown")
        }
        changeSet = try writer.applyMarkdown(
          botId: botId, markdown: markdown, source: .upkeep, actor: "upkeep", reason: "upkeep:\(key)",
          evidenceRefs: ["session:\(sessionId)"]
        )
      } else {
        suggestions = try store.insertSuggestions(
          botId: botId, drafts: BotSuggestion.parseOutput(execution.output), sourceSessionId: sessionId, at: service.now()
        )
      }
      status = .succeeded
    } catch let error as BotStoreError {
      detail = input.redact(error.code)
    } catch is CancellationError {
      detail = "cancelled"
    } catch {
      detail = "bot_job_run_failed"
    }
    try store.finishJobRun(
      botId: botId, job: job, periodKey: key, status: status == .succeeded ? .succeeded : .failed,
      detail: detail, sessionId: sessionId, at: service.now()
    )
    return .init(
      botId: botId, job: job, periodKey: key, status: status, sessionId: sessionId, detail: detail,
      origin: origin, changeSet: changeSet, suggestions: suggestions
    )
  }

  private func decision(
    job: BotJobKind, force: Bool, schedule: BotJobSchedule, input: BotBoardInput,
    overview: BotOverviewRow, lastSuccessAt: Date?
  ) throws -> BotJobDecision {
    let bot = input.bot
    let busy = overview.counts.working > 0 || overview.counts.needsYou > 0
    if force {
      guard !bot.paused else {
        throw BotStoreError(code: "bot_paused", message: "Bot '\(bot.botId)' is paused")
      }
      guard !busy else { return .notDue(reason: "busy") }
      let key = BotJobDue.periodKey(for: input.now, schedule: schedule == .off ? .nightly : schedule, calendar: calendar)
      guard let key else { return .notDue(reason: "invalid_period") }
      return .run(periodKey: "\(key)-manual-\(UUID().uuidString.prefix(8))", skippedPeriodKeys: [])
    }

    let history = try service.store.jobRuns(botId: bot.botId, job: job, limit: Int.max)
    let activity = BotBoardProjector.overviewRow(input).lastActivityAt
    return BotJobDue.decide(BotJobDueInput(
      schedule: schedule, now: input.now, calendar: calendar, paused: bot.paused,
      busy: busy,
      lastActivityAt: activity, lastSuccessAt: lastSuccessAt, ledgerPeriodKeys: Set(history.map(\.periodKey))
    ))
  }

  private func checkReadOnly(_ payload: TemporaryWorkflowPayload) throws {
    let materialized = materializeTemporaryWorkflowPayload(payload)
    guard let workflow = materialized.validation.workflow else {
      throw BotStoreError(code: "look_around_not_read_only", message: "Invalid look-around workflow")
    }
    let issues = LookAroundPolicy.violations(workflow: workflow, nodePayloads: materialized.nodePayloads)
    guard issues.isEmpty else {
      throw BotStoreError(code: "look_around_not_read_only", message: issues.joined(separator: "; "))
    }
  }
}
