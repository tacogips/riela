import Foundation
import RielaCore
import RielaGraphQL
import RielaServer

public struct BotsGraphQLProvider: BotsGraphQLProviding {
  let service: BotsService
  let registry: RemoteRegistry
  let remoteTransport: RemoteHTTP.Transport
  private let pairing: PairingService?
  private let isStillAuthorized: @Sendable () async -> Bool

  public init(
    workingDirectory: String, sessionStoreRoot: String, environment: [String: String],
    isStillAuthorized: @escaping @Sendable () async -> Bool = { true }
  ) {
    self.init(
      workingDirectory: workingDirectory, sessionStoreRoot: sessionStoreRoot, environment: environment,
      pairing: nil, isStillAuthorized: isStillAuthorized
    )
  }

  init(
    workingDirectory: String, sessionStoreRoot: String, environment: [String: String],
    pairing: PairingService?, remoteTransport: @escaping RemoteHTTP.Transport = RemoteHTTP.production,
    isStillAuthorized: @escaping @Sendable () async -> Bool = { true }
  ) {
    let identity = pairing?.identity
    service = BotsService(
      workingDirectory: workingDirectory, sessionStoreRoot: sessionStoreRoot, environment: environment,
      origin: { BotOrigin.local(serverId: identity?.serverId, serverName: identity?.name, at: $0) }
    )
    registry = RemoteRegistry(environment: environment)
    self.remoteTransport = remoteTransport
    self.pairing = pairing
    self.isStillAuthorized = isStillAuthorized
  }

  public func pairingGrants() async throws -> PairingGrantListPayload {
    try withPairing { try $0.grants() }
  }

  public func mintPairingCode(input: MintPairingCodeInput) async throws -> PairingCodePayload {
    try withPairing { try $0.mint(address: input.address, scope: PairingService.scope(input.scope)) }
  }

  public func revokePairingGrant(input: RevokePairingGrantInput) async throws -> PairingGrantListPayload {
    try withPairing { try $0.revoke(grantId: input.grantId) }
  }

  private func withPairing<Value>(_ action: (PairingService) throws -> Value) throws -> Value {
    guard let pairing else {
      throw BotStoreError(code: "pairing_unavailable", message: "Pairing requires a serve host")
    }
    do {
      return try action(pairing)
    } catch let error as RielaAPIKeyStore.StoreError {
      throw BotStoreError(code: error.code, message: "Pairing operation failed")
    }
  }

  public func modelCatalog(providerInstanceId: String?, remote: String?) async throws -> ModelCatalogPayload {
    switch try RemoteRouting.resolve(remote: remote, registry: registry, allowsAll: true) {
    case .local:
      let catalog = service.modelCatalog
      let providers = try providerInstanceId.map { [try catalog.instance(id: $0)] } ?? catalog.instances()
      return ModelCatalogPayload(providers: providers)
    case let .remote(record, token):
      return try await forward(record: record, token: token).modelCatalog(providerInstanceId: providerInstanceId, remote: nil)
    case .all:
      let local = try await localMatch("provider_instance_not_found") {
        try await modelCatalog(providerInstanceId: providerInstanceId, remote: "local")
      }
      let remotes = try await eachRemote { remote in
        try await localMatch("provider_instance_not_found") {
          try await remote.modelCatalog(providerInstanceId: providerInstanceId, remote: nil)
        }
      }
      return ModelCatalogPayload(providers: (local?.providers ?? []) + remotes.compactMap { $0 }.flatMap(\.providers))
    }
  }

  public func providers(remote: String?) async throws -> ProviderListPayload {
    switch try RemoteRouting.resolve(remote: remote, registry: registry, allowsAll: true) {
    case .local:
      return ProviderListPayload(providers: try service.modelCatalog.instances())
    case let .remote(record, token):
      return try await forward(record: record, token: token).providers(remote: nil)
    case .all:
      let local = try service.modelCatalog.instances()
      let remotes = try await eachRemote { try await $0.providers(remote: nil) }
      return ProviderListPayload(providers: local + remotes.flatMap(\.providers))
    }
  }

  public func provider(instanceId: String, remote: String?) async throws -> ProviderPayload {
    if let remote = try forwarded(remote) {
      return try await remote.provider(instanceId: instanceId, remote: nil)
    }
    return ProviderPayload(provider: try service.modelCatalog.instance(id: instanceId))
  }

  public func refreshProviders(input: RefreshProvidersInput) async throws -> ProviderListPayload {
    if let remote = try forwarded(input.remote) {
      return try await remote.refreshProviders(input: input)
    }
    return ProviderListPayload(providers: try await service.modelCatalog.refresh(instanceId: input.instanceId))
  }

  public func saveProviderInstance(input: SaveProviderInstanceInput) async throws -> ProviderPayload {
    if let remote = try forwarded(input.remote) {
      return try await remote.saveProviderInstance(input: input)
    }
    return ProviderPayload(provider: try service.modelCatalog.save(input))
  }

  public func removeProviderInstance(input: RemoveProviderInstanceInput) async throws -> ProviderListPayload {
    if let remote = try forwarded(input.remote) {
      return try await remote.removeProviderInstance(input: input)
    }
    return ProviderListPayload(providers: try service.modelCatalog.remove(id: input.instanceId))
  }

  public func bots(filter: BotFilter?) async throws -> BotListPayload {
    let grouping = filter?.groupBy ?? .none
    switch try RemoteRouting.resolve(remote: filter?.remote, registry: registry, allowsAll: true) {
    case .local:
      return try service.overview(groupBy: grouping)
    case let .remote(record, token):
      return try await remoteOverview(forward(record: record, token: token), filter: filter)
    case .all:
      let local = try service.overview(groupBy: grouping)
      let remotes = try await eachRemote { try await remoteOverview($0, filter: filter) }
      return BotListPayload(bots: local.bots + remotes.flatMap(\.bots), groups: local.groups + remotes.flatMap(\.groups))
    }
  }

  public func bot(botId: String, remote: String?) async throws -> BotDetailPayload {
    if let remote = try forwarded(remote) {
      return try await remote.bot(botId: botId, remote: nil)
    }
    return try service.detail(botId: botId)
  }

  public func botJobHistory(
    botId: String, job: BotJobKind?, limit: Int, remote: String?
  ) async throws -> BotJobHistoryPayload {
    guard limit > 0 else { throw BotStoreError(code: "bot_invalid", message: "Job history limit must be positive") }
    if let remote = try forwarded(remote) {
      return try await remote.botJobHistory(botId: botId, job: job, limit: limit, remote: nil)
    }
    return BotJobHistoryPayload(
      runs: try service.jobHistory(botId: botId, job: job, limit: limit), origin: service.origin(service.now())
    )
  }

  public func botMemoryHistory(botId: String, limit: Int, remote: String?) async throws -> BotMemoryHistoryPayload {
    guard limit > 0 else { throw BotStoreError(code: "bot_invalid", message: "Memory history limit must be positive") }
    if let remote = try forwarded(remote) {
      return try await remote.botMemoryHistory(botId: botId, limit: limit, remote: nil)
    }
    return BotMemoryHistoryPayload(
      changes: try service.memoryWriter().history(botId: botId, limit: limit), origin: service.origin(service.now())
    )
  }

  public func botMemoryDiff(botId: String, changeId: String, remote: String?) async throws -> BotMemoryDiffPayload {
    if let remote = try forwarded(remote) {
      return try await remote.botMemoryDiff(botId: botId, changeId: changeId, remote: nil)
    }
    return BotMemoryDiffPayload(
      diffs: try service.memoryWriter().diff(botId: botId, changeId: changeId), origin: service.origin(service.now())
    )
  }

  public func botMemory(botId: String, remote: String?) async throws -> BotMemoryPayload {
    if let remote = try forwarded(remote) {
      return try await remote.botMemory(botId: botId, remote: nil)
    }
    return try service.memory(botId: botId)
  }

  public func updateBotMemory(input: UpdateBotMemoryInput) async throws -> BotMemoryChangePayload {
    if let remote = try forwarded(input.remote) {
      return try await remote.updateBotMemory(input: input)
    }
    let change = try service.memoryWriter().applyMarkdown(
      botId: input.botId, markdown: input.markdown, source: .user, actor: "api", reason: input.reason ?? "edit"
    )
    return BotMemoryChangePayload(change: change, origin: service.origin(service.now()))
  }

  public func undoBotMemoryChange(input: UndoBotMemoryChangeInput) async throws -> BotMemoryChangePayload {
    if let remote = try forwarded(input.remote) {
      return try await remote.undoBotMemoryChange(input: input)
    }
    let change = try service.memoryWriter().undo(botId: input.botId, changeId: input.changeId, actor: "api")
    return BotMemoryChangePayload(change: change, origin: service.origin(service.now()))
  }

  public func captureBotFeedback(input: CaptureBotFeedbackInput) async throws -> BotMemoryChangePayload {
    if let remote = try forwarded(input.remote) {
      return try await remote.captureBotFeedback(input: input)
    }
    let change = try service.captureFeedback(input)
    return BotMemoryChangePayload(change: change, origin: service.origin(service.now()))
  }

  public func botSuggestions(botId: String, status: BotSuggestion.Status?, remote: String?) async throws -> BotSuggestionListPayload {
    let origin = service.origin(service.now())
    switch try RemoteRouting.resolve(remote: remote, registry: registry, allowsAll: true) {
    case .local:
      return BotSuggestionListPayload(
        botId: botId, suggestions: try service.suggestions(botId: botId, status: status).map { $0.withOrigin(origin) }, origin: origin
      )
    case let .remote(record, token):
      return try await forward(record: record, token: token).botSuggestions(botId: botId, status: status, remote: nil)
    case .all:
      let local = try await localMatch("bot_not_found") { try await botSuggestions(botId: botId, status: status, remote: "local") }
      let remotes = try await eachRemote { remote in
        try await localMatch("bot_not_found") {
          try await remote.botSuggestions(botId: botId, status: status, remote: nil)
        }
      }
      return BotSuggestionListPayload(
        botId: botId, suggestions: (local?.suggestions ?? []) + remotes.compactMap { $0 }.flatMap(\.suggestions), origin: origin
      )
    }
  }

  private func localMatch<T>(_ notFound: String, operation: () async throws -> T) async throws -> T? {
    do {
      return try await operation()
    } catch let error as BotStoreError where error.code == notFound {
      return nil
    }
  }

  public func decideBotSuggestion(input: DecideBotSuggestionInput) async throws -> BotSuggestionPayload {
    if let remote = try forwarded(input.remote) {
      return try await remote.decideBotSuggestion(input: input)
    }
    let suggestion = try await service.decideSuggestion(input, actor: "api")
    let origin = service.origin(service.now())
    return BotSuggestionPayload(suggestion: suggestion.withOrigin(origin), origin: origin)
  }

  public func runBotJob(input: RunBotJobInput) async throws -> BotJobPayload {
    if let remote = try forwarded(input.remote) {
      return try await remote.runBotJob(input: input)
    }
    return try await service.runJob(botId: input.botId, job: input.job, force: input.force == true)
  }

  public func botActivity(
    sessionId: String, afterSequence: Int, limit: Int, waitMs: Int, remote: String?
  ) async throws -> BotActivityPage {
    if let remote = try forwarded(remote) {
      let page = try await remote.botActivity(
        sessionId: sessionId, afterSequence: afterSequence, limit: limit, waitMs: waitMs, remote: nil
      )
      guard await activityIsAuthorized() else {
        throw BotStoreError(code: "UNAUTHENTICATED", message: "The activity grant is no longer valid")
      }
      return page
    }
    do {
      return try await service.activity(
        sessionId: sessionId, afterSequence: afterSequence, limit: limit, waitMs: waitMs,
        isStillAuthorized: { await activityIsAuthorized() }
      )
    } catch let error as BotStoreError where error.code == "activity_wait_revoked" {
      throw BotStoreError(code: "UNAUTHENTICATED", message: error.message)
    }
  }

  private func activityIsAuthorized() async -> Bool {
    guard BotsRequestGrant.current?.isStillValid() ?? true else { return false }
    return await isStillAuthorized()
  }

  public func answerBotRequest(input: AnswerBotRequestInput) async throws -> BotRequestPayload {
    if let remote = try forwarded(input.remote) {
      return try await remote.answerBotRequest(input: input)
    }
    return try service.answer(requestId: input.requestId, optionId: input.optionId, decline: input.decline == true)
  }

  public func createBot(input: CreateBotInput) async throws -> BotMutationPayload {
    if let remote = try forwarded(input.remote) {
      return try await remote.createBot(input: input)
    }
    return try service.create(input)
  }

  public func updateBot(input: UpdateBotInput) async throws -> BotMutationPayload {
    if let remote = try forwarded(input.remote) {
      return try await remote.updateBot(input: input)
    }
    return try service.update(input)
  }

  public func setBotPaused(input: SetBotPausedInput) async throws -> BotMutationPayload {
    if let remote = try forwarded(input.remote) {
      return try await remote.setBotPaused(input: input)
    }
    return BotMutationPayload(
      bot: try service.store.setPaused(botId: input.botId, paused: input.paused), origin: service.origin(service.now())
    )
  }

  public func removeBot(input: RemoveBotInput) async throws -> BotMutationPayload {
    if let remote = try forwarded(input.remote) {
      return try await remote.removeBot(input: input)
    }
    return BotMutationPayload(bot: try service.remove(botId: input.botId), origin: service.origin(service.now()))
  }

  public func setBotListState(input: SetBotListStateInput) async throws -> BotMutationPayload {
    if let remote = try forwarded(input.remote) {
      return try await remote.setBotListState(input: input)
    }
    return BotMutationPayload(bot: try service.setListState(input), origin: service.origin(service.now()))
  }
}
