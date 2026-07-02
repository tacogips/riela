import RielaCore

public enum HookVendor: String, Codable, CaseIterable, Sendable {
  case claudeCode = "claude-code"
  case codex
  case gemini
}

public struct HookContext: Codable, Equatable, Sendable {
  public var vendor: HookVendor
  public var eventName: String
  public var agentSessionId: String
  public var agentBackend: String?
  public var workingDirectory: String
  public var transcriptPath: String?
  public var model: String?
  public var backendMetadata: JSONObject
  public var inferredFields: Set<String>

  private enum CodingKeys: String, CodingKey {
    case vendor
    case eventName
    case agentSessionId
    case agentBackend
    case workingDirectory
    case transcriptPath
    case model
    case backendMetadata
    case inferredFields
  }

  public init(
    vendor: HookVendor = .codex,
    eventName: String = "unknown",
    agentSessionId: String,
    agentBackend: String? = nil,
    workingDirectory: String = "",
    transcriptPath: String? = nil,
    model: String? = nil,
    backendMetadata: JSONObject = [:],
    inferredFields: Set<String> = []
  ) {
    self.vendor = vendor
    self.eventName = eventName
    self.agentSessionId = agentSessionId
    self.agentBackend = agentBackend
    self.workingDirectory = workingDirectory
    self.transcriptPath = transcriptPath
    self.model = model
    self.backendMetadata = backendMetadata
    self.inferredFields = inferredFields
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    var inferredFields = try container.decodeIfPresent(Set<String>.self, forKey: .inferredFields) ?? []
    if let vendor = try container.decodeIfPresent(HookVendor.self, forKey: .vendor) {
      self.vendor = vendor
    } else {
      self.vendor = .codex
      inferredFields.insert("vendor")
    }
    if let eventName = try container.decodeIfPresent(String.self, forKey: .eventName) {
      self.eventName = eventName
    } else {
      self.eventName = "unknown"
      inferredFields.insert("eventName")
    }
    self.agentSessionId = try container.decode(String.self, forKey: .agentSessionId)
    self.agentBackend = try container.decodeIfPresent(String.self, forKey: .agentBackend)
    self.workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
    self.transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
    self.model = try container.decodeIfPresent(String.self, forKey: .model)
    self.backendMetadata = try container.decodeIfPresent(JSONObject.self, forKey: .backendMetadata) ?? [:]
    self.inferredFields = inferredFields
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(vendor, forKey: .vendor)
    try container.encode(eventName, forKey: .eventName)
    try container.encode(agentSessionId, forKey: .agentSessionId)
    try container.encodeIfPresent(agentBackend, forKey: .agentBackend)
    try container.encode(workingDirectory, forKey: .workingDirectory)
    try container.encodeIfPresent(transcriptPath, forKey: .transcriptPath)
    try container.encodeIfPresent(model, forKey: .model)
    try container.encode(backendMetadata, forKey: .backendMetadata)
    if !inferredFields.isEmpty {
      try container.encode(inferredFields.sorted(), forKey: .inferredFields)
    }
  }
}
