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
  private static let claudeModels = basicModels([
    "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-2", "claude-haiku-5-5",
    "claude-sonnet-5", "claude-opus-4-8", "claude-fable-5", "claude-sonnet-4-6", "claude-haiku-4-5"
  ])

  public static let models: [NodeExecutionBackend: [ManifestModel]] = [
    .codexAgent: reasoningModels([
      "gpt-6.2-sol", "gpt-6.1-terra", "gpt-6-astra", "gpt-5.6-sol", "gpt-5.5",
      "gpt-5.4-mini", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.4", "gpt-5.3-codex-spark"
    ]),
    .claudeCodeAgent: claudeModels,
    .cursorCliAgent: basicModels([
      "auto", "composer-2.5", "gpt-5.6-sol-medium", "gpt-5.6-terra-medium", "gpt-5.6-luna-medium",
      "claude-opus-4-8-high", "claude-sonnet-5-high"
    ]),
    .antigravityAgent: reasoningModels([
      "gemini-4-neon", "gemini-4-carbon", "gemini-4-argon", "gemini-4-hydrogen",
      "gemini-3.8-flash", "claude-opus-5-5", "claude-sonnet-5-5"
    ]),
    .officialOpenAISDK: reasoningModels([
      "gpt-6.2-sol", "gpt-6.1-terra", "gpt-6-astra", "gpt-5.6", "gpt-5.4-mini", "gpt-5.5", "gpt-5.4"
    ]),
    .officialAnthropicSDK: claudeModels,
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
