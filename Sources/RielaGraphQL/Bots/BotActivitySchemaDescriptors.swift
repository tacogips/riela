extension GraphQLSchemaGenerator {
  static let botActivityTypes: [TypeDescriptor] = [
    .init(kind: .object, name: "BotActivityEvent", fields: [
      .init(name: "sessionId", type: "String!"),
      .init(name: "seq", type: "Int!"),
      .init(name: "executionId", type: "String"),
      .init(name: "at", type: "String!"),
      .init(name: "kind", type: "String!"),
      .init(name: "payload", type: "JSONObject!")
    ]),
    .init(kind: .object, name: "BotActivityToolCall", fields: [
      .init(name: "toolCallId", type: "String!"),
      .init(name: "title", type: "String"),
      .init(name: "toolKind", type: "String"),
      .init(name: "status", type: "String"),
      .init(name: "locations", type: "[BotActivityLocation!]"),
      .init(name: "updatedAt", type: "String!")
    ]),
    .init(kind: .object, name: "BotActivityLocation", fields: [
      .init(name: "path", type: "String!"),
      .init(name: "line", type: "Int")
    ]),
    .init(kind: .object, name: "BotActivitySubagent", fields: [
      .init(name: "subSessionId", type: "String!"),
      .init(name: "title", type: "String"),
      .init(name: "state", type: "String")
    ]),
    .init(kind: .object, name: "BotActivityStop", fields: [
      .init(name: "stopReason", type: "String!"),
      .init(name: "limited", type: "Boolean!"),
      .init(name: "limitedResetAt", type: "String")
    ]),
    .init(kind: .object, name: "BotActivityState", fields: [
      .init(name: "source", type: "String!"),
      .init(name: "currentExecutionId", type: "String"),
      .init(name: "currentStepId", type: "String"),
      .init(name: "currentNodeId", type: "String"),
      .init(name: "backend", type: "String"),
      .init(name: "requestedModel", type: "String"),
      .init(name: "reportedModel", type: "String"),
      .init(name: "toolCalls", type: "[BotActivityToolCall!]!"),
      .init(name: "plans", type: "[BotActivityPlan!]!"),
      .init(name: "mode", type: "String"),
      .init(name: "commands", type: "[String!]!"),
      .init(name: "configOptions", type: "JSON!"),
      .init(name: "usage", type: "JSON"),
      .init(name: "subagents", type: "[BotActivitySubagent!]!"),
      .init(name: "pendingRequestIds", type: "[String!]!"),
      .init(name: "lastStop", type: "BotActivityStop"),
      .init(name: "lastMessageLine", type: "String"),
      .init(name: "lastEventAt", type: "String")
    ]),
    .init(kind: .object, name: "BotActivityPage", fields: [
      .init(name: "events", type: "[BotActivityEvent!]!"),
      .init(name: "state", type: "BotActivityState"),
      .init(name: "lastSequence", type: "Int!"),
      .init(name: "firstRetainedSequence", type: "Int!"),
      .init(name: "truncated", type: "Boolean!"),
      .init(name: "activitySource", type: "String!"),
      .init(name: "sessionStatus", type: "String!"),
      .init(name: "origin", type: "BotOrigin!")
    ]),
    .init(kind: .input, name: "AnswerBotRequestInput", fields: [
      .init(name: "requestId", type: "String!"),
      .init(name: "optionId", type: "String"),
      .init(name: "decline", type: "Boolean"),
      .init(name: "remote", type: "String")
    ]),
    .init(kind: .object, name: "BotRequestPayload", fields: [
      .init(name: "requestId", type: "String!"),
      .init(name: "status", type: "String!"),
      .init(name: "outcomeOptionId", type: "String"),
      .init(name: "resolvedBy", type: "String")
    ])
  ]
}
