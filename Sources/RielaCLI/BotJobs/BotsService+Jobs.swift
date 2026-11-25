import Foundation
import RielaAddons
import RielaCore
import RielaGraphQL

extension BotsService {
  func runJob(
    botId: String, job: BotJobKind, force: Bool, mockScenarioPath: String? = nil
  ) async throws -> BotJobPayload {
    try await BotJobRunner(service: self, mockScenarioPath: mockScenarioPath).run(botId: botId, job: job, force: force)
  }

  func jobHistory(botId: String, job: BotJobKind?, limit: Int) throws -> [BotJobRun] {
    try requireJobBot(botId)
    let jobs = job.map { [$0] } ?? BotJobKind.allCases
    let history = try jobs.flatMap { try store.jobRuns(botId: botId, job: $0, limit: limit) }
    return Array(history.sorted {
      ($0.startedAt, $0.periodKey, $0.job.rawValue) > ($1.startedAt, $1.periodKey, $1.job.rawValue)
    }.prefix(limit))
  }

  func jobSummaries(bot: BotRecord) throws -> [BotJobSummary] {
    try BotJobKind.allCases.map { job in
      let lastRun = try store.jobRuns(botId: bot.botId, job: job, limit: 1).first
      return BotJobSummary(job: job, schedule: job.schedule(for: bot), lastRun: lastRun)
    }
  }

  func suggestions(botId: String, status: BotSuggestion.Status?) throws -> [BotSuggestion] {
    try requireJobBot(botId)
    return try store.suggestions(botId: botId, status: status)
  }

  func decideSuggestion(
    _ input: DecideBotSuggestionInput, actor: String, mockScenarioPath: String? = nil
  ) async throws -> BotSuggestion {
    let id = input.suggestionId
    switch input.decision {
    case .dismiss:
      return try store.dismissSuggestion(suggestionId: id, by: actor, reason: input.reason, at: now())
    case .accept:
      let accepted = try store.acceptSuggestion(suggestionId: id, by: actor, at: now())
      guard input.run == true else { return accepted }
      guard let action = accepted.action else {
        throw BotStoreError(code: "suggestion_no_action", message: "Accepted suggestion '\(id)' has no workflow action")
      }
      // Suggestions can name a workflow. Inline definitions and paths are
      // ordinary CLI inputs and must not be supplied by a model here.
      let name = action.workflowName
      guard isSafeScopedWorkflowName(name) || (!name.hasSuffix(".json") && WorkflowPackageManifestValidator.isSafePackageName(name)) else {
        throw BotStoreError(code: "suggestion_action_invalid", message: "Suggestion requires a workflow name")
      }
      let provider = WorkflowExecutionProvider(
        workingDirectory: workingDirectory, sessionStoreRoot: sessionStoreRoot, environment: environment
      )
      let run = try await provider.executeWorkflow(
        .init(workflowName: name, runtimeVariables: action.input, botId: accepted.botId),
        mockScenarioPath: mockScenarioPath
      )
      guard try store.link(forSession: run.sessionId)?.botId == accepted.botId else {
        throw BotStoreError(code: "suggestion_run_failed", message: "Suggested workflow did not start a linked session")
      }
      return try store.markSuggestionStarted(suggestionId: id, sessionId: run.sessionId)
    }
  }

  private func requireJobBot(_ botId: String) throws {
    guard try store.load(botId: botId) != nil else {
      throw BotStoreError(code: "bot_not_found", message: "Bot '\(botId)' was not found")
    }
  }
}
