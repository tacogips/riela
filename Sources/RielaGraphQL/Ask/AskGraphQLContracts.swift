import RielaCore

public struct StartAskInput: Codable, Equatable, Sendable {
  public let message: String
  public let context: AskContext?
  public let selection: AskSelection?
  public let draftDefinition: JSONObject?
  public let remote: String?

  public init(
    message: String, context: AskContext? = nil, selection: AskSelection? = nil,
    draftDefinition: JSONObject? = nil, remote: String? = nil
  ) {
    self.message = message
    self.context = context
    self.selection = selection
    self.draftDefinition = draftDefinition
    self.remote = remote
  }
}

public struct SendAskMessageInput: Codable, Equatable, Sendable {
  public let conversationId: String
  public let message: String
  public let context: AskContext?
  public let draftDefinition: JSONObject?
  public let remote: String?

  public init(
    conversationId: String, message: String, context: AskContext? = nil, draftDefinition: JSONObject? = nil,
    remote: String? = nil
  ) {
    self.conversationId = conversationId
    self.message = message
    self.context = context
    self.draftDefinition = draftDefinition
    self.remote = remote
  }
}

public struct AskConversationInput: Codable, Equatable, Sendable {
  public let conversationId: String
  public let remote: String?

  public init(conversationId: String, remote: String? = nil) {
    self.conversationId = conversationId
    self.remote = remote
  }
}

public struct AskActionInput: Codable, Equatable, Sendable {
  public let conversationId: String
  public let actionId: String
  public let remote: String?

  public init(conversationId: String, actionId: String, remote: String? = nil) {
    self.conversationId = conversationId
    self.actionId = actionId
    self.remote = remote
  }
}

public struct AskConversationPayload: Codable, Equatable, Sendable {
  public let conversation: AskConversation
  public let messages: [AskMessage]
  public let actions: [AskAction]
  public let limits: AskLimits
  public let warnings: [String]
  public let origin: BotOrigin

  public init(
    conversation: AskConversation, messages: [AskMessage], actions: [AskAction], limits: AskLimits,
    warnings: [String], origin: BotOrigin
  ) {
    self.conversation = conversation
    self.messages = messages
    self.actions = actions
    self.limits = limits
    self.warnings = warnings
    self.origin = origin
  }
}

public struct AskConversationListPayload: Codable, Equatable, Sendable {
  public let conversations: [AskConversation]
  public let origin: BotOrigin

  public init(conversations: [AskConversation], origin: BotOrigin) {
    self.conversations = conversations
    self.origin = origin
  }
}

public struct AskActivityPage: Codable, Equatable, Sendable {
  public let events: [ActivityEvent]
  public let state: ActivityState?
  public let lastSequence: Int
  public let firstRetainedSequence: Int
  public let truncated: Bool
  public let activitySource: String
  public let turnStatus: String
  public let origin: BotOrigin

  public init(
    events: [ActivityEvent], state: ActivityState?, lastSequence: Int, firstRetainedSequence: Int,
    truncated: Bool, activitySource: String, turnStatus: String, origin: BotOrigin
  ) {
    self.events = events
    self.state = state
    self.lastSequence = lastSequence
    self.firstRetainedSequence = firstRetainedSequence
    self.truncated = truncated
    self.activitySource = activitySource
    self.turnStatus = turnStatus
    self.origin = origin
  }
}
