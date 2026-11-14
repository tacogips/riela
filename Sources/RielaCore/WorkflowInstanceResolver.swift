import Foundation

public struct EffectiveWorkflowInstance: Equatable, Sendable {
  public var identity: String
  public var kind: WorkflowInstanceKind
  public var baseIdentity: String?
  public var configuration: WorkflowInstanceConfiguration

  public init(
    identity: String,
    kind: WorkflowInstanceKind,
    baseIdentity: String? = nil,
    configuration: WorkflowInstanceConfiguration
  ) {
    self.identity = identity
    self.kind = kind
    self.baseIdentity = baseIdentity
    self.configuration = configuration
  }

  public var configurationJSONObject: JSONObject {
    var object: JSONObject = [:]
    if let workingDirectory = configuration.workingDirectory {
      object["workingDirectory"] = .string(workingDirectory)
    }
    if let environmentFilePath = configuration.environmentFilePath {
      object["environmentFilePath"] = .string(environmentFilePath)
    }
    if !configuration.environmentVariables.isEmpty {
      object["environmentVariables"] = .object(
        configuration.environmentVariables.mapValues { .string($0) }
      )
    }
    if !configuration.defaultVariables.isEmpty {
      object["defaultVariables"] = .object(configuration.defaultVariables)
    }
    if let nodePatchJSONObject = configuration.nodePatchJSONObject {
      object["nodePatches"] = .object(nodePatchJSONObject)
    }
    return object
  }
}

public enum WorkflowInstanceResolutionError: Error, Equatable, Sendable {
  case nodePatchMustBeObject(String)
  case unknownNodeId(String)
  case unsupportedField(String)
  case invalidFieldValue(String)
  case modelChangeFrozen(String)
}

public enum WorkflowInstanceResolver {
  public static func resolve(
    workflowId: String,
    base: WorkflowInstanceDefinition?,
    runVariables: JSONObject = [:],
    runNodePatch: [String: WorkflowInstanceNodePatch] = [:],
    nodePayloads: [String: AgentNodePayload]
  ) throws -> (instance: EffectiveWorkflowInstance, nodePayloads: [String: AgentNodePayload]) {
    let baseDefinition = base ?? WorkflowInstanceDefinition.defaultInstance(workflowId: workflowId)
    let baseKind: WorkflowInstanceKind = base == nil ? .default : .named
    let overrideConfiguration = WorkflowInstanceConfiguration(
      defaultVariables: runVariables,
      nodePatches: runNodePatch
    )
    let configuration = baseDefinition.configuration.merging(overrideConfiguration)
    let hasRunOverrides = !runVariables.isEmpty || !runNodePatch.isEmpty
    let effective = EffectiveWorkflowInstance(
      identity: hasRunOverrides ? ephemeralIdentity(baseDefinition.identity) : baseDefinition.identity,
      kind: hasRunOverrides ? .ephemeral : baseKind,
      baseIdentity: hasRunOverrides ? baseDefinition.identity : nil,
      configuration: configuration
    )

    var patchedPayloads = nodePayloads
    patchedPayloads = try applyNodePatches(baseDefinition.configuration.nodePatches, to: patchedPayloads)
    patchedPayloads = try applyNodePatches(runNodePatch, to: patchedPayloads)
    return (effective, patchedPayloads)
  }

  public static func nodePatches(from jsonObject: JSONObject) throws -> [String: WorkflowInstanceNodePatch] {
    var patches: [String: WorkflowInstanceNodePatch] = [:]
    for nodeId in jsonObject.keys.sorted() {
      guard case let .object(nodePatch)? = jsonObject[nodeId] else {
        throw WorkflowInstanceResolutionError.nodePatchMustBeObject(nodeId)
      }
      patches[nodeId] = try WorkflowInstanceNodePatch(jsonObject: nodePatch, nodeId: nodeId)
    }
    return patches
  }

  public static func applyNodePatches(
    _ patches: [String: WorkflowInstanceNodePatch],
    to nodePayloads: [String: AgentNodePayload]
  ) throws -> [String: AgentNodePayload] {
    var patched = nodePayloads
    for nodeId in patches.keys.sorted() {
      guard var payload = patched[nodeId] else {
        throw WorkflowInstanceResolutionError.unknownNodeId(nodeId)
      }
      payload = try apply(patches[nodeId] ?? WorkflowInstanceNodePatch(), to: payload, nodeId: nodeId)
      patched[nodeId] = payload
    }
    return patched
  }

  private static func apply(
    _ patch: WorkflowInstanceNodePatch,
    to payload: AgentNodePayload,
    nodeId: String
  ) throws -> AgentNodePayload {
    var patched = payload
    if let executionBackend = patch.executionBackend {
      patched.executionBackend = executionBackend
    }
    if let model = normalizedModel(patch.model) {
      guard !patched.modelFreeze || model == patched.model else {
        throw WorkflowInstanceResolutionError.modelChangeFrozen(nodeId)
      }
      patched.model = model
    } else if patch.model != nil {
      throw WorkflowInstanceResolutionError.invalidFieldValue("model")
    }
    if let effort = patch.effort {
      patched.effort = effort
    }
    return patched
  }

  public static func ephemeralIdentity(_ baseIdentity: String) -> String {
    "\(baseIdentity)+overrides"
  }

  private static func normalizedModel(_ model: String?) -> String? {
    guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
      return nil
    }
    return model
  }
}
