public enum AskActionKind: String, Codable, Equatable, Sendable {
  case stopSession, rerunSession, answerBotRequest, setBotPaused
}

public enum AskActionStatus: String, Codable, Equatable, Sendable {
  case proposed, confirming, confirmed, failed, dismissed
}

public enum AskActionDecision: String, Codable, Equatable, Sendable {
  case confirm, dismiss
}

public struct AskAction: Codable, Equatable, Sendable {
  public internal(set) var actionId: String
  public let conversationId: String
  public let turnId: String
  public let kind: AskActionKind
  public let target: JSONObject
  public let reason: String
  public internal(set) var status: AskActionStatus
  public let createdAt: String
  public let expiresAt: String
  public internal(set) var decidedAt: String?
  public internal(set) var decision: AskActionDecision?
  public internal(set) var decidedBy: String?
  public internal(set) var result: AskActionResult?

  public init(
    actionId: String = "",
    conversationId: String,
    turnId: String,
    kind: AskActionKind,
    target: JSONObject,
    reason: String,
    status: AskActionStatus = .proposed,
    createdAt: String,
    expiresAt: String,
    decidedAt: String? = nil,
    decision: AskActionDecision? = nil,
    decidedBy: String? = nil,
    result: AskActionResult? = nil
  ) {
    self.actionId = actionId
    self.conversationId = conversationId
    self.turnId = turnId
    self.kind = kind
    self.target = target
    self.reason = reason
    self.status = status
    self.createdAt = createdAt
    self.expiresAt = expiresAt
    self.decidedAt = decidedAt
    self.decision = decision
    self.decidedBy = decidedBy
    self.result = result
  }
}

public struct AskActionResult: Codable, Equatable, Sendable {
  public var ok: Bool
  public var summary: String?
  public var ids: [String]
  public var code: String?
  public var message: String?

  public init(
    ok: Bool,
    summary: String? = nil,
    ids: [String] = [],
    code: String? = nil,
    message: String? = nil
  ) {
    self.ok = ok
    self.summary = summary
    self.ids = ids
    self.code = code
    self.message = message
  }
}
