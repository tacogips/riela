import Foundation

/// App-wide color scheme for RielaApp windows (workflow, notes, settings).
/// Dark is the default; the user can switch to light from the settings window.
public enum RielaAppColorScheme: String, Codable, CaseIterable, Sendable {
  case dark
  case light

  public var displayName: String {
    switch self {
    case .dark:
      return "Dark"
    case .light:
      return "Light"
    }
  }
}

public struct RielaAppAppearanceSettings: Codable, Equatable, Sendable {
  public var colorScheme: RielaAppColorScheme

  public init(colorScheme: RielaAppColorScheme = .dark) {
    self.colorScheme = colorScheme
  }

  private enum CodingKeys: String, CodingKey {
    case colorScheme
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Tolerant decode: an unknown scheme value falls back to the dark default
    // instead of failing the whole settings load.
    let rawValue = try container.decodeIfPresent(String.self, forKey: .colorScheme)
    colorScheme = rawValue.flatMap(RielaAppColorScheme.init(rawValue:)) ?? .dark
  }
}

public struct RielaAppAppearanceSettingsStore: Sendable {
  public var settingsURL: URL

  public init(appRootURL: URL) {
    settingsURL = appRootURL.appendingPathComponent("appearance-settings.json")
  }

  public func load() -> RielaAppAppearanceSettings {
    guard let data = try? Data(contentsOf: settingsURL),
          let settings = try? JSONDecoder().decode(RielaAppAppearanceSettings.self, from: data) else {
      return RielaAppAppearanceSettings()
    }
    return settings
  }

  public func save(_ settings: RielaAppAppearanceSettings) throws {
    try FileManager.default.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(settings).write(to: settingsURL, options: .atomic)
  }
}
