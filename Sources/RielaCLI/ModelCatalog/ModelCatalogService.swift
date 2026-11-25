import Foundation
import RielaAdapters
import RielaCore
import RielaGraphQL

struct ModelCatalogService: Sendable {
  static let openRouterBaseURL = "https://openrouter.ai/api/v1"

  typealias Probe = @Sendable (ProviderInstance, [String: String], Date) async -> BackendCapability

  let store: BotStore
  let environment: [String: String]
  var now: @Sendable () -> Date = Date.init
  var origin: @Sendable (Date) -> BotOrigin = {
    BotOrigin.local(serverId: nil, serverName: nil, at: $0)
  }
  var probe: Probe = { instance, environment, date in
    let observed = await BackendCapabilityProbe().probe(instance.driver, environment: environment, now: date)
    guard let key = instance.apiKeyEnvironment else { return observed }
    let present = environment[key]?.isEmpty == false
    let checksEnvironmentOnly = instance.driver.cliAgentBackend == nil
    return BackendCapability(
      backend: instance.driver, source: .observed, observedAt: date,
      availability: checksEnvironmentOnly ? (present ? .available : .unavailable) : observed.availability,
      authentication: present ? .available : .failed, version: observed.version,
      requiredEnvironment: [key: present], executableAvailable: observed.executableAvailable,
      failures: (checksEnvironmentOnly ? [] : observed.failures)
        + (present ? [] : ["required environment is not configured: \(key)"])
    )
  }

  func catalog() throws -> [CatalogInstance] {
    try ModelCatalog.build(instances: store.providerInstances(), reports: store.providerReports())
  }

  func builtInModelIds() throws -> [NodeExecutionBackend: [String]] {
    let builtIns = try catalog().filter { $0.instance.builtIn }
    return Dictionary(uniqueKeysWithValues: builtIns.map { entry in
      (entry.instance.driver, entry.models.map(\.id).filter { $0 != ModelSentinel.defaultModel })
    })
  }

  func instances() throws -> [GraphQLProviderInstance] {
    let at = origin(now())
    return try catalog().map { GraphQLProviderInstance($0, origin: at) }
  }

  func instance(id: String) throws -> GraphQLProviderInstance {
    let instance = try configuredInstance(id: id)
    return projection(for: instance, report: try store.providerReport(instanceId: id), origin: origin(now()))
  }

  func refresh(instanceId: String?) async throws -> [GraphQLProviderInstance] {
    let selected = try instanceId.map { [try configuredInstance(id: $0)] } ?? store.providerInstances()
    var refreshed: [GraphQLProviderInstance] = []
    for instance in selected {
      let at = now()
      let capability = await probe(instance, environment, at)
      try store.recordProbe(instanceId: instance.instanceId, capability: capability, at: at)
      refreshed.append(try self.instance(id: instance.instanceId))
    }
    return refreshed
  }

  func save(_ input: SaveProviderInstanceInput) throws -> GraphQLProviderInstance {
    guard NodeExecutionBackend(rawValue: input.instanceId) == nil else {
      throw BotStoreError(code: "provider_instance_reserved", message: "Built-in provider instances cannot be changed")
    }
    let existing = try store.providerInstance(id: input.instanceId)
    guard let driver = input.driver.map(NodeExecutionBackend.init(rawValue:)) ?? existing?.driver else {
      throw BotStoreError(code: "provider_instance_invalid", message: "A valid provider driver is required")
    }
    let stored = try store.saveProviderInstance(ProviderInstance(
      instanceId: input.instanceId, driver: driver, label: input.label ?? existing?.label,
      account: input.account ?? existing?.account, providerName: input.providerName ?? existing?.providerName,
      providerProxy: input.providerProxy ?? existing?.providerProxy,
      apiKeyEnvironment: input.apiKeyEnvironment ?? existing?.apiKeyEnvironment,
      customModels: input.customModels?.map { ManifestModel(id: $0) } ?? existing?.customModels ?? []
    ))
    return projection(for: stored, report: try store.providerReport(instanceId: stored.instanceId), origin: origin(now()))
  }

  func remove(id: String) throws -> [GraphQLProviderInstance] {
    try store.removeProviderInstance(id: id)
    return try instances()
  }

  func configuredInstance(id: String) throws -> ProviderInstance {
    guard let instance = try store.providerInstance(id: id) else {
      throw BotStoreError(code: "provider_instance_not_found", message: "Provider instance '\(id)' was not found")
    }
    return instance
  }

  private func projection(for instance: ProviderInstance, report: ProviderReport?, origin: BotOrigin) -> GraphQLProviderInstance {
    let reports = report.map { [instance.instanceId: $0] } ?? [:]
    let catalog = ModelCatalog.build(instances: [instance], reports: reports)
    return GraphQLProviderInstance(catalog[0], origin: origin)
  }
}

public enum AssistantCatalogModels {
  public static func builtIn(sessionStoreRoot: String, environment: [String: String]) -> [NodeExecutionBackend: [String]]? {
    let store = BotStore(sessionStoreRoot: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot))
    return try? ModelCatalogService(store: store, environment: environment).builtInModelIds()
  }
}
