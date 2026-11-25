extension GraphQLSchemaGenerator {
  static let askRootFields: [String: FieldDescriptor] = [
    "Query.askConversations": .init(
      name: "askConversations", arguments: "remote: String",
      type: "AskConversationListPayload!"
    ),
    "Query.askConversation": .init(
      name: "askConversation", arguments: "conversationId: String!, remote: String",
      type: "AskConversationPayload!"
    ),
    "Query.askActivity": .init(
      name: "askActivity", arguments: "conversationId: String!, afterSequence: Int = 0, limit: Int = 200, waitMs: Int = 0, remote: String",
      type: "AskActivityPage!"
    ),
    "Mutation.startAsk": .init(
      name: "startAsk", arguments: "input: StartAskInput!",
      type: "AskConversationPayload!"
    ),
    "Mutation.sendAskMessage": .init(
      name: "sendAskMessage", arguments: "input: SendAskMessageInput!",
      type: "AskConversationPayload!"
    ),
    "Mutation.cancelAsk": .init(
      name: "cancelAsk", arguments: "input: AskConversationInput!",
      type: "AskConversationPayload!"
    ),
    "Mutation.confirmAskAction": .init(
      name: "confirmAskAction", arguments: "input: AskActionInput!",
      type: "AskConversationPayload!"
    ),
    "Mutation.dismissAskAction": .init(
      name: "dismissAskAction", arguments: "input: AskActionInput!",
      type: "AskConversationPayload!"
    ),
    "Mutation.removeAskConversation": .init(
      name: "removeAskConversation", arguments: "input: AskConversationInput!",
      type: "AskConversationListPayload!"
    )
  ]

  static let askTypes: [TypeDescriptor] = [
    .init(kind: .input, name: "StartAskInput", fields: [
      .init(name: "message", type: "String!"),
      .init(name: "context", type: "AskContextInput"),
      .init(name: "selection", type: "AskSelectionInput"),
      .init(name: "draftDefinition", type: "JSON"),
      .init(name: "remote", type: "String")
    ]),
    .init(kind: .input, name: "SendAskMessageInput", fields: [
      .init(name: "conversationId", type: "String!"),
      .init(name: "message", type: "String!"),
      .init(name: "context", type: "AskContextInput"),
      .init(name: "draftDefinition", type: "JSON"),
      .init(name: "remote", type: "String")
    ]),
    .init(kind: .input, name: "AskActionInput", fields: [
      .init(name: "conversationId", type: "String!"),
      .init(name: "actionId", type: "String!"),
      .init(name: "remote", type: "String")
    ]),
    .init(kind: .input, name: "AskConversationInput", fields: [
      .init(name: "conversationId", type: "String!"),
      .init(name: "remote", type: "String")
    ]),
    .init(kind: .input, name: "AskContextInput", fields: [
      .init(name: "kind", type: "String!"),
      .init(name: "id", type: "String")
    ]),
    .init(kind: .input, name: "AskSelectionInput", fields: [
      .init(name: "vendor", type: "String"),
      .init(name: "providerInstanceId", type: "String"),
      .init(name: "model", type: "String"),
      .init(name: "effort", type: "String")
    ]),
    .init(kind: .object, name: "AskContext", fields: [
      .init(name: "kind", type: "String!"),
      .init(name: "id", type: "String")
    ]),
    .init(kind: .object, name: "AskSelection", fields: [
      .init(name: "vendor", type: "String"),
      .init(name: "providerInstanceId", type: "String"),
      .init(name: "model", type: "String"),
      .init(name: "effort", type: "String")
    ]),
    .init(kind: .object, name: "AskConversation", fields: [
      .init(name: "conversationId", type: "String!"),
      .init(name: "title", type: "String!"),
      .init(name: "context", type: "AskContext!"),
      .init(name: "selection", type: "AskSelection!"),
      .init(name: "turn", type: "AskTurn"),
      .init(name: "usage", type: "AskUsage!"),
      .init(name: "createdAt", type: "String!"),
      .init(name: "updatedAt", type: "String!")
    ]),
    .init(kind: .object, name: "AskTurn", fields: [
      .init(name: "turnId", type: "String!"),
      .init(name: "status", type: "String!"),
      .init(name: "startedAt", type: "String!"),
      .init(name: "finishedAt", type: "String"),
      .init(name: "backend", type: "String!"),
      .init(name: "providerInstanceId", type: "String!"),
      .init(name: "model", type: "String"),
      .init(name: "toolTransport", type: "String!"),
      .init(name: "limitedPolicy", type: "Boolean!"),
      .init(name: "error", type: "AskTurnError"),
      .init(name: "runnerId", type: "String!"),
      .init(name: "heartbeatAt", type: "String!"),
      .init(name: "toolCalls", type: "Int!"),
      .init(name: "toolBytes", type: "Int!")
    ]),
    .init(kind: .object, name: "AskTurnError", fields: [
      .init(name: "code", type: "String!"),
      .init(name: "message", type: "String!")
    ]),
    .init(kind: .object, name: "AskUsage", fields: [
      .init(name: "turns", type: "Int!"),
      .init(name: "toolCalls", type: "Int!"),
      .init(name: "toolBytes", type: "Int!")
    ]),
    .init(kind: .object, name: "AskMessage", fields: [
      .init(name: "seq", type: "Int!"),
      .init(name: "role", type: "String!"),
      .init(name: "text", type: "String!"),
      .init(name: "turnId", type: "String!"),
      .init(name: "citations", type: "[AskRef!]!"),
      .init(name: "truncated", type: "Boolean!"),
      .init(name: "createdAt", type: "String!")
    ]),
    .init(kind: .object, name: "AskRef", fields: [
      .init(name: "kind", type: "String!"),
      .init(name: "id", type: "String!"),
      .init(name: "sessionId", type: "String")
    ]),
    .init(kind: .object, name: "AskAction", fields: [
      .init(name: "actionId", type: "String!"),
      .init(name: "conversationId", type: "String!"),
      .init(name: "turnId", type: "String!"),
      .init(name: "kind", type: "String!"),
      .init(name: "target", type: "JSON!"),
      .init(name: "reason", type: "String!"),
      .init(name: "status", type: "String!"),
      .init(name: "createdAt", type: "String!"),
      .init(name: "expiresAt", type: "String!"),
      .init(name: "decidedAt", type: "String"),
      .init(name: "decision", type: "String"),
      .init(name: "decidedBy", type: "String"),
      .init(name: "result", type: "AskActionResult")
    ]),
    .init(kind: .object, name: "AskActionResult", fields: [
      .init(name: "ok", type: "Boolean!"),
      .init(name: "summary", type: "String"),
      .init(name: "ids", type: "[String!]!"),
      .init(name: "code", type: "String"),
      .init(name: "message", type: "String")
    ]),
    .init(kind: .object, name: "AskLimits", fields: [
      .init(name: "userMessageBytes", type: "Int!"),
      .init(name: "assistantMessageBytes", type: "Int!"),
      .init(name: "messagesPerConversation", type: "Int!"),
      .init(name: "conversationsPerStore", type: "Int!"),
      .init(name: "historyMessages", type: "Int!"),
      .init(name: "historyMessageCharacters", type: "Int!"),
      .init(name: "turnsPerConversation", type: "Int!"),
      .init(name: "toolCallsPerTurn", type: "Int!"),
      .init(name: "toolCallsPerConversation", type: "Int!"),
      .init(name: "toolResultBytes", type: "Int!"),
      .init(name: "toolBytesPerTurn", type: "Int!"),
      .init(name: "toolBytesPerConversation", type: "Int!"),
      .init(name: "roundsPerTurn", type: "Int!"),
      .init(name: "turnDeadlineSeconds", type: "Int!"),
      .init(name: "draftDefinitionBytes", type: "Int!"),
      .init(name: "actionsPerTurn", type: "Int!"),
      .init(name: "actionLifetimeSeconds", type: "Int!"),
      .init(name: "contextSummaryBytes", type: "Int!")
    ]),
    .init(kind: .object, name: "AskConversationPayload", fields: [
      .init(name: "conversation", type: "AskConversation!"),
      .init(name: "messages", type: "[AskMessage!]!"),
      .init(name: "actions", type: "[AskAction!]!"),
      .init(name: "limits", type: "AskLimits!"),
      .init(name: "warnings", type: "[String!]!"),
      .init(name: "origin", type: "BotOrigin!")
    ]),
    .init(kind: .object, name: "AskConversationListPayload", fields: [
      .init(name: "conversations", type: "[AskConversation!]!"),
      .init(name: "origin", type: "BotOrigin!")
    ]),
    .init(kind: .object, name: "AskActivityPage", fields: [
      .init(name: "events", type: "[BotActivityEvent!]!"),
      .init(name: "state", type: "BotActivityState"),
      .init(name: "lastSequence", type: "Int!"),
      .init(name: "firstRetainedSequence", type: "Int!"),
      .init(name: "truncated", type: "Boolean!"),
      .init(name: "activitySource", type: "String!"),
      .init(name: "turnStatus", type: "String!"),
      .init(name: "origin", type: "BotOrigin!")
    ])
  ]
}
