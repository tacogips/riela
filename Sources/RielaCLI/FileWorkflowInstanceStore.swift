import Foundation
import RielaCore

public enum WorkflowInstanceScope: String, Codable, CaseIterable, Sendable {
  case project
  case user
  case all
}

public struct FileWorkflowInstanceStore: WorkflowInstanceStoring {
  public var fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public init(rootDirectory: String) {
    self.init(fileURL: URL(fileURLWithPath: rootDirectory, isDirectory: true).appendingPathComponent("instances.json"))
  }

  public static func defaultRootDirectory(
    scope: WorkflowInstanceScope,
    workingDirectory: String,
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
  ) -> String {
    switch scope {
    case .user:
      return URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(environment: environment), isDirectory: true)
        .appendingPathComponent(".riela", isDirectory: true)
        .path
    case .project, .all:
      return URL(fileURLWithPath: workingDirectory, isDirectory: true)
        .appendingPathComponent(".riela", isDirectory: true)
        .path
    }
  }

  public func list(workflowId: String? = nil) throws -> [WorkflowInstanceDefinition] {
    try load().instances
      .filter { workflowId == nil || $0.workflowId == workflowId }
      .sorted(by: instanceSort)
  }

  public func find(identity: String, workflowId: String? = nil) throws -> WorkflowInstanceDefinition? {
    let matches = try list(workflowId: workflowId).filter { $0.identity == identity }
    guard matches.count <= 1 else {
      throw WorkflowInstanceStoreError.ambiguousIdentity(identity, matches.map(\.workflowId).sorted())
    }
    return matches.first
  }

  public func save(_ instance: WorkflowInstanceDefinition) throws {
    try validateIdentity(instance.identity)
    var file = try load()
    if let index = file.instances.firstIndex(where: {
      $0.identity == instance.identity && $0.workflowId == instance.workflowId
    }) {
      file.instances[index] = instance
    } else {
      file.instances.append(instance)
    }
    file.instances.sort(by: instanceSort)
    try save(file)
  }

  public func remove(identity: String, workflowId: String? = nil) throws {
    var file = try load()
    let matches = file.instances.filter { $0.identity == identity && (workflowId == nil || $0.workflowId == workflowId) }
    guard !matches.isEmpty else {
      throw WorkflowInstanceStoreError.notFound(identity)
    }
    guard matches.count == 1 else {
      throw WorkflowInstanceStoreError.ambiguousIdentity(identity, matches.map(\.workflowId).sorted())
    }
    file.instances.removeAll { $0.identity == matches[0].identity && $0.workflowId == matches[0].workflowId }
    try save(file)
  }

  public func load() throws -> WorkflowInstanceStoreFile {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return WorkflowInstanceStoreFile()
    }
    do {
      let data = try Data(contentsOf: fileURL)
      return try JSONDecoder().decode(WorkflowInstanceStoreFile.self, from: data)
    } catch {
      let quarantineURL = corruptFileQuarantineURL(for: fileURL)
      _ = try? FileManager.default.moveItem(at: fileURL, to: quarantineURL)
      throw WorkflowInstanceStoreError.io("failed to load \(fileURL.path); corrupt file moved to \(quarantineURL.path)")
    }
  }

  public func save(_ file: WorkflowInstanceStoreFile) throws {
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(file).write(to: fileURL, options: .atomic)
    } catch let error as WorkflowInstanceStoreError {
      throw error
    } catch {
      throw WorkflowInstanceStoreError.io("failed to save \(fileURL.path): \(error)")
    }
  }

  public static func scopedStores(
    workingDirectory: String,
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
  ) -> [(scope: WorkflowInstanceScope, store: FileWorkflowInstanceStore)] {
    [
      (
        .project,
        FileWorkflowInstanceStore(rootDirectory: defaultRootDirectory(
          scope: .project,
          workingDirectory: workingDirectory,
          environment: environment
        ))
      ),
      (
        .user,
        FileWorkflowInstanceStore(rootDirectory: defaultRootDirectory(
          scope: .user,
          workingDirectory: workingDirectory,
          environment: environment
        ))
      )
    ]
  }

  private func validateIdentity(_ identity: String) throws {
    let trimmed = identity.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          trimmed.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
      throw WorkflowInstanceStoreError.invalidIdentity(identity)
    }
  }

  private func corruptFileQuarantineURL(for url: URL) -> URL {
    let baseURL = url.deletingLastPathComponent()
      .appendingPathComponent("\(url.lastPathComponent).corrupt")
    guard FileManager.default.fileExists(atPath: baseURL.path) else {
      return baseURL
    }
    return url.deletingLastPathComponent()
      .appendingPathComponent("\(url.lastPathComponent).corrupt-\(UUID().uuidString)")
  }

  private func instanceSort(_ lhs: WorkflowInstanceDefinition, _ rhs: WorkflowInstanceDefinition) -> Bool {
    if lhs.workflowId == rhs.workflowId {
      return lhs.identity < rhs.identity
    }
    return lhs.workflowId < rhs.workflowId
  }
}

public struct ScopedWorkflowInstanceStore: Sendable {
  public var project: FileWorkflowInstanceStore
  public var user: FileWorkflowInstanceStore
  public var appProfiles: AppProfileWorkflowInstanceStore

  public init(
    project: FileWorkflowInstanceStore,
    user: FileWorkflowInstanceStore,
    appProfiles: AppProfileWorkflowInstanceStore = AppProfileWorkflowInstanceStore()
  ) {
    self.project = project
    self.user = user
    self.appProfiles = appProfiles
  }

  public init(
    workingDirectory: String,
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
  ) {
    let stores = FileWorkflowInstanceStore.scopedStores(
      workingDirectory: workingDirectory,
      environment: environment
    )
    self.init(
      project: stores[0].store,
      user: stores[1].store,
      appProfiles: AppProfileWorkflowInstanceStore(environment: environment)
    )
  }

  public func list(scope: WorkflowInstanceScope, workflowId: String? = nil) throws -> [(WorkflowInstanceScope, WorkflowInstanceDefinition)] {
    switch scope {
    case .project:
      return try project.list(workflowId: workflowId).map { (.project, $0) }
    case .user:
      return try user.list(workflowId: workflowId).map { (.user, $0) }
    case .all:
      return try project.list(workflowId: workflowId).map { (.project, $0) }
        + user.list(workflowId: workflowId).map { (.user, $0) }
    }
  }

  public func listRecords(scope: WorkflowInstanceScope, workflowId: String? = nil) throws -> [(String, WorkflowInstanceDefinition)] {
    let writable = try list(scope: scope, workflowId: workflowId).map { ($0.0.rawValue, $0.1) }
    guard scope == .all else {
      return writable
    }
    return writable + (try appProfiles.list(workflowId: workflowId))
  }

  public func find(
    identity: String,
    workflowId: String? = nil,
    scope: WorkflowInstanceScope? = nil
  ) throws -> (WorkflowInstanceScope, WorkflowInstanceDefinition)? {
    switch scope {
    case .project:
      return try project.find(identity: identity, workflowId: workflowId).map { (.project, $0) }
    case .user:
      return try user.find(identity: identity, workflowId: workflowId).map { (.user, $0) }
    case .all:
      return try findInPrecedence(identity: identity, workflowId: workflowId)
    case nil:
      return try findInPrecedence(identity: identity, workflowId: workflowId)
    }
  }

  public func save(_ instance: WorkflowInstanceDefinition, scope: WorkflowInstanceScope) throws {
    switch scope {
    case .project:
      try project.save(instance)
    case .user:
      try user.save(instance)
    case .all:
      throw WorkflowInstanceStoreError.unsupportedScope(scope.rawValue)
    }
  }

  public func remove(identity: String, workflowId: String? = nil, scope: WorkflowInstanceScope) throws {
    switch scope {
    case .project:
      try project.remove(identity: identity, workflowId: workflowId)
    case .user:
      try user.remove(identity: identity, workflowId: workflowId)
    case .all:
      throw WorkflowInstanceStoreError.unsupportedScope(scope.rawValue)
    }
  }

  private func findInPrecedence(
    identity: String,
    workflowId: String?
  ) throws -> (WorkflowInstanceScope, WorkflowInstanceDefinition)? {
    if let projectMatch = try project.find(identity: identity, workflowId: workflowId) {
      return (.project, projectMatch)
    }
    if let userMatch = try user.find(identity: identity, workflowId: workflowId) {
      return (.user, userMatch)
    }
    return nil
  }
}

public struct AppProfileWorkflowInstanceStore: Sendable {
  public var homeDirectory: URL

  public init(
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
  ) {
    self.init(homeDirectory: URL(
      fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(environment: environment),
      isDirectory: true
    ))
  }

  public init(homeDirectory: URL) {
    self.homeDirectory = homeDirectory
  }

  public func list(workflowId: String? = nil) throws -> [(String, WorkflowInstanceDefinition)] {
    try profileStateURLs().flatMap { profileName, stateURL in
      try instances(profileName: profileName, stateURL: stateURL, workflowId: workflowId)
    }
  }

  private func instances(
    profileName: String,
    stateURL: URL,
    workflowId: String?
  ) throws -> [(String, WorkflowInstanceDefinition)] {
    guard FileManager.default.fileExists(atPath: stateURL.path) else {
      return []
    }
    let data = try Data(contentsOf: stateURL)
    let state = try JSONDecoder().decode(AppProfileWorkflowStateFile.self, from: data)
    return state.preferences.keys.sorted().compactMap { identity in
      guard let preference = state.preferences[identity] else {
        return nil
      }
      let sourceIdentity = preference.sourceIdentity
      let resolvedWorkflowId = Self.workflowId(from: sourceIdentity) ?? identity
      guard workflowId == nil || workflowId == resolvedWorkflowId || workflowId == sourceIdentity else {
        return nil
      }
      return (
        "app:\(profileName)",
        WorkflowInstanceDefinition(
          identity: identity,
          workflowId: resolvedWorkflowId,
          sourceIdentity: sourceIdentity,
          displayName: preference.displayName,
          configuration: preference.configuration
        )
      )
    }
  }

  private func profileStateURLs() throws -> [(String, URL)] {
    let profilesURL = homeDirectory
      .appendingPathComponent(".riela", isDirectory: true)
      .appendingPathComponent("rielaapp", isDirectory: true)
      .appendingPathComponent("profiles", isDirectory: true)
    guard FileManager.default.fileExists(atPath: profilesURL.path) else {
      return []
    }
    return try FileManager.default.contentsOfDirectory(
      at: profilesURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ).compactMap { profileURL in
      guard (try? profileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
        return nil
      }
      return (
        profileURL.lastPathComponent,
        profileURL.appendingPathComponent("daemon-workflows.json")
      )
    }.sorted { lhs, rhs in
      lhs.0.localizedCaseInsensitiveCompare(rhs.0) == .orderedAscending
    }
  }

  private static func workflowId(from sourceIdentity: String?) -> String? {
    guard let sourceIdentity, !sourceIdentity.isEmpty else {
      return nil
    }
    for prefix in ["user-workflow:", "app-workflow:", "project-workflow:"] where sourceIdentity.hasPrefix(prefix) {
      return String(sourceIdentity.dropFirst(prefix.count))
    }
    return sourceIdentity
  }
}

private struct AppProfileWorkflowStateFile: Decodable {
  var preferences: [String: AppProfileWorkflowPreference]

  private enum CodingKeys: String, CodingKey {
    case preferences
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    preferences = try container.decodeIfPresent([String: AppProfileWorkflowPreference].self, forKey: .preferences) ?? [:]
  }
}

private struct AppProfileWorkflowPreference: Decodable {
  var sourceIdentity: String?
  var displayName: String?
  var configuration: WorkflowInstanceConfiguration

  private enum CodingKeys: String, CodingKey {
    case sourceIdentity
    case displayName
    case configuration
    case environmentFilePath
    case environmentVariables
    case defaultVariables
    case nodePatches
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sourceIdentity = try container.decodeIfPresent(String.self, forKey: .sourceIdentity)
    displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    if let decodedConfiguration = try container.decodeIfPresent(WorkflowInstanceConfiguration.self, forKey: .configuration) {
      configuration = decodedConfiguration
    } else {
      configuration = WorkflowInstanceConfiguration(
        environmentFilePath: try container.decodeIfPresent(String.self, forKey: .environmentFilePath),
        environmentVariables: try container.decodeIfPresent([String: String].self, forKey: .environmentVariables) ?? [:],
        defaultVariables: try container.decodeIfPresent(JSONObject.self, forKey: .defaultVariables) ?? [:],
        nodePatches: try container.decodeIfPresent(
          [String: WorkflowInstanceNodePatch].self,
          forKey: .nodePatches
        ) ?? [:]
      )
    }
  }
}
