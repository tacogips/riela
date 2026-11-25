import Foundation

/// Only the fields consumed by the catalog from normalized ACP config options.
struct ReportedProviderConfig {
  private var models: [ManifestModel]?
  private var currentModel: String?
  private var reasoningEfforts: [String]?
  private var serviceTiers: [String]?
  private var modes: [String]?

  var isEmpty: Bool {
    models == nil && currentModel == nil && reasoningEfforts == nil && serviceTiers == nil && modes == nil
  }

  init(options: [JSONObject], reportedModel: String?) {
    for option in options {
      guard case let .string(id) = option["id"], case let .string(category) = option["category"] else { continue }
      let ids = Self.choiceIDs(from: option["values"])
      switch category {
      case "model":
        if let ids {
          models = ids.filter { Self.modelID($0) != nil }.map { ManifestModel(id: $0) }
        }
        if case let .string(value) = option["currentValue"] {
          currentModel = Self.modelID(value) ?? currentModel
        }
      case "mode":
        modes = ids ?? modes
      case "thought_level":
        reasoningEfforts = ids ?? reasoningEfforts
      case "model_config" where id.lowercased().contains("tier"):
        serviceTiers = ids ?? serviceTiers
      default:
        continue
      }
    }
    currentModel = Self.modelID(reportedModel) ?? currentModel
  }

  func apply(to report: inout ProviderReport) {
    let previousModels = Dictionary(report.reportedModels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var updated = models ?? report.reportedModels
    if let currentModel {
      if !updated.contains(where: { $0.id == currentModel }) {
        updated.append(previousModels[currentModel] ?? ManifestModel(id: currentModel))
      }
      report.currentModel = currentModel
    } else if models != nil, !updated.contains(where: { $0.id == report.currentModel }) {
      report.currentModel = nil
    }
    let previousOptions = report.reportedModels.first?.options ?? report.pendingModelOptions ?? .init()
    report.reportedModels = updated.map { model in
      let previous = previousModels[model.id]
      return ManifestModel(
        id: model.id, label: model.label ?? previous?.label,
        options: applyingOptions(to: previous?.options ?? previousOptions)
      )
    }
    let pending = applyingOptions(to: previousOptions)
    report.pendingModelOptions = updated.isEmpty && pending != .init() ? pending : nil
  }

  private func applyingOptions(to options: CatalogModelOptions) -> CatalogModelOptions {
    CatalogModelOptions(
      reasoningEfforts: reasoningEfforts ?? options.reasoningEfforts,
      serviceTiers: serviceTiers ?? options.serviceTiers,
      modes: modes ?? options.modes
    )
  }

  private static func modelID(_ id: String?) -> String? {
    guard let id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          id != ModelSentinel.defaultModel else { return nil }
    return id
  }

  private static func choiceIDs(from value: JSONValue?) -> [String]? {
    guard case let .array(values) = value else { return nil }
    var seen: Set<String> = []
    let ids: [String] = values.compactMap {
      guard case let .string(id) = $0, !id.isEmpty, seen.insert(id).inserted else { return nil }
      return id
    }
    return ids.isEmpty && !values.isEmpty ? nil : ids
  }
}
