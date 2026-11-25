import Foundation
import RielaCore
import RielaGraphQL

public struct BotsGraphQLProvider: BotsGraphQLProviding {
  private let service: BotsService
  private let isStillAuthorized: @Sendable () async -> Bool

  public init(
    workingDirectory: String, sessionStoreRoot: String, environment: [String: String],
    isStillAuthorized: @escaping @Sendable () async -> Bool = { true }
  ) {
    service = BotsService(workingDirectory: workingDirectory, sessionStoreRoot: sessionStoreRoot, environment: environment)
    self.isStillAuthorized = isStillAuthorized
  }

  public func modelCatalog(providerInstanceId: String?, remote: String?) async throws -> ModelCatalogPayload {
    try service.validate(remote: remote)
    let catalog = service.modelCatalog
    let providers = try providerInstanceId.map { [try catalog.instance(id: $0)] } ?? catalog.instances()
    return ModelCatalogPayload(providers: providers)
  }

  public func providers(remote: String?) async throws -> ProviderListPayload {
    try service.validate(remote: remote)
    return ProviderListPayload(providers: try service.modelCatalog.instances())
  }

  public func provider(instanceId: String, remote: String?) async throws -> ProviderPayload {
    try service.validate(remote: remote)
    return ProviderPayload(provider: try service.modelCatalog.instance(id: instanceId))
  }

  public func refreshProviders(input: RefreshProvidersInput) async throws -> ProviderListPayload {
    try service.validate(remote: input.remote)
    return ProviderListPayload(providers: try await service.modelCatalog.refresh(instanceId: input.instanceId))
  }

  public func saveProviderInstance(input: SaveProviderInstanceInput) async throws -> ProviderPayload {
    try service.validate(remote: input.remote)
    return ProviderPayload(provider: try service.modelCatalog.save(input))
  }

  public func removeProviderInstance(input: RemoveProviderInstanceInput) async throws -> ProviderListPayload {
    try service.validate(remote: input.remote)
    return ProviderListPayload(providers: try service.modelCatalog.remove(id: input.instanceId))
  }

  public func bots(filter: BotFilter?) async throws -> BotListPayload {
    try service.validate(remote: filter?.remote)
    return try service.overview(groupBy: filter?.groupBy ?? .none)
  }

  public func bot(botId: String, remote: String?) async throws -> BotDetailPayload {
    try service.validate(remote: remote)
    return try service.detail(botId: botId)
  }

  public func botActivity(
    sessionId: String, afterSequence: Int, limit: Int, waitMs: Int, remote: String?
  ) async throws -> BotActivityPage {
    try service.validate(remote: remote)
    do {
      return try await service.activity(
        sessionId: sessionId, afterSequence: afterSequence, limit: limit, waitMs: waitMs,
        isStillAuthorized: isStillAuthorized
      )
    } catch let error as BotStoreError where error.code == "activity_wait_revoked" {
      throw BotStoreError(code: "UNAUTHENTICATED", message: error.message)
    }
  }

  public func answerBotRequest(input: AnswerBotRequestInput) async throws -> BotRequestPayload {
    try service.validate(remote: input.remote)
    return try service.answer(requestId: input.requestId, optionId: input.optionId, decline: input.decline == true)
  }

  public func createBot(input: CreateBotInput) async throws -> BotMutationPayload {
    try service.validate(remote: input.remote)
    return try service.create(input)
  }

  public func updateBot(input: UpdateBotInput) async throws -> BotMutationPayload {
    try service.validate(remote: input.remote)
    return try service.update(input)
  }

  public func setBotPaused(input: SetBotPausedInput) async throws -> BotMutationPayload {
    try service.validate(remote: input.remote)
    return BotMutationPayload(bot: try service.store.setPaused(botId: input.botId, paused: input.paused))
  }

  public func removeBot(input: RemoveBotInput) async throws -> BotMutationPayload {
    try service.validate(remote: input.remote)
    return BotMutationPayload(bot: try service.remove(botId: input.botId))
  }

  public func setBotListState(input: SetBotListStateInput) async throws -> BotMutationPayload {
    try service.validate(remote: input.remote)
    return BotMutationPayload(bot: try service.setListState(input))
  }
}
