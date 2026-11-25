import Foundation
import RielaCore

public struct RielaAppAssistantModelCatalog: Equatable, Sendable {
  public static let shared = RielaAppAssistantModelCatalog(modelsByVendor: Dictionary(
    uniqueKeysWithValues: RielaAppAssistantVendor.selectableVendors.map { vendor in
      (vendor.rawValue, ModelManifest.models[vendor.executionBackend, default: []].map(\.id))
    }
  ))

  public var modelsByVendor: [String: [String]]

  public init(modelsByVendor: [String: [String]]) {
    self.modelsByVendor = modelsByVendor.mapValues(Self.uniqueNormalizedModels)
  }

  public func models(for vendor: RielaAppAssistantVendor) -> [String] {
    modelsByVendor[vendor.settingsSelectableVendor.rawValue] ?? []
  }

  public func models(for executionBackend: NodeExecutionBackend?) -> [String] {
    guard let vendor = RielaAppAssistantVendor.selectableVendors.first(where: {
      $0.executionBackend == executionBackend
    }) else {
      return Self.uniqueNormalizedModels(RielaAppAssistantVendor.selectableVendors.flatMap(models(for:)))
    }
    return models(for: vendor)
  }

  public func defaultModel(for vendor: RielaAppAssistantVendor) -> String {
    models(for: vendor).first ?? ""
  }

  static func uniqueNormalizedModels(_ models: [String]) -> [String] {
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
