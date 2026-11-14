import CryptoKit
import Foundation

public enum CodexQueuePromptStatus: String, Equatable, Codable, Sendable {
  case pending
  case running
  case completed
  case failed
}

public struct CodexQueuePrompt: Equatable, Codable, Sendable {
  public var id: String
  public var prompt: String
  public var status: CodexQueuePromptStatus
  public var mode: CodexQueueCommandMode?
  public var imagePaths: [String]
  public var resultExitCode: Int?
  public var createdAt: String?
  public var startedAt: String?
  public var completedAt: String?
  public var updatedAt: String?

  public init(
    id: String,
    prompt: String,
    status: CodexQueuePromptStatus = .pending,
    mode: CodexQueueCommandMode? = nil,
    imagePaths: [String] = [],
    resultExitCode: Int? = nil,
    createdAt: String? = nil,
    startedAt: String? = nil,
    completedAt: String? = nil,
    updatedAt: String? = nil
  ) {
    self.id = id
    self.prompt = prompt
    self.status = status
    self.mode = mode
    self.imagePaths = imagePaths
    self.resultExitCode = resultExitCode
    self.createdAt = createdAt
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case prompt
    case status
    case mode
    case imagePaths
    case images
    case resultExitCode
    case result
    case createdAt
    case addedAt
    case startedAt
    case completedAt
    case updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.prompt = try container.decode(String.self, forKey: .prompt)
    self.status = try container.decodeIfPresent(CodexQueuePromptStatus.self, forKey: .status) ?? .pending
    self.mode = try container.decodeIfPresent(CodexQueueCommandMode.self, forKey: .mode)
    self.imagePaths = try container.decodeIfPresent([String].self, forKey: .imagePaths)
      ?? container.decodeIfPresent([String].self, forKey: .images)
      ?? []
    if let resultExitCode = try container.decodeIfPresent(Int.self, forKey: .resultExitCode) {
      self.resultExitCode = resultExitCode
    } else if let result = try container.decodeIfPresent([String: Int].self, forKey: .result) {
      self.resultExitCode = result["exitCode"]
    } else {
      self.resultExitCode = nil
    }
    self.createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
      ?? container.decodeIfPresent(String.self, forKey: .addedAt)
    self.startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
    self.completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
    self.updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(prompt, forKey: .prompt)
    try container.encode(status, forKey: .status)
    try container.encodeIfPresent(mode ?? .auto, forKey: .mode)
    if !imagePaths.isEmpty {
      try container.encode(imagePaths, forKey: .images)
    }
    if let resultExitCode {
      try container.encode(["exitCode": resultExitCode], forKey: .result)
    }
    try container.encodeIfPresent(createdAt, forKey: .addedAt)
    try container.encodeIfPresent(startedAt, forKey: .startedAt)
    try container.encodeIfPresent(completedAt, forKey: .completedAt)
    try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
  }
}

public enum CodexQueueCommandMode: String, Equatable, Codable, Sendable {
  case auto
  case manual
}

public struct CodexQueue: Equatable, Sendable {
  public var id: String
  public var name: String
  public var projectPath: String?
  public var prompts: [CodexQueuePrompt]
  public var paused: Bool
  public var mode: CodexQueueCommandMode
  public var createdAt: String?

  public init(id: String, name: String, prompts: [CodexQueuePrompt], paused: Bool, mode: CodexQueueCommandMode = .auto, projectPath: String? = nil, createdAt: String? = nil) {
    self.id = id
    self.name = name
    self.projectPath = projectPath
    self.prompts = prompts
    self.paused = paused
    self.mode = mode
    self.createdAt = createdAt
  }
}

extension CodexQueue: Codable {}

public struct CodexQueueRepository: Equatable, Sendable {
  private var queues: [CodexQueue] = []

  public init() {}

  public mutating func createQueue(name: String, projectPath: String? = nil) -> CodexQueue {
    let queue = CodexQueue(id: UUID().uuidString, name: name, prompts: [], paused: false, projectPath: projectPath)
    queues.append(queue)
    return queue
  }

  public mutating func addPrompt(queueId: String, prompt: String, imagePaths: [String] = []) -> CodexQueuePrompt? {
    guard let index = queues.firstIndex(where: { $0.id == queueId }) else {
      return nil
    }
    let item = CodexQueuePrompt(
      id: UUID().uuidString,
      prompt: prompt,
      status: .pending,
      mode: .auto,
      imagePaths: imagePaths,
      createdAt: ISO8601DateFormatter().string(from: Date())
    )
    queues[index].prompts.append(item)
    return item
  }

  public mutating func updatePrompt(
    queueId: String,
    promptId: String,
    status: CodexQueuePromptStatus,
    resultExitCode: Int? = nil
  ) -> Bool {
    guard
      let queueIndex = queues.firstIndex(where: { $0.id == queueId }),
      let promptIndex = queues[queueIndex].prompts.firstIndex(where: { $0.id == promptId })
    else {
      return false
    }
    queues[queueIndex].prompts[promptIndex].status = status
    queues[queueIndex].prompts[promptIndex].resultExitCode = resultExitCode
    return true
  }

  public mutating func updatePrompt(
    queueId: String,
    promptId: String,
    prompt: String? = nil,
    status: CodexQueuePromptStatus? = nil,
    mode: CodexQueueCommandMode? = nil,
    resultExitCode: Int? = nil
  ) -> Bool {
    guard
      let queueIndex = queues.firstIndex(where: { $0.id == queueId }),
      let promptIndex = queues[queueIndex].prompts.firstIndex(where: { $0.id == promptId })
    else {
      return false
    }
    if let prompt {
      queues[queueIndex].prompts[promptIndex].prompt = prompt
    }
    if let status {
      queues[queueIndex].prompts[promptIndex].status = status
    }
    if let mode {
      queues[queueIndex].prompts[promptIndex].mode = mode
    }
    if let resultExitCode {
      queues[queueIndex].prompts[promptIndex].resultExitCode = resultExitCode
    }
    queues[queueIndex].prompts[promptIndex].updatedAt = ISO8601DateFormatter().string(from: Date())
    return true
  }

  public mutating func movePrompt(queueId: String, promptId: String, toIndex: Int) -> Bool {
    guard
      let queueIndex = queues.firstIndex(where: { $0.id == queueId }),
      let promptIndex = queues[queueIndex].prompts.firstIndex(where: { $0.id == promptId })
    else {
      return false
    }
    guard queues[queueIndex].prompts.indices.contains(toIndex) else {
      return false
    }
    let item = queues[queueIndex].prompts.remove(at: promptIndex)
    queues[queueIndex].prompts.insert(item, at: toIndex)
    return true
  }

  public mutating func movePrompt(queueId: String, from: Int, to: Int) -> Bool {
    guard
      let queueIndex = queues.firstIndex(where: { $0.id == queueId }),
      queues[queueIndex].prompts.indices.contains(from),
      queues[queueIndex].prompts.indices.contains(to)
    else {
      return false
    }
    let item = queues[queueIndex].prompts.remove(at: from)
    queues[queueIndex].prompts.insert(item, at: to)
    return true
  }

  public mutating func setMode(queueId: String, mode: CodexQueueCommandMode) -> Bool {
    guard let queueIndex = queues.firstIndex(where: { $0.id == queueId }) else {
      return false
    }
    queues[queueIndex].mode = mode
    return true
  }

  public mutating func removePrompt(queueId: String, promptId: String) -> Bool {
    guard
      let queueIndex = queues.firstIndex(where: { $0.id == queueId }),
      let promptIndex = queues[queueIndex].prompts.firstIndex(where: { $0.id == promptId })
    else {
      return false
    }
    queues[queueIndex].prompts.remove(at: promptIndex)
    return true
  }

  public mutating func pauseQueue(id: String) -> Bool {
    setPaused(id: id, paused: true)
  }

  public mutating func resumeQueue(id: String) -> Bool {
    setPaused(id: id, paused: false)
  }

  public mutating func deleteQueue(id: String) -> Bool {
    guard let index = queues.firstIndex(where: { $0.id == id }) else {
      return false
    }
    queues.remove(at: index)
    return true
  }

  public func listQueues() -> [CodexQueue] {
    queues
  }

  public func getQueue(id: String) -> CodexQueue? {
    queues.first { $0.id == id }
  }

  public func findQueue(_ idOrName: String) -> CodexQueue? {
    queues.first { $0.id == idOrName || $0.name == idOrName }
  }

  public mutating func replaceQueues(_ queues: [CodexQueue]) {
    self.queues = queues
  }

  @discardableResult
  public mutating func runQueue(
    id: String,
    afterPrompt: (([CodexQueue]) throws -> Void)? = nil,
    runner: (CodexQueuePrompt) throws -> Int
  ) rethrows -> [CodexQueuePrompt] {
    guard let queueIndex = queues.firstIndex(where: { $0.id == id }), !queues[queueIndex].paused else {
      return []
    }
    var completed: [CodexQueuePrompt] = []
    for promptIndex in queues[queueIndex].prompts.indices where queues[queueIndex].prompts[promptIndex].status == .pending {
      let startedAt = codexOperationalNow()
      queues[queueIndex].prompts[promptIndex].status = .running
      queues[queueIndex].prompts[promptIndex].startedAt = startedAt
      queues[queueIndex].prompts[promptIndex].updatedAt = startedAt
      let exitCode = try runner(queues[queueIndex].prompts[promptIndex])
      let completedAt = codexOperationalNow()
      queues[queueIndex].prompts[promptIndex].resultExitCode = exitCode
      queues[queueIndex].prompts[promptIndex].status = exitCode == 0 ? .completed : .failed
      queues[queueIndex].prompts[promptIndex].completedAt = completedAt
      queues[queueIndex].prompts[promptIndex].updatedAt = completedAt
      completed.append(queues[queueIndex].prompts[promptIndex])
      try afterPrompt?(queues)
      if queues[queueIndex].mode == .manual {
        break
      }
    }
    return completed
  }

  private mutating func setPaused(id: String, paused: Bool) -> Bool {
    guard let index = queues.firstIndex(where: { $0.id == id }) else {
      return false
    }
    queues[index].paused = paused
    return true
  }
}

public struct CodexQueuesConfig: Equatable, Codable, Sendable {
  public var queues: [CodexQueue]

  public init(queues: [CodexQueue] = []) {
    self.queues = queues
  }
}

public enum CodexQueuePersistence {
  public static func url(configDir: String) -> URL {
    URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent("queues.json")
  }

  public static func load(configDir: String) throws -> CodexQueuesConfig {
    try CodexJSONStore<CodexQueuesConfig>(url: url(configDir: configDir)).load(default: CodexQueuesConfig())
  }

  public static func save(_ config: CodexQueuesConfig, configDir: String) throws {
    try CodexJSONStore<CodexQueuesConfig>(url: url(configDir: configDir)).save(config)
  }

  public static func createQueue(name: String, projectPath: String, configDir: String) throws -> CodexQueue {
    var config = try load(configDir: configDir)
    var repository = CodexQueueRepository()
    repository.replaceQueues(config.queues)
    let queue = repository.createQueue(name: name, projectPath: projectPath)
    config.queues = repository.listQueues()
    try save(config, configDir: configDir)
    return queue
  }

  public static func listQueues(configDir: String) throws -> [CodexQueue] {
    try load(configDir: configDir).queues
  }

  public static func findQueue(_ idOrName: String, configDir: String) throws -> CodexQueue? {
    var repository = CodexQueueRepository()
    repository.replaceQueues(try load(configDir: configDir).queues)
    return repository.findQueue(idOrName)
  }

  public static func addPrompt(queueId: String, prompt: String, imagePaths: [String] = [], configDir: String) throws -> CodexQueuePrompt? {
    var config = try load(configDir: configDir)
    var repository = CodexQueueRepository()
    repository.replaceQueues(config.queues)
    let item = repository.addPrompt(queueId: queueId, prompt: prompt, imagePaths: imagePaths)
    config.queues = repository.listQueues()
    try save(config, configDir: configDir)
    return item
  }

  public static func removeQueue(_ id: String, configDir: String) throws -> Bool {
    var config = try load(configDir: configDir)
    var repository = CodexQueueRepository()
    repository.replaceQueues(config.queues)
    let removed = repository.deleteQueue(id: id)
    config.queues = repository.listQueues()
    try save(config, configDir: configDir)
    return removed
  }

  public static func updateQueuePrompts(queueId: String, prompts: [CodexQueuePrompt], configDir: String) throws -> Bool {
    var config = try load(configDir: configDir)
    guard let index = config.queues.firstIndex(where: { $0.id == queueId }) else {
      return false
    }
    config.queues[index].prompts = prompts
    try save(config, configDir: configDir)
    return true
  }
}

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

public enum CodexBookmarkType: String, Equatable, Codable, Sendable {
  case session
  case message
  case range
}

public struct CodexBookmark: Equatable, Codable, Sendable {
  public var id: String
  public var type: CodexBookmarkType
  public var sessionId: String
  public var messageId: String?
  public var text: String?
  public var name: String?
  public var description: String?
  public var tags: [String]
  public var startLine: Int?
  public var endLine: Int?
  public var fromMessageId: String?
  public var toMessageId: String?
  public var createdAt: String?
  public var updatedAt: String?

  public init(
    id: String,
    type: CodexBookmarkType,
    sessionId: String,
    messageId: String? = nil,
    text: String? = nil,
    name: String? = nil,
    description: String? = nil,
    tags: [String] = [],
    startLine: Int? = nil,
    endLine: Int? = nil,
    fromMessageId: String? = nil,
    toMessageId: String? = nil,
    createdAt: String? = nil,
    updatedAt: String? = nil
  ) {
    let now = codexOperationalNow()
    self.id = id
    self.type = type
    self.sessionId = sessionId
    self.messageId = messageId
    self.text = text
    self.name = name
    self.description = description
    self.tags = tags
    self.startLine = startLine
    self.endLine = endLine
    self.fromMessageId = fromMessageId
    self.toMessageId = toMessageId
    self.createdAt = createdAt ?? now
    self.updatedAt = updatedAt ?? now
  }
}

public struct CodexBookmarkSearchResult: Equatable, Sendable {
  public var bookmark: CodexBookmark
  public var score: Double

  public init(bookmark: CodexBookmark, score: Double) {
    self.bookmark = bookmark
    self.score = score
  }
}

public struct CodexBookmarkManager: Equatable, Sendable {
  private var bookmarks: [CodexBookmark] = []

  public init() {}

  public mutating func create(
    type: CodexBookmarkType,
    sessionId: String,
    messageId: String? = nil,
    text: String? = nil,
    name: String? = nil,
    description: String? = nil,
    tags: [String] = [],
    startLine: Int? = nil,
    endLine: Int? = nil,
    fromMessageId: String? = nil,
    toMessageId: String? = nil
  ) throws -> CodexBookmark {
    let requiredName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let requiredName, !requiredName.isEmpty else {
      throw CodexOperationalError.invalidBookmark
    }
    let hasRangeEndpoints = fromMessageId != nil || toMessageId != nil || startLine != nil || endLine != nil
    if type == .session, messageId != nil || hasRangeEndpoints {
      throw CodexOperationalError.invalidBookmark
    }
    if type == .message, messageId == nil || hasRangeEndpoints {
      throw CodexOperationalError.invalidBookmark
    }
    if type == .range, messageId != nil {
      throw CodexOperationalError.invalidBookmark
    }
    if type == .range, fromMessageId == nil || toMessageId == nil {
      throw CodexOperationalError.invalidBookmark
    }
    if type == .range, startLine != nil, endLine != nil, (startLine ?? 0) > (endLine ?? 0) {
      throw CodexOperationalError.invalidBookmark
    }
    var seenTags = Set<String>()
    let normalizedTags = tags.compactMap { tag -> String? in
      let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalized.isEmpty, !seenTags.contains(normalized) else {
        return nil
      }
      seenTags.insert(normalized)
      return normalized
    }
    let now = codexOperationalNow()
    let bookmark = CodexBookmark(
      id: UUID().uuidString,
      type: type,
      sessionId: sessionId,
      messageId: messageId,
      text: text,
      name: requiredName,
      description: description,
      tags: normalizedTags,
      startLine: startLine,
      endLine: endLine,
      fromMessageId: fromMessageId,
      toMessageId: toMessageId,
      createdAt: now,
      updatedAt: now
    )
    bookmarks.append(bookmark)
    return bookmark
  }

  public func get(id: String) -> CodexBookmark? {
    bookmarks.first { $0.id == id }
  }

  public func list(sessionId: String? = nil, tag: String? = nil) -> [CodexBookmark] {
    bookmarks.filter { bookmark in
      (sessionId == nil || bookmark.sessionId == sessionId) && (tag == nil || bookmark.tags.contains { $0.caseInsensitiveCompare(tag ?? "") == .orderedSame })
    }.sorted { lhs, rhs in
      bookmarkSortTimestamp(lhs) > bookmarkSortTimestamp(rhs)
    }
  }

  public func list(sessionId: String? = nil, type: CodexBookmarkType? = nil, tag: String? = nil) -> [CodexBookmark] {
    bookmarks.filter { bookmark in
      (sessionId == nil || bookmark.sessionId == sessionId) && (type == nil || bookmark.type == type) && (tag == nil || bookmark.tags.contains { $0.caseInsensitiveCompare(tag ?? "") == .orderedSame })
    }.sorted { lhs, rhs in
      bookmarkSortTimestamp(lhs) > bookmarkSortTimestamp(rhs)
    }
  }

  public func search(text: String) -> [CodexBookmark] {
    searchResults(text: text, limit: Int.max).map(\.bookmark)
  }

  public func searchResults(text: String, limit: Int = 50) -> [CodexBookmarkSearchResult] {
    let needle = text.lowercased()
    guard !needle.isEmpty, limit != 0 else {
      return []
    }
    return bookmarks.compactMap { bookmark -> CodexBookmarkSearchResult? in
      var score = 0.0
      if bookmark.name?.lowercased().contains(needle) == true {
        score += 5
      }
      if bookmark.description?.lowercased().contains(needle) == true || bookmark.text?.lowercased().contains(needle) == true {
        score += 3
      }
      if bookmark.sessionId.lowercased().contains(needle) {
        score += 2
      }
      if bookmark.messageId?.lowercased().contains(needle) == true || bookmark.fromMessageId?.lowercased().contains(needle) == true || bookmark.toMessageId?.lowercased().contains(needle) == true {
        score += 2
      }
      score += Double(bookmark.tags.map { $0.lowercased() }.filter { $0.contains(needle) }.count)
      return score > 0 ? CodexBookmarkSearchResult(bookmark: bookmark, score: score) : nil
    }
    .sorted { lhs, rhs in
      if lhs.score == rhs.score {
        return bookmarkSortTimestamp(lhs.bookmark) > bookmarkSortTimestamp(rhs.bookmark)
      }
      return lhs.score > rhs.score
    }
    .prefix(limit)
    .map { $0 }
  }

  public mutating func delete(id: String) -> Bool {
    guard let index = bookmarks.firstIndex(where: { $0.id == id }) else {
      return false
    }
    bookmarks.remove(at: index)
    return true
  }

  public mutating func replaceBookmarks(_ bookmarks: [CodexBookmark]) {
    self.bookmarks = bookmarks
  }
}

private func bookmarkSortTimestamp(_ bookmark: CodexBookmark) -> String {
  bookmark.updatedAt ?? bookmark.createdAt ?? ""
}

public struct CodexBookmarksConfig: Equatable, Codable, Sendable {
  public var bookmarks: [CodexBookmark]

  public init(bookmarks: [CodexBookmark] = []) {
    self.bookmarks = bookmarks
  }
}

public enum CodexBookmarkPersistence {
  public static func url(configDir: String) -> URL {
    URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent("bookmarks.json")
  }

  public static func load(configDir: String) throws -> CodexBookmarksConfig {
    try CodexJSONStore<CodexBookmarksConfig>(url: url(configDir: configDir)).load(default: CodexBookmarksConfig())
  }

  public static func save(_ config: CodexBookmarksConfig, configDir: String) throws {
    try CodexJSONStore<CodexBookmarksConfig>(url: url(configDir: configDir)).save(config)
  }

  public static func addBookmark(
    type: CodexBookmarkType,
    sessionId: String,
    messageId: String? = nil,
    name: String? = nil,
    description: String? = nil,
    tags: [String] = [],
    fromMessageId: String? = nil,
    toMessageId: String? = nil,
    configDir: String
  ) throws -> CodexBookmark {
    var config = try load(configDir: configDir)
    var manager = CodexBookmarkManager()
    manager.replaceBookmarks(config.bookmarks)
    let bookmark = try manager.create(
      type: type,
      sessionId: sessionId,
      messageId: messageId,
      text: description,
      name: name,
      description: description,
      tags: tags,
      fromMessageId: fromMessageId,
      toMessageId: toMessageId
    )
    config.bookmarks = manager.list()
    try save(config, configDir: configDir)
    return bookmark
  }

  public static func getBookmark(id: String, configDir: String) throws -> CodexBookmark? {
    try load(configDir: configDir).bookmarks.first { $0.id == id }
  }

  public static func listBookmarks(sessionId: String? = nil, type: CodexBookmarkType? = nil, tag: String? = nil, configDir: String) throws -> [CodexBookmark] {
    var manager = CodexBookmarkManager()
    manager.replaceBookmarks(try load(configDir: configDir).bookmarks)
    return manager.list(sessionId: sessionId, type: type, tag: tag)
  }

  public static func searchBookmarks(_ text: String, configDir: String) throws -> [CodexBookmark] {
    try searchBookmarkResults(text, limit: Int.max, configDir: configDir).map(\.bookmark)
  }

  public static func searchBookmarkResults(_ text: String, limit: Int = 50, configDir: String) throws -> [CodexBookmarkSearchResult] {
    var manager = CodexBookmarkManager()
    manager.replaceBookmarks(try load(configDir: configDir).bookmarks)
    return manager.searchResults(text: text, limit: limit)
  }

  public static func deleteBookmark(id: String, configDir: String) throws -> Bool {
    var config = try load(configDir: configDir)
    var manager = CodexBookmarkManager()
    manager.replaceBookmarks(config.bookmarks)
    let deleted = manager.delete(id: id)
    config.bookmarks = manager.list()
    try save(config, configDir: configDir)
    return deleted
  }
}

private func codexOperationalNow() -> String {
  ISO8601DateFormatter().string(from: Date())
}

public struct CodexTokenMetadata: Equatable, Codable, Sendable {
  public var id: String
  public var name: String?
  public var permissions: [String]
  public var createdAt: String?
  public var expiresAt: String?
  public var revoked: Bool
  public var revokedAt: String?

  public init(id: String, permissions: [String], revoked: Bool = false, name: String? = nil, createdAt: String? = nil, expiresAt: String? = nil, revokedAt: String? = nil) {
    self.id = id
    self.name = name
    self.permissions = permissions
    self.createdAt = createdAt
    self.expiresAt = expiresAt
    self.revoked = revoked
    self.revokedAt = revokedAt
  }
}

public struct CodexTokenRecord: Equatable, Codable, Sendable {
  var secretHash: String
  public var metadata: CodexTokenMetadata

  public init(secretHash: String, metadata: CodexTokenMetadata) {
    self.secretHash = secretHash
    self.metadata = metadata
  }

  private enum CodingKeys: String, CodingKey {
    case secretHash
    case metadata
    case id
    case name
    case permissions
    case createdAt
    case expiresAt
    case revoked
    case revokedAt
    case tokenHash
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let metadata = try container.decodeIfPresent(CodexTokenMetadata.self, forKey: .metadata) {
      self.metadata = metadata
      self.secretHash = try container.decode(String.self, forKey: .secretHash)
      return
    }

    let id = try container.decode(String.self, forKey: .id)
    let revokedAt = try container.decodeIfPresent(String.self, forKey: .revokedAt)
    self.metadata = CodexTokenMetadata(
      id: id,
      permissions: try container.decodeIfPresent([String].self, forKey: .permissions) ?? [],
      revoked: (try container.decodeIfPresent(Bool.self, forKey: .revoked)) ?? (revokedAt != nil),
      name: try container.decodeIfPresent(String.self, forKey: .name),
      createdAt: try container.decodeIfPresent(String.self, forKey: .createdAt),
      expiresAt: try container.decodeIfPresent(String.self, forKey: .expiresAt),
      revokedAt: revokedAt
    )
    self.secretHash = try container.decode(String.self, forKey: .tokenHash)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(metadata.id, forKey: .id)
    try container.encodeIfPresent(metadata.name, forKey: .name)
    try container.encode(metadata.permissions, forKey: .permissions)
    try container.encodeIfPresent(metadata.createdAt, forKey: .createdAt)
    try container.encodeIfPresent(metadata.expiresAt, forKey: .expiresAt)
    try container.encodeIfPresent(metadata.revokedAt, forKey: .revokedAt)
    try container.encode(secretHash, forKey: .tokenHash)
  }
}

public struct CodexTokenManager: Sendable {
  private var tokens: [String: CodexTokenRecord] = [:]

  public init() {}

  public init(records: [CodexTokenRecord]) {
    self.tokens = Dictionary(uniqueKeysWithValues: records.map { ($0.metadata.id, $0) })
  }

  public mutating func create(permissions: [String] = ["session:read"]) -> (secret: String, metadata: CodexTokenMetadata) {
    let secret = UUID().uuidString
    let metadata = CodexTokenMetadata(id: UUID().uuidString, permissions: Self.normalizePermissions(permissions), revoked: false, createdAt: nowString())
    tokens[metadata.id] = CodexTokenRecord(secretHash: hashSecret(secret), metadata: metadata)
    return (secret, metadata)
  }

  public mutating func createRawToken(name: String? = nil, permissions: [String] = ["session:read"], expiresAt: String? = nil) -> String {
    let created = create(permissions: permissions)
    var metadata = created.metadata
    metadata.name = name
    metadata.expiresAt = expiresAt
    tokens[metadata.id] = CodexTokenRecord(secretHash: hashSecret(created.secret), metadata: metadata)
    return "\(metadata.id).\(created.secret)"
  }

  public func verify(id: String, secret: String, permission: String) -> Bool {
    guard let stored = tokens[id], !stored.metadata.revoked else {
      return false
    }
    guard !isExpired(stored.metadata) else {
      return false
    }
    return timingSafeEqual(stored.secretHash, hashSecret(secret)) && permits(stored.metadata.permissions, permission: permission)
  }

  public func verify(rawToken: String, permission: String) -> CodexTokenMetadata? {
    let parts = rawToken.split(separator: ".", maxSplits: 1).map(String.init)
    guard parts.count == 2, verify(id: parts[0], secret: parts[1], permission: permission) else {
      return nil
    }
    return tokens[parts[0]]?.metadata
  }

  public func listMetadata() -> [CodexTokenMetadata] {
    tokens.values.map(\.metadata).sorted { $0.id < $1.id }
  }

  public static func parsePermissionsCSV(_ text: String) -> [String] {
    normalizePermissions(text.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty })
  }

  public mutating func revoke(id: String) -> Bool {
    guard var stored = tokens[id] else {
      return false
    }
    stored.metadata.revoked = true
    stored.metadata.revokedAt = nowString()
    tokens[id] = stored
    return true
  }

  public mutating func rotate(id: String) -> String? {
    guard var stored = tokens[id] else {
      return nil
    }
    let secret = UUID().uuidString
    stored.secretHash = hashSecret(secret)
    stored.metadata.revoked = false
    stored.metadata.revokedAt = nil
    tokens[id] = stored
    return secret
  }

  public static func normalizePermissions(_ permissions: [String]) -> [String] {
    let allowed: Set<String> = ["session:create", "session:read", "session:cancel", "group:*", "queue:*", "bookmark:*"]
    var seen: Set<String> = []
    var normalized: [String] = []
    for permission in permissions.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }) where !seen.contains(permission) && allowed.contains(permission) {
      seen.insert(permission)
      normalized.append(permission)
    }
    return normalized
  }

  private func hashSecret(_ secret: String) -> String {
    SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func timingSafeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard !left.isEmpty, !right.isEmpty else {
      return left.isEmpty && right.isEmpty
    }
    var difference = left.count ^ right.count
    let maxCount = max(left.count, right.count)
    for index in 0..<maxCount {
      difference |= Int(left[index % left.count] ^ right[index % right.count])
    }
    return difference == 0
  }

  private func permits(_ permissions: [String], permission: String) -> Bool {
    permissions.contains(permission) || permissions.contains("*") || permissions.contains(permission.split(separator: ":").first.map { "\($0):*" } ?? "")
  }

  public func records() -> [CodexTokenRecord] {
    tokens.values.sorted { $0.metadata.id < $1.metadata.id }
  }

  private func isExpired(_ metadata: CodexTokenMetadata) -> Bool {
    guard let expiresAt = metadata.expiresAt else {
      return false
    }
    return ISO8601DateFormatter().date(from: expiresAt).map { $0 <= Date() } ?? false
  }

  private func nowString() -> String {
    ISO8601DateFormatter().string(from: Date())
  }
}

public struct CodexTokensConfig: Equatable, Codable, Sendable {
  public var tokens: [CodexTokenRecord]

  public init(tokens: [CodexTokenRecord] = []) {
    self.tokens = tokens
  }
}

public enum CodexTokenPersistence {
  public static func url(configDir: String) -> URL {
    URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent("tokens.json")
  }

  public static func load(configDir: String) throws -> CodexTokenManager {
    let config = try CodexJSONStore<CodexTokensConfig>(url: url(configDir: configDir)).load(default: CodexTokensConfig())
    return CodexTokenManager(records: config.tokens)
  }

  public static func save(_ manager: CodexTokenManager, configDir: String) throws {
    try CodexJSONStore<CodexTokensConfig>(url: url(configDir: configDir)).save(CodexTokensConfig(tokens: manager.records()))
  }

  public static func createRawToken(name: String? = nil, permissions: [String], expiresAt: String? = nil, configDir: String) throws -> String {
    var manager = try load(configDir: configDir)
    let token = manager.createRawToken(name: name, permissions: permissions, expiresAt: expiresAt)
    try save(manager, configDir: configDir)
    return token
  }

  public static func listMetadata(configDir: String) throws -> [CodexTokenMetadata] {
    try load(configDir: configDir).listMetadata()
  }

  public static func verify(rawToken: String, permission: String, configDir: String) throws -> CodexTokenMetadata? {
    try load(configDir: configDir).verify(rawToken: rawToken, permission: permission)
  }

  public static func revoke(id: String, configDir: String) throws -> Bool {
    var manager = try load(configDir: configDir)
    let revoked = manager.revoke(id: id)
    try save(manager, configDir: configDir)
    return revoked
  }

  public static func rotate(id: String, configDir: String) throws -> String? {
    var manager = try load(configDir: configDir)
    guard let secret = manager.rotate(id: id), let metadata = manager.listMetadata().first(where: { $0.id == id }) else {
      return nil
    }
    try save(manager, configDir: configDir)
    return "\(metadata.id).\(secret)"
  }
}

public struct CodexJSONStore<Value: Codable & Sendable>: Sendable {
  public var url: URL

  public init(url: URL) {
    self.url = url
  }

  public func load(default defaultValue: Value) throws -> Value {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return defaultValue
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(Value.self, from: data)
  }

  public func save(_ value: Value) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: [.atomic])
  }
}

public enum CodexSessionCommands {
  public static func list(codexHome: String? = nil) -> [CodexSession] {
    listSessions(options: CodexSessionListOptions(codexHome: codexHome)).sessions
  }

  public static func show(sessionId: String, codexHome: String? = nil) -> CodexSession? {
    findSession(id: sessionId, codexHome: codexHome)
  }

  public static func search(query: String, codexHome: String? = nil) throws -> CodexSessionsSearchResult {
    try CodexSessionIndex.searchSessions(query: query, options: CodexSessionListOptions(codexHome: codexHome))
  }

  public static func runArguments(prompt: String, options: CodexProcessOptions = CodexProcessOptions()) -> [String] {
    CodexProcessCommandBuilder.buildExecArguments(prompt: prompt, options: options)
  }

  public static func resumeArguments(sessionId: String, prompt: String? = nil, options: CodexProcessOptions = CodexProcessOptions()) -> [String] {
    CodexProcessCommandBuilder.buildResumeArguments(sessionId: sessionId, prompt: prompt, options: options)
  }
}

public enum CodexOperationalError: Error, Equatable {
  case invalidBookmark
}
