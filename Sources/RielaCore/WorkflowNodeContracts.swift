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
  public var guaranteedWhen: [String]?

  public init(
    description: String? = nil,
    jsonSchema: JSONObject? = nil,
    maxValidationAttempts: Int? = nil,
    projection: WorkflowOutputProjection? = nil,
    guaranteedWhen: [String]? = nil
  ) {
    self.description = description
    self.jsonSchema = jsonSchema
    self.maxValidationAttempts = maxValidationAttempts
    self.projection = projection
    self.guaranteedWhen = guaranteedWhen
  }

  public var invalidGuaranteedWhenIndex: Int? {
    var seen: Set<String> = []
    for (index, name) in (guaranteedWhen ?? []).enumerated() {
      let reserved: Set<String> = ["true", "false", "always", "never"]
      let parsed = try? ParsedWorkflowCondition(name)
      if name.isEmpty || reserved.contains(name) || parsed?.identifiers.map(\.name) != [name]
        || !seen.insert(name).inserted {
        return index
      }
    }
    return nil
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
