import Foundation

public struct WorkflowInstanceNodePatch: Codable, Equatable, Sendable {
  public var executionBackend: NodeExecutionBackend?
  public var model: String?
  public var effort: NodeReasoningEffort?
  /// A stable named Kaiba API instance override for a `kaiba/*` node.
  public var kaibaInstanceId: String?
  /// Distinguishes an inherited binding from an explicit reset persisted as
  /// `kaibaInstanceId: null` in a workflow-instance patch.
  public var clearsKaibaInstanceId: Bool

  public init(
    executionBackend: NodeExecutionBackend? = nil,
    model: String? = nil,
    effort: NodeReasoningEffort? = nil,
    kaibaInstanceId: String? = nil,
    clearsKaibaInstanceId: Bool = false
  ) {
    self.executionBackend = executionBackend
    self.model = model
    self.effort = effort
    self.kaibaInstanceId = kaibaInstanceId
    self.clearsKaibaInstanceId = clearsKaibaInstanceId
  }

  public var isEmpty: Bool {
    executionBackend == nil
      && normalizedModel == nil
      && effort == nil
      && kaibaInstanceId == nil
      && !clearsKaibaInstanceId
  }

  public var jsonObject: JSONObject {
    var object: JSONObject = [:]
    if let executionBackend {
      object["executionBackend"] = .string(executionBackend.rawValue)
    }
    if let normalizedModel {
      object["model"] = .string(normalizedModel)
    }
    if let effort {
      object["effort"] = .string(effort.rawValue)
    }
    if clearsKaibaInstanceId {
      object["kaibaInstanceId"] = .null
    } else if let kaibaInstanceId {
      object["kaibaInstanceId"] = .string(kaibaInstanceId)
    }
    return object
  }

  public init(jsonObject: JSONObject, nodeId: String) throws {
    self.init()
    for field in jsonObject.keys.sorted() {
      guard Self.supportedFields.contains(field) else {
        throw WorkflowInstanceResolutionError.unsupportedField(field)
      }
      switch field {
      case "executionBackend":
        guard let raw = Self.stringValue(jsonObject[field]),
              let backend = NodeExecutionBackend(rawValue: raw) else {
          throw WorkflowInstanceResolutionError.invalidFieldValue(field)
        }
        executionBackend = backend
      case "model":
        guard let model = Self.stringValue(jsonObject[field]),
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw WorkflowInstanceResolutionError.invalidFieldValue(field)
        }
        self.model = model
      case "effort":
        guard let raw = Self.stringValue(jsonObject[field]),
              let effort = NodeReasoningEffort(rawValue: raw) else {
          throw WorkflowInstanceResolutionError.invalidFieldValue(field)
        }
        self.effort = effort
      case "kaibaInstanceId":
        if case .null = jsonObject[field] {
          clearsKaibaInstanceId = true
          continue
        }
        guard let identifier = Self.stringValue(jsonObject[field]),
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw WorkflowInstanceResolutionError.invalidFieldValue(field)
        }
        kaibaInstanceId = identifier
      default:
        throw WorkflowInstanceResolutionError.unsupportedField(field)
      }
    }
    _ = nodeId
  }

  private static let supportedFields: Set<String> = ["executionBackend", "model", "effort", "kaibaInstanceId"]

  private enum CodingKeys: String, CodingKey {
    case executionBackend
    case model
    case effort
    case kaibaInstanceId
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    executionBackend = try container.decodeIfPresent(NodeExecutionBackend.self, forKey: .executionBackend)
    model = try container.decodeIfPresent(String.self, forKey: .model)
    effort = try container.decodeIfPresent(NodeReasoningEffort.self, forKey: .effort)
    if container.contains(.kaibaInstanceId) {
      clearsKaibaInstanceId = try container.decodeNil(forKey: .kaibaInstanceId)
    } else {
      clearsKaibaInstanceId = false
    }
    kaibaInstanceId = clearsKaibaInstanceId
      ? nil
      : try container.decodeIfPresent(String.self, forKey: .kaibaInstanceId)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(executionBackend, forKey: .executionBackend)
    try container.encodeIfPresent(model, forKey: .model)
    try container.encodeIfPresent(effort, forKey: .effort)
    if clearsKaibaInstanceId {
      try container.encodeNil(forKey: .kaibaInstanceId)
    } else {
      try container.encodeIfPresent(kaibaInstanceId, forKey: .kaibaInstanceId)
    }
  }

  public func merging(_ override: WorkflowInstanceNodePatch) -> WorkflowInstanceNodePatch {
    var merged = self
    if let executionBackend = override.executionBackend {
      merged.executionBackend = executionBackend
    }
    if let model = override.model {
      merged.model = model
    }
    if let effort = override.effort {
      merged.effort = effort
    }
    if override.clearsKaibaInstanceId {
      merged.kaibaInstanceId = nil
      merged.clearsKaibaInstanceId = true
    } else if let kaibaInstanceId = override.kaibaInstanceId {
      merged.kaibaInstanceId = kaibaInstanceId
      merged.clearsKaibaInstanceId = false
    }
    return merged
  }

  private static func stringValue(_ value: JSONValue?) -> String? {
    guard case let .string(string)? = value else {
      return nil
    }
    return string
  }

  private var normalizedModel: String? {
    guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
      return nil
    }
    return model
  }
}

public struct WorkflowInstanceConfiguration: Codable, Equatable, Sendable {
  public var workingDirectory: String?
  public var environmentFilePath: String?
  public var environmentVariables: [String: String]
  public var defaultVariables: JSONObject
  public var nodePatches: [String: WorkflowInstanceNodePatch]

  public init(
    workingDirectory: String? = nil,
    environmentFilePath: String? = nil,
    environmentVariables: [String: String] = [:],
    defaultVariables: JSONObject = [:],
    nodePatches: [String: WorkflowInstanceNodePatch] = [:]
  ) {
    self.workingDirectory = workingDirectory
    self.environmentFilePath = environmentFilePath
    self.environmentVariables = environmentVariables
    self.defaultVariables = defaultVariables
    self.nodePatches = nodePatches
  }

  private enum CodingKeys: String, CodingKey {
    case workingDirectory
    case environmentFilePath
    case environmentVariables
    case defaultVariables
    case nodePatches
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      workingDirectory: try container.decodeIfPresent(String.self, forKey: .workingDirectory),
      environmentFilePath: try container.decodeIfPresent(String.self, forKey: .environmentFilePath),
      environmentVariables: try container.decodeIfPresent([String: String].self, forKey: .environmentVariables) ?? [:],
      defaultVariables: try container.decodeIfPresent(JSONObject.self, forKey: .defaultVariables) ?? [:],
      nodePatches: try container.decodeIfPresent(
        [String: WorkflowInstanceNodePatch].self,
        forKey: .nodePatches
      ) ?? [:]
    )
  }

  public var isEmpty: Bool {
    normalizedWorkingDirectory == nil
      && environmentFilePath == nil
      && environmentVariables.isEmpty
      && defaultVariables.isEmpty
      && nodePatches.values.allSatisfy(\.isEmpty)
  }

  public var nodePatchJSONObject: JSONObject? {
    let entries = nodePatches
      .filter { !$0.value.isEmpty }
      .map { ($0.key, JSONValue.object($0.value.jsonObject)) }
    guard !entries.isEmpty else {
      return nil
    }
    return Dictionary(uniqueKeysWithValues: entries)
  }

  public var normalizedWorkingDirectory: String? {
    guard let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
          !workingDirectory.isEmpty else {
      return nil
    }
    return workingDirectory
  }

  public func merging(_ override: WorkflowInstanceConfiguration) -> WorkflowInstanceConfiguration {
    var merged = self
    if let workingDirectory = override.workingDirectory {
      merged.workingDirectory = workingDirectory
    }
    if let environmentFilePath = override.environmentFilePath {
      merged.environmentFilePath = environmentFilePath
    }
    for (key, value) in override.environmentVariables {
      merged.environmentVariables[key] = value
    }
    for (key, value) in override.defaultVariables {
      merged.defaultVariables[key] = value
    }
    for (key, value) in override.nodePatches {
      merged.nodePatches[key] = (merged.nodePatches[key] ?? WorkflowInstanceNodePatch()).merging(value)
    }
    return merged
  }
}

public struct WorkflowInstanceDefinition: Codable, Equatable, Sendable {
  public var identity: String
  public var workflowId: String
  public var sourceIdentity: String?
  public var displayName: String?
  public var configuration: WorkflowInstanceConfiguration

  public init(
    identity: String,
    workflowId: String,
    sourceIdentity: String? = nil,
    displayName: String? = nil,
    configuration: WorkflowInstanceConfiguration = WorkflowInstanceConfiguration()
  ) {
    self.identity = identity
    self.workflowId = workflowId
    self.sourceIdentity = sourceIdentity
    self.displayName = displayName
    self.configuration = configuration
  }

  private enum CodingKeys: String, CodingKey {
    case identity
    case workflowId
    case sourceIdentity
    case displayName
    case configuration
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      identity: try container.decode(String.self, forKey: .identity),
      workflowId: try container.decode(String.self, forKey: .workflowId),
      sourceIdentity: try container.decodeIfPresent(String.self, forKey: .sourceIdentity),
      displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
      configuration: try container.decodeIfPresent(
        WorkflowInstanceConfiguration.self,
        forKey: .configuration
      ) ?? WorkflowInstanceConfiguration()
    )
  }

  public static func defaultInstance(workflowId: String) -> WorkflowInstanceDefinition {
    WorkflowInstanceDefinition(identity: WorkflowInstanceIdentity.defaultIdentity, workflowId: workflowId)
  }
}

public enum WorkflowInstanceKind: String, Codable, Equatable, Sendable {
  case `default`
  case named
  case ephemeral

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    switch value {
    case Self.default.rawValue:
      self = .default
    case Self.named.rawValue:
      self = .named
    case Self.ephemeral.rawValue:
      self = .ephemeral
    default:
      throw DecodingError.dataCorruptedError(
        in: try decoder.singleValueContainer(),
        debugDescription: "unknown workflow instance kind '\(value)'"
      )
    }
  }
}

public enum WorkflowInstanceIdentity {
  public static let defaultIdentity = "default"
}
