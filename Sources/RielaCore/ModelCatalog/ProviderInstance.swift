import Foundation

public struct ProviderInstance: Codable, Equatable, Sendable {
  public var instanceId: String
  public var driver: NodeExecutionBackend
  public var label: String?
  public var account: String?
  public var providerName: String?
  public var providerProxy: String?
  public var apiKeyEnvironment: String?
  public var customModels: [ManifestModel]
  public var builtIn: Bool

  public init(
    instanceId: String, driver: NodeExecutionBackend, label: String? = nil, account: String? = nil,
    providerName: String? = nil, providerProxy: String? = nil, apiKeyEnvironment: String? = nil,
    customModels: [ManifestModel] = [], builtIn: Bool = false
  ) {
    self.instanceId = instanceId
    self.driver = driver
    self.label = label
    self.account = account
    self.providerName = providerName
    self.providerProxy = providerProxy
    self.apiKeyEnvironment = apiKeyEnvironment
    self.customModels = customModels
    self.builtIn = builtIn
  }

  public static func builtIn(_ driver: NodeExecutionBackend) -> ProviderInstance {
    ProviderInstance(instanceId: driver.rawValue, driver: driver, builtIn: true)
  }

  public func validate() throws {
    guard !builtIn, NodeExecutionBackend(rawValue: instanceId) == nil else {
      throw BotStoreError(code: "provider_instance_reserved", message: "Built-in provider instances cannot be changed")
    }
    guard instanceId.range(of: #"\A[a-z0-9][a-z0-9/_-]{0,63}\z"#, options: .regularExpression) != nil else {
      throw BotStoreError(code: "provider_instance_invalid", message: "Invalid provider instance id")
    }
    if let apiKeyEnvironment,
       apiKeyEnvironment.range(of: #"\A[A-Z_][A-Z0-9_]*\z"#, options: .regularExpression) == nil {
      throw BotStoreError(code: "provider_instance_invalid", message: "API key environment must be a variable name")
    }
    guard !customModels.contains(where: { $0.id == ModelSentinel.defaultModel }) else {
      throw BotStoreError(code: "provider_instance_invalid", message: "The default model id is reserved")
    }
  }
}

public struct ProviderReport: Codable, Equatable, Sendable {
  public var instanceId: String
  public var observedAt: Date
  public var reportedModels: [ManifestModel]
  public var currentModel: String?
  public var availability: BackendCapability.Availability?
  public var authentication: BackendCapability.Authentication?
  public var version: String?
  public var failures: [String]?
  public var probedAt: Date?

  // Kept only while no real model is available to carry the reported options.
  var pendingModelOptions: CatalogModelOptions?

  public init(
    instanceId: String, observedAt: Date, reportedModels: [ManifestModel] = [], currentModel: String? = nil,
    availability: BackendCapability.Availability? = nil, authentication: BackendCapability.Authentication? = nil,
    version: String? = nil, failures: [String]? = nil, probedAt: Date? = nil
  ) {
    self.instanceId = instanceId
    self.observedAt = observedAt
    self.reportedModels = reportedModels
    self.currentModel = currentModel
    self.availability = availability
    self.authentication = authentication
    self.version = version
    self.failures = failures
    self.probedAt = probedAt
  }
}
