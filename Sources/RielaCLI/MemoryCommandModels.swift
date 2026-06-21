import Foundation

public enum MemoryCommandKind: String, Codable, Sendable {
  case save
  case load
  case search
}

public struct MemoryCommand: Equatable, Sendable {
  public var kind: MemoryCommandKind
  public var options: MemoryCommandOptions

  public init(kind: MemoryCommandKind, options: MemoryCommandOptions) {
    self.kind = kind
    self.options = options
  }
}

public struct MemoryCommandOptions: Equatable, Sendable {
  public var memoryId: String
  public var workflowId: String?
  public var allWorkflows: Bool
  public var nodeId: String?
  public var payloadJSON: String?
  public var payloadFile: String?
  public var registeredAt: String?
  public var matchPatterns: [String]
  public var limit: Int
  public var databaseRoot: String?
  public var workingDirectory: String
  public var output: WorkflowOutputFormat

  public init(
    memoryId: String,
    workflowId: String? = nil,
    allWorkflows: Bool = false,
    nodeId: String? = nil,
    payloadJSON: String? = nil,
    payloadFile: String? = nil,
    registeredAt: String? = nil,
    matchPatterns: [String] = [],
    limit: Int = 30,
    databaseRoot: String? = nil,
    workingDirectory: String = FileManager.default.currentDirectoryPath,
    output: WorkflowOutputFormat = .jsonl
  ) {
    self.memoryId = memoryId
    self.workflowId = workflowId
    self.allWorkflows = allWorkflows
    self.nodeId = nodeId
    self.payloadJSON = payloadJSON
    self.payloadFile = payloadFile
    self.registeredAt = registeredAt
    self.matchPatterns = matchPatterns
    self.limit = limit
    self.databaseRoot = databaseRoot
    self.workingDirectory = workingDirectory
    self.output = output
  }
}
