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
