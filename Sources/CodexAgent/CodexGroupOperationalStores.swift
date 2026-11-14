import Foundation

public struct CodexGroup: Equatable, Codable, Sendable {
  public var id: String
  public var name: String
  public var description: String?
  public var sessionIds: [String]
  public var paused: Bool
  public var createdAt: String?
  public var updatedAt: String?

  public init(id: String = UUID().uuidString, name: String, description: String? = nil, sessionIds: [String] = [], paused: Bool = false, createdAt: String? = nil, updatedAt: String? = nil) {
    let now = codexOperationalNow()
    self.id = id
    self.name = name
    self.description = description
    self.sessionIds = sessionIds
    self.paused = paused
    self.createdAt = createdAt ?? now
    self.updatedAt = updatedAt ?? now
  }
}

public struct CodexGroupRepository: Equatable, Sendable {
  private var groups: [CodexGroup] = []

  public init() {}

  public mutating func createGroup(name: String, description: String? = nil) -> CodexGroup {
    let group = CodexGroup(id: UUID().uuidString, name: name, description: description, sessionIds: [], paused: false)
    groups.append(group)
    return group
  }

  public mutating func addSession(groupId: String, sessionId: String) -> Bool {
    guard let index = groups.firstIndex(where: { $0.id == groupId }) else {
      return false
    }
    if !groups[index].sessionIds.contains(sessionId) {
      groups[index].sessionIds.append(sessionId)
      groups[index].updatedAt = codexOperationalNow()
    }
    return true
  }

  public mutating func removeSession(groupId: String, sessionId: String) -> Bool {
    guard let groupIndex = groups.firstIndex(where: { $0.id == groupId }), let sessionIndex = groups[groupIndex].sessionIds.firstIndex(of: sessionId) else {
      return false
    }
    groups[groupIndex].sessionIds.remove(at: sessionIndex)
    groups[groupIndex].updatedAt = codexOperationalNow()
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

  public func listGroups() -> [CodexGroup] {
    groups
  }

  public func getGroup(id: String) -> CodexGroup? {
    groups.first { $0.id == id }
  }

  public func findGroup(_ idOrName: String) -> CodexGroup? {
    groups.first { $0.id == idOrName || $0.name == idOrName }
  }

  public mutating func replaceGroups(_ groups: [CodexGroup]) {
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
    groups[index].updatedAt = codexOperationalNow()
    return true
  }
}

public struct CodexGroupsConfig: Equatable, Codable, Sendable {
  public var groups: [CodexGroup]

  public init(groups: [CodexGroup] = []) {
    self.groups = groups
  }
}

public enum CodexGroupPersistence {
  public static func url(configDir: String) -> URL {
    URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent("groups.json")
  }

  public static func load(configDir: String) throws -> CodexGroupsConfig {
    try CodexJSONStore<CodexGroupsConfig>(url: url(configDir: configDir)).load(default: CodexGroupsConfig())
  }

  public static func save(_ config: CodexGroupsConfig, configDir: String) throws {
    try CodexJSONStore<CodexGroupsConfig>(url: url(configDir: configDir)).save(config)
  }

  private static func mutate(configDir: String, _ update: (inout CodexGroupRepository) throws -> Void) throws -> [CodexGroup] {
    var config = try load(configDir: configDir)
    var repository = CodexGroupRepository()
    repository.replaceGroups(config.groups)
    try update(&repository)
    config.groups = repository.listGroups()
    try save(config, configDir: configDir)
    return config.groups
  }

  public static func createGroup(name: String, description: String? = nil, configDir: String) throws -> CodexGroup {
    var created: CodexGroup?
    _ = try mutate(configDir: configDir) { repository in
      created = repository.createGroup(name: name, description: description)
    }
    return created!
  }

  public static func listGroups(configDir: String) throws -> [CodexGroup] {
    try load(configDir: configDir).groups
  }

  public static func findGroup(_ idOrName: String, configDir: String) throws -> CodexGroup? {
    var repository = CodexGroupRepository()
    repository.replaceGroups(try load(configDir: configDir).groups)
    return repository.findGroup(idOrName)
  }

  public static func addSession(groupId: String, sessionId: String, configDir: String) throws -> Bool {
    var changed = false
    _ = try mutate(configDir: configDir) { repository in
      changed = repository.addSession(groupId: groupId, sessionId: sessionId)
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
}
