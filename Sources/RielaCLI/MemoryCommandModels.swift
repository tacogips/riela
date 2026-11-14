import Foundation
import RielaMemory

public enum MemoryCommandKind: String, Codable, CaseIterable, Sendable {
  case save
  case update
  case load
  case search
  case metadata
  case tags
  case relatedIds = "related-ids"
  case history
  case showVersion = "show-version"
  case restoreVersion = "restore-version"
  case retireHistory = "retire-history"
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
  public var version: Int64?
  public var beforeVersion: Int64?
  public var expectedHeadVersion: Int64?
  public var throughVersion: Int64?
  public var dryRun: Bool
  public var payloadJSON: String?
  public var payloadFile: String?
  public var registeredAt: String?
  public var matchPatterns: [String]
  public var tags: [String]
  public var relatedRecordIds: [Int64]
  public var filePaths: [String]
  public var clearFiles: Bool
  public var sortOrder: MemoryValueSortOrder
  public var limit: Int
  public var maxPayloadBytes: Int
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
    version: Int64? = nil,
    beforeVersion: Int64? = nil,
    expectedHeadVersion: Int64? = nil,
    throughVersion: Int64? = nil,
    dryRun: Bool = false,
    payloadJSON: String? = nil,
    payloadFile: String? = nil,
    registeredAt: String? = nil,
    matchPatterns: [String] = [],
    tags: [String] = [],
    relatedRecordIds: [Int64] = [],
    filePaths: [String] = [],
    clearFiles: Bool = false,
    sortOrder: MemoryValueSortOrder = .valueAsc,
    limit: Int = 30,
    maxPayloadBytes: Int = MemorySearchOptions.defaultMaxPayloadBytes,
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
    self.version = version
    self.beforeVersion = beforeVersion
    self.expectedHeadVersion = expectedHeadVersion
    self.throughVersion = throughVersion
    self.dryRun = dryRun
    self.payloadJSON = payloadJSON
    self.payloadFile = payloadFile
    self.registeredAt = registeredAt
    self.matchPatterns = matchPatterns
    self.tags = tags
    self.relatedRecordIds = relatedRecordIds
    self.filePaths = filePaths
    self.clearFiles = clearFiles
    self.sortOrder = sortOrder
    self.limit = limit
    self.maxPayloadBytes = maxPayloadBytes
    self.offset = offset
    self.databaseRoot = databaseRoot
    self.workingDirectory = workingDirectory
    self.output = output
  }
}
