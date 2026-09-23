import Foundation

public struct NodePromptVariant: Codable, Equatable, Sendable {
  public var systemPromptTemplate: String?
  public var systemPromptTemplateFile: String?
  public var promptTemplate: String?
  public var promptTemplateFile: String?
  public var sessionStartPromptTemplate: String?
  public var sessionStartPromptTemplateFile: String?

  public init(
    systemPromptTemplate: String? = nil,
    systemPromptTemplateFile: String? = nil,
    promptTemplate: String? = nil,
    promptTemplateFile: String? = nil,
    sessionStartPromptTemplate: String? = nil,
    sessionStartPromptTemplateFile: String? = nil
  ) {
    self.systemPromptTemplate = systemPromptTemplate
    self.systemPromptTemplateFile = systemPromptTemplateFile
    self.promptTemplate = promptTemplate
    self.promptTemplateFile = promptTemplateFile
    self.sessionStartPromptTemplate = sessionStartPromptTemplate
    self.sessionStartPromptTemplateFile = sessionStartPromptTemplateFile
  }
}

public struct NodeInputContract: Codable, Equatable, Sendable {
  public var description: String?
  public var jsonSchema: JSONObject?

  public init(description: String? = nil, jsonSchema: JSONObject? = nil) {
    self.description = description
    self.jsonSchema = jsonSchema
  }
}

public struct NodeOutputContract: Codable, Equatable, Sendable {
  public var description: String?
  public var jsonSchema: JSONObject?
  public var maxValidationAttempts: Int?
  public var projection: WorkflowOutputProjection?

  public init(
    description: String? = nil,
    jsonSchema: JSONObject? = nil,
    maxValidationAttempts: Int? = nil,
    projection: WorkflowOutputProjection? = nil
  ) {
    self.description = description
    self.jsonSchema = jsonSchema
    self.maxValidationAttempts = maxValidationAttempts
    self.projection = projection
  }
}

public enum WorkflowOutputProjectionKind: String, Codable, CaseIterable, Hashable, Sendable {
  case latestInputPayload = "latest-input-payload"
}

public struct WorkflowOutputProjection: Codable, Equatable, Sendable {
  public var kind: WorkflowOutputProjectionKind

  public init(kind: WorkflowOutputProjectionKind) {
    self.kind = kind
  }
}
