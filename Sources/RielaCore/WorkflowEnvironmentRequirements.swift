import Foundation

/// Declaration-only union. Values are resolved once at the execution boundary.
public enum WorkflowEnvironmentRequirements {
  public static func names(workflow: WorkflowDefinition, nodePayloads: [String: AgentNodePayload]) throws -> [String] {
    var names = workflow.requiredEnvironment ?? []
    for node in workflow.nodes { names += node.requiredEnvironment ?? [] }
    for node in workflow.nodeRegistry { names += (node.requiredEnvironment ?? []) + addonNames(node.addon?.env) }
    for node in workflow.nodes { names += addonNames(node.addon?.env) }
    for payload in nodePayloads.values {
      names += payload.requiredEnvironment ?? []
      names += payload.agentEnvironment.values.compactMap { $0.required ? $0.fromEnv : nil }
      if let name = payload.apiKeyEnvironment { names.append(name) }
    }
    return try validated(names)
  }

  public static func addonNames(_ environment: JSONObject?) -> [String] {
    environment?.values.compactMap { value in
      guard case let .object(binding) = value, case let .string(name)? = binding["fromEnv"],
        binding["required"] != .bool(false) else { return nil }
      return name
    } ?? []
  }

  public static func validated(_ names: [String]) throws -> [String] {
    guard names.count <= 4096, names.allSatisfy({ $0.utf8.count <= 128 && isValidEnvironmentVariableName($0) }) else {
      throw AgentEnvironmentResolutionError.invalidTargetName("requiredEnvironment")
    }
    return Array(Set(names)).sorted()
  }
}
