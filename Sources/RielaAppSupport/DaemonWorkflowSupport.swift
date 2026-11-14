import Foundation
import RielaAddons
import RielaCore
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

public struct RielaAppEnvRequirement: Equatable, Sendable {
  public var name: String
  public var description: String?
  public var secret: Bool

  public init(name: String, description: String? = nil, secret: Bool = false) {
    self.name = name
    self.description = description
    self.secret = secret
  }
}

public enum RielaAppDaemonWorkflowSourceScope: String, Equatable, Sendable {
  case profile
  case external
}

public struct RielaAppDaemonWorkflowCandidate: Identifiable, Equatable, Sendable {
  public var id: String
  public var sourceIdentity: String
  public var managementId: String?
  public var workflowId: String
  public var displayName: String
  public var description: String
  public var sourceDescription: String
  public var sourceScope: RielaAppDaemonWorkflowSourceScope
  public var workflowDirectory: String
  public var packageDirectory: String?
  public var workingDirectory: String
  public var eventRoot: String?
  public var eventSources: [RielaAppDaemonEventSourceSummary]
  public var requiredEnvironment: [RielaAppEnvRequirement]

  public init(
    id: String,
    sourceIdentity: String? = nil,
    managementId: String? = nil,
    workflowId: String,
    displayName: String,
    sourceDescription: String,
    sourceScope: RielaAppDaemonWorkflowSourceScope = .external,
    workflowDirectory: String,
    packageDirectory: String? = nil,
    workingDirectory: String,
    eventRoot: String?,
    eventSources: [RielaAppDaemonEventSourceSummary],
    requiredEnvironment: [RielaAppEnvRequirement] = [],
    description: String = ""
  ) {
    self.id = id
    self.sourceIdentity = sourceIdentity ?? id
    self.managementId = managementId
    self.workflowId = workflowId
    self.displayName = displayName
    self.description = description
    self.sourceDescription = sourceDescription
    self.sourceScope = sourceScope
    self.workflowDirectory = workflowDirectory
    self.packageDirectory = packageDirectory
    self.workingDirectory = workingDirectory
    self.eventRoot = eventRoot
    self.eventSources = eventSources
    self.requiredEnvironment = requiredEnvironment
  }

  public var eventSourceSummary: String {
    let summary = eventSources.map { "\($0.id):\($0.kind)" }.joined(separator: ", ")
    return summary.isEmpty ? "None" : summary
  }

  public var sourceDirectory: String {
    packageDirectory ?? workflowDirectory
  }

  public var isRielaAppProfileScoped: Bool {
    sourceScope == .profile
  }

  public var serveSelection: WorkflowServeSelection {
    .directDirectory(workflowDirectory, identifier: workflowId)
  }

  public var startsEventSources: Bool {
    eventRoot != nil && !eventSources.isEmpty
  }

  public var isManagedInstance: Bool {
    managementId != nil
  }

  public func managedInstance(identity: String, displayName: String? = nil) -> RielaAppDaemonWorkflowCandidate {
    RielaAppDaemonWorkflowCandidate(
      id: identity,
      sourceIdentity: id,
      managementId: identity,
      workflowId: workflowId,
      displayName: displayName?.isEmpty == false ? displayName ?? self.displayName : self.displayName,
      sourceDescription: sourceDescription,
      sourceScope: sourceScope,
      workflowDirectory: workflowDirectory,
      packageDirectory: packageDirectory,
      workingDirectory: workingDirectory,
      eventRoot: eventRoot,
      eventSources: eventSources,
      requiredEnvironment: requiredEnvironment,
      description: description
    )
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
    try createProfileDirectories(profileName)
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

  public func prepareInitialProfile(_ profileName: RielaAppProfileName, persistsSelection: Bool) throws {
    if persistsSelection {
      try saveActiveProfileName(profileName)
    } else {
      try createProfileDirectories(profileName)
    }
  }

  public func createProfileDirectories(_ profileName: RielaAppProfileName) throws {
    try FileManager.default.createDirectory(
      at: Self.workflowRootURL(appRootURL: appRootURL, profileName: profileName),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: Self.packageRootURL(appRootURL: appRootURL, profileName: profileName),
      withIntermediateDirectories: true
    )
  }

  public func removeProfile(_ profileName: RielaAppProfileName) throws {
    let profileURL = Self.profilesRootURL(appRootURL: appRootURL)
      .appendingPathComponent(profileName.rawValue, isDirectory: true)
    guard FileManager.default.fileExists(atPath: profileURL.path) else {
      return
    }
    try FileManager.default.removeItem(at: profileURL)
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

  /// The profile's workflow storage: imported workflows (`workflows`),
  /// packages (`packages`) and the app-owned mutable registry
  /// (`temporary-workflows`, `workflow-state`). `storageDirectory` is the
  /// profile's configured override; the default lives inside the profile.
  public static func workflowStorageRootURL(
    appRootURL: URL,
    profileName: RielaAppProfileName,
    storageDirectory: String? = nil
  ) -> URL {
    if let storageDirectory = storageDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
       !storageDirectory.isEmpty {
      return URL(fileURLWithPath: storageDirectory, isDirectory: true).standardizedFileURL
    }
    return profilesRootURL(appRootURL: appRootURL)
      .appendingPathComponent(profileName.rawValue, isDirectory: true)
  }

  public static func workflowRootURL(
    appRootURL: URL,
    profileName: RielaAppProfileName,
    storageDirectory: String? = nil
  ) -> URL {
    workflowStorageRootURL(appRootURL: appRootURL, profileName: profileName, storageDirectory: storageDirectory)
      .appendingPathComponent("workflows", isDirectory: true)
  }

  public static func packageRootURL(
    appRootURL: URL,
    profileName: RielaAppProfileName,
    storageDirectory: String? = nil
  ) -> URL {
    workflowStorageRootURL(appRootURL: appRootURL, profileName: profileName, storageDirectory: storageDirectory)
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
  public var workflowRepositories: [RielaAppWorkflowRepositoryReference]
  public var assistant: RielaAppAssistantSettings
  public var backends: [String: BackendCapabilityDeclaration]
  public var hostTraits: [HostTrait]
  /// Overrides the profile's workflow storage root; nil keeps the default
  /// inside the profile directory (see `RielaAppProfileStore.workflowStorageRootURL`).
  public var workflowStorageDirectory: String?

  private enum CodingKeys: String, CodingKey {
    case version
    case preferences
    case workflowDirectories
    case projectDirectories
    case workflowRepositories
    case assistant
    case backends
    case hostTraits
    case workflowStorageDirectory
  }

  public init(
    version: Int = 1,
    preferences: [String: RielaAppDaemonWorkflowPreference] = [:],
    workflowDirectories: [String] = [],
    projectDirectories: [String] = [],
    workflowRepositories: [RielaAppWorkflowRepositoryReference] = [],
    assistant: RielaAppAssistantSettings = RielaAppAssistantSettings(),
    backends: [String: BackendCapabilityDeclaration] = [:],
    hostTraits: [HostTrait] = [],
    workflowStorageDirectory: String? = nil
  ) {
    self.version = version
    self.preferences = preferences
    self.workflowDirectories = workflowDirectories
    self.projectDirectories = projectDirectories
    self.workflowRepositories = workflowRepositories
    self.assistant = assistant
    self.backends = backends
    self.hostTraits = Array(Set(hostTraits)).sorted()
    self.workflowStorageDirectory = workflowStorageDirectory
  }

  public func preference(for identity: String) -> RielaAppDaemonWorkflowPreference {
    preferences[identity] ?? RielaAppDaemonWorkflowPreference(identity: identity)
  }

  public func managedCandidates(
    from sourceCandidates: [RielaAppDaemonWorkflowCandidate]
  ) -> [RielaAppDaemonWorkflowCandidate] {
    workflowInstances(from: sourceCandidates).map(\.candidate)
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
    workflowRepositories = try container.decodeIfPresent(
      [RielaAppWorkflowRepositoryReference].self,
      forKey: .workflowRepositories
    ) ?? []
    assistant = try container.decodeIfPresent(RielaAppAssistantSettings.self, forKey: .assistant)
      ?? RielaAppAssistantSettings()
    backends = try container.decodeIfPresent(
      [String: BackendCapabilityDeclaration].self,
      forKey: .backends
    ) ?? [:]
    hostTraits = (try container.decodeIfPresent([HostTrait].self, forKey: .hostTraits) ?? []).sorted()
    workflowStorageDirectory = try container.decodeIfPresent(String.self, forKey: .workflowStorageDirectory)
  }

  public func containsWorkflowRepository(id: String) -> Bool {
    workflowRepositories.contains { $0.id == id }
  }

  public mutating func addWorkflowRepository(_ repository: RielaAppWorkflowRepositoryReference) {
    guard !containsWorkflowRepository(id: repository.id) else {
      return
    }
    workflowRepositories.append(repository)
    workflowRepositories.sort { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
  }

  public mutating func removeWorkflowRepository(id: String) {
    workflowRepositories.removeAll { $0.id == id }
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

public struct RielaAppDaemonWorkflowDiscovery: Sendable {
  private struct MinimalWorkflow: Decodable {
    var workflowId: String
    var description: String?
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

  public var projectRoots: [URL]

  /// RielaApp discovers only its own profile storage plus explicitly added
  /// projects and directories; the CLI's `~/.riela/{workflows,packages}` stay
  /// out of the app so the two never share definitions implicitly.
  public init(
    projectRoot: URL? = nil,
    projectRoots: [URL] = []
  ) {
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
      sourceDescription: "profile workflow",
      sourceScope: .profile,
      identityPrefix: "app-workflow",
      requiresLiveEventSource: false
    )
  }

  public func discoverAppPackageDirectory(_ path: String) -> RielaAppDaemonWorkflowCandidate? {
    let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    return discoverPackageWorkflows(
      root: directory.deletingLastPathComponent(),
      sourceDescription: "profile package",
      sourceScope: .profile,
      identityPrefix: "app-package"
    ).first { $0.packageDirectory == directory.path }
  }

  private func discoverSelectedWorkflowDirectories(_ paths: [String]) -> [RielaAppDaemonWorkflowCandidate] {
    paths.compactMap(discoverSelectedWorkflowDirectory)
  }

  private func discoverAppWorkflowDirectories(root: URL) -> [RielaAppDaemonWorkflowCandidate] {
    discoverWorkflowDirectories(
      root: root,
      sourceDescription: "profile workflow",
      sourceScope: .profile,
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
    sourceScope: RielaAppDaemonWorkflowSourceScope = .external,
    identityPrefix: String
  ) -> [RielaAppDaemonWorkflowCandidate] {
    let directories = directoryChildren(root)
    return directories.compactMap { directory in
      candidate(
        workflowDirectory: directory,
        sourceDescription: sourceDescription,
        sourceScope: sourceScope,
        identityPrefix: identityPrefix,
        requiresLiveEventSource: false
      )
    }
  }

  private func discoverAppPackageWorkflows(root: URL) -> [RielaAppDaemonWorkflowCandidate] {
    discoverPackageWorkflows(
      root: root,
      sourceDescription: "profile package",
      sourceScope: .profile,
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
    sourceScope: RielaAppDaemonWorkflowSourceScope = .external,
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
        requiredEnvironment: manifest.requiredEnvironmentForRielaApp,
        sourceDescription: sourceDescription,
        sourceScope: sourceScope,
        identityPrefix: identityPrefix,
        requiresLiveEventSource: false
      )
    }
  }

  private func candidate(
    workflowDirectory: URL,
    packageDirectory: URL? = nil,
    packageName: String? = nil,
    requiredEnvironment: [RielaAppEnvRequirement] = [],
    sourceDescription: String,
    sourceScope: RielaAppDaemonWorkflowSourceScope = .external,
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
      sourceScope: sourceScope,
      workflowDirectory: workflowDirectory.path,
      packageDirectory: packageDirectory?.path,
      workingDirectory: workflowDirectory.deletingLastPathComponent().path,
      eventRoot: eventRootAndSources?.0.path,
      eventSources: eventRootAndSources?.1 ?? [],
      requiredEnvironment: RielaAppWorkflowEnvironmentRequirements.requiredEnvironment(
        workflowDirectory: workflowDirectory,
        packageRequirements: requiredEnvironment
      ),
      description: workflow.description ?? ""
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

  public static func daemonSourceKinds() -> [String] {
    [
      EventSourceKind.discordGateway,
      .slackGateway,
      .telegramGateway,
      .cron,
      .webhooky
    ]
    .filter(\.supportsLiveEventServe)
    .map(\.rawValue)
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
    var configuration: WorkflowServeRuntimeConfiguration
    var server: RielaServerConfiguration
    var sessionStoreRoot: String
    var controller: WorkflowServingController
    var snapshot: RuntimeSnapshot
    var endpoint: String?
    var monitorTask: Task<Void, Never>?
    /// Managed names of the private channel the child was started with; nil
    /// for a child without a channel (or one that has not been prepared yet).
    var channelNames: [String]?
  }

  private let eventSourceFactory: any WorkflowServeEventSourceFactory
  private let monitorIntervalNanoseconds: UInt64
  private let environmentStore: RuntimeEnvironmentSnapshotStore
  private var environmentStatuses: [RuntimeEnvironmentScope: RuntimeEnvironmentStatus] = [:]
  private var runningWorkflows: [String: RunningWorkflow] = [:]

  public init(
    eventSourceFactory: any WorkflowServeEventSourceFactory = RielaAppDaemonProcessEventSourceFactory(),
    monitorIntervalNanoseconds: UInt64 = 2_000_000_000,
    environmentStore: RuntimeEnvironmentSnapshotStore = RuntimeEnvironmentSnapshotStore()
  ) {
    self.eventSourceFactory = eventSourceFactory
    self.monitorIntervalNanoseconds = monitorIntervalNanoseconds
    self.environmentStore = environmentStore
  }
  public func snapshot(for identity: String) -> RuntimeSnapshot {
    runningWorkflows[identity]?.snapshot ?? RuntimeSnapshot(status: .stopped, detail: "Inactive")
  }

  public func prepareEnvironment(
    for candidate: RielaAppDaemonWorkflowCandidate,
    configuration: WorkflowServeRuntimeConfiguration
  ) async throws -> RuntimeEnvironmentSnapshot {
    let scope = try environmentScope(identity: candidate.id, profile: configuration.environmentProfile ?? defaultEnvironmentProfile(identity: candidate.id))
    do {
      let snapshot = try await environmentStore.prepare(
        scope: scope, configuration: configuration.environmentResolution ?? RuntimeEnvironmentConfiguration(),
        requiredNames: candidate.requiredEnvironment.map(\.name), baseEnvironment: configuration.inheritedEnvironment
      )
      environmentStatuses[scope] = await environmentStore.status(scope: scope)
      return snapshot
    } catch {
      environmentStatuses[scope] = await environmentStore.status(scope: scope)
      throw error
    }
  }

  public func cachedEnvironmentStatus(identity: String, profile: String) -> RuntimeEnvironmentStatus {
    guard let scope = try? environmentScope(identity: identity, profile: profile) else {
      return RuntimeEnvironmentStatus(readiness: .failed, lastError: .invalidConfiguration)
    }
    return environmentStatuses[scope] ?? RuntimeEnvironmentStatus()
  }

  public func environmentStatus(identity: String, profile: String) async -> RuntimeEnvironmentStatus {
    guard let scope = try? environmentScope(identity: identity, profile: profile) else {
      return RuntimeEnvironmentStatus(readiness: .failed, lastError: .invalidConfiguration)
    }
    let status = await environmentStore.status(scope: scope)
    environmentStatuses[scope] = status
    return status
  }

  /// Reloads the instance's loaders and, when a channel child is running,
  /// installs the new snapshot into it before publishing.
  ///
  /// Preconditions fail before the store or the child is touched:
  /// - a running child whose managed-name set would change (or a legacy child
  ///   without a channel that would gain managed names) needs a stop/start:
  ///   `environment_restart_required`;
  /// - a concurrent reload of the same scope: `environment_reload_in_progress`.
  /// A child that is (re)started or stopped while loaders run fails the reload
  /// with `environment_instance_changed`, so the store never publishes a
  /// generation the live child does not run.
  public func reloadEnvironment(
    for candidate: RielaAppDaemonWorkflowCandidate,
    configuration: WorkflowServeRuntimeConfiguration
  ) async throws -> RuntimeEnvironmentStatus {
    let scope = try environmentScope(identity: candidate.id, profile: configuration.environmentProfile ?? defaultEnvironmentProfile(identity: candidate.id))
    let identity = candidate.id
    let running = runningWorkflows[identity]
    let resolution = configuration.environmentResolution ?? RuntimeEnvironmentConfiguration()
    let requiredNames = candidate.requiredEnvironment.map(\.name)
    let requiresChannel = configuration.environmentResolution != nil || !requiredNames.isEmpty
    // Only an event-serve child holds managed values; a listener-only instance has none.
    if let running, running.snapshot.status == .running, running.candidate.startsEventSources {
      if let channelNames = running.channelNames {
        let nextNames = RuntimeEnvironmentSnapshotStore.managedNames(configuration: resolution, requiredNames: requiredNames)
        // The child validates every frame against its bootstrap names; a
        // different set would be rejected and the child reaped.
        guard nextNames == channelNames else { throw RuntimeEnvironmentError.restartRequired }
      } else if requiresChannel {
        // A legacy child has no private control pipe.
        throw RuntimeEnvironmentError.restartRequired
      }
    }
    let captured = running?.controller
    // A live (or starting) child keeps running the previous snapshot if loading
    // fails, so the store keeps mirroring it even when the descriptor changed.
    let liveChild = running.map { $0.snapshot.status == .running || $0.snapshot.status == .starting } ?? false
    do {
      let status = try await environmentStore.reload(
        scope: scope, configuration: resolution, requiredNames: requiredNames,
        baseEnvironment: configuration.inheritedEnvironment, retainPreviousOnFailure: liveChild,
        install: { [weak self] snapshot in
          guard let self else { throw RuntimeEnvironmentError.instanceChanged }
          guard let target = try await self.liveChannelController(identity: identity, captured: captured, names: snapshot.names) else {
            return
          }
          do {
            try await target.updateRuntimeEnvironment(
              generation: snapshot.generation, names: snapshot.names, values: snapshot.runtimeEnvironment()
            )
          } catch let error as WorkflowServeRuntimeEnvironmentError {
            throw RuntimeEnvironmentError(rawValue: error.rawValue) ?? .sourceFailed
          }
        }
      )
      environmentStatuses[scope] = status
      if let live = runningWorkflows[identity], live.controller === captured {
        runningWorkflows[identity]?.configuration = configuration
      }
      return status
    } catch {
      environmentStatuses[scope] = await environmentStore.status(scope: scope)
      throw error
    }
  }

  /// Re-reads the live instance after loaders complete (the monitor or a start
  /// may have replaced the child while this reload was suspended).
  private func liveChannelController(
    identity: String, captured: WorkflowServingController?, names: [String]
  ) throws -> WorkflowServingController? {
    guard let live = runningWorkflows[identity], live.snapshot.status == .running || live.snapshot.status == .starting else {
      // No child holds any generation: publishing alone is consistent.
      return nil
    }
    // A replaced controller, or one still starting, owns a child that may have
    // been bootstrapped from the previous snapshot.
    guard let captured, live.controller === captured, live.snapshot.status == .running else {
      throw RuntimeEnvironmentError.instanceChanged
    }
    guard let channelNames = live.channelNames else { return nil }
    guard channelNames == names else { throw RuntimeEnvironmentError.restartRequired }
    return live.controller
  }

  /// Drops one instance's in-memory credentials and status (instance deleted).
  /// A running child keeps the values it already holds until it is stopped.
  public func evictEnvironment(identity: String, profile: String) async {
    guard let scope = try? environmentScope(identity: identity, profile: profile) else { return }
    environmentStatuses.removeValue(forKey: scope)
    await environmentStore.evict(scope: scope)
  }

  /// Drops every in-memory credential and status of one profile (profile switched away).
  public func evictEnvironment(profile: String) async {
    for scope in environmentStatuses.keys where scope.profile == profile { environmentStatuses.removeValue(forKey: scope) }
    await environmentStore.evict(profile: profile)
  }

  /// An unspecified profile means the instance's own profile, never a mismatch.
  private func defaultEnvironmentProfile(identity: String) -> String {
    #if os(macOS)
    if let profiled = RielaAppProfileInstanceIdentity(rawValue: identity) { return profiled.profileName.rawValue }
    #endif
    return "default"
  }

  private func environmentScope(identity: String, profile: String) throws -> RuntimeEnvironmentScope {
    guard !identity.isEmpty, !profile.isEmpty else { throw RuntimeEnvironmentError.invalidConfiguration }
    #if os(macOS)
    if let profiled = RielaAppProfileInstanceIdentity(rawValue: identity), profiled.profileName.rawValue != profile {
      throw RuntimeEnvironmentError.invalidConfiguration
    }
    #endif
    return RuntimeEnvironmentScope(profile: profile, instanceIdentity: identity)
  }

  public func noteAPIEndpoint(noteRoot: String) -> String? {
    let standardizedNoteRoot = URL(fileURLWithPath: noteRoot, isDirectory: true).standardizedFileURL.path
    return runningWorkflows.values.first { running in
      guard running.snapshot.status == .running,
            running.server.noteAPIEnabled,
            let servedNoteRoot = running.server.noteRoot else {
        return false
      }
      return URL(fileURLWithPath: servedNoteRoot, isDirectory: true).standardizedFileURL.path == standardizedNoteRoot
    }?.endpoint
  }

  public func start(
    _ candidate: RielaAppDaemonWorkflowCandidate,
    inheritedEnvironment: [String: String] = [:],
    defaultVariables: JSONObject = [:],
    nodePatch: JSONObject? = nil,
    server: RielaServerConfiguration = RielaServerConfiguration(),
    sessionStoreRoot: String? = nil
  ) async {
    if runningWorkflows[candidate.id]?.snapshot.status == .running {
      return
    }
    await startController(
      candidate,
      configuration: WorkflowServeRuntimeConfiguration(
        workingDirectory: candidate.workingDirectory,
        inheritedEnvironment: inheritedEnvironment,
        defaultVariables: defaultVariables,
        nodePatch: nodePatch
      ),
      server: server,
      sessionStoreRoot: sessionStoreRoot ?? Self.defaultSessionStoreRootPath,
      monitorTask: nil
    )
    scheduleMonitorIfNeeded(for: candidate.id)
  }
  public func start(
    _ candidate: RielaAppDaemonWorkflowCandidate,
    configuration: WorkflowServeRuntimeConfiguration,
    server: RielaServerConfiguration = RielaServerConfiguration(),
    sessionStoreRoot: String? = nil
  ) async {
    if runningWorkflows[candidate.id]?.snapshot.status == .running {
      return
    }
    var runtimeConfiguration = configuration
    if runtimeConfiguration.workingDirectory == nil {
      runtimeConfiguration.workingDirectory = candidate.workingDirectory
    }
    await startController(
      candidate, configuration: runtimeConfiguration, server: server,
      sessionStoreRoot: sessionStoreRoot ?? Self.defaultSessionStoreRootPath, monitorTask: nil
    )
    scheduleMonitorIfNeeded(for: candidate.id)
  }
  public func refresh(identity: String) async {
    guard let running = runningWorkflows[identity] else {
      return
    }
    let state = await running.controller.currentState()
    runningWorkflows[identity]?.snapshot = snapshot(from: state)
    runningWorkflows[identity]?.endpoint = state.generation?.endpoint
    guard shouldRestart(state) else {
      return
    }
    _ = try? await running.controller.stop()
    await startController(
      running.candidate,
      configuration: running.configuration,
      server: running.server,
      sessionStoreRoot: running.sessionStoreRoot,
      monitorTask: running.monitorTask
    )
  }

  private func startController(
    _ candidate: RielaAppDaemonWorkflowCandidate,
    configuration: WorkflowServeRuntimeConfiguration,
    server: RielaServerConfiguration,
    sessionStoreRoot: String,
    monitorTask: Task<Void, Never>?
  ) async {
    let controller = WorkflowServingController(dependencies: WorkflowServingDependencies(
      eventSourceFactory: eventSourceFactory
    ))
    var server = server
    server.port = Self.port(for: candidate.id)
    runningWorkflows[candidate.id] = RunningWorkflow(
      candidate: candidate,
      configuration: configuration,
      server: server,
      sessionStoreRoot: sessionStoreRoot,
      controller: controller,
      snapshot: RuntimeSnapshot(status: .starting, detail: "Starting"),
      endpoint: nil,
      monitorTask: monitorTask
    )
    do {
      let environment = try await prepareEnvironment(for: candidate, configuration: configuration)
      var preparedConfiguration = configuration
      if configuration.environmentResolution != nil || !environment.names.isEmpty {
        preparedConfiguration.runtimeEnvironmentValues = environment.runtimeEnvironment()
        preparedConfiguration.runtimeEnvironmentGeneration = environment.generation
        preparedConfiguration.runtimeEnvironmentNames = environment.names
        if candidate.startsEventSources, runningWorkflows[candidate.id]?.controller === controller {
          runningWorkflows[candidate.id]?.channelNames = environment.names
        }
      }
      let state = try await controller.start(WorkflowServeStartRequest(
        selection: candidate.serveSelection,
        server: server,
        configuration: preparedConfiguration,
        sessionStoreRoot: sessionStoreRoot,
        eventRoot: candidate.eventRoot,
        startsEventSources: candidate.startsEventSources
      ))
      runningWorkflows[candidate.id]?.snapshot = snapshot(from: state)
      runningWorkflows[candidate.id]?.endpoint = state.generation?.endpoint
    } catch {
      runningWorkflows[candidate.id]?.snapshot = RuntimeSnapshot(status: .failed, detail: "\(error)")
      runningWorkflows[candidate.id]?.endpoint = nil
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
      runningWorkflows[identity]?.endpoint = nil
    } catch {
      runningWorkflows[identity]?.snapshot = RuntimeSnapshot(status: .failed, detail: "\(error)")
      runningWorkflows[identity]?.endpoint = nil
      return
    }
    runningWorkflows.removeValue(forKey: identity)
  }

  public func stopAll() async {
    for identity in Array(runningWorkflows.keys) {
      await stop(identity: identity)
    }
  }

  private func scheduleMonitorIfNeeded(for identity: String) {
    guard monitorIntervalNanoseconds > 0, runningWorkflows[identity]?.monitorTask == nil else {
      return
    }
    let interval = monitorIntervalNanoseconds
    let task = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(nanoseconds: interval) } catch { return }
        guard !Task.isCancelled, let self else { return }
        await self.refresh(identity: identity)
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

  public static var defaultSessionStoreRootPath: String {
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

private extension WorkflowPackageManifest {
  var requiredEnvironmentForRielaApp: [RielaAppEnvRequirement] {
    environmentVariables.filter(\.required).map {
      RielaAppEnvRequirement(name: $0.name, description: $0.description, secret: $0.secret)
    }
  }
}
