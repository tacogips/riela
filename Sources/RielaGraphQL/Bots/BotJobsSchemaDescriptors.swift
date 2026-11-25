extension GraphQLSchemaGenerator {
  static let botJobsRootFields: [String: FieldDescriptor] = [
    "Query.botJobHistory": .init(
      name: "botJobHistory", arguments: "botId: String!, job: String, limit: Int, remote: String", type: "BotJobHistoryPayload!"
    ),
    "Query.botSuggestions": .init(
      name: "botSuggestions", arguments: "botId: String!, status: String, remote: String", type: "BotSuggestionListPayload!"
    ),
    "Mutation.decideBotSuggestion": .init(
      name: "decideBotSuggestion", arguments: "input: DecideBotSuggestionInput!", type: "BotSuggestionPayload!"
    ),
    "Mutation.runBotJob": .init(name: "runBotJob", arguments: "input: RunBotJobInput!", type: "BotJobPayload!")
  ]

  static let botJobsTypes: [TypeDescriptor] = [
    .init(kind: .object, name: "BotSuggestion", fields: [
      .init(name: "suggestionId", type: "String!"),
      .init(name: "botId", type: "String!"),
      .init(name: "title", type: "String!"),
      .init(name: "detail", type: "String"),
      .init(name: "action", type: "BotSuggestionAction"),
      .init(name: "status", type: "String!"),
      .init(name: "createdAt", type: "String!"),
      .init(name: "sourceSessionId", type: "String"),
      .init(name: "acceptedAt", type: "String"),
      .init(name: "acceptedBy", type: "String"),
      .init(name: "dismissedAt", type: "String"),
      .init(name: "dismissedBy", type: "String"),
      .init(name: "dismissReason", type: "String"),
      .init(name: "startedSessionId", type: "String"),
      .init(name: "origin", type: "BotOrigin")
    ]),
    .init(kind: .object, name: "BotSuggestionAction", fields: [
      .init(name: "workflowName", type: "String!"),
      .init(name: "input", type: "JSON!")
    ]),
    .init(kind: .object, name: "BotSuggestionListPayload", fields: [
      .init(name: "botId", type: "String!"),
      .init(name: "suggestions", type: "[BotSuggestion!]!"),
      .init(name: "origin", type: "BotOrigin!")
    ]),
    .init(kind: .object, name: "BotSuggestionPayload", fields: [
      .init(name: "suggestion", type: "BotSuggestion!"),
      .init(name: "origin", type: "BotOrigin!")
    ]),
    .init(kind: .object, name: "BotJobSummary", fields: [
      .init(name: "job", type: "String!"),
      .init(name: "schedule", type: "String!"),
      .init(name: "lastRun", type: "BotJobRun")
    ]),
    .init(kind: .object, name: "BotJobHistoryPayload", fields: [
      .init(name: "runs", type: "[BotJobRun!]!"),
      .init(name: "origin", type: "BotOrigin!")
    ]),
    .init(kind: .object, name: "BotJobRun", fields: [
      .init(name: "botId", type: "String!"),
      .init(name: "job", type: "String!"),
      .init(name: "periodKey", type: "String!"),
      .init(name: "status", type: "String!"),
      .init(name: "sessionId", type: "String"),
      .init(name: "detail", type: "String"),
      .init(name: "startedAt", type: "String!"),
      .init(name: "finishedAt", type: "String")
    ]),
    .init(kind: .object, name: "BotJobPayload", fields: [
      .init(name: "botId", type: "String!"),
      .init(name: "job", type: "String!"),
      .init(name: "periodKey", type: "String"),
      .init(name: "status", type: "String!"),
      .init(name: "sessionId", type: "String"),
      .init(name: "detail", type: "String"),
      .init(name: "origin", type: "BotOrigin!"),
      .init(name: "changeSet", type: "BotMemoryChange"),
      .init(name: "suggestions", type: "[BotSuggestion!]")
    ]),
    .init(kind: .input, name: "DecideBotSuggestionInput", fields: [
      .init(name: "suggestionId", type: "String!"),
      .init(name: "decision", type: "String!"),
      .init(name: "run", type: "Boolean"),
      .init(name: "reason", type: "String"),
      .init(name: "remote", type: "String")
    ]),
    .init(kind: .input, name: "RunBotJobInput", fields: [
      .init(name: "botId", type: "String!"),
      .init(name: "job", type: "String!"),
      .init(name: "force", type: "Boolean"),
      .init(name: "remote", type: "String")
    ])
  ]
}
