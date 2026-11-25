import RielaCore
import RielaGraphQL
import RielaWorkflowRegistry

struct ProviderAskReadSurface: AskReadSurface {
  let providers: AskReadProviders

  func opsOverview(_ arguments: JSONObject) async throws -> AskReadResult {
    let payload = try await providers.console.opsOverview()
    let workflows = payload.workflows.map { AskRef(kind: .workflow, id: $0.workflowId) }
    let sessions = payload.runs.map { AskRef(kind: .session, id: $0.sessionId) }
    return (try BotSurfaceJSON.value(payload), workflows + sessions)
  }

  func botList(_ arguments: JSONObject) async throws -> AskReadResult {
    let payload = try await providers.bots.bots(filter: .init(remote: "local"))
    let bots = payload.bots.map { AskRef(kind: .bot, id: $0.bot.botId) }
    let sessions = payload.bots.flatMap(\.inProgress).compactMap(\.sessionId)
    return (try BotSurfaceJSON.value(payload), bots + sessions.map { AskRef(kind: .session, id: $0) })
  }

  func botBoard(_ arguments: JSONObject) async throws -> AskReadResult {
    let payload = try await bot(id: arguments.askRequiredString("botId"))
    let board = payload.board
    let items = board.needsYou + board.inProgress + board.waiting + board.planned + board.closed
    let sessions = items.compactMap(\.sessionId).map { AskRef(kind: .session, id: $0) }
    let workflows = items.compactMap(\.workflowId).map { AskRef(kind: .workflow, id: $0) }
    let routines = payload.routines.map { AskRef(kind: .routine, id: $0.routineId) }
    let data: JSONObject = [
      "bot": try BotSurfaceJSON.value(payload.bot), "board": try BotSurfaceJSON.value(board),
      "routines": try BotSurfaceJSON.value(payload.routines), "origin": try BotSurfaceJSON.value(payload.origin),
      "suggestions": .object([
        "open": .integer(Int64(payload.suggestions.filter { $0.status == .open }.count)),
        "accepted": .integer(Int64(payload.suggestions.filter { $0.status == .accepted }.count))
      ])
    ]
    return (.object(data), [AskRef(kind: .bot, id: payload.bot.botId)] + sessions + workflows + routines)
  }

  func botActivity(_ arguments: JSONObject) async throws -> AskReadResult {
    let sessionId: String
    var refs: [AskRef] = []
    if let botId = arguments.askString("botId") {
      let payload = try await bot(id: botId)
      let board = payload.board
      sessionId = try askRead { try botBoardActivitySessionId(in: [board.needsYou, board.inProgress, board.closed], botId: botId) }
      refs.append(AskRef(kind: .bot, id: payload.bot.botId))
    } else {
      sessionId = try arguments.askRequiredString("sessionId")
    }
    let page: BotActivityPage
    do {
      page = try await providers.bots.botActivity(
        sessionId: sessionId, afterSequence: arguments.askInt("afterSequence") ?? 0,
        limit: try arguments.askRequiredInt("limit"), waitMs: 0, remote: "local"
      )
    } catch WorkflowRuntimePersistenceStoreError.invalidSessionId {
      throw askRecordNotFound()
    }
    guard page.sessionStatus != "unknown" else { throw askRecordNotFound() }
    refs.append(AskRef(kind: .session, id: sessionId))
    if let stepId = page.state?.currentStepId {
      refs.append(AskRef(kind: .step, id: stepId, sessionId: sessionId))
    }
    return (try BotSurfaceJSON.value(page), refs)
  }

  func routineList(_ arguments: JSONObject) async throws -> AskReadResult {
    let status = try arguments.askString("status").map { value in
      guard let status = GraphQLRoutineStatus(rawValue: value.uppercased()) else {
        throw AskError(code: "tool_arguments_invalid", message: "Invalid routine status")
      }
      return status
    }
    let records = try await providers.routines.routines(filter: .init(status: status))
    return (try BotSurfaceJSON.value(records), records.map { AskRef(kind: .routine, id: $0.routineId) })
  }

  func workflowList(_ arguments: JSONObject) async throws -> AskReadResult {
    let entries = try await registryRead {
      try await providers.registry.workflows(filter: .init(query: arguments.askString("query"), scope: providers.registryScope))
    }
    return (try BotSurfaceJSON.value(entries), entries.map { AskRef(kind: .workflow, id: $0.workflowId) })
  }

  func workflowInspect(_ arguments: JSONObject) async throws -> AskReadResult {
    let id = try arguments.askRequiredString("workflowId")
    let (entry, inspection) = try await registryRead { try await providers.workflowInspect(id) }
    let value = try BotSurfaceJSON.value(entry)
    let refs = [AskRef(kind: .workflow, id: entry.workflowId)]
    if let inspection, case var .object(data) = value {
      data["inspection"] = inspection
      return (.object(data), refs)
    }
    return (value, refs)
  }

  func workflowValidate(_ arguments: JSONObject) async throws -> AskReadResult {
    let id = try arguments.askRequiredString("workflowId")
    return try await registryRead { try await providers.workflowValidate(id) }
  }

  func definitionHistory(_ arguments: JSONObject) async throws -> AskReadResult {
    let name = try arguments.askRequiredString("workflowName")
    let limit = try arguments.askRequiredInt("limit")
    do {
      let records = try await providers.definitions.workflowDefinitionHistory(
        workflowName: name, nodeId: nil, limit: limit, storeScope: nil
      )
      let ids = Set(records.map(\.workflowName)).sorted()
      return (try BotSurfaceJSON.value(records), ids.map { AskRef(kind: .workflow, id: $0) })
    } catch let error as WorkflowDefinitionGraphQLError where error.code == "DEFINITION_NOT_REGISTERED" {
      throw askRecordNotFound()
    }
  }

  func modelCatalog(_ arguments: JSONObject) async throws -> AskReadResult {
    do {
      let payload = try await providers.bots.modelCatalog(
        providerInstanceId: arguments.askString("providerInstanceId"), remote: "local"
      )
      return (try BotSurfaceJSON.value(payload), [])
    } catch let error as BotStoreError where error.code == "provider_instance_not_found" {
      throw askRecordNotFound()
    }
  }

  func remoteList(_ arguments: JSONObject) async throws -> AskReadResult {
    let payload = try await providers.bots.remotes()
    let remotes = payload.remotes.map { remote -> JSONValue in
      .object([
        "name": .string(remote.name), "serverName": .string(remote.serverName),
        "connection": .string(remote.connection.rawValue)
      ])
    }
    return (.array(remotes), [])
  }

  func contextSummary(_ context: AskContext) async throws -> (data: JSONObject, ref: AskRef)? {
    guard context.kind != .none else { return nil }
    guard let id = context.id, !id.isEmpty else { throw askRecordNotFound() }
    switch context.kind {
    case .none:
      return nil
    case .session:
      let record = try await actionSession(id: id)
      return (sessionSummary(record), AskRef(kind: .session, id: record.sessionId))
    case .bot:
      let payload = try await bot(id: id)
      let board = payload.board
      let counts = [
        "needsYou": board.needsYou.count, "inProgress": board.inProgress.count,
        "waiting": board.waiting.count, "planned": board.planned.count, "closed": board.closedTotal
      ]
      return ([
        "botId": .string(payload.bot.botId), "name": .string(payload.bot.name), "paused": .bool(payload.bot.paused),
        "counts": .object(counts.mapValues { .integer(Int64($0)) })
      ], AskRef(kind: .bot, id: payload.bot.botId))
    case .workflow:
      let entry = try await registryRead { try await providers.workflowInspect(id).entry }
      return ([
        "workflowId": .string(entry.workflowId), "origin": .string(entry.originId),
        "activationState": .string(entry.activationState), "definitionRevision": entry.definitionRevision.map(JSONValue.string) ?? .null
      ], AskRef(kind: .workflow, id: entry.workflowId))
    }
  }

  func actionBotExists(id: String) async throws -> Bool {
    do {
      _ = try await bot(id: id)
      return true
    } catch let error as AskError where error.code == "not_found" {
      return false
    }
  }

  func actionPermissionRequest(id: String) async throws -> ActivityRequestRecord? {
    try providers.permissionRequest(id)
  }

  private func bot(id: String) async throws -> BotDetailPayload {
    do {
      return try await providers.bots.bot(botId: id, remote: "local")
    } catch let error as BotStoreError where error.code == "bot_not_found" {
      throw askRecordNotFound()
    }
  }

  func registryRead<Value>(_ operation: () async throws -> Value) async throws -> Value {
    do {
      return try await CLIRuntimeEnvironment.$overrides.withValue(nil) {
        try await CLIRuntimeEnvironment.$captured.withValue(providers.environment, operation: operation)
      }
    } catch let error as WorkflowRegistryError where error.code == .workflowNotFound {
      throw askRecordNotFound()
    }
  }
}

func askRead<Value>(_ operation: () throws -> Value) throws -> Value {
  do {
    return try operation()
  } catch WorkflowRuntimePersistenceStoreError.notFound, WorkflowRuntimePersistenceStoreError.invalidSessionId {
    throw askRecordNotFound()
  } catch let error as BotStoreError where error.code == "bot_no_activity" {
    throw askRecordNotFound()
  }
}

func askRecordNotFound() -> AskError {
  AskError(code: "not_found", message: "Record not found")
}

extension JSONObject {
  fileprivate func askInt(_ field: String) -> Int? {
    self[field]?.asInt64.flatMap(Int.init(exactly:))
  }

  func askRequiredInt(_ field: String) throws -> Int {
    guard let value = askInt(field) else {
      throw AskError(code: "tool_arguments_invalid", message: "Missing or invalid \(field)")
    }
    return value
  }

  func askString(_ field: String) -> String? {
    guard case let .string(value)? = self[field] else { return nil }
    return value
  }

  func askRequiredString(_ field: String) throws -> String {
    guard let value = askString(field) else {
      throw AskError(code: "tool_arguments_invalid", message: "Missing or invalid \(field)")
    }
    return value
  }

  func askBool(_ field: String) -> Bool? {
    guard case let .bool(value)? = self[field] else { return nil }
    return value
  }
}
