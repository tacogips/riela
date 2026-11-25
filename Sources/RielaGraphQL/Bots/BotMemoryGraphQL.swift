import RielaCore

public struct BotMemorySummary: Codable, Equatable, Sendable {
  public let instructionCount: Int
  public let noteCount: Int
  public let lastChangedAt: String?

  public init(instructionCount: Int = 0, noteCount: Int = 0, lastChangedAt: String? = nil) {
    self.instructionCount = instructionCount
    self.noteCount = noteCount
    self.lastChangedAt = lastChangedAt
  }
}

public struct BotMemoryPayload: Codable, Equatable, Sendable {
  public let botId: String
  public let markdown: String
  public let instructionCount: Int
  public let noteCount: Int
  public let changes: [BotMemoryChangeSet]
  public let origin: BotOrigin

  public init(botId: String, markdown: String, summary: BotMemorySummary, changes: [BotMemoryChangeSet], origin: BotOrigin) {
    self.botId = botId
    self.markdown = markdown
    instructionCount = summary.instructionCount
    noteCount = summary.noteCount
    self.changes = changes
    self.origin = origin
  }
}

public struct BotMemoryChangePayload: Codable, Equatable, Sendable {
  public let change: BotMemoryChangeSet
  public let origin: BotOrigin

  public init(change: BotMemoryChangeSet, origin: BotOrigin) {
    self.change = change
    self.origin = origin
  }
}

public struct UpdateBotMemoryInput: Codable, Equatable, Sendable {
  public let botId: String
  public let markdown: String
  public let reason: String?
  public let remote: String?

  package init(botId: String, markdown: String, reason: String?, remote: String?) {
    self.botId = botId
    self.markdown = markdown
    self.reason = reason
    self.remote = remote
  }
}

public struct UndoBotMemoryChangeInput: Codable, Equatable, Sendable {
  public let botId: String
  public let changeId: String?
  public let remote: String?

  package init(botId: String, changeId: String?, remote: String?) {
    self.botId = botId
    self.changeId = changeId
    self.remote = remote
  }
}

public struct CaptureBotFeedbackInput: Codable, Equatable, Sendable {
  public let botId: String
  public let sessionId: String?
  public let taskId: String?
  public let text: String?
  public let topic: String?
  public let fromFindings: Bool?
  public let remote: String?

  public init(
    botId: String, sessionId: String? = nil, taskId: String? = nil,
    text: String? = nil, topic: String? = nil, fromFindings: Bool? = nil, remote: String? = nil
  ) {
    self.botId = botId
    self.sessionId = sessionId
    self.taskId = taskId
    self.text = text
    self.topic = topic
    self.fromFindings = fromFindings
    self.remote = remote
  }
}

public struct BotMemoryHistoryPayload: Codable, Equatable, Sendable {
  public let changes: [BotMemoryChangeSet]
  public let origin: BotOrigin

  public init(changes: [BotMemoryChangeSet], origin: BotOrigin) {
    self.changes = changes
    self.origin = origin
  }
}

public struct BotMemoryDiffPayload: Codable, Equatable, Sendable {
  public let diffs: [BotMemoryEntryDiff]
  public let origin: BotOrigin

  public init(diffs: [BotMemoryEntryDiff], origin: BotOrigin) {
    self.diffs = diffs
    self.origin = origin
  }
}
