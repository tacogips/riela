#if os(macOS)
import Foundation

public struct RielaAppProfileName: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
  public static let `default` = RielaAppProfileName(Self.defaultRawValue)
  public static let defaultRawValue = "default"

  public var rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = Self.sanitizedRawValue(rawValue)
  }

  public var description: String {
    rawValue
  }

  public static func sanitizedRawValue(_ rawValue: String) -> String {
    let sanitized = sanitized(rawValue)
    return sanitized.isEmpty ? defaultRawValue : sanitized
  }

  private static func sanitized(_ rawValue: String) -> String {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let mapped = trimmed.map { character in
      character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
        ? character
        : "-"
    }
    return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
  }
}

public struct RielaAppProfileState: Codable, Equatable, Sendable {
  public var version: Int
  public var activeProfile: String

  public init(version: Int = 1, activeProfile: String = RielaAppProfileName.defaultRawValue) {
    self.version = version
    self.activeProfile = RielaAppProfileName(activeProfile).rawValue
  }

  public var activeProfileName: RielaAppProfileName {
    RielaAppProfileName(activeProfile)
  }
}

public struct RielaAppAssistantSettings: Codable, Equatable, Sendable {
  public static let maximumStoredMessages = 80

  public var assistance: String
  public var vendor: RielaAppAssistantVendor
  public var model: String
  public var modelsByVendor: [String: String]
  public var isFolded: Bool
  public var messages: [RielaAppAssistantMessage]

  private enum CodingKeys: String, CodingKey {
    case assistance
    case vendor
    case model
    case modelsByVendor
    case isFolded
    case messages
  }

  public init(
    assistance: String = "",
    vendor: RielaAppAssistantVendor = RielaAppAssistantVendor.defaultSelectableVendor,
    model: String = "",
    modelsByVendor: [String: String] = [:],
    isFolded: Bool = true,
    messages: [RielaAppAssistantMessage] = []
  ) {
    self.assistance = assistance
    self.vendor = vendor
    self.model = model
    self.modelsByVendor = modelsByVendor
    self.isFolded = isFolded
    self.messages = messages
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    assistance = try container.decodeIfPresent(String.self, forKey: .assistance) ?? ""
    vendor = try container.decodeIfPresent(RielaAppAssistantVendor.self, forKey: .vendor)
      ?? RielaAppAssistantVendor.defaultSelectableVendor
    model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
    modelsByVendor = try container.decodeIfPresent([String: String].self, forKey: .modelsByVendor) ?? [:]
    isFolded = try container.decodeIfPresent(Bool.self, forKey: .isFolded) ?? true
    messages = try container.decodeIfPresent([RielaAppAssistantMessage].self, forKey: .messages) ?? []
  }

  public var normalizedAssistance: String {
    assistance.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var normalizedModel: String {
    selectedModel(for: vendor.settingsSelectableVendor)
  }

  public func selectedModel(for vendor: RielaAppAssistantVendor) -> String {
    let configured = modelsByVendor[vendor.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let configured, vendor.modelSuggestions.contains(configured) {
      return configured
    }
    let legacyModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    if vendor == self.vendor, vendor.modelSuggestions.contains(legacyModel) {
      return legacyModel
    }
    return vendor.defaultModel
  }

  public mutating func setSelectedModel(_ model: String, for vendor: RielaAppAssistantVendor) {
    let normalized = vendor.modelSuggestions.contains(model) ? model : vendor.defaultModel
    modelsByVendor[vendor.rawValue] = normalized
    if vendor == self.vendor {
      self.model = normalized
    }
  }

  public var isEmpty: Bool {
    normalizedAssistance.isEmpty && messages.isEmpty
  }

  public mutating func appendMessage(role: RielaAppAssistantMessageRole, content: String) {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return
    }
    messages.append(RielaAppAssistantMessage(role: role, content: trimmed))
    if messages.count > Self.maximumStoredMessages {
      messages.removeFirst(messages.count - Self.maximumStoredMessages)
    }
  }

  public mutating func clearMessages() {
    messages.removeAll()
  }
}

public enum RielaAppAssistantMessageRole: String, Codable, Equatable, Sendable {
  case user
  case assistant
  case system

  public var label: String {
    switch self {
    case .user:
      "You"
    case .assistant:
      "Riela Assistant"
    case .system:
      "System"
    }
  }
}

public struct RielaAppAssistantMessage: Codable, Equatable, Sendable {
  public var role: RielaAppAssistantMessageRole
  public var content: String

  public init(role: RielaAppAssistantMessageRole, content: String) {
    self.role = role
    self.content = content
  }
}

public struct RielaAppAssistantModelCatalog: Equatable, Sendable {
  public static let shared = RielaAppAssistantModelCatalog.loadBundledCatalog()

  public var modelsByVendor: [String: [String]]

  public init(modelsByVendor: [String: [String]]) {
    self.modelsByVendor = modelsByVendor.mapValues { models in
      models
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }
  }

  public func models(for vendor: RielaAppAssistantVendor) -> [String] {
    modelsByVendor[vendor.settingsSelectableVendor.rawValue] ?? []
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
}

public enum RielaAppAssistantVendor: String, Codable, CaseIterable, Equatable, Sendable {
  case automatic
  case codexCLI = "codex-cli"
  case claudeCodeCLI = "claude-code-cli"
  case cursorCLI = "cursor-cli"
  case openAIAPI = "openai-api"
  case anthropicAPI = "anthropic-api"
  case cursorAPI = "cursor-api"

  public static let defaultSelectableVendor: RielaAppAssistantVendor = .openAIAPI

  public var displayName: String {
    switch self {
    case .automatic:
      "Automatic"
    case .codexCLI:
      "Codex CLI"
    case .claudeCodeCLI:
      "Claude Code CLI"
    case .cursorCLI:
      "Cursor CLI"
    case .openAIAPI:
      "OpenAI API"
    case .anthropicAPI:
      "Claude API"
    case .cursorAPI:
      "Cursor API"
    }
  }

  public var defaultModel: String {
    RielaAppAssistantModelCatalog.shared.defaultModel(for: self)
  }

  public var executableName: String? {
    switch self {
    case .codexCLI:
      "codex"
    case .claudeCodeCLI:
      "claude"
    case .cursorCLI:
      "cursor-agent"
    case .automatic, .openAIAPI, .anthropicAPI, .cursorAPI:
      nil
    }
  }

  public var apiKeyEnvironmentNames: [String] {
    switch self {
    case .openAIAPI:
      ["OPENAI_API_KEY"]
    case .anthropicAPI:
      ["ANTHROPIC_API_KEY", "CLAUDE_API_KEY"]
    case .cursorAPI:
      ["CURSOR_API_KEY"]
    case .automatic, .codexCLI, .claudeCodeCLI, .cursorCLI:
      []
    }
  }

  public var modelSuggestions: [String] {
    RielaAppAssistantModelCatalog.shared.models(for: self)
  }

  public static var selectableVendors: [RielaAppAssistantVendor] {
    allCases.filter { $0 != .automatic }
  }

  public var settingsSelectableVendor: RielaAppAssistantVendor {
    self == .automatic ? Self.defaultSelectableVendor : self
  }
}
#endif
