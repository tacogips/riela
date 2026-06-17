import CryptoKit
import Foundation

public enum CursorCLIQueuePromptStatus: String, Equatable, Codable, Sendable {
  case pending
  case running
  case completed
  case failed
  case skipped
}

public enum CursorCLIQueueStatus: String, Equatable, Codable, Sendable {
  case pending
  case running
  case paused
  case completed
  case failed
  case stopped
}

public struct CursorCLIQueuePrompt: Equatable, Codable, Sendable {
  public var id: String
  public var prompt: String
  public var status: CursorCLIQueuePromptStatus
  public var mode: CursorCLIQueueCommandMode?
  public var imagePaths: [String]
  public var resultExitCode: Int?
  public var sessionId: String?
  public var error: String?
  public var createdAt: String?
  public var startedAt: String?
  public var completedAt: String?
  public var updatedAt: String?

  public init(id: String, prompt: String, status: CursorCLIQueuePromptStatus = .pending, mode: CursorCLIQueueCommandMode? = nil, imagePaths: [String] = [], resultExitCode: Int? = nil, sessionId: String? = nil, error: String? = nil, createdAt: String? = nil, startedAt: String? = nil, completedAt: String? = nil, updatedAt: String? = nil) {
    self.id = id
    self.prompt = prompt
    self.status = status
    self.mode = mode
    self.imagePaths = imagePaths
    self.resultExitCode = resultExitCode
    self.sessionId = sessionId
    self.error = error
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
    case sessionMode
    case imagePaths
    case images
    case resultExitCode
    case result
    case sessionId
    case error
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
    self.status = try container.decodeIfPresent(CursorCLIQueuePromptStatus.self, forKey: .status) ?? .pending
    self.mode = try container.decodeIfPresent(CursorCLIQueueCommandMode.self, forKey: .mode)
      ?? container.decodeIfPresent(CursorCLIQueueCommandMode.self, forKey: .sessionMode)
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
    self.sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
    self.error = try container.decodeIfPresent(String.self, forKey: .error)
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
    try container.encodeIfPresent(mode ?? .continueMode, forKey: .sessionMode)
    if !imagePaths.isEmpty {
      try container.encode(imagePaths, forKey: .images)
    }
    if let resultExitCode {
      try container.encode(["exitCode": resultExitCode], forKey: .result)
    }
    try container.encodeIfPresent(sessionId, forKey: .sessionId)
    try container.encodeIfPresent(error, forKey: .error)
    try container.encodeIfPresent(createdAt, forKey: .addedAt)
    try container.encodeIfPresent(startedAt, forKey: .startedAt)
    try container.encodeIfPresent(completedAt, forKey: .completedAt)
    try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
  }
}

public enum CursorCLIQueueCommandMode: String, Equatable, Codable, Sendable {
  case auto
  case manual
  case continueMode = "continue"
  case new

  public static func legacy(_ raw: String) -> CursorCLIQueueCommandMode? {
    switch raw {
    case "continue":
      return .continueMode
    case "new":
      return .new
    case "auto":
      return .continueMode
    case "manual":
      return .new
    default:
      return CursorCLIQueueCommandMode(rawValue: raw)
    }
  }
}

public struct CursorCLIQueue: Equatable, Sendable {
  public var id: String
  public var name: String
  public var projectPath: String?
  public var prompts: [CursorCLIQueuePrompt]
  public var paused: Bool
  public var mode: CursorCLIQueueCommandMode
  public var createdAt: String?
  public var status: CursorCLIQueueStatus
  public var currentIndex: Int
  public var currentSessionId: String?
  public var totalCostUsd: Double
  public var updatedAt: String?
  public var startedAt: String?
  public var completedAt: String?

  public init(id: String, name: String, prompts: [CursorCLIQueuePrompt], paused: Bool, mode: CursorCLIQueueCommandMode = .auto, projectPath: String? = nil, createdAt: String? = nil, status: CursorCLIQueueStatus? = nil, currentIndex: Int = 0, currentSessionId: String? = nil, totalCostUsd: Double = 0, updatedAt: String? = nil, startedAt: String? = nil, completedAt: String? = nil) {
    self.id = id
    self.name = name
    self.projectPath = projectPath
    self.prompts = prompts
    self.paused = paused
    self.mode = mode
    self.createdAt = createdAt
    self.status = status ?? (paused ? .paused : .pending)
    self.currentIndex = currentIndex
    self.currentSessionId = currentSessionId
    self.totalCostUsd = totalCostUsd
    self.updatedAt = updatedAt
    self.startedAt = startedAt
    self.completedAt = completedAt
  }
}

extension CursorCLIQueue: Codable {
  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case projectPath
    case prompts
    case commands
    case paused
    case mode
    case status
    case currentIndex
    case totalCostUsd
    case createdAt
    case updatedAt
    case startedAt
    case completedAt
    case currentSessionId
    case additionalArgs
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(String.self, forKey: .id)
    let name = try container.decode(String.self, forKey: .name)
    let projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
    let prompts = try container.decodeIfPresent([CursorCLIQueuePrompt].self, forKey: .prompts)
      ?? container.decodeIfPresent([CursorCLIQueuePrompt].self, forKey: .commands)
      ?? []
    let status = try container.decodeIfPresent(CursorCLIQueueStatus.self, forKey: .status) ?? .pending
    let paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? (status == .paused || status == .stopped)
    let mode = try container.decodeIfPresent(CursorCLIQueueCommandMode.self, forKey: .mode)
      ?? (paused ? .manual : .continueMode)
    let createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
    self.init(
      id: id,
      name: name,
      prompts: prompts,
      paused: paused,
      mode: mode,
      projectPath: projectPath,
      createdAt: createdAt,
      status: status,
      currentIndex: try container.decodeIfPresent(Int.self, forKey: .currentIndex) ?? 0,
      currentSessionId: try container.decodeIfPresent(String.self, forKey: .currentSessionId),
      totalCostUsd: try container.decodeIfPresent(Double.self, forKey: .totalCostUsd) ?? 0,
      updatedAt: try container.decodeIfPresent(String.self, forKey: .updatedAt),
      startedAt: try container.decodeIfPresent(String.self, forKey: .startedAt),
      completedAt: try container.decodeIfPresent(String.self, forKey: .completedAt)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encodeIfPresent(projectPath, forKey: .projectPath)
    try container.encode(status, forKey: .status)
    try container.encode(prompts, forKey: .commands)
    try container.encode(prompts, forKey: .prompts)
    try container.encode(paused, forKey: .paused)
    try container.encode(mode, forKey: .mode)
    try container.encode(currentIndex, forKey: .currentIndex)
    try container.encode(totalCostUsd, forKey: .totalCostUsd)
    try container.encodeIfPresent(createdAt, forKey: .createdAt)
    try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
    try container.encodeIfPresent(startedAt, forKey: .startedAt)
    try container.encodeIfPresent(completedAt, forKey: .completedAt)
    try container.encodeIfPresent(currentSessionId, forKey: .currentSessionId)
  }
}

public struct CursorCLIQueueRepository: Equatable, Sendable {
  private var queues: [CursorCLIQueue] = []

  public init() {}

  public mutating func createQueue(name: String, projectPath: String? = nil) -> CursorCLIQueue {
    let queue = CursorCLIQueue(id: UUID().uuidString, name: name, prompts: [], paused: false, projectPath: projectPath)
    queues.append(queue)
    return queue
  }

  public mutating func addPrompt(queueId: String, prompt: String, imagePaths: [String] = []) -> CursorCLIQueuePrompt? {
    guard let index = queues.firstIndex(where: { $0.id == queueId }) else {
      return nil
    }
    guard isMutable(queues[index]) else {
      return nil
    }
    let item = CursorCLIQueuePrompt(id: UUID().uuidString, prompt: prompt, status: .pending, mode: .continueMode, imagePaths: imagePaths, createdAt: ISO8601DateFormatter().string(from: Date()))
    queues[index].prompts.append(item)
    queues[index].updatedAt = cursorCLIOperationalNow()
    return item
  }

  public mutating func updatePrompt(queueId: String, promptId: String, status: CursorCLIQueuePromptStatus, resultExitCode: Int? = nil) -> Bool {
    guard let queueIndex = queues.firstIndex(where: { $0.id == queueId }), let promptIndex = queues[queueIndex].prompts.firstIndex(where: { $0.id == promptId }) else {
      return false
    }
    guard isMutable(queues[queueIndex]) else {
      return false
    }
    queues[queueIndex].prompts[promptIndex].status = status
    queues[queueIndex].prompts[promptIndex].resultExitCode = resultExitCode
    return true
  }

  public mutating func updatePrompt(queueId: String, promptId: String, prompt: String? = nil, status: CursorCLIQueuePromptStatus? = nil, mode: CursorCLIQueueCommandMode? = nil, resultExitCode: Int? = nil) -> Bool {
    guard let queueIndex = queues.firstIndex(where: { $0.id == queueId }), let promptIndex = queues[queueIndex].prompts.firstIndex(where: { $0.id == promptId }) else {
      return false
    }
    guard isMutable(queues[queueIndex]) else {
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
    guard let queueIndex = queues.firstIndex(where: { $0.id == queueId }), let promptIndex = queues[queueIndex].prompts.firstIndex(where: { $0.id == promptId }) else {
      return false
    }
    guard isMutable(queues[queueIndex]) else {
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
    guard let queueIndex = queues.firstIndex(where: { $0.id == queueId }), queues[queueIndex].prompts.indices.contains(from), queues[queueIndex].prompts.indices.contains(to) else {
      return false
    }
    guard isMutable(queues[queueIndex]) else {
      return false
    }
    let item = queues[queueIndex].prompts.remove(at: from)
    queues[queueIndex].prompts.insert(item, at: to)
    return true
  }

  public mutating func setMode(queueId: String, mode: CursorCLIQueueCommandMode) -> Bool {
    guard let queueIndex = queues.firstIndex(where: { $0.id == queueId }) else {
      return false
    }
    guard isMutable(queues[queueIndex]) else {
      return false
    }
    queues[queueIndex].mode = mode
    return true
  }

  public mutating func removePrompt(queueId: String, promptId: String) -> Bool {
    guard let queueIndex = queues.firstIndex(where: { $0.id == queueId }), let promptIndex = queues[queueIndex].prompts.firstIndex(where: { $0.id == promptId }) else {
      return false
    }
    guard isMutable(queues[queueIndex]) else {
      return false
    }
    queues[queueIndex].prompts.remove(at: promptIndex)
    return true
  }

  public mutating func pauseQueue(id: String) -> Bool {
    setStatus(id: id, status: .paused)
  }

  public mutating func resumeQueue(id: String) -> Bool {
    guard let index = queues.firstIndex(where: { $0.id == id }), queues[index].status == .paused else {
      return false
    }
    return setStatus(id: id, status: .pending)
  }

  public mutating func stopQueue(id: String) -> Bool {
    guard let index = queues.firstIndex(where: { $0.id == id }) else {
      return false
    }
    let now = cursorCLIOperationalNow()
    for promptIndex in queues[index].prompts.indices where queues[index].prompts[promptIndex].status == .pending {
      queues[index].prompts[promptIndex].status = .skipped
      queues[index].prompts[promptIndex].updatedAt = now
    }
    queues[index].status = .stopped
    queues[index].paused = true
    queues[index].completedAt = queues[index].completedAt ?? now
    queues[index].updatedAt = now
    return true
  }

  public mutating func deleteQueue(id: String) -> Bool {
    guard let index = queues.firstIndex(where: { $0.id == id }) else {
      return false
    }
    queues.remove(at: index)
    return true
  }

  public func listQueues() -> [CursorCLIQueue] {
    queues
  }

  public func getQueue(id: String) -> CursorCLIQueue? {
    queues.first { $0.id == id }
  }

  public func findQueue(_ idOrName: String) -> CursorCLIQueue? {
    queues.first { $0.id == idOrName || $0.name == idOrName }
  }

  public mutating func replaceQueues(_ queues: [CursorCLIQueue]) {
    self.queues = queues
  }

  @discardableResult
  public mutating func runQueue(id: String, afterPrompt: (([CursorCLIQueue]) throws -> Void)? = nil, runner: (CursorCLIQueuePrompt) throws -> Int) rethrows -> [CursorCLIQueuePrompt] {
    guard let queueIndex = queues.firstIndex(where: { $0.id == id }), !queues[queueIndex].paused else {
      return []
    }
    var completed: [CursorCLIQueuePrompt] = []
    for promptIndex in queues[queueIndex].prompts.indices where queues[queueIndex].prompts[promptIndex].status == .pending {
      let startedAt = cursorCLIOperationalNow()
      queues[queueIndex].prompts[promptIndex].status = .running
      queues[queueIndex].prompts[promptIndex].startedAt = startedAt
      queues[queueIndex].prompts[promptIndex].updatedAt = startedAt
      let exitCode = try runner(queues[queueIndex].prompts[promptIndex])
      let completedAt = cursorCLIOperationalNow()
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

  private func isMutable(_ queue: CursorCLIQueue) -> Bool {
    queue.status == .pending || queue.status == .paused
  }

  private mutating func setStatus(id: String, status: CursorCLIQueueStatus) -> Bool {
    guard let index = queues.firstIndex(where: { $0.id == id }) else {
      return false
    }
    queues[index].status = status
    queues[index].paused = status == .paused || status == .stopped
    queues[index].updatedAt = cursorCLIOperationalNow()
    return true
  }
}

public struct CursorCLIQueuesConfig: Equatable, Codable, Sendable {
  public var queues: [CursorCLIQueue]

  public init(queues: [CursorCLIQueue] = []) {
    self.queues = queues
  }
}

public enum CursorCLIQueuePersistence {
  public static func url(configDir: String) -> URL {
    URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent("queues.json")
  }

  public static func legacyDirectory(configDir: String) -> URL {
    URL(fileURLWithPath: configDir, isDirectory: true)
      .appendingPathComponent("metadata", isDirectory: true)
      .appendingPathComponent("queues", isDirectory: true)
  }

  public static func legacyURL(queueId: String, configDir: String) -> URL {
    legacyDirectory(configDir: configDir).appendingPathComponent("\(queueId).json")
  }

  public static func load(configDir: String) throws -> CursorCLIQueuesConfig {
    var config = try CursorCLIJSONStore<CursorCLIQueuesConfig>(url: url(configDir: configDir)).load(default: CursorCLIQueuesConfig())
    let legacyQueues = try loadLegacyQueues(configDir: configDir)
    for queue in legacyQueues {
      if let index = config.queues.firstIndex(where: { $0.id == queue.id }) {
        config.queues[index] = queue
      } else {
        config.queues.append(queue)
      }
    }
    return config
  }

  public static func save(_ config: CursorCLIQueuesConfig, configDir: String) throws {
    try CursorCLIJSONStore<CursorCLIQueuesConfig>(url: url(configDir: configDir)).save(config)
    try saveLegacyQueues(config.queues, configDir: configDir)
  }

  public static func createQueue(name: String, projectPath: String? = nil, configDir: String) throws -> CursorCLIQueue {
    var config = try load(configDir: configDir)
    var repository = CursorCLIQueueRepository()
    repository.replaceQueues(config.queues)
    let queue = repository.createQueue(name: name, projectPath: projectPath)
    config.queues = repository.listQueues()
    try save(config, configDir: configDir)
    return queue
  }

  public static func listQueues(configDir: String) throws -> [CursorCLIQueue] {
    try load(configDir: configDir).queues
  }

  public static func findQueue(_ idOrName: String, configDir: String) throws -> CursorCLIQueue? {
    var repository = CursorCLIQueueRepository()
    repository.replaceQueues(try load(configDir: configDir).queues)
    return repository.findQueue(idOrName)
  }

  public static func addPrompt(queueId: String, prompt: String, imagePaths: [String] = [], configDir: String) throws -> CursorCLIQueuePrompt? {
    var config = try load(configDir: configDir)
    var repository = CursorCLIQueueRepository()
    repository.replaceQueues(config.queues)
    let item = repository.addPrompt(queueId: queueId, prompt: prompt, imagePaths: imagePaths)
    config.queues = repository.listQueues()
    try save(config, configDir: configDir)
    return item
  }

  public static func removeQueue(_ id: String, configDir: String) throws -> Bool {
    var config = try load(configDir: configDir)
    var repository = CursorCLIQueueRepository()
    repository.replaceQueues(config.queues)
    let removed = repository.deleteQueue(id: id)
    config.queues = repository.listQueues()
    try save(config, configDir: configDir)
    return removed
  }

  public static func updateQueuePrompts(queueId: String, prompts: [CursorCLIQueuePrompt], configDir: String) throws -> Bool {
    var config = try load(configDir: configDir)
    guard let index = config.queues.firstIndex(where: { $0.id == queueId }) else {
      return false
    }
    config.queues[index].prompts = prompts
    try save(config, configDir: configDir)
    return true
  }

  private static func loadLegacyQueues(configDir: String) throws -> [CursorCLIQueue] {
    let directory = legacyDirectory(configDir: configDir)
    guard FileManager.default.fileExists(atPath: directory.path) else {
      return []
    }
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    return files.compactMap { file in
      guard let data = try? Data(contentsOf: file) else {
        return nil
      }
      return try? JSONDecoder().decode(CursorCLIQueue.self, from: data)
    }
  }

  private static func saveLegacyQueues(_ queues: [CursorCLIQueue], configDir: String) throws {
    let directory = legacyDirectory(configDir: configDir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let expected = Set(queues.map { "\($0.id).json" })
    let existing = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    for file in existing where file.pathExtension == "json" && !expected.contains(file.lastPathComponent) {
      try? FileManager.default.removeItem(at: file)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    for queue in queues {
      let data = try encoder.encode(queue)
      try data.write(to: legacyURL(queueId: queue.id, configDir: configDir), options: .atomic)
    }
  }
}

public struct CursorCLIGroupSession: Equatable, Codable, Sendable {
  public var id: String
  public var projectPath: String?
  public var prompt: String?
  public var status: String?
  public var dependsOn: [String]
  public var createdAt: String?

  public init(id: String, projectPath: String? = nil, prompt: String? = nil, status: String? = nil, dependsOn: [String] = [], createdAt: String? = nil) {
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

  public init(id: String = UUID().uuidString, name: String, description: String? = nil, sessionIds: [String] = [], sessions: [CursorCLIGroupSession]? = nil, paused: Bool = false, createdAt: String? = nil, updatedAt: String? = nil) {
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

public enum CursorCLIBookmarkType: String, Equatable, Codable, Sendable {
  case session
  case message
  case range
}

public struct CursorCLIBookmark: Equatable, Codable, Sendable {
  public var id: String
  public var type: CursorCLIBookmarkType
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

  public init(id: String, type: CursorCLIBookmarkType, sessionId: String, messageId: String? = nil, text: String? = nil, name: String? = nil, description: String? = nil, tags: [String] = [], startLine: Int? = nil, endLine: Int? = nil, fromMessageId: String? = nil, toMessageId: String? = nil, createdAt: String? = nil, updatedAt: String? = nil) {
    let now = cursorCLIOperationalNow()
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

public struct CursorCLIBookmarkSearchResult: Equatable, Sendable {
  public var bookmark: CursorCLIBookmark
  public var score: Double

  public init(bookmark: CursorCLIBookmark, score: Double) {
    self.bookmark = bookmark
    self.score = score
  }
}

public struct CursorCLIBookmarkManager: Equatable, Sendable {
  private var bookmarks: [CursorCLIBookmark] = []

  public init() {}

  public mutating func create(type: CursorCLIBookmarkType, sessionId: String, messageId: String? = nil, text: String? = nil, name: String? = nil, description: String? = nil, tags: [String] = [], startLine: Int? = nil, endLine: Int? = nil, fromMessageId: String? = nil, toMessageId: String? = nil) throws -> CursorCLIBookmark {
    let requiredName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let requiredName, !requiredName.isEmpty else {
      throw CursorCLIOperationalError.invalidBookmark
    }
    let hasRangeEndpoints = fromMessageId != nil || toMessageId != nil || startLine != nil || endLine != nil
    if type == .session, messageId != nil || hasRangeEndpoints {
      throw CursorCLIOperationalError.invalidBookmark
    }
    if type == .message, messageId == nil || hasRangeEndpoints {
      throw CursorCLIOperationalError.invalidBookmark
    }
    if type == .range, messageId != nil {
      throw CursorCLIOperationalError.invalidBookmark
    }
    if type == .range, fromMessageId == nil || toMessageId == nil {
      throw CursorCLIOperationalError.invalidBookmark
    }
    if type == .range, startLine != nil, endLine != nil, (startLine ?? 0) > (endLine ?? 0) {
      throw CursorCLIOperationalError.invalidBookmark
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
    let now = cursorCLIOperationalNow()
    let bookmark = CursorCLIBookmark(id: UUID().uuidString, type: type, sessionId: sessionId, messageId: messageId, text: text, name: requiredName, description: description, tags: normalizedTags, startLine: startLine, endLine: endLine, fromMessageId: fromMessageId, toMessageId: toMessageId, createdAt: now, updatedAt: now)
    bookmarks.append(bookmark)
    return bookmark
  }

  public func get(id: String) -> CursorCLIBookmark? {
    bookmarks.first { $0.id == id }
  }

  public func list(sessionId: String? = nil, tag: String? = nil) -> [CursorCLIBookmark] {
    bookmarks.filter { bookmark in
      (sessionId == nil || bookmark.sessionId == sessionId) && (tag == nil || bookmark.tags.contains { $0.caseInsensitiveCompare(tag ?? "") == .orderedSame })
    }.sorted { lhs, rhs in
      bookmarkSortTimestamp(lhs) > bookmarkSortTimestamp(rhs)
    }
  }

  public func list(sessionId: String? = nil, type: CursorCLIBookmarkType? = nil, tag: String? = nil) -> [CursorCLIBookmark] {
    bookmarks.filter { bookmark in
      (sessionId == nil || bookmark.sessionId == sessionId) && (type == nil || bookmark.type == type) && (tag == nil || bookmark.tags.contains { $0.caseInsensitiveCompare(tag ?? "") == .orderedSame })
    }.sorted { lhs, rhs in
      bookmarkSortTimestamp(lhs) > bookmarkSortTimestamp(rhs)
    }
  }

  public func search(text: String) -> [CursorCLIBookmark] {
    searchResults(text: text, limit: Int.max).map(\.bookmark)
  }

  public func searchResults(text: String, limit: Int = 50) -> [CursorCLIBookmarkSearchResult] {
    let needle = text.lowercased()
    guard !needle.isEmpty, limit != 0 else {
      return []
    }
    return bookmarks.compactMap { bookmark -> CursorCLIBookmarkSearchResult? in
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
      return score > 0 ? CursorCLIBookmarkSearchResult(bookmark: bookmark, score: score) : nil
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

  public mutating func replaceBookmarks(_ bookmarks: [CursorCLIBookmark]) {
    self.bookmarks = bookmarks
  }
}

private func bookmarkSortTimestamp(_ bookmark: CursorCLIBookmark) -> String {
  bookmark.updatedAt ?? bookmark.createdAt ?? ""
}

public struct CursorCLIBookmarksConfig: Equatable, Codable, Sendable {
  public var bookmarks: [CursorCLIBookmark]

  public init(bookmarks: [CursorCLIBookmark] = []) {
    self.bookmarks = bookmarks
  }
}

public enum CursorCLIBookmarkPersistence {
  public static func url(configDir: String) -> URL {
    URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent("bookmarks.json")
  }

  public static func legacyDirectory(configDir: String) -> URL {
    URL(fileURLWithPath: configDir, isDirectory: true)
      .appendingPathComponent("metadata", isDirectory: true)
      .appendingPathComponent("bookmarks", isDirectory: true)
  }

  public static func legacyURL(bookmarkId: String, configDir: String) -> URL {
    legacyDirectory(configDir: configDir).appendingPathComponent("\(bookmarkId).json")
  }

  public static func load(configDir: String) throws -> CursorCLIBookmarksConfig {
    var config = try CursorCLIJSONStore<CursorCLIBookmarksConfig>(url: url(configDir: configDir)).load(default: CursorCLIBookmarksConfig())
    config.bookmarks = mergeBookmarks(config.bookmarks, loadLegacyBookmarks(configDir: configDir))
    return config
  }

  public static func save(_ config: CursorCLIBookmarksConfig, configDir: String) throws {
    try CursorCLIJSONStore<CursorCLIBookmarksConfig>(url: url(configDir: configDir)).save(config)
    try saveLegacyBookmarks(config.bookmarks, configDir: configDir)
  }

  public static func addBookmark(type: CursorCLIBookmarkType, sessionId: String, messageId: String? = nil, name: String? = nil, description: String? = nil, tags: [String] = [], fromMessageId: String? = nil, toMessageId: String? = nil, configDir: String) throws -> CursorCLIBookmark {
    var config = try load(configDir: configDir)
    var manager = CursorCLIBookmarkManager()
    manager.replaceBookmarks(config.bookmarks)
    let bookmark = try manager.create(type: type, sessionId: sessionId, messageId: messageId, text: description, name: name, description: description, tags: tags, fromMessageId: fromMessageId, toMessageId: toMessageId)
    config.bookmarks = manager.list()
    try save(config, configDir: configDir)
    return bookmark
  }

  public static func getBookmark(id: String, configDir: String) throws -> CursorCLIBookmark? {
    try load(configDir: configDir).bookmarks.first { $0.id == id }
  }

  public static func listBookmarks(sessionId: String? = nil, type: CursorCLIBookmarkType? = nil, tag: String? = nil, configDir: String) throws -> [CursorCLIBookmark] {
    var manager = CursorCLIBookmarkManager()
    manager.replaceBookmarks(try load(configDir: configDir).bookmarks)
    return manager.list(sessionId: sessionId, type: type, tag: tag)
  }

  public static func searchBookmarks(_ text: String, configDir: String) throws -> [CursorCLIBookmark] {
    try searchBookmarkResults(text, limit: Int.max, configDir: configDir).map(\.bookmark)
  }

  public static func searchBookmarkResults(_ text: String, limit: Int = 50, configDir: String) throws -> [CursorCLIBookmarkSearchResult] {
    var manager = CursorCLIBookmarkManager()
    manager.replaceBookmarks(try load(configDir: configDir).bookmarks)
    return manager.searchResults(text: text, limit: limit)
  }

  public static func deleteBookmark(id: String, configDir: String) throws -> Bool {
    var config = try load(configDir: configDir)
    var manager = CursorCLIBookmarkManager()
    manager.replaceBookmarks(config.bookmarks)
    let deleted = manager.delete(id: id)
    config.bookmarks = manager.list()
    try save(config, configDir: configDir)
    return deleted
  }

  private static func mergeBookmarks(_ aggregate: [CursorCLIBookmark], _ legacy: [CursorCLIBookmark]) -> [CursorCLIBookmark] {
    var byId = Dictionary(uniqueKeysWithValues: aggregate.map { ($0.id, $0) })
    for bookmark in legacy {
      byId[bookmark.id] = bookmark
    }
    return byId.values.sorted { bookmarkSortTimestamp($0) > bookmarkSortTimestamp($1) }
  }

  private static func loadLegacyBookmarks(configDir: String) -> [CursorCLIBookmark] {
    let directory = legacyDirectory(configDir: configDir)
    guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
      return []
    }
    return entries.compactMap { entry -> CursorCLIBookmark? in
      guard entry.pathExtension == "json" else {
        return nil
      }
      let isRegularFile = (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
      guard isRegularFile, let data = try? Data(contentsOf: entry) else {
        return nil
      }
      return try? JSONDecoder().decode(CursorCLIBookmark.self, from: data)
    }
  }

  private static func saveLegacyBookmarks(_ bookmarks: [CursorCLIBookmark], configDir: String) throws {
    let directory = legacyDirectory(configDir: configDir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let expected = Set(bookmarks.map { "\($0.id).json" })
    let existing = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
    for entry in existing where entry.pathExtension == "json" && !expected.contains(entry.lastPathComponent) {
      try? FileManager.default.removeItem(at: entry)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    for bookmark in bookmarks {
      try encoder.encode(bookmark).write(to: legacyURL(bookmarkId: bookmark.id, configDir: configDir), options: .atomic)
    }
  }
}

private func cursorCLIOperationalNow() -> String {
  ISO8601DateFormatter().string(from: Date())
}

public struct CursorCLITokenMetadata: Equatable, Codable, Sendable {
  public var id: String
  public var name: String?
  public var permissions: [String]
  public var createdAt: String?
  public var expiresAt: String?
  public var lastUsedAt: String?
  public var revoked: Bool
  public var revokedAt: String?

  public init(id: String, permissions: [String], revoked: Bool = false, name: String? = nil, createdAt: String? = nil, expiresAt: String? = nil, lastUsedAt: String? = nil, revokedAt: String? = nil) {
    self.id = id
    self.name = name
    self.permissions = permissions
    self.createdAt = createdAt
    self.expiresAt = expiresAt
    self.lastUsedAt = lastUsedAt
    self.revoked = revoked
    self.revokedAt = revokedAt
  }
}

public struct CursorCLITokenRecord: Equatable, Codable, Sendable {
  var secretHash: String
  public var metadata: CursorCLITokenMetadata

  public init(secretHash: String, metadata: CursorCLITokenMetadata) {
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
    case lastUsedAt
    case revoked
    case revokedAt
    case hash
    case tokenHash
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let metadata = try container.decodeIfPresent(CursorCLITokenMetadata.self, forKey: .metadata) {
      self.metadata = metadata
      self.secretHash = try container.decode(String.self, forKey: .secretHash)
      return
    }

    let id = try container.decode(String.self, forKey: .id)
    let revokedAt = try container.decodeIfPresent(String.self, forKey: .revokedAt)
    self.metadata = CursorCLITokenMetadata(
      id: id,
      permissions: try container.decodeIfPresent([String].self, forKey: .permissions) ?? [],
      revoked: (try container.decodeIfPresent(Bool.self, forKey: .revoked)) ?? (revokedAt != nil),
      name: try container.decodeIfPresent(String.self, forKey: .name),
      createdAt: try container.decodeIfPresent(String.self, forKey: .createdAt),
      expiresAt: try container.decodeIfPresent(String.self, forKey: .expiresAt),
      lastUsedAt: try container.decodeIfPresent(String.self, forKey: .lastUsedAt),
      revokedAt: revokedAt
    )
    self.secretHash = try container.decodeIfPresent(String.self, forKey: .hash)
      ?? container.decode(String.self, forKey: .tokenHash)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(metadata.id, forKey: .id)
    try container.encodeIfPresent(metadata.name, forKey: .name)
    try container.encode(metadata.permissions, forKey: .permissions)
    try container.encodeIfPresent(metadata.createdAt, forKey: .createdAt)
    try container.encodeIfPresent(metadata.expiresAt, forKey: .expiresAt)
    try container.encodeIfPresent(metadata.lastUsedAt, forKey: .lastUsedAt)
    try container.encodeIfPresent(metadata.revokedAt, forKey: .revokedAt)
    try container.encode(secretHash, forKey: .tokenHash)
  }
}

public struct CursorCLITokenManager: Sendable {
  private var tokens: [String: CursorCLITokenRecord] = [:]

  public init() {}

  public init(records: [CursorCLITokenRecord]) {
    self.tokens = Dictionary(uniqueKeysWithValues: records.map { ($0.metadata.id, $0) })
  }

  public mutating func create(permissions: [String] = ["session:read"]) -> (secret: String, metadata: CursorCLITokenMetadata) {
    let id = UUID().uuidString
    let rawToken = Self.generateRawToken(id: id)
    guard let secret = Self.parseRawToken(rawToken)?.secret else {
      preconditionFailure("generated token must parse")
    }
    let metadata = CursorCLITokenMetadata(id: id, permissions: Self.normalizePermissions(permissions), revoked: false, createdAt: nowString())
    tokens[metadata.id] = CursorCLITokenRecord(secretHash: hashSecret(secret), metadata: metadata)
    return (rawToken, metadata)
  }

  public mutating func createRawToken(name: String? = nil, permissions: [String] = ["session:read"], expiresAt: String? = nil) -> String {
    let created = create(permissions: permissions)
    var metadata = created.metadata
    metadata.name = name
    metadata.expiresAt = expiresAt
    guard let secret = Self.parseRawToken(created.secret)?.secret else {
      return created.secret
    }
    tokens[metadata.id] = CursorCLITokenRecord(secretHash: hashSecret(secret), metadata: metadata)
    return created.secret
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

  public mutating func verify(rawToken: String, permission: String) -> CursorCLITokenMetadata? {
    guard let parsed = Self.parseRawToken(rawToken) else {
      return nil
    }
    guard let stored = tokens[parsed.id], !stored.metadata.revoked, stored.metadata.revokedAt == nil, !isExpired(stored.metadata) else {
      return nil
    }
    guard timingSafeEqual(stored.secretHash, hashSecret(parsed.secret)), permits(stored.metadata.permissions, permission: permission) else {
      return nil
    }
    var metadata = stored.metadata
    metadata.lastUsedAt = nowString()
    tokens[parsed.id] = CursorCLITokenRecord(secretHash: stored.secretHash, metadata: metadata)
    return metadata
  }

  public func listMetadata() -> [CursorCLITokenMetadata] {
    tokens.values.map(\.metadata).sorted { $0.id < $1.id }
  }

  public static func parsePermissionsCSV(_ text: String) -> [String] {
    normalizePermissions(text.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty })
  }

  public mutating func revoke(id: String) -> Bool {
    guard let stored = tokens[id] else {
      return false
    }
    var metadata = stored.metadata
    metadata.revoked = true
    metadata.revokedAt = nowString()
    tokens[id] = CursorCLITokenRecord(secretHash: stored.secretHash, metadata: metadata)
    return true
  }

  public mutating func rotate(id: String) -> String? {
    guard let stored = tokens[id] else {
      return nil
    }
    let rawToken = Self.generateRawToken(id: id)
    guard let secret = Self.parseRawToken(rawToken)?.secret else {
      return nil
    }
    var metadata = stored.metadata
    metadata.revoked = false
    metadata.revokedAt = nil
    tokens[id] = CursorCLITokenRecord(secretHash: hashSecret(secret), metadata: metadata)
    return rawToken
  }

  public static func normalizePermissions(_ permissions: [String]) -> [String] {
    let allowed: Set<String> = ["session:create", "session:read", "session:cancel", "group:run", "group:*", "queue:*", "bookmark:*", "files:*", "server:read", "server:admin"]
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
    permissions.contains(permission) || permissions.contains("*") || permissions.contains(permission.split(separator: ":").first.map { "\($0):*" } ?? "") || (permission == "server:read" && permissions.contains("server:admin"))
  }

  public func records() -> [CursorCLITokenRecord] {
    tokens.values.sorted { $0.metadata.id < $1.metadata.id }
  }

  private func isExpired(_ metadata: CursorCLITokenMetadata) -> Bool {
    guard let expiresAt = metadata.expiresAt else {
      return false
    }
    guard let expiresAtDate = parseTokenTimestamp(expiresAt) else {
      return true
    }
    return expiresAtDate <= Date()
  }

  private func nowString() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
  }

  private func parseTokenTimestamp(_ text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: text) {
      return date
    }
    return ISO8601DateFormatter().date(from: text)
  }

  private static func generateRawToken(id: String) -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    for index in bytes.indices {
      bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
    }
    let encoded = Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "\(id).\(encoded)"
  }

  private static func parseRawToken(_ rawToken: String) -> (id: String, secret: String)? {
    let parts = rawToken.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
      return nil
    }
    return (String(parts[0]), String(parts[1]))
  }

}

public struct CursorCLITokensConfig: Equatable, Codable, Sendable {
  public var tokens: [CursorCLITokenRecord]

  public init(tokens: [CursorCLITokenRecord] = []) {
    self.tokens = tokens
  }
}

public enum CursorCLITokenPersistence {
  public static func url(configDir: String) -> URL {
    URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent("tokens.json")
  }

  public static func load(configDir: String) throws -> CursorCLITokenManager {
    let config = try CursorCLIJSONStore<CursorCLITokensConfig>(url: url(configDir: configDir)).load(default: CursorCLITokensConfig())
    return CursorCLITokenManager(records: config.tokens)
  }

  public static func save(_ manager: CursorCLITokenManager, configDir: String) throws {
    try CursorCLIJSONStore<CursorCLITokensConfig>(url: url(configDir: configDir)).save(CursorCLITokensConfig(tokens: manager.records()))
  }

  public static func createRawToken(name: String? = nil, permissions: [String], expiresAt: String? = nil, configDir: String) throws -> String {
    var manager = try load(configDir: configDir)
    let token = manager.createRawToken(name: name, permissions: permissions, expiresAt: expiresAt)
    try save(manager, configDir: configDir)
    return token
  }

  public static func listMetadata(configDir: String) throws -> [CursorCLITokenMetadata] {
    try load(configDir: configDir).listMetadata()
  }

  public static func verify(rawToken: String, permission: String, configDir: String) throws -> CursorCLITokenMetadata? {
    var manager = try load(configDir: configDir)
    guard let metadata = manager.verify(rawToken: rawToken, permission: permission) else {
      return nil
    }
    try save(manager, configDir: configDir)
    return metadata
  }

  public static func revoke(id: String, configDir: String) throws -> Bool {
    var manager = try load(configDir: configDir)
    let revoked = manager.revoke(id: id)
    try save(manager, configDir: configDir)
    return revoked
  }

  public static func rotate(id: String, configDir: String) throws -> String? {
    var manager = try load(configDir: configDir)
    guard let rawToken = manager.rotate(id: id) else {
      return nil
    }
    try save(manager, configDir: configDir)
    return rawToken
  }
}

public struct CursorCLIJSONStore<Value: Codable & Sendable>: Sendable {
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

public enum CursorCLISessionCommands {
  public static func list(cursorCLIHome: String? = nil) -> [CursorCLISession] {
    listSessions(options: CursorCLISessionListOptions(cursorCLIHome: cursorCLIHome)).sessions
  }

  public static func show(sessionId: String, cursorCLIHome: String? = nil) -> CursorCLISession? {
    findSession(id: sessionId, cursorCLIHome: cursorCLIHome)
  }

  public static func search(query: String, cursorCLIHome: String? = nil) throws -> CursorCLISessionsSearchResult {
    try CursorCLISessionIndex.searchSessions(query: query, options: CursorCLISessionListOptions(cursorCLIHome: cursorCLIHome))
  }

  public static func runArguments(prompt: String, options: CursorCLIProcessOptions = CursorCLIProcessOptions()) -> [String] {
    CursorCLIProcessCommandBuilder.buildExecArguments(prompt: prompt, options: options)
  }

  public static func resumeArguments(sessionId: String, prompt: String? = nil, options: CursorCLIProcessOptions = CursorCLIProcessOptions()) -> [String] {
    CursorCLIProcessCommandBuilder.buildResumeArguments(sessionId: sessionId, prompt: prompt, options: options)
  }
}

public enum CursorCLIOperationalError: Error, Equatable {
  case invalidBookmark
}
