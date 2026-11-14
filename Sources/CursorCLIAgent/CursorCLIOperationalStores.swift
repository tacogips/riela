import Foundation
import AgentRuntimeKit

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

  public init(
    id: String,
    prompt: String,
    status: CursorCLIQueuePromptStatus = .pending,
    mode: CursorCLIQueueCommandMode? = nil,
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

  public init(
    id: String,
    name: String,
    prompts: [CursorCLIQueuePrompt],
    paused: Bool,
    mode: CursorCLIQueueCommandMode = .auto,
    projectPath: String? = nil,
    createdAt: String? = nil,
    status: CursorCLIQueueStatus? = nil,
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

func cursorCLIOperationalNow() -> String {
  agentRuntimeISO8601Now()
}

public typealias CursorCLIJSONStore<Value: Codable & Sendable> = AgentJSONFileStore<Value>

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
