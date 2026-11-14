import AgentGateway
import AgentGatewayAppCore
import Foundation

public protocol RielaAppAssistantModelLoading: Sendable {
  func models(for vendor: RielaAppAssistantVendor) async throws -> [String]
}

public struct RielaAppAssistantModelLoader: RielaAppAssistantModelLoading, Sendable {
  private let listing: any GatewayModelListing
  private let environment: [String: String]

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    listing = ProductionGatewayExecutor()
    self.environment = environment
  }

  init(
    listing: any GatewayModelListing,
    environment: [String: String]
  ) {
    self.listing = listing
    self.environment = environment
  }

  public func models(for vendor: RielaAppAssistantVendor) async throws -> [String] {
    guard let gatewayVendor = vendor.gatewayModelCatalogVendor else {
      return vendor.modelSuggestions
    }
    let result = try await listing.models(GatewayModelCatalogParams(
      vendor: gatewayVendor,
      apiKeyEnvironment: vendor.apiKeyEnvironmentNames.first(where: hasNonEmptyEnvironmentValue)
    ))
    return RielaAppAssistantModelCatalog.uniqueNormalizedModels(result.models.map(\.modelId))
  }

  private func hasNonEmptyEnvironmentValue(_ name: String) -> Bool {
    environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
  }
}

extension RielaAppAssistantVendor {
  public var supportsLiveModelListing: Bool {
    gatewayModelCatalogVendor != nil
  }

  fileprivate var gatewayModelCatalogVendor: GatewayVendor? {
    switch self {
    case .openAIAPI:
      .openAI
    case .anthropicAPI:
      .anthropic
    case .cursorAPI:
      .cursorAPI
    case .automatic, .codexCLI, .claudeCodeCLI, .cursorCLI:
      nil
    }
  }
}
