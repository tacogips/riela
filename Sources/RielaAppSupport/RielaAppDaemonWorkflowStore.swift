import Foundation

public struct RielaAppDaemonWorkflowLoadResult: Equatable, Sendable {
  public var state: RielaAppDaemonWorkflowState
  public var quarantinedStateURL: URL?

  public init(state: RielaAppDaemonWorkflowState, quarantinedStateURL: URL? = nil) {
    self.state = state
    self.quarantinedStateURL = quarantinedStateURL
  }
}

public struct RielaAppDaemonWorkflowReadOnlyResult: Equatable, Sendable {
  public var state: RielaAppDaemonWorkflowState?
  public var error: String?

  public init(state: RielaAppDaemonWorkflowState? = nil, error: String? = nil) {
    self.state = state
    self.error = error
  }
}

public struct RielaAppDaemonWorkflowStore: Sendable {
  public var profileName: RielaAppProfileName
  public var stateURL: URL

  public init(
    profileName: RielaAppProfileName = .default,
    homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) {
    self.profileName = profileName
    stateURL = Self.defaultStateURL(profileName: profileName, homeDirectory: homeDirectory)
  }

  public init(
    stateURL: URL,
    profileName: RielaAppProfileName = .default
  ) {
    self.profileName = profileName
    self.stateURL = stateURL
  }

  public func load() -> RielaAppDaemonWorkflowState {
    loadResult().state
  }

  public func loadResult() -> RielaAppDaemonWorkflowLoadResult {
    let loadURL = FileManager.default.fileExists(atPath: stateURL.path) ? stateURL : nil
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

  /// Decodes profile configuration without moving, creating, or rewriting it.
  /// Validation and dry-run callers must use this instead of `loadResult()`.
  public func loadReadOnlyResult() -> RielaAppDaemonWorkflowReadOnlyResult {
    guard FileManager.default.fileExists(atPath: stateURL.path) else {
      return RielaAppDaemonWorkflowReadOnlyResult(state: RielaAppDaemonWorkflowState())
    }
    do {
      let data = try Data(contentsOf: stateURL)
      return RielaAppDaemonWorkflowReadOnlyResult(
        state: try JSONDecoder().decode(RielaAppDaemonWorkflowState.self, from: data)
      )
    } catch {
      return RielaAppDaemonWorkflowReadOnlyResult(error: "profile backend configuration is incompatible or corrupt")
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

}
