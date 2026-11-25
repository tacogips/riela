public struct CatalogModelOptions: Codable, Equatable, Sendable {
  public var reasoningEfforts: [String]
  public var serviceTiers: [String]
  public var modes: [String]

  public init(reasoningEfforts: [String] = [], serviceTiers: [String] = [], modes: [String] = []) {
    self.reasoningEfforts = reasoningEfforts
    self.serviceTiers = serviceTiers
    self.modes = modes
  }
}

public struct ManifestModel: Codable, Equatable, Sendable {
  public var id: String
  public var label: String?
  public var options: CatalogModelOptions

  public init(id: String, label: String? = nil, options: CatalogModelOptions = .init()) {
    self.id = id
    self.label = label
    self.options = options
  }
}

public enum ModelManifest {
  public static let models: [NodeExecutionBackend: [ManifestModel]] = [
    .codexAgent: reasoningModels(["gpt-5.6-sol", "gpt-5.5", "gpt-5.4-mini"]),
    .claudeCodeAgent: basicModels(["claude-sonnet-5", "claude-opus-4-8"]),
    .cursorCliAgent: basicModels(["auto", "composer-2.5"]),
    .officialOpenAISDK: reasoningModels(["gpt-5.6", "gpt-5.4-mini"]),
    .officialAnthropicSDK: basicModels(["claude-sonnet-5", "claude-opus-4-8"]),
    .officialGeminiSDK: basicModels(["gemini-3.5-flash-lite", "gemini-3.5-flash"]),
    .officialCursorSDK: basicModels(["composer-2.5"])
  ]

  private static func basicModels(_ ids: [String]) -> [ManifestModel] {
    ids.map { ManifestModel(id: $0) }
  }

  private static func reasoningModels(_ ids: [String]) -> [ManifestModel] {
    let options = CatalogModelOptions(reasoningEfforts: NodeReasoningEffort.allCases.map(\.rawValue))
    return ids.map { ManifestModel(id: $0, options: options) }
  }
}
