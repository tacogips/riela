import Foundation

public enum RielaMemoryError: Error, Equatable, Sendable {
  case invalidMemoryId(String)
  case invalidWorkflowId(String)
  case invalidLimit(Int)
  case invalidPattern(String)
  case invalidOffset(Int)
  case tooManyTags(Int)
  case duplicateTag(String)
  case tooManyRelatedRecordIds(Int)
  case duplicateRelatedRecordId(Int64)
  case invalidRelatedRecordId(Int64)
  case missingRelatedRecordId(Int64)
  case missingRecordId(Int64)
  case tooManyFiles(Int)
  case duplicateFilePath(String)
  case invalidFilePath(String)
  case openFailed(String)
  case sqliteFailed(String)
  case jsonBUnavailable
  case invalidJSON(String)
}

public enum MemoryValueSortOrder: String, Codable, Equatable, Sendable {
  case valueAsc = "value-asc"
  case valueDesc = "value-desc"
}

public enum MemorySortOrder: String, Codable, Equatable, Sendable {
  case registeredDesc = "registered-desc"
  case registeredAsc = "registered-asc"
}

public enum MemoryJSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([MemoryJSONValue])
  case object([String: MemoryJSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([MemoryJSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: MemoryJSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case let .bool(value):
      try container.encode(value)
    case let .number(value):
      try container.encode(value)
    case let .string(value):
      try container.encode(value)
    case let .array(value):
      try container.encode(value)
    case let .object(value):
      try container.encode(value)
    }
  }
}

public struct MemoryRecord: Codable, Equatable, Sendable {
  public var recordId: Int64
  public var memoryId: String
  public var workflowId: String
  public var nodeId: String?
  public var registeredAt: String
  public var tags: [String]
  public var relatedRecordIds: [Int64]
  public var files: [MemoryFileReference]
  public var payload: MemoryJSONValue

  public init(
    recordId: Int64,
    memoryId: String,
    workflowId: String,
    nodeId: String? = nil,
    registeredAt: String,
    tags: [String] = [],
    relatedRecordIds: [Int64] = [],
    files: [MemoryFileReference] = [],
    payload: MemoryJSONValue
  ) {
    self.recordId = recordId
    self.memoryId = memoryId
    self.workflowId = workflowId
    self.nodeId = nodeId
    self.registeredAt = registeredAt
    self.tags = tags
    self.relatedRecordIds = relatedRecordIds
    self.files = files
    self.payload = payload
  }
}

public struct MemoryFileReference: Codable, Equatable, Sendable {
  public var path: String
  public var mediaType: String?
  public var kind: String?
  public var name: String?
  public var sizeBytes: Int64?

  public init(
    path: String,
    mediaType: String? = nil,
    kind: String? = nil,
    name: String? = nil,
    sizeBytes: Int64? = nil
  ) {
    self.path = path
    self.mediaType = mediaType
    self.kind = kind
    self.name = name
    self.sizeBytes = sizeBytes
  }
}

public struct MemoryMetadata: Codable, Equatable, Sendable {
  public var memoryId: String
  public var description: String?
  public var purpose: String?
  public var dataSchema: MemoryJSONValue?
  public var updatedAt: String

  public init(
    memoryId: String,
    description: String? = nil,
    purpose: String? = nil,
    dataSchema: MemoryJSONValue? = nil,
    updatedAt: String
  ) {
    self.memoryId = memoryId
    self.description = description
    self.purpose = purpose
    self.dataSchema = dataSchema
    self.updatedAt = updatedAt
  }
}

public struct MemoryRecordReference: Codable, Equatable, Sendable {
  public var referenceId: Int64
  public var memoryId: String
  public var recordId: Int64
  public var referencedAt: String

  public init(referenceId: Int64, memoryId: String, recordId: Int64, referencedAt: String) {
    self.referenceId = referenceId
    self.memoryId = memoryId
    self.recordId = recordId
    self.referencedAt = referencedAt
  }
}

public struct MemorySearchOptions: Equatable, Sendable {
  public static let defaultMaxPayloadBytes = 1_000_000

  public var workflowId: String
  public var includeAllWorkflows: Bool
  public var nodeId: String?
  public var matchPatterns: [String]
  public var tags: [String]
  public var relatedRecordIds: [Int64]
  public var sortOrder: MemorySortOrder
  public var limit: Int
  public var maxPayloadBytes: Int

  public init(
    workflowId: String,
    includeAllWorkflows: Bool = false,
    nodeId: String? = nil,
    matchPatterns: [String] = [],
    tags: [String] = [],
    relatedRecordIds: [Int64] = [],
    sortOrder: MemorySortOrder = .registeredDesc,
    limit: Int = 30,
    maxPayloadBytes: Int = MemorySearchOptions.defaultMaxPayloadBytes
  ) {
    self.workflowId = workflowId
    self.includeAllWorkflows = includeAllWorkflows
    self.nodeId = nodeId
    self.matchPatterns = matchPatterns
    self.tags = tags
    self.relatedRecordIds = relatedRecordIds
    self.sortOrder = sortOrder
    self.limit = limit
    self.maxPayloadBytes = maxPayloadBytes
  }
}

public struct MemoryValueListOptions: Equatable, Sendable {
  public var workflowId: String?
  public var includeAllWorkflows: Bool
  public var sortOrder: MemoryValueSortOrder
  public var limit: Int
  public var offset: Int

  public init(
    workflowId: String? = nil,
    includeAllWorkflows: Bool = false,
    sortOrder: MemoryValueSortOrder = .valueAsc,
    limit: Int = 30,
    offset: Int = 0
  ) {
    self.workflowId = workflowId
    self.includeAllWorkflows = includeAllWorkflows
    self.sortOrder = sortOrder
    self.limit = limit
    self.offset = offset
  }
}
