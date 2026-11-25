import RielaCore

public struct BotActivityPage: Codable, Equatable, Sendable {
  public static let defaultLimit = 200
  public static let maximumLimit = 500
  public static let maximumWaitMs = 25_000

  public let events: [ActivityEvent]
  public let state: ActivityState?
  public let lastSequence: Int
  public let firstRetainedSequence: Int
  public let truncated: Bool
  public let activitySource: String
  public let sessionStatus: String
  public let origin: BotOrigin

  public init(
    events: [ActivityEvent], state: ActivityState?, lastSequence: Int, firstRetainedSequence: Int,
    truncated: Bool, activitySource: String, sessionStatus: String, origin: BotOrigin
  ) {
    self.events = events
    self.state = state
    self.lastSequence = lastSequence
    self.firstRetainedSequence = firstRetainedSequence
    self.truncated = truncated
    self.activitySource = activitySource
    self.sessionStatus = sessionStatus
    self.origin = origin
  }
}

public struct AnswerBotRequestInput: Codable, Equatable, Sendable {
  public let requestId: String
  public let optionId: String?
  public let decline: Bool?
  public let remote: String?

  public init(requestId: String, optionId: String? = nil, decline: Bool? = nil, remote: String? = nil) {
    self.requestId = requestId
    self.optionId = optionId
    self.decline = decline
    self.remote = remote
  }
}

public struct BotRequestPayload: Codable, Equatable, Sendable {
  public let requestId: String
  public let status: ActivityRequestRecord.Status
  public let outcomeOptionId: String?
  public let resolvedBy: ActivityRequestRecord.Resolution?
  public let origin: BotOrigin

  public init(
    requestId: String, status: ActivityRequestRecord.Status, outcomeOptionId: String?,
    resolvedBy: ActivityRequestRecord.Resolution?, origin: BotOrigin
  ) {
    self.requestId = requestId
    self.status = status
    self.outcomeOptionId = outcomeOptionId
    self.resolvedBy = resolvedBy
    self.origin = origin
  }

  public init(_ request: ActivityRequestRecord, origin: BotOrigin) {
    self.init(
      requestId: request.requestId, status: request.status,
      outcomeOptionId: request.outcomeOptionId, resolvedBy: request.resolvedBy, origin: origin
    )
  }
}
