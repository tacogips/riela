#if os(macOS)
import Foundation
import RielaAddons
import RielaEvents
import RielaServer

public struct RielaAppDaemonEventSourceSummary: Equatable, Sendable {
  public var id: String
  public var kind: String

  public init(id: String, kind: String) {
    self.id = id
    self.kind = kind
  }
}

public struct RielaAppDaemonWorkflowCandidate: Identifiable, Equatable, Sendable {
  public var id: String
  public var workflowId: String
  public var displayName: String
  public var sourceDescription: String
  public var workflowDirectory: String
  public var packageDirectory: String?
  public var workingDirectory: String
  public var eventRoot: String?
  public var eventSources: [RielaAppDaemonEventSourceSummary]

  public init(
    id: String,
    workflowId: String,
    displayName: String,
    sourceDescription: String,
    workflowDirectory: String,
    packageDirectory: String? = nil,
    workingDirectory: String,
    eventRoot: String?,
    eventSources: [RielaAppDaemonEventSourceSummary]
  ) {
    self.id = id
    self.workflowId = workflowId
    self.displayName = displayName
    self.sourceDescription = sourceDescription
    self.workflowDirectory = workflowDirectory
    self.packageDirectory = packageDirectory
    self.workingDirectory = workingDirectory
    self.eventRoot = eventRoot
    self.eventSources = eventSources
  }

  public var eventSourceSummary: String {
    let summary = eventSources.map { "\($0.id):\($0.kind)" }.joined(separator: ", ")
    return summary.isEmpty ? "None" : summary
  }

  public var serveSelection: WorkflowServeSelection {
    .directDirectory(workflowDirectory, identifier: workflowId)
  }

  public var startsEventSources: Bool {
    eventRoot != nil && !eventSources.isEmpty
  }
}

public struct RielaAppDaemonWorkflowPreference: Codable, Equatable, Sendable {
  public var identity: String
  public var available: Bool
  public var active: Bool

  private enum CodingKeys: String, CodingKey {
    case identity
    case available
    case enabledAtLaunch
    case active
  }

  public init(identity: String, available: Bool = false, active: Bool = false) {
    self.identity = identity
    self.available = available
    self.active = active
  }

  public init(identity: String, enabledAtLaunch: Bool, active: Bool = false) {
    self.init(identity: identity, available: enabledAtLaunch, active: active)
  }

  public var enabledAtLaunch: Bool {
    get { available }
    set { available = newValue }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    identity = try container.decode(String.self, forKey: .identity)
    available = try container.decodeIfPresent(Bool.self, forKey: .available)
      ?? container.decodeIfPresent(Bool.self, forKey: .enabledAtLaunch)
      ?? false
    active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? available
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(identity, forKey: .identity)
    try container.encode(available, forKey: .available)
    try container.encode(active, forKey: .active)
  }
}

public struct RielaAppProfileName: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
  public static let `default` = RielaAppProfileName(Self.defaultRawValue)
  public static let defaultRawValue = "default"

  public var rawValue: String

  public init(_ rawValue: String) {
    let sanitized = Self.sanitized(rawValue)
    self.rawValue = sanitized.isEmpty ? Self.defaultRawValue : sanitized
  }

  public var description: String {
    rawValue
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

public struct RielaAppProfileStore: Sendable {
  public var appRootURL: URL
  public var activeProfileURL: URL

  public init(
    appRootURL: URL = Self.defaultAppRootURL(),
    activeProfileURL: URL? = nil
  ) {
    self.appRootURL = appRootURL
    self.activeProfileURL = activeProfileURL ?? appRootURL.appendingPathComponent("active-profile.json")
  }

  public func loadActiveProfileName() -> RielaAppProfileName {
    guard let data = try? Data(contentsOf: activeProfileURL),
      let state = try? JSONDecoder().decode(RielaAppProfileState.self, from: data)
    else {
      return .default
    }
    return state.activeProfileName
  }

  public func saveActiveProfileName(_ profileName: RielaAppProfileName) throws {
    try FileManager.default.createDirectory(
      at: activeProfileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(RielaAppProfileState(activeProfile: profileName.rawValue)).write(
      to: activeProfileURL,
      options: .atomic
    )
  }

  public func listProfileNames(including activeProfileName: RielaAppProfileName? = nil) -> [RielaAppProfileName] {
    let profilesRoot = Self.profilesRootURL(appRootURL: appRootURL)
    let children = (try? FileManager.default.contentsOfDirectory(
      at: profilesRoot,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    var names = Set(children.compactMap { url -> RielaAppProfileName? in
      guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
        return nil
      }
      return RielaAppProfileName(url.lastPathComponent)
    })
    names.insert(.default)
    if let activeProfileName {
      names.insert(activeProfileName)
    }
    return names.sorted { lhs, rhs in
      lhs.rawValue.localizedCaseInsensitiveCompare(rhs.rawValue) == .orderedAscending
    }
  }

  public static func defaultAppRootURL(
    homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> URL {
    homeDirectory
      .appendingPathComponent(".riela", isDirectory: true)
      .appendingPathComponent("rielaapp", isDirectory: true)
  }

  public static func profilesRootURL(appRootURL: URL) -> URL {
    appRootURL.appendingPathComponent("profiles", isDirectory: true)
  }

  public static func workflowRootURL(appRootURL: URL, profileName: RielaAppProfileName) -> URL {
    profilesRootURL(appRootURL: appRootURL)
      .appendingPathComponent(profileName.rawValue, isDirectory: true)
      .appendingPathComponent("workflows", isDirectory: true)
  }

  public static func packageRootURL(appRootURL: URL, profileName: RielaAppProfileName) -> URL {
    profilesRootURL(appRootURL: appRootURL)
      .appendingPathComponent(profileName.rawValue, isDirectory: true)
      .appendingPathComponent("packages", isDirectory: true)
  }

  public static func defaultWorkflowRootURL(
    profileName: RielaAppProfileName = .default,
    homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> URL {
    workflowRootURL(appRootURL: defaultAppRootURL(homeDirectory: homeDirectory), profileName: profileName)
  }

  public static func defaultPackageRootURL(
    profileName: RielaAppProfileName = .default,
    homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> URL {
    packageRootURL(appRootURL: defaultAppRootURL(homeDirectory: homeDirectory), profileName: profileName)
  }
}

public struct RielaAppDaemonWorkflowState: Codable, Equatable, Sendable {
  public var version: Int
  public var preferences: [String: RielaAppDaemonWorkflowPreference]
  public var workflowDirectories: [String]
  public var projectDirectories: [String]

  private enum CodingKeys: String, CodingKey {
    case version
    case preferences
    case workflowDirectories
    case projectDirectories
  }

  public init(
    version: Int = 1,
    preferences: [String: RielaAppDaemonWorkflowPreference] = [:],
    workflowDirectories: [String] = [],
    projectDirectories: [String] = []
  ) {
    self.version = version
    self.preferences = preferences
    self.workflowDirectories = workflowDirectories
    self.projectDirectories = projectDirectories
  }

  public func preference(for identity: String) -> RielaAppDaemonWorkflowPreference {
    preferences[identity] ?? RielaAppDaemonWorkflowPreference(identity: identity)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
    preferences = try container.decodeIfPresent(
      [String: RielaAppDaemonWorkflowPreference].self,
      forKey: .preferences
    ) ?? [:]
    workflowDirectories = try container.decodeIfPresent([String].self, forKey: .workflowDirectories) ?? []
    projectDirectories = try container.decodeIfPresent([String].self, forKey: .projectDirectories) ?? []
  }

  public func containsWorkflowDirectory(_ path: String) -> Bool {
    let normalizedPath = Self.normalizedDirectory(path)
    return workflowDirectories.contains { Self.normalizedDirectory($0) == normalizedPath }
  }

  public mutating func addWorkflowDirectory(_ path: String) {
    let normalizedPath = Self.normalizedDirectory(path)
    guard !workflowDirectories.contains(where: { Self.normalizedDirectory($0) == normalizedPath }) else {
      return
    }
    workflowDirectories.append(normalizedPath)
    workflowDirectories.sort()
  }

  public mutating func removeWorkflowDirectory(_ path: String) {
    let normalizedPath = Self.normalizedDirectory(path)
    workflowDirectories.removeAll { Self.normalizedDirectory($0) == normalizedPath }
  }

  public func containsProjectDirectory(_ path: String) -> Bool {
    let normalizedPath = Self.normalizedDirectory(path)
    return projectDirectories.contains { Self.normalizedDirectory($0) == normalizedPath }
  }

  public func projectDirectory(containing path: String) -> String? {
    let normalizedPath = Self.normalizedDirectory(path)
    return projectDirectories.first { projectDirectory in
      Self.path(normalizedPath, isContainedIn: Self.normalizedDirectory(projectDirectory))
    }
  }

  public mutating func addProjectDirectory(_ path: String) {
    let normalizedPath = Self.normalizedDirectory(path)
    guard !projectDirectories.contains(where: { Self.normalizedDirectory($0) == normalizedPath }) else {
      return
    }
    projectDirectories.append(normalizedPath)
    projectDirectories.sort()
  }

  public mutating func removeProjectDirectory(_ path: String) {
    let normalizedPath = Self.normalizedDirectory(path)
    projectDirectories.removeAll { Self.normalizedDirectory($0) == normalizedPath }
  }

  public static func normalizedDirectory(_ path: String) -> String {
    URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
  }

  public static func path(_ path: String, isContainedIn rootPath: String) -> Bool {
    let normalizedPath = normalizedDirectory(path)
    let normalizedRoot = normalizedDirectory(rootPath)
    return normalizedPath == normalizedRoot || normalizedPath.hasPrefix(normalizedRoot + "/")
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
    let loadURL = ([stateURL] + legacyStateURLs).first { FileManager.default.fileExists(atPath: $0.path) }
    guard let loadURL, let data = try? Data(contentsOf: loadURL) else {
      return RielaAppDaemonWorkflowState()
    }
    return (try? JSONDecoder().decode(RielaAppDaemonWorkflowState.self, from: data)) ?? RielaAppDaemonWorkflowState()
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

public struct RielaAppDaemonWorkflowDiscovery: Sendable {
  private struct MinimalWorkflow: Decodable {
    var workflowId: String
  }

  private struct EventBinding: Decodable {
    var enabled: Bool?
    var sourceId: String
    var workflowName: String?
  }

  private struct EventSource: Decodable {
    var id: String
    var kind: String
  }

  public var homeDirectory: URL
  public var projectRoots: [URL]

  public init(
    homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
    projectRoot: URL? = nil,
    projectRoots: [URL] = []
  ) {
    self.homeDirectory = homeDirectory
    self.projectRoots = Self.uniqueProjectRoots(([projectRoot].compactMap { $0 } + projectRoots))
  }

  public func discoverUserDaemonWorkflows(
    appWorkflowRoot: URL? = nil,
    appPackageRoot: URL? = nil,
    projectDirectories: [String] = [],
    additionalWorkflowDirectories: [String] = []
  ) -> [RielaAppDaemonWorkflowCandidate] {
    var candidates: [RielaAppDaemonWorkflowCandidate] = []
    let effectiveProjectRoots = Self.uniqueProjectRoots(projectRoots + projectDirectories.map {
      URL(fileURLWithPath: $0, isDirectory: true)
    })
    if let appWorkflowRoot {
      candidates.append(contentsOf: discoverAppWorkflowDirectories(root: appWorkflowRoot))
    }
    if let appPackageRoot {
      candidates.append(contentsOf: discoverAppPackageWorkflows(root: appPackageRoot))
    }
    for projectRoot in effectiveProjectRoots {
      candidates.append(contentsOf: discoverProjectWorkflowDirectories(projectRoot: projectRoot))
      candidates.append(contentsOf: discoverProjectPackageWorkflows(projectRoot: projectRoot))
    }
    candidates.append(contentsOf: discoverUserWorkflowDirectories())
    candidates.append(contentsOf: discoverUserPackageWorkflows())
    candidates.append(contentsOf: discoverSelectedWorkflowDirectories(additionalWorkflowDirectories))
    return Dictionary(grouping: candidates, by: \.id)
      .compactMap { _, values in values.first }
      .sorted { lhs, rhs in
        lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
      }
  }

  public func discoverSelectedWorkflowDirectory(_ path: String) -> RielaAppDaemonWorkflowCandidate? {
    let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    return candidate(
      workflowDirectory: directory,
      sourceDescription: "selected workflow",
      identityPrefix: "selected-workflow",
      requiresLiveEventSource: false,
      usesPathIdentity: true
    )
  }

  public func discoverAppWorkflowDirectory(_ path: String) -> RielaAppDaemonWorkflowCandidate? {
    let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    return candidate(
      workflowDirectory: directory,
      sourceDescription: "RielaApp workflow",
      identityPrefix: "app-workflow",
      requiresLiveEventSource: false
    )
  }

  public func discoverAppPackageDirectory(_ path: String) -> RielaAppDaemonWorkflowCandidate? {
    let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    return discoverPackageWorkflows(
      root: directory.deletingLastPathComponent(),
      sourceDescription: "RielaApp package",
      identityPrefix: "app-package"
    ).first { $0.packageDirectory == directory.path }
  }

  private func discoverSelectedWorkflowDirectories(_ paths: [String]) -> [RielaAppDaemonWorkflowCandidate] {
    paths.compactMap(discoverSelectedWorkflowDirectory)
  }

  private func discoverUserWorkflowDirectories() -> [RielaAppDaemonWorkflowCandidate] {
    let root = homeDirectory.appendingPathComponent(".riela/workflows", isDirectory: true)
    return discoverWorkflowDirectories(
      root: root,
      sourceDescription: "user workflow",
      identityPrefix: "user-workflow"
    )
  }

  private func discoverAppWorkflowDirectories(root: URL) -> [RielaAppDaemonWorkflowCandidate] {
    discoverWorkflowDirectories(
      root: root,
      sourceDescription: "RielaApp workflow",
      identityPrefix: "app-workflow"
    )
  }

  private func discoverProjectWorkflowDirectories(projectRoot: URL) -> [RielaAppDaemonWorkflowCandidate] {
    let root = projectRoot.appendingPathComponent(".riela/workflows", isDirectory: true)
    return discoverWorkflowDirectories(
      root: root,
      sourceDescription: "project workflow",
      identityPrefix: "project-workflow:\(projectRoot.path)"
    )
  }

  private func discoverWorkflowDirectories(
    root: URL,
    sourceDescription: String,
    identityPrefix: String
  ) -> [RielaAppDaemonWorkflowCandidate] {
    let directories = directoryChildren(root)
    return directories.compactMap { directory in
      candidate(
        workflowDirectory: directory,
        sourceDescription: sourceDescription,
        identityPrefix: identityPrefix,
        requiresLiveEventSource: false
      )
    }
  }

  private func discoverUserPackageWorkflows() -> [RielaAppDaemonWorkflowCandidate] {
    let root = homeDirectory.appendingPathComponent(".riela/packages", isDirectory: true)
    return discoverPackageWorkflows(
      root: root,
      sourceDescription: "user package",
      identityPrefix: "user-package"
    )
  }

  private func discoverAppPackageWorkflows(root: URL) -> [RielaAppDaemonWorkflowCandidate] {
    discoverPackageWorkflows(
      root: root,
      sourceDescription: "RielaApp package",
      identityPrefix: "app-package"
    )
  }

  private func discoverProjectPackageWorkflows(projectRoot: URL) -> [RielaAppDaemonWorkflowCandidate] {
    let root = projectRoot.appendingPathComponent(".riela/packages", isDirectory: true)
    return discoverPackageWorkflows(
      root: root,
      sourceDescription: "project package",
      identityPrefix: "project-package:\(projectRoot.path)"
    )
  }

  private func discoverPackageWorkflows(
    root: URL,
    sourceDescription: String,
    identityPrefix: String
  ) -> [RielaAppDaemonWorkflowCandidate] {
    return directoryChildren(root).compactMap { packageDirectory in
      let manifestURL = packageDirectory.appendingPathComponent(WorkflowPackageArchiveManager.manifestFileName)
      guard
        let data = try? Data(contentsOf: manifestURL),
        let manifest = try? JSONDecoder().decode(WorkflowPackageManifest.self, from: data),
        manifest.kind == .workflow
      else {
        return nil
      }
      guard let workflowRelativePath = WorkflowPackageManifestValidator.normalizePackageRelativePath(
        manifest.workflowDirectory ?? "."
      ) else {
        return nil
      }
      let workflowDirectory = packageDirectory
        .appendingPathComponent(workflowRelativePath, isDirectory: true)
        .standardizedFileURL
      guard RielaAppDaemonWorkflowState.path(
        workflowDirectory.resolvingSymlinksInPath().path,
        isContainedIn: packageDirectory.resolvingSymlinksInPath().path
      ) else {
        return nil
      }
      return candidate(
        workflowDirectory: workflowDirectory,
        packageDirectory: packageDirectory,
        packageName: manifest.name,
        sourceDescription: sourceDescription,
        identityPrefix: identityPrefix,
        requiresLiveEventSource: false
      )
    }
  }

  private func candidate(
    workflowDirectory: URL,
    packageDirectory: URL? = nil,
    packageName: String? = nil,
    sourceDescription: String,
    identityPrefix: String,
    requiresLiveEventSource: Bool,
    usesPathIdentity: Bool = false
  ) -> RielaAppDaemonWorkflowCandidate? {
    let workflowURL = workflowDirectory.appendingPathComponent("workflow.json")
    guard
      let data = try? Data(contentsOf: workflowURL),
      let workflow = try? JSONDecoder().decode(MinimalWorkflow.self, from: data)
    else {
      return nil
    }
    let eventRootAndSources = eventRoots(workflowDirectory: workflowDirectory, packageDirectory: packageDirectory)
      .lazy
      .compactMap { eventRoot -> (URL, [RielaAppDaemonEventSourceSummary])? in
        let eventSources = daemonEventSources(eventRoot: eventRoot, workflowId: workflow.workflowId)
        return eventSources.isEmpty ? nil : (eventRoot, eventSources)
      }
      .first
    if requiresLiveEventSource, eventRootAndSources == nil {
      return nil
    }
    let identity = if usesPathIdentity {
      "\(identityPrefix):\(workflowDirectory.path)"
    } else {
      "\(identityPrefix)\(packageName.map { ":\($0)" } ?? ""):\(workflow.workflowId)"
    }
    return RielaAppDaemonWorkflowCandidate(
      id: identity,
      workflowId: workflow.workflowId,
      displayName: workflow.workflowId,
      sourceDescription: sourceDescription,
      workflowDirectory: workflowDirectory.path,
      packageDirectory: packageDirectory?.path,
      workingDirectory: workflowDirectory.deletingLastPathComponent().path,
      eventRoot: eventRootAndSources?.0.path,
      eventSources: eventRootAndSources?.1 ?? []
    )
  }

  private func daemonEventSources(eventRoot: URL, workflowId: String) -> [RielaAppDaemonEventSourceSummary] {
    let sources = decodeDirectory(eventRoot.appendingPathComponent("sources", isDirectory: true), as: EventSource.self)
    let bindings = decodeDirectory(eventRoot.appendingPathComponent("bindings", isDirectory: true), as: EventBinding.self)
      .filter { binding in
        binding.enabled != false && binding.workflowName == workflowId
      }
    let boundSourceIds = Set(bindings.map(\.sourceId))
    return sources
      .filter { boundSourceIds.contains($0.id) && Self.isDaemonSourceKind($0.kind) }
      .map { RielaAppDaemonEventSourceSummary(id: $0.id, kind: $0.kind) }
      .sorted { $0.id < $1.id }
  }

  private func eventRoots(workflowDirectory: URL, packageDirectory: URL?) -> [URL] {
    var roots = [
      workflowDirectory.appendingPathComponent(".riela-events", isDirectory: true),
      workflowDirectory.appendingPathComponent("event-templates/.riela-events", isDirectory: true)
    ]
    if let packageDirectory {
      roots.append(packageDirectory.appendingPathComponent(".riela-events", isDirectory: true))
      roots.append(packageDirectory.appendingPathComponent("event-templates/.riela-events", isDirectory: true))
    }
    return roots.filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  private func directoryChildren(_ root: URL) -> [URL] {
    guard let children = try? FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }
    return children.filter { url in
      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
  }

  private func decodeDirectory<T: Decodable>(_ directory: URL, as type: T.Type) -> [T] {
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }
    return files
      .filter { $0.pathExtension == "json" }
      .compactMap { file in
        guard let data = try? Data(contentsOf: file) else {
          return nil
        }
        return try? JSONDecoder().decode(type, from: data)
      }
  }

  public static func isDaemonSourceKind(_ rawKind: String) -> Bool {
    EventSourceKind(rawValue: rawKind).supportsLiveEventServe
  }

  private static func uniqueProjectRoots(_ roots: [URL]) -> [URL] {
    var seen = Set<String>()
    var unique: [URL] = []
    for root in roots {
      let normalized = root.standardizedFileURL
      guard !seen.contains(normalized.path) else {
        continue
      }
      seen.insert(normalized.path)
      unique.append(normalized)
    }
    return unique
  }
}

@MainActor
public final class RielaAppDaemonWorkflowRuntime {
  public struct RuntimeSnapshot: Equatable {
    public var status: WorkflowServeStatus
    public var detail: String

    public init(status: WorkflowServeStatus, detail: String) {
      self.status = status
      self.detail = detail
    }
  }

  private struct RunningWorkflow {
    var candidate: RielaAppDaemonWorkflowCandidate
    var controller: WorkflowServingController
    var snapshot: RuntimeSnapshot
    var monitorTask: Task<Void, Never>?
  }

  private let eventSourceFactory: any WorkflowServeEventSourceFactory
  private let monitorIntervalNanoseconds: UInt64
  private var runningWorkflows: [String: RunningWorkflow] = [:]

  public init(
    eventSourceFactory: any WorkflowServeEventSourceFactory = RielaAppDaemonProcessEventSourceFactory(),
    monitorIntervalNanoseconds: UInt64 = 2_000_000_000
  ) {
    self.eventSourceFactory = eventSourceFactory
    self.monitorIntervalNanoseconds = monitorIntervalNanoseconds
  }

  public func snapshot(for identity: String) -> RuntimeSnapshot {
    runningWorkflows[identity]?.snapshot ?? RuntimeSnapshot(status: .stopped, detail: "Inactive")
  }

  public func start(_ candidate: RielaAppDaemonWorkflowCandidate) async {
    if runningWorkflows[candidate.id]?.snapshot.status == .running {
      return
    }
    await startController(candidate, monitorTask: nil)
    scheduleMonitorIfNeeded(for: candidate.id)
  }

  public func refresh(identity: String) async {
    guard let running = runningWorkflows[identity] else {
      return
    }
    let state = await running.controller.currentState()
    runningWorkflows[identity]?.snapshot = snapshot(from: state)
    guard shouldRestart(state) else {
      return
    }
    _ = try? await running.controller.stop()
    await startController(running.candidate, monitorTask: running.monitorTask)
  }

  private func startController(
    _ candidate: RielaAppDaemonWorkflowCandidate,
    monitorTask: Task<Void, Never>?
  ) async {
    let controller = WorkflowServingController(dependencies: WorkflowServingDependencies(
      eventSourceFactory: eventSourceFactory
    ))
    runningWorkflows[candidate.id] = RunningWorkflow(
      candidate: candidate,
      controller: controller,
      snapshot: RuntimeSnapshot(status: .starting, detail: "Starting"),
      monitorTask: monitorTask
    )
    do {
      let state = try await controller.start(WorkflowServeStartRequest(
        selection: candidate.serveSelection,
        server: RielaServerConfiguration(port: Self.port(for: candidate.id)),
        workingDirectory: candidate.workingDirectory,
        sessionStoreRoot: defaultSessionStoreRoot(),
        eventRoot: candidate.eventRoot,
        startsEventSources: candidate.startsEventSources
      ))
      runningWorkflows[candidate.id]?.snapshot = snapshot(from: state)
    } catch {
      runningWorkflows[candidate.id]?.snapshot = RuntimeSnapshot(status: .failed, detail: "\(error)")
    }
  }

  public func stop(identity: String) async {
    guard let running = runningWorkflows[identity] else {
      return
    }
    running.monitorTask?.cancel()
    do {
      let state = try await running.controller.stop()
      runningWorkflows[identity]?.snapshot = snapshot(from: state)
    } catch {
      runningWorkflows[identity]?.snapshot = RuntimeSnapshot(status: .failed, detail: "\(error)")
      return
    }
    runningWorkflows.removeValue(forKey: identity)
  }

  private func scheduleMonitorIfNeeded(for identity: String) {
    guard monitorIntervalNanoseconds > 0, runningWorkflows[identity]?.monitorTask == nil else {
      return
    }
    let interval = monitorIntervalNanoseconds
    let task = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: interval)
        await self?.refresh(identity: identity)
      }
    }
    runningWorkflows[identity]?.monitorTask = task
  }

  private func shouldRestart(_ state: WorkflowServeState) -> Bool {
    guard state.status == .running, let generation = state.generation else {
      return false
    }
    return generation.eventSources.contains { $0.status != "running" }
  }

  private func snapshot(from state: WorkflowServeState) -> RuntimeSnapshot {
    let detail: String
    if let generation = state.generation {
      let sources = generation.eventSources.map { source in
        source.status == "running" ? source.sourceId : "\(source.sourceId):\(source.status)"
      }.joined(separator: ", ")
      detail = sources.isEmpty ? generation.endpoint : "\(generation.endpoint) [\(sources)]"
    } else {
      detail = state.diagnostics.first?.message ?? state.status.rawValue
    }
    return RuntimeSnapshot(status: state.status, detail: detail)
  }

  private func defaultSessionStoreRoot() -> String {
    URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent(".riela/sessions", isDirectory: true)
      .path
  }

  private static func port(for identity: String) -> Int {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in identity.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return 18_000 + Int(hash % 20_000)
  }
}
#endif
