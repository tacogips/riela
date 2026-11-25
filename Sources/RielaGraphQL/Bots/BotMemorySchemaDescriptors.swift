extension GraphQLSchemaGenerator {
  static let botMemoryRootFields: [String: FieldDescriptor] = [
    "Query.bot": .init(name: "bot", arguments: "botId: String!, remote: String", type: "BotDetailPayload!"),
    "Query.botMemory": .init(name: "botMemory", arguments: "botId: String!, remote: String", type: "BotMemoryPayload!"),
    "Query.botMemoryHistory": .init(
      name: "botMemoryHistory", arguments: "botId: String!, limit: Int, remote: String", type: "BotMemoryHistoryPayload!"
    ),
    "Query.botMemoryDiff": .init(
      name: "botMemoryDiff", arguments: "botId: String!, changeId: String!, remote: String", type: "BotMemoryDiffPayload!"
    ),
    "Mutation.updateBotMemory": .init(
      name: "updateBotMemory", arguments: "input: UpdateBotMemoryInput!", type: "BotMemoryChangePayload!"
    ),
    "Mutation.undoBotMemoryChange": .init(
      name: "undoBotMemoryChange", arguments: "input: UndoBotMemoryChangeInput!", type: "BotMemoryChangePayload!"
    ),
    "Mutation.captureBotFeedback": .init(
      name: "captureBotFeedback", arguments: "input: CaptureBotFeedbackInput!", type: "BotMemoryChangePayload!"
    )
  ]

  static let botMemoryTypes: [TypeDescriptor] = [
    .init(kind: .object, name: "BotMemorySummary", fields: [
      .init(name: "instructionCount", type: "Int!"),
      .init(name: "noteCount", type: "Int!"),
      .init(name: "lastChangedAt", type: "String")
    ]),
    .init(kind: .object, name: "BotMemoryPayload", fields: [
      .init(name: "botId", type: "String!"),
      .init(name: "markdown", type: "String!"),
      .init(name: "instructionCount", type: "Int!"),
      .init(name: "noteCount", type: "Int!"),
      .init(name: "changes", type: "[BotMemoryChange!]!"),
      .init(name: "origin", type: "BotOrigin!")
    ]),
    .init(kind: .object, name: "BotMemoryHistoryPayload", fields: [
      .init(name: "changes", type: "[BotMemoryChange!]!"),
      .init(name: "origin", type: "BotOrigin!")
    ]),
    .init(kind: .object, name: "BotMemoryDiffPayload", fields: [
      .init(name: "diffs", type: "[BotMemoryEntryDiff!]!"),
      .init(name: "origin", type: "BotOrigin!")
    ]),
    .init(kind: .object, name: "BotMemoryEntryDiff", fields: [
      .init(name: "entry", type: "BotMemoryChangeEntry!"),
      .init(name: "changes", type: "[BotMemoryDiffField!]!")
    ]),
    .init(kind: .object, name: "BotMemoryDiffField", fields: [
      .init(name: "path", type: "String!"),
      .init(name: "op", type: "String!"),
      .init(name: "beforeJSON", type: "String"),
      .init(name: "afterJSON", type: "String"),
      .init(name: "encoding", type: "String"),
      .init(name: "beforeSHA256", type: "String"),
      .init(name: "afterSHA256", type: "String"),
      .init(name: "beforeByteCount", type: "Int"),
      .init(name: "afterByteCount", type: "Int"),
      .init(name: "prefixByteCount", type: "Int"),
      .init(name: "suffixByteCount", type: "Int")
    ]),
    .init(kind: .object, name: "BotMemoryChangePayload", fields: [
      .init(name: "change", type: "BotMemoryChange!"),
      .init(name: "origin", type: "BotOrigin!")
    ]),
    .init(kind: .object, name: "BotMemoryChange", fields: [
      .init(name: "changeId", type: "String!"),
      .init(name: "botId", type: "String!"),
      .init(name: "actor", type: "String!"),
      .init(name: "reason", type: "String!"),
      .init(name: "evidenceRefs", type: "[String!]!"),
      .init(name: "createdAt", type: "String!"),
      .init(name: "entries", type: "[BotMemoryChangeEntry!]!"),
      .init(name: "redacted", type: "Boolean!"),
      .init(name: "downgraded", type: "Boolean!"),
      .init(name: "ignoredInstructionChanges", type: "Int!")
    ]),
    .init(kind: .object, name: "BotMemoryChangeEntry", fields: [
      .init(name: "recordId", type: "Int!"),
      .init(name: "op", type: "String!"),
      .init(name: "fromVersion", type: "Int"),
      .init(name: "toVersion", type: "Int!")
    ]),
    .init(kind: .input, name: "UpdateBotMemoryInput", fields: [
      .init(name: "botId", type: "String!"),
      .init(name: "markdown", type: "String!"),
      .init(name: "reason", type: "String"),
      .init(name: "remote", type: "String")
    ]),
    .init(kind: .input, name: "UndoBotMemoryChangeInput", fields: [
      .init(name: "botId", type: "String!"),
      .init(name: "changeId", type: "String"),
      .init(name: "remote", type: "String")
    ]),
    .init(kind: .input, name: "CaptureBotFeedbackInput", fields: [
      .init(name: "botId", type: "String!"),
      .init(name: "sessionId", type: "String"),
      .init(name: "taskId", type: "String"),
      .init(name: "text", type: "String"),
      .init(name: "topic", type: "String"),
      .init(name: "fromFindings", type: "Boolean"),
      .init(name: "remote", type: "String")
    ])
  ]
}
