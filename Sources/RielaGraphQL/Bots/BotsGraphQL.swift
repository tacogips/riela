import Foundation
import RielaCore

public protocol BotsGraphQLProviding: Sendable {
  func remotes() async throws -> RemoteListPayload
  func addRemote(input: AddRemoteInput) async throws -> RemoteListPayload
  func removeRemote(input: RemoveRemoteInput) async throws -> RemoteListPayload
  func useRemote(input: UseRemoteInput) async throws -> RemoteListPayload
  func botMemoryHistory(botId: String, limit: Int, remote: String?) async throws -> BotMemoryHistoryPayload
  func botMemoryDiff(botId: String, changeId: String, remote: String?) async throws -> BotMemoryDiffPayload
  func botJobHistory(botId: String, job: BotJobKind?, limit: Int, remote: String?) async throws -> BotJobHistoryPayload
  func pairingGrants() async throws -> PairingGrantListPayload
  func mintPairingCode(input: MintPairingCodeInput) async throws -> PairingCodePayload
  func revokePairingGrant(input: RevokePairingGrantInput) async throws -> PairingGrantListPayload
  func modelCatalog(providerInstanceId: String?, remote: String?) async throws -> ModelCatalogPayload
  func providers(remote: String?) async throws -> ProviderListPayload
  func provider(instanceId: String, remote: String?) async throws -> ProviderPayload
  func refreshProviders(input: RefreshProvidersInput) async throws -> ProviderListPayload
  func saveProviderInstance(input: SaveProviderInstanceInput) async throws -> ProviderPayload
  func removeProviderInstance(input: RemoveProviderInstanceInput) async throws -> ProviderListPayload
  func bots(filter: BotFilter?) async throws -> BotListPayload
  func bot(botId: String, remote: String?) async throws -> BotDetailPayload
  func botMemory(botId: String, remote: String?) async throws -> BotMemoryPayload
  func botSuggestions(botId: String, status: BotSuggestion.Status?, remote: String?) async throws -> BotSuggestionListPayload
  func decideBotSuggestion(input: DecideBotSuggestionInput) async throws -> BotSuggestionPayload
  func runBotJob(input: RunBotJobInput) async throws -> BotJobPayload
  func updateBotMemory(input: UpdateBotMemoryInput) async throws -> BotMemoryChangePayload
  func undoBotMemoryChange(input: UndoBotMemoryChangeInput) async throws -> BotMemoryChangePayload
  func captureBotFeedback(input: CaptureBotFeedbackInput) async throws -> BotMemoryChangePayload
  func botActivity(sessionId: String, afterSequence: Int, limit: Int, waitMs: Int, remote: String?) async throws -> BotActivityPage
  func createBot(input: CreateBotInput) async throws -> BotMutationPayload
  func updateBot(input: UpdateBotInput) async throws -> BotMutationPayload
  func setBotPaused(input: SetBotPausedInput) async throws -> BotMutationPayload
  func removeBot(input: RemoveBotInput) async throws -> BotMutationPayload
  func setBotListState(input: SetBotListStateInput) async throws -> BotMutationPayload
  func answerBotRequest(input: AnswerBotRequestInput) async throws -> BotRequestPayload
}

public struct BotsGraphQLDocumentExecutor: GraphQLDocumentExecuting {
  public static let queryFields: Set<String> = [
    "bots", "bot", "botActivity", "botMemory", "botSuggestions", "modelCatalog", "providers", "provider", "pairingGrants", "remotes",
    "botMemoryHistory", "botMemoryDiff", "botJobHistory"
  ]
  public static let mutationFields: Set<String> = [
    "createBot", "updateBot", "setBotPaused", "removeBot", "setBotListState", "answerBotRequest",
    "refreshProviders", "saveProviderInstance", "removeProviderInstance",
    "updateBotMemory", "undoBotMemoryChange", "captureBotFeedback", "decideBotSuggestion", "runBotJob",
    "mintPairingCode", "revokePairingGrant", "addRemote", "removeRemote", "useRemote"
  ]

  public let provider: any BotsGraphQLProviding
  public let next: (any GraphQLDocumentExecuting)?

  public init(provider: any BotsGraphQLProviding, next: (any GraphQLDocumentExecuting)? = nil) {
    self.provider = provider
    self.next = next
  }

  public static func supports(_ field: String) -> Bool {
    queryFields.contains(field) || mutationFields.contains(field)
  }

  public func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    var completed: JSONObject = [:]
    do {
      let roots = try roots(for: request)
      let owned = roots.filter { Self.supports($0.fieldName) }
      guard !owned.isEmpty else { return await next?.execute(request) ?? .notHandled }
      try validateUniqueGraphQLRootResponseKeys(roots)
      if let rejection = await preflight(request, rootFields: roots) { return rejection }
      for root in roots {
        if Self.supports(root.fieldName) {
          completed[root.responseKey] = try await execute(root)
        } else {
          var forwarded = request
          forwarded.parsedRootFields = [root]
          let response = await next?.execute(forwarded) ?? .notHandled
          if let errors = response.body["errors"] {
            return GraphQLDocumentExecutionResponse(
              handled: true, body: ["data": completed.isEmpty ? .null : .object(completed), "errors": errors]
            )
          }
          guard case let .object(data)? = response.body["data"], response.handled else {
            throw BotStoreError(code: "INVALID_BOT", message: "Unsupported GraphQL root field")
          }
          completed.merge(data) { _, latest in latest }
        }
      }
      return GraphQLDocumentExecutionResponse(handled: true, body: ["data": .object(completed)])
    } catch let error as BotStoreError {
      return failure(error, completed: completed)
    } catch {
      return failure(BotStoreError(code: "BOT_IO_FAILURE", message: "Bot operation failed"), completed: completed)
    }
  }

  private func roots(for request: GraphQLDocumentRequest) throws -> [ParsedGraphQLRootField] {
    if let roots = request.parsedRootFields { return roots }
    do {
      let operations = try parseGraphQLOperations(
        in: request.query, operationName: request.operationName, variables: request.variables, parseArguments: true
      )
      return try selectGraphQLOperation(operations, operationName: request.operationName)?.rootFields ?? []
    } catch {
      throw BotStoreError(code: "INVALID_BOT", message: "Invalid GraphQL document")
    }
  }

  private func execute(_ root: ParsedGraphQLRootField) async throws -> JSONValue {
    let value: JSONValue
    switch try decode(root) {
    case let .memoryHistory(id, limit, remote):
      value = try await BotSurfaceJSON.value(provider.botMemoryHistory(botId: id, limit: limit, remote: remote))
    case let .memoryDiff(id, changeId, remote):
      value = try await BotSurfaceJSON.value(provider.botMemoryDiff(botId: id, changeId: changeId, remote: remote))
    case let .jobHistory(id, job, limit, remote):
      value = try await BotSurfaceJSON.value(provider.botJobHistory(botId: id, job: job, limit: limit, remote: remote))
    case let .registry(operation): value = try await executeRegistry(operation)
    case let .modelCatalog(id, remote):
      value = try await BotSurfaceJSON.value(provider.modelCatalog(providerInstanceId: id, remote: remote))
    case let .providers(remote): value = try await BotSurfaceJSON.value(provider.providers(remote: remote))
    case let .provider(id, remote): value = try await BotSurfaceJSON.value(provider.provider(instanceId: id, remote: remote))
    case let .refreshProviders(input): value = try await BotSurfaceJSON.value(provider.refreshProviders(input: input))
    case let .saveProviderInstance(input): value = try await BotSurfaceJSON.value(provider.saveProviderInstance(input: input))
    case let .removeProviderInstance(input): value = try await BotSurfaceJSON.value(provider.removeProviderInstance(input: input))
    case let .list(filter): value = try await BotSurfaceJSON.value(provider.bots(filter: filter))
    case let .detail(id, remote): value = try await BotSurfaceJSON.value(provider.bot(botId: id, remote: remote))
    case let .memory(id, remote): value = try await BotSurfaceJSON.value(provider.botMemory(botId: id, remote: remote))
    case let .suggestions(id, status, remote):
      value = try await BotSurfaceJSON.value(provider.botSuggestions(botId: id, status: status, remote: remote))
    case let .decideSuggestion(input): value = try await BotSurfaceJSON.value(provider.decideBotSuggestion(input: input))
    case let .runJob(input): value = try await BotSurfaceJSON.value(provider.runBotJob(input: input))
    case let .updateMemory(input): value = try await BotSurfaceJSON.value(provider.updateBotMemory(input: input))
    case let .undoMemory(input): value = try await BotSurfaceJSON.value(provider.undoBotMemoryChange(input: input))
    case let .captureFeedback(input): value = try await BotSurfaceJSON.value(provider.captureBotFeedback(input: input))
    case let .activity(sessionId, afterSequence, limit, waitMs, remote):
      value = try await BotSurfaceJSON.value(provider.botActivity(
        sessionId: sessionId, afterSequence: afterSequence, limit: limit, waitMs: waitMs, remote: remote
      ))
    case let .create(input): value = try await BotSurfaceJSON.value(provider.createBot(input: input))
    case let .update(input): value = try await BotSurfaceJSON.value(provider.updateBot(input: input))
    case let .pause(input): value = try await BotSurfaceJSON.value(provider.setBotPaused(input: input))
    case let .remove(input): value = try await BotSurfaceJSON.value(provider.removeBot(input: input))
    case let .listState(input): value = try await BotSurfaceJSON.value(provider.setBotListState(input: input))
    case let .answer(input): value = try await BotSurfaceJSON.value(provider.answerBotRequest(input: input))
    }
    return projectGraphQLValue(value, selections: root.selections)
  }

  private enum Operation {
    case memoryHistory(String, Int, String?)
    case memoryDiff(String, String, String?)
    case jobHistory(String, BotJobKind?, Int, String?)
    case registry(RegistryOperation)
    case modelCatalog(String?, String?)
    case providers(String?)
    case provider(String, String?)
    case refreshProviders(RefreshProvidersInput)
    case saveProviderInstance(SaveProviderInstanceInput)
    case removeProviderInstance(RemoveProviderInstanceInput)
    case list(BotFilter?)
    case detail(String, String?)
    case memory(String, String?)
    case suggestions(String, BotSuggestion.Status?, String?)
    case decideSuggestion(DecideBotSuggestionInput)
    case runJob(RunBotJobInput)
    case updateMemory(UpdateBotMemoryInput)
    case undoMemory(UndoBotMemoryChangeInput)
    case captureFeedback(CaptureBotFeedbackInput)
    case activity(sessionId: String, afterSequence: Int, limit: Int, waitMs: Int, remote: String?)
    case create(CreateBotInput)
    case update(UpdateBotInput)
    case pause(SetBotPausedInput)
    case remove(RemoveBotInput)
    case listState(SetBotListStateInput)
    case answer(AnswerBotRequestInput)
  }

  private func decode(_ root: ParsedGraphQLRootField) throws -> Operation {
    let invalid = BotStoreError(code: "INVALID_BOT", message: "Invalid arguments for '\(root.fieldName)'")
    func input<T: Decodable>(_ type: T.Type, at key: String = "input") throws -> T {
      guard let value = root.arguments[key],
        let decoded = try? JSONDecoder().decode(type, from: JSONEncoder().encode(value)) else { throw invalid }
      return decoded
    }
    func optionalInput<T: Decodable>(_ type: T.Type, at key: String) throws -> T? {
      guard let value = root.arguments[key], value != .null else { return nil }
      return try input(type, at: key)
    }
    if let operation = try decodeRegistry(root, invalid: invalid) { return .registry(operation) }
    switch root.fieldName {
    case "botMemoryHistory":
      return .memoryHistory(
        try input(String.self, at: "botId"), try optionalInput(Int.self, at: "limit") ?? 50,
        try optionalInput(String.self, at: "remote")
      )
    case "botMemoryDiff":
      return .memoryDiff(
        try input(String.self, at: "botId"), try input(String.self, at: "changeId"), try optionalInput(String.self, at: "remote")
      )
    case "botJobHistory":
      return .jobHistory(
        try input(String.self, at: "botId"), try optionalInput(BotJobKind.self, at: "job"),
        try optionalInput(Int.self, at: "limit") ?? 50, try optionalInput(String.self, at: "remote")
      )
    case "modelCatalog":
      return .modelCatalog(try optionalInput(String.self, at: "providerInstanceId"), try optionalInput(String.self, at: "remote"))
    case "providers": return .providers(try optionalInput(String.self, at: "remote"))
    case "provider": return .provider(try input(String.self, at: "instanceId"), try optionalInput(String.self, at: "remote"))
    case "refreshProviders": return .refreshProviders(try input(RefreshProvidersInput.self))
    case "saveProviderInstance": return .saveProviderInstance(try input(SaveProviderInstanceInput.self))
    case "removeProviderInstance": return .removeProviderInstance(try input(RemoveProviderInstanceInput.self))
    case "bots":
      let filter = root.arguments["filter"]
      return .list(filter == nil || filter == .null ? nil : try input(BotFilter.self, at: "filter"))
    case "bot":
      let remote = root.arguments["remote"]
      return .detail(try input(String.self, at: "botId"), remote == nil || remote == .null ? nil : try input(String.self, at: "remote"))
    case "botMemory":
      return .memory(try input(String.self, at: "botId"), try optionalInput(String.self, at: "remote"))
    case "botSuggestions":
      return .suggestions(
        try input(String.self, at: "botId"), try optionalInput(BotSuggestion.Status.self, at: "status"),
        try optionalInput(String.self, at: "remote")
      )
    case "decideBotSuggestion": return .decideSuggestion(try input(DecideBotSuggestionInput.self))
    case "runBotJob": return .runJob(try input(RunBotJobInput.self))
    case "updateBotMemory": return .updateMemory(try input(UpdateBotMemoryInput.self))
    case "undoBotMemoryChange": return .undoMemory(try input(UndoBotMemoryChangeInput.self))
    case "captureBotFeedback": return .captureFeedback(try input(CaptureBotFeedbackInput.self))
    case "botActivity":
      let limit = try optionalInput(Int.self, at: "limit") ?? BotActivityPage.defaultLimit
      let waitMs = try optionalInput(Int.self, at: "waitMs") ?? 0
      return .activity(
        sessionId: try input(String.self, at: "sessionId"),
        afterSequence: try optionalInput(Int.self, at: "afterSequence") ?? 0,
        limit: min(BotActivityPage.maximumLimit, max(1, limit)),
        waitMs: min(BotActivityPage.maximumWaitMs, max(0, waitMs)),
        remote: try optionalInput(String.self, at: "remote")
      )
    case "createBot":
      let value = try input(CreateBotInput.self)
      guard value.name != nil, value.botId == nil else { throw invalid }
      return .create(value)
    case "updateBot":
      let value = try input(UpdateBotInput.self)
      guard value.botId != nil, value.id == nil else { throw invalid }
      return .update(value)
    case "setBotPaused": return .pause(try input(SetBotPausedInput.self))
    case "removeBot": return .remove(try input(RemoveBotInput.self))
    case "setBotListState": return .listState(try input(SetBotListStateInput.self))
    case "answerBotRequest": return .answer(try input(AnswerBotRequestInput.self))
    default: throw invalid
    }
  }

  private enum RegistryOperation {
    case pairingGrants
    case mintPairingCode(MintPairingCodeInput)
    case revokePairingGrant(RevokePairingGrantInput)
    case remotes
    case addRemote(AddRemoteInput)
    case removeRemote(RemoveRemoteInput)
    case useRemote(UseRemoteInput)
  }

  private func decodeRegistry(
    _ root: ParsedGraphQLRootField, invalid: BotStoreError
  ) throws -> RegistryOperation? {
    func input<Value: Decodable>(_ type: Value.Type) throws -> Value {
      guard let input = root.arguments["input"],
            let result = try? JSONDecoder().decode(type, from: JSONEncoder().encode(input)) else { throw invalid }
      return result
    }
    switch root.fieldName {
    case "pairingGrants": return .pairingGrants
    case "mintPairingCode": return .mintPairingCode(try input(MintPairingCodeInput.self))
    case "revokePairingGrant": return .revokePairingGrant(try input(RevokePairingGrantInput.self))
    case "remotes": return .remotes
    case "addRemote": return .addRemote(try input(AddRemoteInput.self))
    case "removeRemote": return .removeRemote(try input(RemoveRemoteInput.self))
    case "useRemote": return .useRemote(try input(UseRemoteInput.self))
    default: return nil
    }
  }

  private func executeRegistry(_ operation: RegistryOperation) async throws -> JSONValue {
    let value: JSONValue
    switch operation {
    case .pairingGrants: value = try await BotSurfaceJSON.value(provider.pairingGrants())
    case let .mintPairingCode(input): value = try await BotSurfaceJSON.value(provider.mintPairingCode(input: input))
    case let .revokePairingGrant(input): value = try await BotSurfaceJSON.value(provider.revokePairingGrant(input: input))
    case .remotes: value = try await BotSurfaceJSON.value(provider.remotes())
    case let .addRemote(input): value = try await BotSurfaceJSON.value(provider.addRemote(input: input))
    case let .removeRemote(input): value = try await BotSurfaceJSON.value(provider.removeRemote(input: input))
    case let .useRemote(input): value = try await BotSurfaceJSON.value(provider.useRemote(input: input))
    }
    return value
  }

  private func failure(_ error: BotStoreError, completed: JSONObject = [:]) -> GraphQLDocumentExecutionResponse {
    GraphQLDocumentExecutionResponse(handled: true, body: [
      "data": completed.isEmpty ? .null : .object(completed),
      "errors": .array([.object(["message": .string(error.message), "extensions": .object(["code": .string(error.code)])])])
    ])
  }
}

extension BotsGraphQLDocumentExecutor: GraphQLDocumentDomainPreflighting {
  func preflight(
    _ request: GraphQLDocumentRequest, rootFields: [ParsedGraphQLRootField]
  ) async -> GraphQLDocumentExecutionResponse? {
    let owned = rootFields.filter { Self.supports($0.fieldName) }
    let forwarded = rootFields.filter { !Self.supports($0.fieldName) }
    if !owned.isEmpty, !request.isLocallyTrusted {
      return failure(BotStoreError(code: "BOTS_UNAVAILABLE", message: "Bot GraphQL requires a locally trusted host"))
    }
    for root in owned {
      let expected: GraphQLDocumentOperationType = Self.queryFields.contains(root.fieldName) ? .query : .mutation
      guard root.operationType == expected, (try? decode(root)) != nil else {
        return failure(BotStoreError(code: "INVALID_BOT", message: "Invalid bot field '\(root.fieldName)'"))
      }
    }
    guard !forwarded.isEmpty else { return nil }
    guard let next = next as? any GraphQLDocumentDomainPreflighting else {
      return failure(BotStoreError(code: "INVALID_BOT", message: "GraphQL fallback does not support preflight"))
    }
    return await next.preflight(request, rootFields: forwarded)
  }
}
