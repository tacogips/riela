#if os(macOS)
import Foundation
import RielaCore
import RielaServer

public struct RielaAppDaemonWorkflowPreference: Codable, Equatable, Sendable {
  public var identity: String
  public var sourceIdentity: String?
  public var displayName: String?
  public var available: Bool
  public var active: Bool
  public var configuration: RielaAppDaemonWorkflowConfiguration

  private enum CodingKeys: String, CodingKey {
    case identity
    case sourceIdentity
    case displayName
    case available
    case enabledAtLaunch
    case active
    case environmentFilePath
    case environmentVariables
    case defaultVariables
    case nodePatches
    case configuration
  }

  public init(
    identity: String,
    sourceIdentity: String? = nil,
    displayName: String? = nil,
    available: Bool = false,
    active: Bool = false,
    workingDirectory: String? = nil,
    environmentFilePath: String? = nil,
    environmentVariables: [String: String] = [:],
    defaultVariables: JSONObject = [:],
    nodePatches: [String: RielaAppDaemonWorkflowNodePatch] = [:]
  ) {
    self.identity = identity
    self.sourceIdentity = sourceIdentity
    self.displayName = displayName
    self.available = available
    self.active = active
    configuration = RielaAppDaemonWorkflowConfiguration(
      workingDirectory: workingDirectory,
      environmentFilePath: environmentFilePath,
      environmentVariables: environmentVariables,
      defaultVariables: defaultVariables,
      nodePatches: nodePatches
    )
  }

  public init(identity: String, enabledAtLaunch: Bool, active: Bool = false) {
    self.init(identity: identity, available: enabledAtLaunch, active: active)
  }

  public static func imported(identity: String, startsImmediately: Bool) -> RielaAppDaemonWorkflowPreference {
    RielaAppDaemonWorkflowPreference(identity: identity, available: true, active: startsImmediately)
  }

  public var enabledAtLaunch: Bool {
    get { available }
    set { available = newValue }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    identity = try container.decode(String.self, forKey: .identity)
    sourceIdentity = try container.decodeIfPresent(String.self, forKey: .sourceIdentity)
    displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    available = try container.decodeIfPresent(Bool.self, forKey: .available)
      ?? container.decodeIfPresent(Bool.self, forKey: .enabledAtLaunch)
      ?? false
    active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? available
    if let decodedConfiguration = try container.decodeIfPresent(
      RielaAppDaemonWorkflowConfiguration.self,
      forKey: .configuration
    ) {
      configuration = decodedConfiguration
    } else {
      configuration = RielaAppDaemonWorkflowConfiguration(
        environmentFilePath: try container.decodeIfPresent(String.self, forKey: .environmentFilePath),
        environmentVariables: try container.decodeIfPresent([String: String].self, forKey: .environmentVariables) ?? [:],
        defaultVariables: try container.decodeIfPresent(JSONObject.self, forKey: .defaultVariables) ?? [:],
        nodePatches: try container.decodeIfPresent(
          [String: RielaAppDaemonWorkflowNodePatch].self,
          forKey: .nodePatches
        ) ?? [:]
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(identity, forKey: .identity)
    try container.encodeIfPresent(sourceIdentity, forKey: .sourceIdentity)
    try container.encodeIfPresent(displayName, forKey: .displayName)
    try container.encode(available, forKey: .available)
    try container.encode(active, forKey: .active)
    if !configuration.isEmpty {
      try container.encode(configuration, forKey: .configuration)
    }
  }

  public var workingDirectory: String? {
    get { configuration.workingDirectory }
    set { configuration.workingDirectory = newValue }
  }

  public var environmentFilePath: String? {
    get { configuration.environmentFilePath }
    set { configuration.environmentFilePath = newValue }
  }

  public var environmentVariables: [String: String] {
    get { configuration.environmentVariables }
    set { configuration.environmentVariables = newValue }
  }

  public var defaultVariables: JSONObject {
    get { configuration.defaultVariables }
    set { configuration.defaultVariables = newValue }
  }

  public var nodePatches: [String: RielaAppDaemonWorkflowNodePatch] {
    get { configuration.nodePatches }
    set { configuration.nodePatches = newValue }
  }

  public var nodePatchJSONObject: JSONObject? {
    configuration.nodePatchJSONObject
  }
}

public struct RielaAppDaemonWorkflowConfiguration: Codable, Equatable, Sendable {
  public var workingDirectory: String?
  public var environmentFilePath: String?
  public var environmentVariables: [String: String]
  public var defaultVariables: JSONObject
  public var nodePatches: [String: RielaAppDaemonWorkflowNodePatch]

  public init(
    workingDirectory: String? = nil,
    environmentFilePath: String? = nil,
    environmentVariables: [String: String] = [:],
    defaultVariables: JSONObject = [:],
    nodePatches: [String: RielaAppDaemonWorkflowNodePatch] = [:]
  ) {
    self.workingDirectory = workingDirectory
    self.environmentFilePath = environmentFilePath
    self.environmentVariables = environmentVariables
    self.defaultVariables = defaultVariables
    self.nodePatches = nodePatches
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

  public func serveConfiguration(inheritedEnvironment: [String: String]) -> WorkflowServeRuntimeConfiguration {
    WorkflowServeRuntimeConfiguration(
      workingDirectory: normalizedWorkingDirectory,
      inheritedEnvironment: inheritedEnvironment,
      defaultVariables: defaultVariables,
      nodePatch: nodePatchJSONObject
    )
  }

  private var normalizedWorkingDirectory: String? {
    guard let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
          !workingDirectory.isEmpty else {
      return nil
    }
    return workingDirectory
  }
}

public struct RielaAppDaemonWorkflowNodePatch: Codable, Equatable, Sendable {
  public var executionBackend: NodeExecutionBackend?
  public var model: String?
  public var effort: NodeReasoningEffort?

  public init(
    executionBackend: NodeExecutionBackend? = nil,
    model: String? = nil,
    effort: NodeReasoningEffort? = nil
  ) {
    self.executionBackend = executionBackend
    self.model = model
    self.effort = effort
  }

  public var isEmpty: Bool {
    executionBackend == nil && normalizedModel == nil && effort == nil
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
    return object
  }

  private var normalizedModel: String? {
    guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
      return nil
    }
    return model
  }
}
#endif
