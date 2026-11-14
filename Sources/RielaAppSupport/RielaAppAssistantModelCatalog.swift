import Foundation
import RielaCore

public struct RielaAppAssistantModelCatalog: Equatable, Sendable {
  public static let shared = RielaAppAssistantModelCatalog.loadBundledCatalog()

  public var modelsByVendor: [String: [String]]

  public init(modelsByVendor: [String: [String]]) {
    self.modelsByVendor = modelsByVendor.mapValues(Self.uniqueNormalizedModels)
  }

  public func models(for vendor: RielaAppAssistantVendor) -> [String] {
    modelsByVendor[vendor.settingsSelectableVendor.rawValue] ?? []
  }

  public func models(for executionBackend: NodeExecutionBackend?) -> [String] {
    guard let vendor = executionBackend?.assistantVendor else {
      return Self.uniqueNormalizedModels(RielaAppAssistantVendor.selectableVendors.flatMap(models(for:)))
    }
    return models(for: vendor)
  }

  public func defaultModel(for vendor: RielaAppAssistantVendor) -> String {
    models(for: vendor).first ?? ""
  }

  private static func loadBundledCatalog() -> RielaAppAssistantModelCatalog {
    guard
      let url = Bundle.module.url(forResource: "assistant-models", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
    else {
      return RielaAppAssistantModelCatalog(modelsByVendor: [:])
    }
    return RielaAppAssistantModelCatalog(modelsByVendor: decoded)
  }

  private static func uniqueNormalizedModels(_ models: [String]) -> [String] {
    var seen: Set<String> = []
    return models.compactMap { model in
      let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalized.isEmpty, seen.insert(normalized).inserted else {
        return nil
      }
      return normalized
    }
  }
}

private extension NodeExecutionBackend {
  var assistantVendor: RielaAppAssistantVendor? {
    switch self {
    case .codexAgent:
      .codexCLI
    case .claudeCodeAgent:
      .claudeCodeCLI
    case .cursorCliAgent:
      .cursorCLI
    case .officialOpenAISDK:
      .openAIAPI
    case .officialAnthropicSDK:
      .anthropicAPI
    case .officialCursorSDK:
      .cursorAPI
    case .officialGeminiSDK:
      nil
    }
  }
}
