import Foundation

public struct CursorCLIGroupSession: Equatable, Codable, Sendable {
  public var id: String
  public var projectPath: String?
  public var prompt: String?
  public var status: String?
  public var dependsOn: [String]
  public var createdAt: String?

  public init(
    id: String,
    projectPath: String? = nil,
    prompt: String? = nil,
    status: String? = nil,
    dependsOn: [String] = [],
    createdAt: String? = nil
  ) {
    self.id = id
    self.projectPath = projectPath
    self.prompt = prompt
    self.status = status
    self.dependsOn = dependsOn
    self.createdAt = createdAt
  }
}

public struct CursorCLIGroup: Equatable, Sendable {
  public var id: String
  public var name: String
  public var description: String?
  public var sessionIds: [String]
  public var sessions: [CursorCLIGroupSession]
  public var paused: Bool
  public var createdAt: String?
  public var updatedAt: String?

  public init(
    id: String = UUID().uuidString,
    name: String,
    description: String? = nil,
    sessionIds: [String] = [],
    sessions: [CursorCLIGroupSession]? = nil,
    paused: Bool = false,
    createdAt: String? = nil,
    updatedAt: String? = nil
  ) {
    let now = cursorCLIOperationalNow()
    self.id = id
    self.name = name
    self.description = description
    self.sessions = sessions ?? sessionIds.map { CursorCLIGroupSession(id: $0) }
    self.sessionIds = self.sessions.map(\.id)
    self.paused = paused
    self.createdAt = createdAt ?? now
    self.updatedAt = updatedAt ?? now
  }
}

extension CursorCLIGroup: Codable {
  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case description
    case sessionIds
    case sessions
    case paused
    case createdAt
    case updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedSessions = try container.decodeIfPresent([CursorCLIGroupSession].self, forKey: .sessions)
    let decodedSessionIds = try container.decodeIfPresent([String].self, forKey: .sessionIds) ?? []
    self.init(
      id: try container.decode(String.self, forKey: .id),
      name: try container.decode(String.self, forKey: .name),
      description: try container.decodeIfPresent(String.self, forKey: .description),
      sessionIds: decodedSessionIds,
      sessions: decodedSessions,
      paused: try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false,
      createdAt: try container.decodeIfPresent(String.self, forKey: .createdAt),
      updatedAt: try container.decodeIfPresent(String.self, forKey: .updatedAt)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encodeIfPresent(description, forKey: .description)
    try container.encode(sessionIds, forKey: .sessionIds)
    try container.encode(sessions, forKey: .sessions)
    try container.encode(paused, forKey: .paused)
    try container.encodeIfPresent(createdAt, forKey: .createdAt)
    try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
  }
}

public struct CursorCLIGroupRepository: Equatable, Sendable {
  private var groups: [CursorCLIGroup] = []

  public init() {}

  public mutating func createGroup(name: String, description: String? = nil) -> CursorCLIGroup {
    let group = CursorCLIGroup(id: UUID().uuidString, name: name, description: description, sessionIds: [], paused: false)
    groups.append(group)
    return group
  }

  public mutating func addSession(groupId: String, sessionId: String) -> Bool {
    addSession(groupId: groupId, session: CursorCLIGroupSession(id: sessionId))
  }

  public mutating func addSession(groupId: String, session: CursorCLIGroupSession) -> Bool {
    guard let index = groups.firstIndex(where: { $0.id == groupId }) else {
      return false
    }
    if let sessionIndex = groups[index].sessions.firstIndex(where: { $0.id == session.id }) {
      groups[index].sessions[sessionIndex] = session
    } else {
      groups[index].sessions.append(session)
    }
    if !groups[index].sessionIds.contains(session.id) {
      groups[index].sessionIds.append(session.id)
      groups[index].updatedAt = cursorCLIOperationalNow()
    }
    return true
  }

  public mutating func removeSession(groupId: String, sessionId: String) -> Bool {
    guard let groupIndex = groups.firstIndex(where: { $0.id == groupId }), let sessionIndex = groups[groupIndex].sessionIds.firstIndex(of: sessionId) else {
      return false
    }
    groups[groupIndex].sessionIds.remove(at: sessionIndex)
    groups[groupIndex].sessions.removeAll { $0.id == sessionId }
    groups[groupIndex].updatedAt = cursorCLIOperationalNow()
    return true
  }

  public mutating func pauseGroup(id: String) -> Bool {
    setPaused(id: id, paused: true)
  }

  public mutating func resumeGroup(id: String) -> Bool {
    setPaused(id: id, paused: false)
  }

  public mutating func deleteGroup(id: String) -> Bool {
    guard let index = groups.firstIndex(where: { $0.id == id }) else {
      return false
    }
    groups.remove(at: index)
    return true
  }

  public func listGroups() -> [CursorCLIGroup] {
    groups
  }

  public func getGroup(id: String) -> CursorCLIGroup? {
    groups.first { $0.id == id }
  }

  public func findGroup(_ idOrName: String) -> CursorCLIGroup? {
    groups.first { $0.id == idOrName || $0.name == idOrName }
  }

  public mutating func replaceGroups(_ groups: [CursorCLIGroup]) {
    self.groups = groups
  }

  public func runGroup(id: String, maxConcurrent: Int = 1, runner: (String) throws -> Int) rethrows -> [(sessionId: String, exitCode: Int)] {
    guard let group = groups.first(where: { $0.id == id }), !group.paused else {
      return []
    }
    var results: [(sessionId: String, exitCode: Int)] = []
    for sessionId in group.sessionIds {
      results.append((sessionId, try runner(sessionId)))
    }
    return results
  }

  private mutating func setPaused(id: String, paused: Bool) -> Bool {
    guard let index = groups.firstIndex(where: { $0.id == id }) else {
      return false
    }
    groups[index].paused = paused
    groups[index].updatedAt = cursorCLIOperationalNow()
    return true
  }
}

public struct CursorCLIGroupsConfig: Equatable, Codable, Sendable {
  public var groups: [CursorCLIGroup]

  public init(groups: [CursorCLIGroup] = []) {
    self.groups = groups
  }
}

public enum CursorCLIGroupPersistence {
  public static func url(configDir: String) -> URL {
    URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent("groups.json")
  }

  public static func legacyDirectory(configDir: String) -> URL {
    URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent("session-groups", isDirectory: true)
  }

  public static func legacyMetaURL(groupId: String, configDir: String) -> URL {
    legacyDirectory(configDir: configDir).appendingPathComponent(groupId, isDirectory: true).appendingPathComponent("meta.json")
  }

  public static func load(configDir: String) throws -> CursorCLIGroupsConfig {
    var config = try CursorCLIJSONStore<CursorCLIGroupsConfig>(url: url(configDir: configDir)).load(default: CursorCLIGroupsConfig())
    config.groups = mergeGroups(config.groups, loadLegacyGroups(configDir: configDir))
    return config
  }

  public static func save(_ config: CursorCLIGroupsConfig, configDir: String) throws {
    try CursorCLIJSONStore<CursorCLIGroupsConfig>(url: url(configDir: configDir)).save(config)
    try saveLegacyGroups(config.groups, configDir: configDir)
  }

  private static func mutate(configDir: String, _ update: (inout CursorCLIGroupRepository) throws -> Void) throws -> [CursorCLIGroup] {
    var config = try load(configDir: configDir)
    var repository = CursorCLIGroupRepository()
    repository.replaceGroups(config.groups)
    try update(&repository)
    config.groups = repository.listGroups()
    try save(config, configDir: configDir)
    return config.groups
  }

  public static func createGroup(name: String, description: String? = nil, configDir: String) throws -> CursorCLIGroup {
    var created: CursorCLIGroup?
    _ = try mutate(configDir: configDir) { repository in
      created = repository.createGroup(name: name, description: description)
    }
    return created!
  }

  public static func listGroups(configDir: String) throws -> [CursorCLIGroup] {
    try load(configDir: configDir).groups
  }

  public static func findGroup(_ idOrName: String, configDir: String) throws -> CursorCLIGroup? {
    var repository = CursorCLIGroupRepository()
    repository.replaceGroups(try load(configDir: configDir).groups)
    return repository.findGroup(idOrName)
  }

  public static func addSession(groupId: String, sessionId: String, configDir: String) throws -> Bool {
    try addSession(groupId: groupId, session: CursorCLIGroupSession(id: sessionId), configDir: configDir)
  }

  public static func addSession(groupId: String, session: CursorCLIGroupSession, configDir: String) throws -> Bool {
    var changed = false
    _ = try mutate(configDir: configDir) { repository in
      changed = repository.addSession(groupId: groupId, session: session)
    }
    return changed
  }

  public static func removeSession(groupId: String, sessionId: String, configDir: String) throws -> Bool {
    var changed = false
    _ = try mutate(configDir: configDir) { repository in
      changed = repository.removeSession(groupId: groupId, sessionId: sessionId)
    }
    return changed
  }

  public static func setPaused(groupId: String, paused: Bool, configDir: String) throws -> Bool {
    var changed = false
    _ = try mutate(configDir: configDir) { repository in
      changed = paused ? repository.pauseGroup(id: groupId) : repository.resumeGroup(id: groupId)
    }
    return changed
  }

  public static func deleteGroup(id: String, configDir: String) throws -> Bool {
    var deleted = false
    _ = try mutate(configDir: configDir) { repository in
      deleted = repository.deleteGroup(id: id)
    }
    return deleted
  }

  private static func mergeGroups(_ aggregate: [CursorCLIGroup], _ legacy: [CursorCLIGroup]) -> [CursorCLIGroup] {
    var byId = Dictionary(uniqueKeysWithValues: aggregate.map { ($0.id, $0) })
    for group in legacy {
      byId[group.id] = group
    }
    return byId.values.sorted { ($0.updatedAt ?? $0.createdAt ?? "") > ($1.updatedAt ?? $1.createdAt ?? "") }
  }

  private static func loadLegacyGroups(configDir: String) -> [CursorCLIGroup] {
    let directory = legacyDirectory(configDir: configDir)
    guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
      return []
    }
    return entries.compactMap { entry -> CursorCLIGroup? in
      let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
      guard isDirectory else {
        return nil
      }
      let meta = entry.appendingPathComponent("meta.json")
      guard let data = try? Data(contentsOf: meta) else {
        return nil
      }
      return try? JSONDecoder().decode(CursorCLIGroup.self, from: data)
    }
  }

  private static func saveLegacyGroups(_ groups: [CursorCLIGroup], configDir: String) throws {
    let directory = legacyDirectory(configDir: configDir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let expected = Set(groups.map(\.id))
    let existing = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
    for entry in existing {
      let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
      if isDirectory, !expected.contains(entry.lastPathComponent) {
        try? FileManager.default.removeItem(at: entry)
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    for group in groups {
      let groupDirectory = directory.appendingPathComponent(group.id, isDirectory: true)
      try FileManager.default.createDirectory(at: groupDirectory, withIntermediateDirectories: true)
      try encoder.encode(group).write(to: groupDirectory.appendingPathComponent("meta.json"), options: .atomic)
    }
  }
}
