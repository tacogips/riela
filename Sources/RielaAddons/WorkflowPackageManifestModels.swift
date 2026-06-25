public enum WorkflowPackageKind: String, Codable, Sendable {
  case workflow
  case nodeAddon = "node-addon"
}

public enum WorkflowPackageSkillVendor: String, Codable, CaseIterable, Sendable {
  case agents
  case claude
  case codex
  case cursor
  case gemini
}

public enum WorkflowPackageAddonExecutionKind: String, Codable, Sendable {
  case declarative
  case container
  case localCommand = "local-command"
  case nativeBundle = "native-bundle"
}

public struct WorkflowPackageLoopMetadata: Codable, Equatable, Sendable {
  public var promotionReady: Bool
  public var usageContract: Bool
  public var requiredMockScenarios: [String]
  public var expectedResults: [String]
  public var requiredGates: [String]
  public var requiredPolicies: [String]
  public var minimumEvidenceSchemaVersion: Int?

  public init(
    promotionReady: Bool = false,
    usageContract: Bool = false,
    requiredMockScenarios: [String] = [],
    expectedResults: [String] = [],
    requiredGates: [String] = [],
    requiredPolicies: [String] = [],
    minimumEvidenceSchemaVersion: Int? = nil
  ) {
    self.promotionReady = promotionReady
    self.usageContract = usageContract
    self.requiredMockScenarios = requiredMockScenarios
    self.expectedResults = expectedResults
    self.requiredGates = requiredGates
    self.requiredPolicies = requiredPolicies
    self.minimumEvidenceSchemaVersion = minimumEvidenceSchemaVersion
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case promotionReady
    case usageContract
    case requiredMockScenarios
    case expectedResults
    case requiredGates
    case requiredPolicies
    case minimumEvidenceSchemaVersion
  }

  public init(from decoder: Decoder) throws {
    try rejectUnsupportedKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue), label: "package manifest loop metadata")
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.promotionReady = try container.decodeIfPresent(Bool.self, forKey: .promotionReady) ?? false
    self.usageContract = try container.decodeIfPresent(Bool.self, forKey: .usageContract) ?? false
    self.requiredMockScenarios = try container.decodeIfPresent([String].self, forKey: .requiredMockScenarios) ?? []
    self.expectedResults = try container.decodeIfPresent([String].self, forKey: .expectedResults) ?? []
    self.requiredGates = try container.decodeIfPresent([String].self, forKey: .requiredGates) ?? []
    self.requiredPolicies = try container.decodeIfPresent([String].self, forKey: .requiredPolicies) ?? []
    self.minimumEvidenceSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .minimumEvidenceSchemaVersion)
  }
}

public struct WorkflowPackageValidationIssue: Codable, Equatable, Sendable {
  public var code: String
  public var path: String
  public var message: String

  public init(code: String, path: String, message: String) {
    self.code = code
    self.path = path
    self.message = message
  }
}
