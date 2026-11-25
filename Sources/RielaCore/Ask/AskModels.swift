public enum AskContextKind: String, Codable, Equatable, Sendable {
  case none, session, bot, workflow
}

public struct AskContext: Codable, Equatable, Sendable {
  public var kind: AskContextKind
  public var id: String?

  public init(
    kind: AskContextKind = .none,
    id: String? = nil
  ) {
    self.kind = kind
    self.id = id
  }
}

public struct AskSelection: Codable, Equatable, Sendable {
  public var vendor: String?
  public var providerInstanceId: String?
  public var model: String?
  public var effort: String?

  public init(
    vendor: String? = nil,
    providerInstanceId: String? = nil,
    model: String? = nil,
    effort: String? = nil
  ) {
    self.vendor = vendor
    self.providerInstanceId = providerInstanceId
    self.model = model
    self.effort = effort
  }
}

public enum AskToolTransport: String, Codable, Equatable, Sendable {
  case mcp, rounds
}

public enum AskTurnStatus: String, Codable, Equatable, Sendable {
  case running, completed, failed, cancelled
}

public struct AskTurn: Codable, Equatable, Sendable {
  public var turnId: String
  public var status: AskTurnStatus
  public var startedAt: String
  public var finishedAt: String?
  public var backend: String
  public var providerInstanceId: String
  public var model: String?
  public var toolTransport: AskToolTransport
  public var limitedPolicy: Bool
  public var error: AskTurnError?
  public var runnerId: String
  public var heartbeatAt: String
  public internal(set) var toolCalls: Int = 0
  public internal(set) var toolBytes: Int = 0
  public internal(set) var draftDefinition: JSONObject?

  public init(
    turnId: String = "",
    status: AskTurnStatus = .running,
    startedAt: String = "",
    finishedAt: String? = nil,
    backend: String,
    providerInstanceId: String,
    model: String? = nil,
    toolTransport: AskToolTransport,
    limitedPolicy: Bool = false,
    error: AskTurnError? = nil,
    runnerId: String,
    heartbeatAt: String = "",
    draftDefinition: JSONObject? = nil
  ) {
    self.turnId = turnId
    self.status = status
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.backend = backend
    self.providerInstanceId = providerInstanceId
    self.model = model
    self.toolTransport = toolTransport
    self.limitedPolicy = limitedPolicy
    self.error = error
    self.runnerId = runnerId
    self.heartbeatAt = heartbeatAt
    self.draftDefinition = draftDefinition
  }
}

public struct AskTurnError: Codable, Equatable, Sendable {
  public var code: String
  public var message: String

  public init(
    code: String,
    message: String
  ) {
    self.code = code
    self.message = message
  }
}

public struct AskUsage: Codable, Equatable, Sendable {
  public internal(set) var turns: Int
  public internal(set) var toolCalls: Int
  public internal(set) var toolBytes: Int

  public init(
    turns: Int = 0,
    toolCalls: Int = 0,
    toolBytes: Int = 0
  ) {
    self.turns = turns
    self.toolCalls = toolCalls
    self.toolBytes = toolBytes
  }
}

public struct AskConversation: Codable, Equatable, Sendable {
  public func withoutDraft() -> AskConversation {
    var record = self
    record.turn?.draftDefinition = nil
    return record
  }

  public let conversationId: String
  public let title: String
  public internal(set) var context: AskContext
  public internal(set) var selection: AskSelection
  public internal(set) var knownRefs: [AskRef]?
  public internal(set) var turn: AskTurn?
  public internal(set) var usage = AskUsage()
  public let createdAt: String
  public internal(set) var updatedAt: String
}

public enum AskRefKind: String, Codable, Equatable, Sendable {
  case session, step, bot, workflow, routine
}

public struct AskRef: Codable, Hashable, Sendable {
  public var kind: AskRefKind
  public var id: String
  public var sessionId: String?

  public init(
    kind: AskRefKind,
    id: String,
    sessionId: String? = nil
  ) {
    self.kind = kind
    self.id = id
    self.sessionId = sessionId
  }
}

public enum AskMessageRole: String, Codable, Equatable, Sendable {
  case user, assistant
}

public struct AskMessage: Codable, Equatable, Sendable {
  public let seq: Int
  public let role: AskMessageRole
  public let text: String
  public let turnId: String
  public let citations: [AskRef]
  public let truncated: Bool
  public let createdAt: String
}

public struct AskError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
  public var code: String
  public var message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }

  public var description: String { "\(code): \(message)" }
}

public enum AskActivityKey {
  public static func sessionId(_ conversationId: String) -> String { "ask:\(conversationId)" }
}
