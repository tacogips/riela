#if os(macOS)
import Foundation
import RielaAddons
import RielaCore

enum RielaAppWorkflowEnvironmentRequirements {
  static func requiredEnvironment(
    workflowDirectory: URL,
    packageRequirements: [RielaAppEnvRequirement] = []
  ) -> [RielaAppEnvRequirement] {
    var requirements = packageRequirements
    for requirement in workflowRequirements(workflowDirectory: workflowDirectory)
      where !requirements.contains(where: { $0.name == requirement.name }) {
      requirements.append(requirement)
    }
    return requirements.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  private static func workflowRequirements(workflowDirectory: URL) -> [RielaAppEnvRequirement] {
    let workflowURL = workflowDirectory.appendingPathComponent("workflow.json")
    guard let workflow = decode(WorkflowEnvironmentDescriptor.self, from: workflowURL) else {
      return []
    }
    var requirements: [RielaAppEnvRequirement] = []
    appendRequirements(from: workflow.nodes, workflowDirectory: workflowDirectory, into: &requirements)
    return requirements
  }

  private static func appendRequirements(
    from nodes: [WorkflowEnvironmentNode],
    workflowDirectory: URL,
    into requirements: inout [RielaAppEnvRequirement]
  ) {
    for node in nodes {
      appendAddonRequirements(from: node.addon, into: &requirements)
      appendAgentRequirements(from: node.agentEnvironment, into: &requirements)
      if let nodeFile = node.nodeFile,
        let referenced = decode(
          WorkflowEnvironmentNodePayload.self,
          from: workflowDirectory.appendingPathComponent(nodeFile)
        ) {
        appendAddonRequirements(from: referenced.addon, into: &requirements)
        appendAgentRequirements(from: referenced.agentEnvironment, into: &requirements)
      }
    }
  }

  private static func appendAddonRequirements(
    from addon: WorkflowEnvironmentAddon?,
    into requirements: inout [RielaAppEnvRequirement]
  ) {
    guard let env = addon?.env else {
      return
    }
    for binding in env.values where binding.required != false {
      appendRequirement(binding.fromEnv, into: &requirements)
    }
  }

  private static func appendAgentRequirements(
    from agentEnvironment: [String: WorkflowEnvironmentAgentBinding]?,
    into requirements: inout [RielaAppEnvRequirement]
  ) {
    guard let agentEnvironment else {
      return
    }
    for binding in agentEnvironment.values where binding.required {
      appendRequirement(binding.fromEnv, into: &requirements)
    }
  }

  private static func appendRequirement(_ name: String?, into requirements: inout [RielaAppEnvRequirement]) {
    guard let name, WorkflowPackageManifestValidator.isValidEnvironmentVariableName(name) else {
      return
    }
    if !requirements.contains(where: { $0.name == name }) {
      requirements.append(RielaAppEnvRequirement(name: name))
    }
  }

  private static func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else {
      return nil
    }
    return try? JSONDecoder().decode(type, from: data)
  }
}

private struct WorkflowEnvironmentDescriptor: Decodable {
  var nodes: [WorkflowEnvironmentNode]

  private enum CodingKeys: String, CodingKey {
    case nodes
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    nodes = try container.decodeIfPresent([WorkflowEnvironmentNode].self, forKey: .nodes) ?? []
  }
}

private struct WorkflowEnvironmentNode: Decodable {
  var nodeFile: String?
  var addon: WorkflowEnvironmentAddon?
  var agentEnvironment: [String: WorkflowEnvironmentAgentBinding]?
}

private struct WorkflowEnvironmentNodePayload: Decodable {
  var addon: WorkflowEnvironmentAddon?
  var agentEnvironment: [String: WorkflowEnvironmentAgentBinding]?
}

private struct WorkflowEnvironmentAddon: Decodable {
  var env: [String: WorkflowEnvironmentAddonBinding]?
}

private struct WorkflowEnvironmentAddonBinding: Decodable {
  var fromEnv: String?
  var required: Bool?
}

private struct WorkflowEnvironmentAgentBinding: Decodable {
  var fromEnv: String?
  var required: Bool

  private enum CodingKeys: String, CodingKey {
    case fromEnv
    case required
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    fromEnv = try container.decodeIfPresent(String.self, forKey: .fromEnv)
    required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
  }
}
#endif
