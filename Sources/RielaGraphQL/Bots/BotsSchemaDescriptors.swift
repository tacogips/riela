extension GraphQLSchemaGenerator {
  static let botTypes: [TypeDescriptor] = [
    .init(kind: .object, name: "Bot", fields: [
      .init(name: "botId", type: "String!"),
      .init(name: "name", type: "String!"),
      .init(name: "purpose", type: "String"),
      .init(name: "personaId", type: "String"),
      .init(name: "defaultBackend", type: "String"),
      .init(name: "defaultModel", type: "String"),
      .init(name: "providerInstanceId", type: "String"),
      .init(name: "workspace", type: "String"),
      .init(name: "paused", type: "Boolean!"),
      .init(name: "memoryUpkeep", type: "String!"),
      .init(name: "lookAround", type: "String!"),
      .init(name: "permissionWaitMs", type: "Int!"),
      .init(name: "createdAt", type: "String!"),
      .init(name: "updatedAt", type: "String!")
    ]),
    .init(kind: .object, name: "BotCounts", fields: [
      .init(name: "needsYou", type: "Int!"),
      .init(name: "working", type: "Int!"),
      .init(name: "waiting", type: "Int!"),
      .init(name: "planned", type: "Int!")
    ]),
    .init(kind: .object, name: "BotOrigin", fields: [
      .init(name: "remote", type: "String!"),
      .init(name: "serverId", type: "String"),
      .init(name: "serverName", type: "String"),
      .init(name: "verified", type: "Boolean!"),
      .init(name: "connection", type: "String!"),
      .init(name: "observedAt", type: "String!")
    ]),
    .init(kind: .object, name: "BotListState", fields: [
      .init(name: "pinned", type: "Boolean!"),
      .init(name: "manualOrder", type: "Int"),
      .init(name: "snoozedUntil", type: "String"),
      .init(name: "snoozedAt", type: "String"),
      .init(name: "settledAt", type: "String"),
      .init(name: "settledBy", type: "String")
    ]),
    .init(kind: .object, name: "BotBoardItem", fields: [
      .init(name: "itemKind", type: "String!"),
      .init(name: "itemId", type: "String!"),
      .init(name: "group", type: "String!"),
      .init(name: "title", type: "String!"),
      .init(name: "workflowId", type: "String"),
      .init(name: "stepId", type: "String"),
      .init(name: "nodeId", type: "String"),
      .init(name: "backend", type: "String"),
      .init(name: "model", type: "String"),
      .init(name: "startedAt", type: "String"),
      .init(name: "elapsedMs", type: "Int"),
      .init(name: "lastActivityAt", type: "String"),
      .init(name: "status", type: "String!"),
      .init(name: "waitingReason", type: "String"),
      .init(name: "limitedResetAt", type: "String"),
      .init(name: "activitySource", type: "String!"),
      .init(name: "doingNow", type: "String"),
      .init(name: "checklist", type: "[BotActivityPlan!]!"),
      .init(name: "pendingRequests", type: "[BotPendingRequest!]!"),
      .init(name: "answerPath", type: "String"),
      .init(name: "question", type: "BotBoardQuestion"),
      .init(name: "lastResult", type: "String"),
      .init(name: "sessionId", type: "String"),
      .init(name: "bumpedAt", type: "String"),
      .init(name: "listState", type: "BotListState!"),
      .init(name: "origin", type: "BotOrigin!")
    ]),
    .init(kind: .object, name: "BotActivityPlan", fields: [
      .init(name: "planId", type: "String!"),
      .init(name: "entries", type: "[BotActivityPlanEntry!]!")
    ]),
    .init(kind: .object, name: "BotActivityPlanEntry", fields: [
      .init(name: "content", type: "String!"),
      .init(name: "status", type: "String!"),
      .init(name: "priority", type: "String!")
    ]),
    .init(kind: .object, name: "BotPendingRequest", fields: [
      .init(name: "requestId", type: "String!"),
      .init(name: "title", type: "String"),
      .init(name: "options", type: "[BotPermissionOption!]!"),
      .init(name: "createdAt", type: "String!"),
      .init(name: "expiresAt", type: "String!")
    ]),
    .init(kind: .object, name: "BotPermissionOption", fields: [
      .init(name: "optionId", type: "String!"),
      .init(name: "name", type: "String!"),
      .init(name: "kind", type: "String!")
    ]),
    .init(kind: .object, name: "BotBoardQuestion", fields: [
      .init(name: "questionId", type: "String!"),
      .init(name: "text", type: "String!"),
      .init(name: "optionIds", type: "[String!]!")
    ]),
    .init(kind: .object, name: "BotBoard", fields: [
      .init(name: "needsYou", type: "[BotBoardItem!]!"),
      .init(name: "inProgress", type: "[BotBoardItem!]!"),
      .init(name: "waiting", type: "[BotBoardItem!]!"),
      .init(name: "planned", type: "[BotBoardItem!]!"),
      .init(name: "closed", type: "[BotBoardItem!]!"),
      .init(name: "closedTotal", type: "Int!")
    ]),
    .init(kind: .object, name: "BotOverviewRow", fields: [
      .init(name: "bot", type: "Bot!"),
      .init(name: "counts", type: "BotCounts!"),
      .init(name: "inProgress", type: "[BotBoardItem!]!"),
      .init(name: "lastActivityAt", type: "String"),
      .init(name: "lastResult", type: "String"),
      .init(name: "listState", type: "BotListState!"),
      .init(name: "section", type: "String!"),
      .init(name: "workspaceGroup", type: "String!"),
      .init(name: "origin", type: "BotOrigin!")
    ]),
    .init(kind: .object, name: "BotWorkspaceGroup", fields: [
      .init(name: "key", type: "String!"),
      .init(name: "needsYou", type: "Boolean!"),
      .init(name: "botIds", type: "[String!]!")
    ]),
    .init(kind: .object, name: "BotRoutine", fields: [
      .init(name: "routineId", type: "String!"),
      .init(name: "name", type: "String!"),
      .init(name: "workflowName", type: "String!"),
      .init(name: "status", type: "String!"),
      .init(name: "nextRunAt", type: "String")
    ]),
    .init(kind: .object, name: "BotListPayload", fields: [
      .init(name: "bots", type: "[BotOverviewRow!]!"),
      .init(name: "groups", type: "[BotWorkspaceGroup!]!")
    ]),
    .init(kind: .object, name: "BotDetailPayload", fields: [
      .init(name: "bot", type: "Bot!"),
      .init(name: "board", type: "BotBoard!"),
      .init(name: "routines", type: "[BotRoutine!]!"),
      .init(name: "origin", type: "BotOrigin!"),
      .init(name: "suggestions", type: "[JSON!]!"),
      .init(name: "memory", type: "JSON")
    ]),
    .init(kind: .object, name: "BotMutationPayload", fields: [
      .init(name: "bot", type: "Bot!"),
      .init(name: "warnings", type: "[String!]!")
    ]),
    .init(kind: .input, name: "BotFilter", fields: [
      .init(name: "groupBy", type: "String"),
      .init(name: "remote", type: "String")
    ]),
    .init(kind: .input, name: "CreateBotInput", fields: [
      .init(name: "id", type: "String"),
      .init(name: "name", type: "String!"),
      .init(name: "purpose", type: "String"),
      .init(name: "personaId", type: "String"),
      .init(name: "defaultBackend", type: "String"),
      .init(name: "defaultModel", type: "String"),
      .init(name: "providerInstanceId", type: "String"),
      .init(name: "workspace", type: "String"),
      .init(name: "memoryUpkeep", type: "String"),
      .init(name: "lookAround", type: "String"),
      .init(name: "permissionWaitMs", type: "Int"),
      .init(name: "remote", type: "String")
    ]),
    .init(kind: .input, name: "UpdateBotInput", fields: [
      .init(name: "botId", type: "String!"),
      .init(name: "name", type: "String"),
      .init(name: "purpose", type: "String"),
      .init(name: "personaId", type: "String"),
      .init(name: "defaultBackend", type: "String"),
      .init(name: "defaultModel", type: "String"),
      .init(name: "providerInstanceId", type: "String"),
      .init(name: "workspace", type: "String"),
      .init(name: "memoryUpkeep", type: "String"),
      .init(name: "lookAround", type: "String"),
      .init(name: "permissionWaitMs", type: "Int"),
      .init(name: "remote", type: "String")
    ]),
    .init(kind: .input, name: "SetBotPausedInput", fields: [
      .init(name: "botId", type: "String!"),
      .init(name: "paused", type: "Boolean!"),
      .init(name: "remote", type: "String")
    ]),
    .init(kind: .input, name: "RemoveBotInput", fields: [
      .init(name: "botId", type: "String!"),
      .init(name: "remote", type: "String")
    ]),
    .init(kind: .input, name: "SetBotListStateInput", fields: [
      .init(name: "botId", type: "String!"),
      .init(name: "itemKind", type: "String"),
      .init(name: "itemId", type: "String"),
      .init(name: "pinned", type: "Boolean"),
      .init(name: "manualOrder", type: "Int"),
      .init(name: "snoozedUntil", type: "String"),
      .init(name: "clearSnooze", type: "Boolean"),
      .init(name: "settled", type: "Boolean"),
      .init(name: "remote", type: "String")
    ])
  ] + botActivityTypes
}
