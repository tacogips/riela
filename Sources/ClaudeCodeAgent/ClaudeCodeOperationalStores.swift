import Foundation

public enum ClaudeCodeQueuePromptStatus: String, Equatable, Codable, Sendable {
  case pending
  case running
  case completed
  case failed
  case skipped
}

public enum ClaudeCodeQueueStatus: String, Equatable, Codable, Sendable {
  case pending
  case running
  case paused
  case completed
  case failed
  case stopped
}

public struct ClaudeCodeQueuePrompt: Equatable, Codable, Sendable {
  public var id: String
  public var prompt: String
  public var status: ClaudeCodeQueuePromptStatus
  public var mode: ClaudeCodeQueueCommandMode?
  public var imagePaths: [String]
  public var resultExitCode: Int?
  public var sessionId: String?
  public var error: String?
  public var createdAt: String?
  public var startedAt: String?
  public var completedAt: String?
  public var updatedAt: String?

  public init(
    id: String,
    prompt: String,
    status: ClaudeCodeQueuePromptStatus = .pending,
    mode: ClaudeCodeQueueCommandMode? = nil,
    imagePaths: [String] = [],
    resultExitCode: Int? = nil,
    sessionId: String? = nil,
    error: String? = nil,
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
    self.status = try container.decodeIfPresent(ClaudeCodeQueuePromptStatus.self, forKey: .status) ?? .pending
    self.mode = try container.decodeIfPresent(ClaudeCodeQueueCommandMode.self, forKey: .mode)
      ?? container.decodeIfPresent(ClaudeCodeQueueCommandMode.self, forKey: .sessionMode)
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

public enum ClaudeCodeQueueCommandMode: String, Equatable, Codable, Sendable {
  case auto
  case manual
  case continueMode = "continue"
  case new

  public static func legacy(_ raw: String) -> ClaudeCodeQueueCommandMode? {
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
      return ClaudeCodeQueueCommandMode(rawValue: raw)
    }
  }
}

public struct ClaudeCodeQueue: Equatable, Sendable {
  public var id: String
  public var name: String
  public var projectPath: String?
  public var prompts: [ClaudeCodeQueuePrompt]
  public var paused: Bool
  public var mode: ClaudeCodeQueueCommandMode
  public var createdAt: String?
  public var status: ClaudeCodeQueueStatus
  public var currentIndex: Int
  public var currentSessionId: String?
  public var totalCostUsd: Double
  public var updatedAt: String?
  public var startedAt: String?
  public var completedAt: String?

  public init(
    id: String,
    name: String,
    prompts: [ClaudeCodeQueuePrompt],
    paused: Bool,
    mode: ClaudeCodeQueueCommandMode = .auto,
    projectPath: String? = nil,
    createdAt: String? = nil,
    status: ClaudeCodeQueueStatus? = nil,
    currentIndex: Int = 0,
    currentSessionId: String? = nil,
    totalCostUsd: Double = 0,
    updatedAt: String? = nil,
    startedAt: String? = nil,
    completedAt: String? = nil
  ) {
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

extension ClaudeCodeQueue: Codable {
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
    let prompts = try container.decodeIfPresent([ClaudeCodeQueuePrompt].self, forKey: .prompts)
      ?? container.decodeIfPresent([ClaudeCodeQueuePrompt].self, forKey: .commands)
      ?? []
    let status = try container.decodeIfPresent(ClaudeCodeQueueStatus.self, forKey: .status) ?? .pending
    let paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? (status == .paused || status == .stopped)
    let mode = try container.decodeIfPresent(ClaudeCodeQueueCommandMode.self, forKey: .mode)
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

public struct ClaudeCodeQueueRepository: Equatable, Sendable {
  private var queues: [ClaudeCodeQueue] = []

  public init() {}

  public mutating func createQueue(name: String, projectPath: String? = nil) -> ClaudeCodeQueue {
    let queue = ClaudeCodeQueue(id: UUID().uuidString, name: name, prompts: [], paused: false, projectPath: projectPath)
    queues.append(queue)
    return queue
  }

  public mutating func addPrompt(queueId: String, prompt: String, imagePaths: [String] = []) -> ClaudeCodeQueuePrompt? {
    guard let index = queues.firstIndex(where: { $0.id == queueId }) else {
      return nil
    }
    guard isMutable(queues[index]) else {
      return nil
    }
    let item = ClaudeCodeQueuePrompt(id: UUID().uuidString, prompt: prompt, status: .pending, mode: .continueMode, imagePaths: imagePaths, createdAt: ISO8601DateFormatter().string(from: Date()))
    queues[index].prompts.append(item)
    queues[index].updatedAt = claudeCodeOperationalNow()
    return item
  }

  public mutating func updatePrompt(queueId: String, promptId: String, status: ClaudeCodeQueuePromptStatus, resultExitCode: Int? = nil) -> Bool {
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

  public mutating func updatePrompt(queueId: String, promptId: String, prompt: String? = nil, status: ClaudeCodeQueuePromptStatus? = nil, mode: ClaudeCodeQueueCommandMode? = nil, resultExitCode: Int? = nil) -> Bool {
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

  public mutating func setMode(queueId: String, mode: ClaudeCodeQueueCommandMode) -> Bool {
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
    let now = claudeCodeOperationalNow()
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

  public func listQueues() -> [ClaudeCodeQueue] {
    queues
  }

  public func getQueue(id: String) -> ClaudeCodeQueue? {
    queues.first { $0.id == id }
  }

  public func findQueue(_ idOrName: String) -> ClaudeCodeQueue? {
    queues.first { $0.id == idOrName || $0.name == idOrName }
  }

  public mutating func replaceQueues(_ queues: [ClaudeCodeQueue]) {
    self.queues = queues
  }

  @discardableResult
  public mutating func runQueue(id: String, afterPrompt: (([ClaudeCodeQueue]) throws -> Void)? = nil, runner: (ClaudeCodeQueuePrompt) throws -> Int) rethrows -> [ClaudeCodeQueuePrompt] {
    guard let queueIndex = queues.firstIndex(where: { $0.id == id }), !queues[queueIndex].paused else {
      return []
    }
    var completed: [ClaudeCodeQueuePrompt] = []
    for promptIndex in queues[queueIndex].prompts.indices where queues[queueIndex].prompts[promptIndex].status == .pending {
      let startedAt = claudeCodeOperationalNow()
      queues[queueIndex].prompts[promptIndex].status = .running
      queues[queueIndex].prompts[promptIndex].startedAt = startedAt
      queues[queueIndex].prompts[promptIndex].updatedAt = startedAt
      let exitCode = try runner(queues[queueIndex].prompts[promptIndex])
      let completedAt = claudeCodeOperationalNow()
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

  private func isMutable(_ queue: ClaudeCodeQueue) -> Bool {
    queue.status == .pending || queue.status == .paused
  }

  private mutating func setStatus(id: String, status: ClaudeCodeQueueStatus) -> Bool {
    guard let index = queues.firstIndex(where: { $0.id == id }) else {
      return false
    }
    queues[index].status = status
    queues[index].paused = status == .paused || status == .stopped
    queues[index].updatedAt = claudeCodeOperationalNow()
    return true
  }
}

public struct ClaudeCodeQueuesConfig: Equatable, Codable, Sendable {
  public var queues: [ClaudeCodeQueue]

  public init(queues: [ClaudeCodeQueue] = []) {
    self.queues = queues
  }
}

public enum ClaudeCodeQueuePersistence {
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

  public static func load(configDir: String) throws -> ClaudeCodeQueuesConfig {
    var config = try ClaudeCodeJSONStore<ClaudeCodeQueuesConfig>(url: url(configDir: configDir)).load(default: ClaudeCodeQueuesConfig())
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

  public static func save(_ config: ClaudeCodeQueuesConfig, configDir: String) throws {
    try ClaudeCodeJSONStore<ClaudeCodeQueuesConfig>(url: url(configDir: configDir)).save(config)
    try saveLegacyQueues(config.queues, configDir: configDir)
  }

  public static func createQueue(name: String, projectPath: String? = nil, configDir: String) throws -> ClaudeCodeQueue {
    var config = try load(configDir: configDir)
    var repository = ClaudeCodeQueueRepository()
    repository.replaceQueues(config.queues)
    let queue = repository.createQueue(name: name, projectPath: projectPath)
    config.queues = repository.listQueues()
    try save(config, configDir: configDir)
    return queue
  }

  public static func listQueues(configDir: String) throws -> [ClaudeCodeQueue] {
    try load(configDir: configDir).queues
  }

  public static func findQueue(_ idOrName: String, configDir: String) throws -> ClaudeCodeQueue? {
    var repository = ClaudeCodeQueueRepository()
    repository.replaceQueues(try load(configDir: configDir).queues)
    return repository.findQueue(idOrName)
  }

  public static func addPrompt(queueId: String, prompt: String, imagePaths: [String] = [], configDir: String) throws -> ClaudeCodeQueuePrompt? {
    var config = try load(configDir: configDir)
    var repository = ClaudeCodeQueueRepository()
    repository.replaceQueues(config.queues)
    let item = repository.addPrompt(queueId: queueId, prompt: prompt, imagePaths: imagePaths)
    config.queues = repository.listQueues()
    try save(config, configDir: configDir)
    return item
  }

  public static func removeQueue(_ id: String, configDir: String) throws -> Bool {
    var config = try load(configDir: configDir)
    var repository = ClaudeCodeQueueRepository()
    repository.replaceQueues(config.queues)
    let removed = repository.deleteQueue(id: id)
    config.queues = repository.listQueues()
    try save(config, configDir: configDir)
    return removed
  }

  public static func updateQueuePrompts(queueId: String, prompts: [ClaudeCodeQueuePrompt], configDir: String) throws -> Bool {
    var config = try load(configDir: configDir)
    guard let index = config.queues.firstIndex(where: { $0.id == queueId }) else {
      return false
    }
    config.queues[index].prompts = prompts
    try save(config, configDir: configDir)
    return true
  }

  private static func loadLegacyQueues(configDir: String) throws -> [ClaudeCodeQueue] {
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
      return try? JSONDecoder().decode(ClaudeCodeQueue.self, from: data)
    }
  }

  private static func saveLegacyQueues(_ queues: [ClaudeCodeQueue], configDir: String) throws {
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

public struct ClaudeCodeGroupSession: Equatable, Codable, Sendable {
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

public struct ClaudeCodeGroup: Equatable, Sendable {
  public var id: String
  public var name: String
  public var description: String?
  public var sessionIds: [String]
  public var sessions: [ClaudeCodeGroupSession]
  public var paused: Bool
  public var createdAt: String?
  public var updatedAt: String?

  public init(
    id: String = UUID().uuidString,
    name: String,
    description: String? = nil,
    sessionIds: [String] = [],
    sessions: [ClaudeCodeGroupSession]? = nil,
    paused: Bool = false,
    createdAt: String? = nil,
    updatedAt: String? = nil
  ) {
    let now = claudeCodeOperationalNow()
    self.id = id
    self.name = name
    self.description = description
    self.sessions = sessions ?? sessionIds.map { ClaudeCodeGroupSession(id: $0) }
    self.sessionIds = self.sessions.map(\.id)
    self.paused = paused
    self.createdAt = createdAt ?? now
    self.updatedAt = updatedAt ?? now
  }
}

extension ClaudeCodeGroup: Codable {
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
    let decodedSessions = try container.decodeIfPresent([ClaudeCodeGroupSession].self, forKey: .sessions)
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

public struct ClaudeCodeGroupRepository: Equatable, Sendable {
  private var groups: [ClaudeCodeGroup] = []

  public init() {}

  public mutating func createGroup(name: String, description: String? = nil) -> ClaudeCodeGroup {
    let group = ClaudeCodeGroup(id: UUID().uuidString, name: name, description: description, sessionIds: [], paused: false)
    groups.append(group)
    return group
  }

  public mutating func addSession(groupId: String, sessionId: String) -> Bool {
    addSession(groupId: groupId, session: ClaudeCodeGroupSession(id: sessionId))
  }

  public mutating func addSession(groupId: String, session: ClaudeCodeGroupSession) -> Bool {
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
      groups[index].updatedAt = claudeCodeOperationalNow()
    }
    return true
  }

  public mutating func removeSession(groupId: String, sessionId: String) -> Bool {
    guard let groupIndex = groups.firstIndex(where: { $0.id == groupId }), let sessionIndex = groups[groupIndex].sessionIds.firstIndex(of: sessionId) else {
      return false
    }
    groups[groupIndex].sessionIds.remove(at: sessionIndex)
    groups[groupIndex].sessions.removeAll { $0.id == sessionId }
    groups[groupIndex].updatedAt = claudeCodeOperationalNow()
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

  public func listGroups() -> [ClaudeCodeGroup] {
    groups
  }

  public func getGroup(id: String) -> ClaudeCodeGroup? {
    groups.first { $0.id == id }
  }

  public func findGroup(_ idOrName: String) -> ClaudeCodeGroup? {
    groups.first { $0.id == idOrName || $0.name == idOrName }
  }

  public mutating func replaceGroups(_ groups: [ClaudeCodeGroup]) {
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
    groups[index].updatedAt = claudeCodeOperationalNow()
    return true
  }
}

public struct ClaudeCodeGroupsConfig: Equatable, Codable, Sendable {
  public var groups: [ClaudeCodeGroup]

  public init(groups: [ClaudeCodeGroup] = []) {
    self.groups = groups
  }
}

public enum ClaudeCodeGroupPersistence {
  public static func url(configDir: String) -> URL {
    URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent("groups.json")
  }

  public static func legacyDirectory(configDir: String) -> URL {
    URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent("session-groups", isDirectory: true)
  }

  public static func legacyMetaURL(groupId: String, configDir: String) -> URL {
    legacyDirectory(configDir: configDir).appendingPathComponent(groupId, isDirectory: true).appendingPathComponent("meta.json")
  }

  public static func load(configDir: String) throws -> ClaudeCodeGroupsConfig {
    var config = try ClaudeCodeJSONStore<ClaudeCodeGroupsConfig>(url: url(configDir: configDir)).load(default: ClaudeCodeGroupsConfig())
    config.groups = mergeGroups(config.groups, loadLegacyGroups(configDir: configDir))
    return config
  }

  public static func save(_ config: ClaudeCodeGroupsConfig, configDir: String) throws {
    try ClaudeCodeJSONStore<ClaudeCodeGroupsConfig>(url: url(configDir: configDir)).save(config)
    try saveLegacyGroups(config.groups, configDir: configDir)
  }

  private static func mutate(configDir: String, _ update: (inout ClaudeCodeGroupRepository) throws -> Void) throws -> [ClaudeCodeGroup] {
    var config = try load(configDir: configDir)
    var repository = ClaudeCodeGroupRepository()
    repository.replaceGroups(config.groups)
    try update(&repository)
    config.groups = repository.listGroups()
    try save(config, configDir: configDir)
    return config.groups
  }

  public static func createGroup(name: String, description: String? = nil, configDir: String) throws -> ClaudeCodeGroup {
    var created: ClaudeCodeGroup?
    _ = try mutate(configDir: configDir) { repository in
      created = repository.createGroup(name: name, description: description)
    }
    return created!
  }

  public static func listGroups(configDir: String) throws -> [ClaudeCodeGroup] {
    try load(configDir: configDir).groups
  }

  public static func findGroup(_ idOrName: String, configDir: String) throws -> ClaudeCodeGroup? {
    var repository = ClaudeCodeGroupRepository()
    repository.replaceGroups(try load(configDir: configDir).groups)
    return repository.findGroup(idOrName)
  }

  public static func addSession(groupId: String, sessionId: String, configDir: String) throws -> Bool {
    try addSession(groupId: groupId, session: ClaudeCodeGroupSession(id: sessionId), configDir: configDir)
  }

  public static func addSession(groupId: String, session: ClaudeCodeGroupSession, configDir: String) throws -> Bool {
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

  private static func mergeGroups(_ aggregate: [ClaudeCodeGroup], _ legacy: [ClaudeCodeGroup]) -> [ClaudeCodeGroup] {
    var byId = Dictionary(uniqueKeysWithValues: aggregate.map { ($0.id, $0) })
    for group in legacy {
      byId[group.id] = group
    }
    return byId.values.sorted { ($0.updatedAt ?? $0.createdAt ?? "") > ($1.updatedAt ?? $1.createdAt ?? "") }
  }

  private static func loadLegacyGroups(configDir: String) -> [ClaudeCodeGroup] {
    let directory = legacyDirectory(configDir: configDir)
    guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
      return []
    }
    return entries.compactMap { entry -> ClaudeCodeGroup? in
      let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
      guard isDirectory else {
        return nil
      }
      let meta = entry.appendingPathComponent("meta.json")
      guard let data = try? Data(contentsOf: meta) else {
        return nil
      }
      return try? JSONDecoder().decode(ClaudeCodeGroup.self, from: data)
    }
  }

  private static func saveLegacyGroups(_ groups: [ClaudeCodeGroup], configDir: String) throws {
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

public enum ClaudeCodeSessionCommands {
  public static func list(claudeCodeHome: String? = nil) -> [ClaudeCodeSession] {
    listSessions(options: ClaudeCodeSessionListOptions(claudeCodeHome: claudeCodeHome)).sessions
  }

  public static func show(sessionId: String, claudeCodeHome: String? = nil) -> ClaudeCodeSession? {
    findSession(id: sessionId, claudeCodeHome: claudeCodeHome)
  }

  public static func search(query: String, claudeCodeHome: String? = nil) throws -> ClaudeCodeSessionsSearchResult {
    try ClaudeCodeSessionIndex.searchSessions(query: query, options: ClaudeCodeSessionListOptions(claudeCodeHome: claudeCodeHome))
  }

  public static func runArguments(prompt: String, options: ClaudeCodeProcessOptions = ClaudeCodeProcessOptions()) -> [String] {
    ClaudeCodeProcessCommandBuilder.buildExecArguments(prompt: prompt, options: options)
  }

  public static func resumeArguments(sessionId: String, prompt: String? = nil, options: ClaudeCodeProcessOptions = ClaudeCodeProcessOptions()) -> [String] {
    ClaudeCodeProcessCommandBuilder.buildResumeArguments(sessionId: sessionId, prompt: prompt, options: options)
  }
}
