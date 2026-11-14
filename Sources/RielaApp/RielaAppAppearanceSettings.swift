#if os(macOS)
import AppKit
import Foundation

/// App-wide color scheme for RielaApp windows (workflow, notes, settings).
/// Dark is the default; the user can switch to light from the settings window.
enum RielaAppColorScheme: String, Codable, CaseIterable, Sendable {
  case dark
  case light

  var displayName: String {
    switch self {
    case .dark:
      return "Dark"
    case .light:
      return "Light"
    }
  }

  var nsAppearanceName: NSAppearance.Name {
    switch self {
    case .dark:
      return .darkAqua
    case .light:
      return .aqua
    }
  }
}

struct RielaAppAppearanceSettings: Codable, Equatable, Sendable {
  var colorScheme: RielaAppColorScheme

  init(colorScheme: RielaAppColorScheme = .dark) {
    self.colorScheme = colorScheme
  }

  private enum CodingKeys: String, CodingKey {
    case colorScheme
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Tolerant decode: an unknown scheme value falls back to the dark default
    // instead of failing the whole settings load.
    let rawValue = try container.decodeIfPresent(String.self, forKey: .colorScheme)
    colorScheme = rawValue.flatMap(RielaAppColorScheme.init(rawValue:)) ?? .dark
  }
}

struct RielaAppAppearanceSettingsStore: Sendable {
  var settingsURL: URL

  init(appRootURL: URL) {
    settingsURL = appRootURL.appendingPathComponent("appearance-settings.json")
  }

  func load() -> RielaAppAppearanceSettings {
    guard let data = try? Data(contentsOf: settingsURL),
          let settings = try? JSONDecoder().decode(RielaAppAppearanceSettings.self, from: data) else {
      return RielaAppAppearanceSettings()
    }
    return settings
  }

  func save(_ settings: RielaAppAppearanceSettings) throws {
    try FileManager.default.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(settings).write(to: settingsURL, options: .atomic)
  }
}

@MainActor
func rielaAppApplyColorScheme(_ colorScheme: RielaAppColorScheme) {
  NSApplication.shared.appearance = NSAppearance(named: colorScheme.nsAppearanceName)
}
#endif
