import Foundation
import RielaCore

public struct GraphQLCatalogModel: Codable, Equatable, Sendable {
  public let id: String
  public let label: String?
  public let sources: [String]
  public let reasoningEfforts: [String]
  public let serviceTiers: [String]
  public let modes: [String]
  public let observedAt: Date?
  public let origin: BotOrigin?

  public init(_ model: CatalogModel, origin: BotOrigin? = nil) {
    id = model.id
    label = model.label
    sources = model.sources
    reasoningEfforts = model.options.reasoningEfforts
    serviceTiers = model.options.serviceTiers
    modes = model.options.modes
    observedAt = model.observedAt
    self.origin = origin
  }

  private enum CodingKeys: String, CodingKey {
    case id, label, sources, reasoningEfforts, serviceTiers, modes, observedAt, origin
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(id, forKey: .id)
    try values.encode(label, forKey: .label)
    try values.encode(sources, forKey: .sources)
    try values.encode(reasoningEfforts, forKey: .reasoningEfforts)
    try values.encode(serviceTiers, forKey: .serviceTiers)
    try values.encode(modes, forKey: .modes)
    try values.encode(observedAt, forKey: .observedAt)
    try values.encodeIfPresent(origin, forKey: .origin)
  }
}

public struct GraphQLProviderInstance: Codable, Equatable, Sendable {
  public let instanceId: String
  public let driver: NodeExecutionBackend
  public let label: String?
  public let account: String?
  public let builtIn: Bool
  public let availability: BackendCapability.Availability?
  public let authentication: BackendCapability.Authentication?
  public let version: String?
  public let failures: [String]
  public let probedAt: Date?
  public let models: [GraphQLCatalogModel]
  public let origin: BotOrigin

  public init(_ value: CatalogInstance, origin: BotOrigin) {
    instanceId = value.instance.instanceId
    driver = value.instance.driver
    label = value.instance.label
    account = value.instance.account
    builtIn = value.instance.builtIn
    availability = value.report?.availability
    authentication = value.report?.authentication
    version = value.report?.version
    failures = value.report?.failures ?? []
    probedAt = value.report?.probedAt
    models = value.models.map { GraphQLCatalogModel($0, origin: origin) }
    self.origin = origin
  }

  private enum CodingKeys: String, CodingKey {
    case instanceId, driver, label, account, builtIn, availability, authentication, version, failures, probedAt, models, origin
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(instanceId, forKey: .instanceId)
    try values.encode(driver, forKey: .driver)
    try values.encode(label, forKey: .label)
    try values.encode(account, forKey: .account)
    try values.encode(builtIn, forKey: .builtIn)
    try values.encode(availability, forKey: .availability)
    try values.encode(authentication, forKey: .authentication)
    try values.encode(version, forKey: .version)
    try values.encode(failures, forKey: .failures)
    try values.encode(probedAt, forKey: .probedAt)
    try values.encode(models, forKey: .models)
    try values.encode(origin, forKey: .origin)
  }
}

public struct ModelCatalogPayload: Codable, Equatable, Sendable {
  public let providers: [GraphQLProviderInstance]
  public init(providers: [GraphQLProviderInstance]) { self.providers = providers }
}

public struct ProviderListPayload: Codable, Equatable, Sendable {
  public let providers: [GraphQLProviderInstance]
  public init(providers: [GraphQLProviderInstance]) { self.providers = providers }
}

public struct ProviderPayload: Codable, Equatable, Sendable {
  public let provider: GraphQLProviderInstance
  public init(provider: GraphQLProviderInstance) { self.provider = provider }
}

public struct RefreshProvidersInput: Codable, Sendable {
  public var instanceId: String?
  public var remote: String?
  public init(instanceId: String? = nil) { self.instanceId = instanceId }
}

public struct SaveProviderInstanceInput: Codable, Sendable {
  public var instanceId: String
  public var driver: String?
  public var label: String?
  public var account: String?
  public var providerName: String?
  public var providerProxy: String?
  public var apiKeyEnvironment: String?
  public var customModels: [String]?
  public var remote: String?

  public init(instanceId: String) { self.instanceId = instanceId }
}

public struct RemoveProviderInstanceInput: Codable, Sendable {
  public var instanceId: String
  public var remote: String?
  public init(instanceId: String) { self.instanceId = instanceId }
}
