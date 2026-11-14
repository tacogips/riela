#if os(macOS)
import Foundation

public struct RielaAppDaemonWorkflowLoadResult: Equatable, Sendable {
  public var state: RielaAppDaemonWorkflowState
  public var quarantinedStateURL: URL?

  public init(state: RielaAppDaemonWorkflowState, quarantinedStateURL: URL? = nil) {
    self.state = state
    self.quarantinedStateURL = quarantinedStateURL
  }
}

public struct RielaAppDaemonWorkflowStore: Sendable {
  public var profileName: RielaAppProfileName
  public var stateURL: URL
  public var legacyStateURLs: [URL]

  public init(
    profileName: RielaAppProfileName = .default,
    homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) {
    self.profileName = profileName
    stateURL = Self.defaultStateURL(profileName: profileName, homeDirectory: homeDirectory)
    legacyStateURLs = profileName == .default ? Self.defaultLegacyStateURLs(homeDirectory: homeDirectory) : []
  }

  public init(
    stateURL: URL,
    legacyStateURLs: [URL] = [],
    profileName: RielaAppProfileName = .default
  ) {
    self.profileName = profileName
    self.stateURL = stateURL
    self.legacyStateURLs = legacyStateURLs
  }

  public func load() -> RielaAppDaemonWorkflowState {
    loadResult().state
  }

  public func loadResult() -> RielaAppDaemonWorkflowLoadResult {
    let loadURL = ([stateURL] + legacyStateURLs).first { FileManager.default.fileExists(atPath: $0.path) }
    guard let loadURL, let data = try? Data(contentsOf: loadURL) else {
      return RielaAppDaemonWorkflowLoadResult(state: RielaAppDaemonWorkflowState())
    }
    do {
      return RielaAppDaemonWorkflowLoadResult(
        state: try JSONDecoder().decode(RielaAppDaemonWorkflowState.self, from: data)
      )
    } catch {
      let quarantineURL = quarantineCorruptStateFile(at: loadURL)
      return RielaAppDaemonWorkflowLoadResult(
        state: RielaAppDaemonWorkflowState(),
        quarantinedStateURL: quarantineURL
      )
    }
  }

  public func save(_ state: RielaAppDaemonWorkflowState) throws {
    try FileManager.default.createDirectory(
      at: stateURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(state).write(to: stateURL, options: .atomic)
  }

  public static func defaultStateURL(
    profileName: RielaAppProfileName = .default,
    homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> URL {
    let appRoot = RielaAppProfileStore.defaultAppRootURL(homeDirectory: homeDirectory)
    return RielaAppProfileStore.profilesRootURL(appRootURL: appRoot)
      .appendingPathComponent(profileName.rawValue, isDirectory: true)
      .appendingPathComponent("daemon-workflows.json")
  }

  public static func corruptStateQuarantineURL(for stateURL: URL) -> URL {
    let baseURL = stateURL.deletingLastPathComponent()
      .appendingPathComponent("\(stateURL.lastPathComponent).corrupt")
    guard FileManager.default.fileExists(atPath: baseURL.path) else {
      return baseURL
    }
    return stateURL.deletingLastPathComponent()
      .appendingPathComponent("\(stateURL.lastPathComponent).corrupt-\(UUID().uuidString)")
  }

  private func quarantineCorruptStateFile(at url: URL) -> URL? {
    let quarantineURL = Self.corruptStateQuarantineURL(for: url)
    do {
      try FileManager.default.moveItem(at: url, to: quarantineURL)
      return quarantineURL
    } catch {
      return nil
    }
  }

  public static func defaultLegacyStateURLs(
    homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> [URL] {
    [
      legacyUserRielaStateURL(homeDirectory: homeDirectory),
      legacyApplicationSupportStateURL()
    ]
  }

  public static func legacyApplicationSupportStateURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
    return base
      .appendingPathComponent("RielaApp", isDirectory: true)
      .appendingPathComponent("daemon-workflows.json")
  }

  public static func legacyUserRielaStateURL(
    homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> URL {
    homeDirectory
      .appendingPathComponent(".riela", isDirectory: true)
      .appendingPathComponent("rielaapp-daemon-workflows.json")
  }
}
#endif
