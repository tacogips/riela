import RielaCore

public struct RunBotJobInput: Codable, Equatable, Sendable {
  public let botId: String
  public let job: BotJobKind
  public let force: Bool?
  public let remote: String?

  package init(botId: String, job: BotJobKind, force: Bool?, remote: String?) {
    self.botId = botId
    self.job = job
    self.force = force
    self.remote = remote
  }
}

public enum BotSuggestionDecision: String, Codable, Sendable {
  case accept, dismiss
}

public struct DecideBotSuggestionInput: Codable, Equatable, Sendable {
  public let suggestionId: String
  public let decision: BotSuggestionDecision
  public let run: Bool?
  public let reason: String?
  public let remote: String?

  public init(
    suggestionId: String, decision: BotSuggestionDecision, run: Bool? = nil, reason: String? = nil, remote: String? = nil
  ) {
    self.suggestionId = suggestionId
    self.decision = decision
    self.run = run
    self.reason = reason
    self.remote = remote
  }
}

public struct BotJobPayload: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable {
    case notDue = "not_due"
    case skipped, succeeded, failed
  }

  public let botId: String
  public let job: BotJobKind
  public let periodKey: String?
  public let status: Status
  public let sessionId: String?
  public let detail: String?
  public let origin: BotOrigin
  public let changeSet: BotMemoryChangeSet?
  public let suggestions: [BotSuggestion]?

  public init(
    botId: String, job: BotJobKind, periodKey: String? = nil, status: Status,
    sessionId: String? = nil, detail: String? = nil, origin: BotOrigin,
    changeSet: BotMemoryChangeSet? = nil, suggestions: [BotSuggestion]? = nil
  ) {
    self.botId = botId
    self.job = job
    self.periodKey = periodKey
    self.status = status
    self.sessionId = sessionId
    self.detail = detail
    self.origin = origin
    self.changeSet = changeSet
    self.suggestions = suggestions?.map { $0.withOrigin(origin) }
  }
}

public struct BotJobSummary: Codable, Equatable, Sendable {
  public let job: BotJobKind
  public let schedule: BotJobSchedule
  public let lastRun: BotJobRun?

  public init(job: BotJobKind, schedule: BotJobSchedule, lastRun: BotJobRun?) {
    self.job = job
    self.schedule = schedule
    self.lastRun = lastRun
  }
}

public struct BotSuggestionListPayload: Codable, Equatable, Sendable {
  public let botId: String
  public let suggestions: [BotSuggestion]
  public let origin: BotOrigin

  public init(botId: String, suggestions: [BotSuggestion], origin: BotOrigin) {
    self.botId = botId
    self.suggestions = suggestions
    self.origin = origin
  }
}

public struct BotSuggestionPayload: Codable, Equatable, Sendable {
  public let suggestion: BotSuggestion
  public let origin: BotOrigin

  public init(suggestion: BotSuggestion, origin: BotOrigin) {
    self.suggestion = suggestion
    self.origin = origin
  }
}

public struct BotJobHistoryPayload: Codable, Equatable, Sendable {
  public let runs: [BotJobRun]
  public let origin: BotOrigin

  public init(runs: [BotJobRun], origin: BotOrigin) {
    self.runs = runs
    self.origin = origin
  }
}
