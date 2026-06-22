import Foundation
import RielaMemory

public enum MemoryCommandKind: String, Codable, Sendable {
  case save
  case update
  case load
  case search
  case metadata
  case tags
  case relatedIds = "related-ids"
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
  public var recordId: Int64?
  public var payloadJSON: String?
  public var payloadFile: String?
  public var registeredAt: String?
  public var matchPatterns: [String]
  public var tags: [String]
  public var relatedRecordIds: [Int64]
  public var sortOrder: MemoryValueSortOrder
  public var limit: Int
  public var offset: Int
  public var databaseRoot: String?
  public var workingDirectory: String
  public var output: WorkflowOutputFormat

  public init(
    memoryId: String,
    workflowId: String? = nil,
    allWorkflows: Bool = false,
    nodeId: String? = nil,
    recordId: Int64? = nil,
    payloadJSON: String? = nil,
    payloadFile: String? = nil,
    registeredAt: String? = nil,
    matchPatterns: [String] = [],
    tags: [String] = [],
    relatedRecordIds: [Int64] = [],
    sortOrder: MemoryValueSortOrder = .valueAsc,
    limit: Int = 30,
    offset: Int = 0,
    databaseRoot: String? = nil,
    workingDirectory: String = FileManager.default.currentDirectoryPath,
    output: WorkflowOutputFormat = .jsonl
  ) {
    self.memoryId = memoryId
    self.workflowId = workflowId
    self.allWorkflows = allWorkflows
    self.nodeId = nodeId
    self.recordId = recordId
    self.payloadJSON = payloadJSON
    self.payloadFile = payloadFile
    self.registeredAt = registeredAt
    self.matchPatterns = matchPatterns
    self.tags = tags
    self.relatedRecordIds = relatedRecordIds
    self.sortOrder = sortOrder
    self.limit = limit
    self.offset = offset
    self.databaseRoot = databaseRoot
    self.workingDirectory = workingDirectory
    self.output = output
  }
}
