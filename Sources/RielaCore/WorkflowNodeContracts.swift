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

public func normalizeCliAgentBackend(_ rawValue: String) -> CliAgentBackend? {
  CliAgentBackend(rawValue: rawValue)
}

public func normalizeNodeExecutionBackend(_ rawValue: String) -> NodeExecutionBackend? {
  NodeExecutionBackend(rawValue: rawValue)
}

public func nodeExecutionBackendListText() -> String {
  let values = NodeExecutionBackend.allCases.map(\.rawValue)
  guard let last = values.last else {
    return ""
  }
  let leading = values.dropLast()
  return leading.isEmpty ? last : "\(leading.joined(separator: ", ")), or \(last)"
}
