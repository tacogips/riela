#if os(macOS)
import Foundation

public struct RielaAppWebServerSettings: Codable, Equatable, Sendable {
  public static let currentVersion = 1
  public static let defaultPort = 19_091

  public var version: Int
  public var isEnabled: Bool
  public var port: Int

  public init(version: Int = currentVersion, isEnabled: Bool = false, port: Int = defaultPort) {
    self.version = version
    self.isEnabled = isEnabled
    self.port = port
  }

  public func validated() throws -> Self {
    guard (1...65_535).contains(port) else {
      throw RielaAppWebServerSettingsError.invalidPort(port)
    }
    return self
  }
}

public enum RielaAppWebServerSettingsError: LocalizedError, Equatable, Sendable {
  case invalidPort(Int)

  public var errorDescription: String? {
    switch self {
    case let .invalidPort(port):
      "Web server port must be between 1 and 65535; received \(port)."
    }
  }
}

public struct RielaAppWebServerSettingsLoadResult: Equatable, Sendable {
  public var settings: RielaAppWebServerSettings
  public var quarantinedURL: URL?
  public var diagnostic: String?

  public init(
    settings: RielaAppWebServerSettings,
    quarantinedURL: URL? = nil,
    diagnostic: String? = nil
  ) {
    self.settings = settings
    self.quarantinedURL = quarantinedURL
    self.diagnostic = diagnostic
  }
}

public struct RielaAppWebServerSettingsStore: Sendable {
  public var settingsURL: URL

  public init(appRootURL: URL) {
    settingsURL = appRootURL.appendingPathComponent("web-server.json")
  }

  public init(settingsURL: URL) {
    self.settingsURL = settingsURL
  }

  public func load() -> RielaAppWebServerSettingsLoadResult {
    guard FileManager.default.fileExists(atPath: settingsURL.path) else {
      return .init(settings: RielaAppWebServerSettings())
    }
    do {
      let data = try Data(contentsOf: settingsURL)
      let settings = try JSONDecoder().decode(RielaAppWebServerSettings.self, from: data)
      return .init(settings: try settings.validated())
    } catch {
      let quarantineURL = Self.availableQuarantineURL(for: settingsURL)
      do {
        try FileManager.default.moveItem(at: settingsURL, to: quarantineURL)
        return .init(
          settings: RielaAppWebServerSettings(),
          quarantinedURL: quarantineURL,
          diagnostic: "Invalid web server settings were moved to \(quarantineURL.path)."
        )
      } catch {
        return .init(
          settings: RielaAppWebServerSettings(),
          diagnostic: "Invalid web server settings could not be quarantined."
        )
      }
    }
  }

  public func save(_ settings: RielaAppWebServerSettings) throws {
    let validated = try settings.validated()
    try FileManager.default.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(validated).write(to: settingsURL, options: .atomic)
  }

  public static func availableQuarantineURL(for settingsURL: URL) -> URL {
    let base = settingsURL.deletingLastPathComponent()
      .appendingPathComponent("\(settingsURL.lastPathComponent).corrupt")
    guard FileManager.default.fileExists(atPath: base.path) else {
      return base
    }
    return settingsURL.deletingLastPathComponent()
      .appendingPathComponent("\(settingsURL.lastPathComponent).corrupt-\(UUID().uuidString)")
  }
}
#endif
