import Foundation

public struct CatalogModel: Codable, Equatable, Sendable {
  public var id: String
  public var label: String?
  public var options: CatalogModelOptions
  public var sources: [String]
  public var observedAt: Date?
}

public struct CatalogInstance: Equatable, Sendable {
  public var instance: ProviderInstance
  public var report: ProviderReport?
  public var models: [CatalogModel]
}

public enum ModelCatalog {
  public struct NodeModelReference: Sendable {
    public let path: String
    public let driver: NodeExecutionBackend
    public let model: String?

    public init(path: String, driver: NodeExecutionBackend, model: String?) {
      self.path = path
      self.driver = driver
      self.model = model
    }
  }

  public static func build(instances: [ProviderInstance], reports: [String: ProviderReport]) -> [CatalogInstance] {
    instances.map { instance in
      let report = reports[instance.instanceId]
      return CatalogInstance(instance: instance, report: report, models: models(for: instance, report: report))
    }
  }

  public static func isKnown(model: String?, driver: NodeExecutionBackend, catalog: [CatalogInstance]) -> Bool {
    guard let model, !model.isEmpty, model != ModelSentinel.defaultModel else { return true }
    return catalog.contains { $0.instance.driver == driver && $0.models.contains { $0.id == model } }
  }

  public static func diagnostics(
    nodeModels: [NodeModelReference],
    catalog: [CatalogInstance]
  ) -> [WorkflowValidationDiagnostic] {
    nodeModels.compactMap { node in
      guard let model = node.model, !isKnown(model: model, driver: node.driver, catalog: catalog) else { return nil }
      return WorkflowValidationDiagnostic(
        severity: .warning, path: node.path,
        message: "model_unknown: '\(model)' is not in the catalog for \(node.driver.rawValue)"
      )
    }
  }

  private enum Source: String {
    case manifest, reported, custom
  }

  private static func models(for instance: ProviderInstance, report: ProviderReport?) -> [CatalogModel] {
    let sentinel = ModelSentinel.defaultModel
    let groups: [(Source, [ManifestModel])] = [
      (.manifest, ModelManifest.models[instance.driver] ?? []),
      (.reported, report?.reportedModels ?? []),
      (.custom, instance.customModels)
    ]
    var models = [CatalogModel(id: sentinel, options: .init(), sources: [Source.manifest.rawValue])]
    var positions: [String: Int] = [:]
    for (source, entries) in groups {
      for entry in entries where !entry.id.isEmpty && entry.id != sentinel {
        let observedAt = source == .reported ? report?.observedAt : nil
        if let position = positions[entry.id] {
          models[position].merge(entry, source: source.rawValue, observedAt: observedAt, preferIncoming: source == .reported)
        } else {
          positions[entry.id] = models.count
          models.append(CatalogModel(
            id: entry.id, label: entry.label, options: entry.options, sources: [source.rawValue], observedAt: observedAt
          ))
        }
      }
    }
    return models
  }
}

private extension CatalogModel {
  mutating func merge(_ entry: ManifestModel, source: String, observedAt: Date?, preferIncoming: Bool) {
    if !sources.contains(source) {
      sources.append(source)
      sources.sort()
    }
    if let incomingLabel = entry.label, preferIncoming || label == nil {
      label = incomingLabel
    }
    if let observedAt {
      self.observedAt = observedAt
    }
    for key in [\CatalogModelOptions.reasoningEfforts, \.serviceTiers, \.modes] {
      let incoming = entry.options[keyPath: key]
      if !incoming.isEmpty && (preferIncoming || options[keyPath: key].isEmpty) {
        options[keyPath: key] = incoming
      }
    }
  }
}
