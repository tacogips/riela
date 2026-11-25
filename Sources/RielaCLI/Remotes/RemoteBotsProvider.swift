import Foundation
import RielaCore
import RielaGraphQL

struct RemoteBotsProvider: BotsGraphQLProviding {
  let record: RemoteRecord
  let token: String
  let registry: RemoteRegistry
  var transport: RemoteHTTP.Transport = RemoteHTTP.production
  var now: @Sendable () -> Date = Date.init

  func pairingGrants() async throws -> PairingGrantListPayload { throw Self.localOnly }
  func mintPairingCode(input: MintPairingCodeInput) async throws -> PairingCodePayload { throw Self.localOnly }
  func revokePairingGrant(input: RevokePairingGrantInput) async throws -> PairingGrantListPayload { throw Self.localOnly }

  private static var localOnly: BotStoreError {
    BotStoreError(code: "remote_selector_invalid", message: "Pairing administration must target the receiving server")
  }

  func bots(filter: BotFilter?) async throws -> BotListPayload {
    let arguments: JSONObject = try filter.map { ["filter": try Self.inputValue($0)] } ?? [:]
    let payload: BotListPayload = try await execute("Query.bots", arguments: arguments)
    let hasVerifiedOrigin = payload.origin?.verified == true || !payload.bots.isEmpty
    if hasVerifiedOrigin, payload.bots.allSatisfy(\.origin.verified) {
      let lastKnown = RemoteLastKnown(observedAt: now(), bots: payload.bots.map {
        RemoteLastKnown.Bot(botId: $0.bot.botId, name: $0.bot.name, counts: $0.counts)
      })
      try? registry.updateLastKnown(name: record.name, lastKnown: lastKnown, grantId: record.grantId)
    }
    return payload
  }

  func modelCatalog(providerInstanceId: String?, remote: String?) async throws -> ModelCatalogPayload {
    let arguments: JSONObject = providerInstanceId.map { ["providerInstanceId": .string($0)] } ?? [:]
    return try await execute("Query.modelCatalog", arguments: arguments)
  }

  func providers(remote: String?) async throws -> ProviderListPayload {
    try await execute("Query.providers")
  }

  func provider(instanceId: String, remote: String?) async throws -> ProviderPayload {
    try await execute("Query.provider", arguments: ["instanceId": .string(instanceId)])
  }

  func bot(botId: String, remote: String?) async throws -> BotDetailPayload {
    try await execute("Query.bot", arguments: ["botId": .string(botId)])
  }

  func botJobHistory(botId: String, job: BotJobKind?, limit: Int, remote: String?) async throws -> BotJobHistoryPayload {
    var arguments: JSONObject = ["botId": .string(botId), "limit": .integer(Int64(limit))]
    arguments["job"] = job.map { .string($0.rawValue) }
    return try await execute("Query.botJobHistory", arguments: arguments)
  }

  func botMemoryHistory(botId: String, limit: Int, remote: String?) async throws -> BotMemoryHistoryPayload {
    try await execute("Query.botMemoryHistory", arguments: ["botId": .string(botId), "limit": .integer(Int64(limit))])
  }

  func botMemoryDiff(botId: String, changeId: String, remote: String?) async throws -> BotMemoryDiffPayload {
    try await execute("Query.botMemoryDiff", arguments: ["botId": .string(botId), "changeId": .string(changeId)])
  }

  func botMemory(botId: String, remote: String?) async throws -> BotMemoryPayload {
    try await execute("Query.botMemory", arguments: ["botId": .string(botId)])
  }

  func botSuggestions(botId: String, status: BotSuggestion.Status?, remote: String?) async throws -> BotSuggestionListPayload {
    var arguments: JSONObject = ["botId": .string(botId)]
    arguments["status"] = status.map { .string($0.rawValue) }
    return try await execute("Query.botSuggestions", arguments: arguments)
  }

  func botActivity(
    sessionId: String, afterSequence: Int, limit: Int, waitMs: Int, remote: String?
  ) async throws -> BotActivityPage {
    try await execute("Query.botActivity", arguments: [
      "sessionId": .string(sessionId), "afterSequence": .integer(Int64(afterSequence)),
      "limit": .integer(Int64(limit)), "waitMs": .integer(Int64(waitMs))
    ])
  }

  func refreshProviders(input: RefreshProvidersInput) async throws -> ProviderListPayload {
    try await mutate("refreshProviders", input: input)
  }

  func saveProviderInstance(input: SaveProviderInstanceInput) async throws -> ProviderPayload {
    try await mutate("saveProviderInstance", input: input)
  }

  func removeProviderInstance(input: RemoveProviderInstanceInput) async throws -> ProviderListPayload {
    try await mutate("removeProviderInstance", input: input)
  }

  func decideBotSuggestion(input: DecideBotSuggestionInput) async throws -> BotSuggestionPayload {
    try await mutate("decideBotSuggestion", input: input)
  }

  func runBotJob(input: RunBotJobInput) async throws -> BotJobPayload {
    try await mutate("runBotJob", input: input)
  }

  func updateBotMemory(input: UpdateBotMemoryInput) async throws -> BotMemoryChangePayload {
    try await mutate("updateBotMemory", input: input)
  }

  func undoBotMemoryChange(input: UndoBotMemoryChangeInput) async throws -> BotMemoryChangePayload {
    try await mutate("undoBotMemoryChange", input: input)
  }

  func captureBotFeedback(input: CaptureBotFeedbackInput) async throws -> BotMemoryChangePayload {
    try await mutate("captureBotFeedback", input: input)
  }

  func createBot(input: CreateBotInput) async throws -> BotMutationPayload {
    try await mutate("createBot", input: input)
  }

  func updateBot(input: UpdateBotInput) async throws -> BotMutationPayload {
    try await mutate("updateBot", input: input)
  }

  func setBotPaused(input: SetBotPausedInput) async throws -> BotMutationPayload {
    try await mutate("setBotPaused", input: input)
  }

  func removeBot(input: RemoveBotInput) async throws -> BotMutationPayload {
    try await mutate("removeBot", input: input)
  }

  func setBotListState(input: SetBotListStateInput) async throws -> BotMutationPayload {
    try await mutate("setBotListState", input: input)
  }

  func answerBotRequest(input: AnswerBotRequestInput) async throws -> BotRequestPayload {
    try await mutate("answerBotRequest", input: input)
  }

  private func mutate<Input: Encodable, Output: Decodable>(_ field: String, input: Input) async throws -> Output {
    try await execute("Mutation.\(field)", arguments: ["input": try Self.inputValue(input)])
  }

  private func execute<Output: Decodable>(_ root: String, arguments: JSONObject = [:]) async throws -> Output {
    let document = try GraphQLSelectionBuilder.document(for: root, arguments: Set(arguments.keys))
    let client = RemoteGraphQLClient(record: record, token: token, transport: transport)
    let data = try await client.execute(query: document.query, variables: arguments, operationName: nil)
    guard let value = data[document.field.name] else { throw Self.invalidResponse }
    let verified = RemoteOriginProjection(record: record, observedAt: now()).rewrite(value, type: document.field.type)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let payload: Output
    do {
      payload = try decoder.decode(Output.self, from: JSONEncoder().encode(verified))
    } catch {
      throw Self.invalidResponse
    }
    try? registry.touchLastSeen(name: record.name, at: now(), grantId: record.grantId)
    return payload
  }

  static func inputValue<Input: Encodable>(_ input: Input) throws -> JSONValue {
    guard case var .object(fields) = try BotSurfaceJSON.value(input) else { throw invalidResponse }
    fields.removeValue(forKey: "remote")
    return .object(fields)
  }

  private static var invalidResponse: BotStoreError {
    BotStoreError(code: "remote_invalid_response", message: "The remote returned an invalid bot payload")
  }
}

struct RemoteOriginProjection {
  let record: RemoteRecord
  let observedAt: Date

  func rewrite(_ value: JSONValue, type: String) -> JSONValue {
    guard let descriptor = GraphQLSelectionBuilder.object(forType: type) else { return value }
    if case let .array(items) = value { return .array(items.map { rewrite($0, type: type) }) }
    if descriptor.name == "BotOrigin" { return origin(value) }
    guard case var .object(fields) = value else { return value }
    for field in descriptor.fields where GraphQLSelectionBuilder.object(forType: field.type) != nil {
      if let child = fields[field.name] {
        fields[field.name] = rewrite(child, type: field.type)
      } else if field.name == "origin" {
        fields[field.name] = origin(.null)
      }
    }
    return .object(fields)
  }

  private func origin(_ value: JSONValue) -> JSONValue {
    var fields: JSONObject = [:]
    if case let .object(object) = value { fields = object }
    let matches = fields["serverId"] == .string(record.serverId)
    fields["remote"] = .string(matches ? record.name : "unverified")
    fields["verified"] = .bool(matches)
    fields["connection"] = .string("connected")
    if case .string? = fields["observedAt"] {
      return .object(fields)
    }
    fields["observedAt"] = .string(ISO8601DateFormatter().string(from: observedAt))
    return .object(fields)
  }
}
