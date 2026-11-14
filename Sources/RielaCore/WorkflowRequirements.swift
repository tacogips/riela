import Foundation

public struct WorkflowRequirementProvenance: Codable, Equatable, Hashable, Sendable {
  public var workflowId: String
  public var stepId: String
  public var nodeId: String

  public init(workflowId: String, stepId: String, nodeId: String) {
    self.workflowId = workflowId
    self.stepId = stepId
    self.nodeId = nodeId
  }
}

public struct WorkflowBackendRequirement: Codable, Equatable, Sendable {
  public var pin: NodeExecutionBackend?
  public var policy: WorkflowBackendPolicy?
  public var explicitModel: String?
  public var addonExecutable: String?
  public var requiredEnvironment: [String]
  public var provenance: [WorkflowRequirementProvenance]

  public init(
    pin: NodeExecutionBackend? = nil,
    policy: WorkflowBackendPolicy? = nil,
    explicitModel: String? = nil,
    addonExecutable: String? = nil,
    requiredEnvironment: [String] = [],
    provenance: [WorkflowRequirementProvenance]
  ) {
    self.pin = pin
    self.policy = policy
    self.explicitModel = explicitModel
    self.addonExecutable = addonExecutable
    self.requiredEnvironment = requiredEnvironment
    self.provenance = provenance
  }
}

/// Host requirements projected by the package/add-on resolver. Core consumes
/// this neutral value without depending on package manifest implementations.
public struct WorkflowNodeHostRequirement: Codable, Equatable, Sendable {
  public var addonExecutable: String?
  public var requiredEnvironment: [String]

  public init(addonExecutable: String? = nil, requiredEnvironment: [String] = []) {
    self.addonExecutable = addonExecutable
    self.requiredEnvironment = requiredEnvironment
  }
}

public enum WorkflowRequirementResolutionError: Error, Equatable, Sendable {
  case unknownWorkflow(String)
  case unknownStep(workflowId: String, stepId: String)
  case unknownNode(workflowId: String, nodeId: String)
  case unresolvedAddonExecutable(workflowId: String, nodeId: String)
}

/// Typed input passed to existing planner workflow variables. Dispatch owns
/// selecting the intended host; this value keeps planner and validation on the
/// same snapshot and requirement vocabulary.
public struct WorkflowPlanningCapabilityContext: Codable, Equatable, Sendable {
  public var host: HostCapabilitySnapshot
  public var requirements: [WorkflowBackendRequirement]

  public init(host: HostCapabilitySnapshot, requirements: [WorkflowBackendRequirement]) {
    self.host = host
    self.requirements = requirements
  }

  public func workflowVariables() throws -> JSONObject {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let value = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(self))
    return ["hostCapabilityContext": value]
  }
}

/// Computes executable requirements from a selected entry. Cross-workflow
/// calls are resolved from the supplied bundle map and cycles are visited once.
public struct WorkflowRequirementResolver: Sendable {
  public init() {}

  public func resolve(
    workflowId: String,
    entryStepId: String? = nil,
    workflows: [String: WorkflowDefinition],
    nodePayloads: [String: [String: AgentNodePayload]],
    nodeHostRequirements: [String: [String: WorkflowNodeHostRequirement]] = [:],
    reusedPrefixStepIds: Set<String> = []
  ) throws -> [WorkflowBackendRequirement] {
    guard let root = workflows[workflowId] else {
      throw WorkflowRequirementResolutionError.unknownWorkflow(workflowId)
    }
    var visited: Set<String> = []
    var requirements: [WorkflowBackendRequirement] = []
    try visit(
      workflow: root,
      stepId: entryStepId ?? root.entryStepId,
      workflows: workflows,
      nodePayloads: nodePayloads,
      nodeHostRequirements: nodeHostRequirements,
      reusedPrefixStepIds: reusedPrefixStepIds,
      visited: &visited,
      requirements: &requirements
    )
    return deduplicated(requirements)
  }

  private func visit(
    workflow: WorkflowDefinition,
    stepId: String,
    workflows: [String: WorkflowDefinition],
    nodePayloads: [String: [String: AgentNodePayload]],
    nodeHostRequirements: [String: [String: WorkflowNodeHostRequirement]],
    reusedPrefixStepIds: Set<String>,
    visited: inout Set<String>,
    requirements: inout [WorkflowBackendRequirement]
  ) throws {
    var pending = [(workflowId: workflow.workflowId, stepId: stepId)]
    while let current = pending.popLast() {
      guard let currentWorkflow = workflows[current.workflowId] else {
        throw WorkflowRequirementResolutionError.unknownWorkflow(current.workflowId)
      }
      let visitKey = "\(current.workflowId):\(current.stepId)"
      guard visited.insert(visitKey).inserted else { continue }
      guard let step = currentWorkflow.steps.first(where: { $0.id == current.stepId }) else {
        throw WorkflowRequirementResolutionError.unknownStep(
          workflowId: current.workflowId, stepId: current.stepId
        )
      }
      if !reusedPrefixStepIds.contains(visitKey) {
        let payload = nodePayloads[current.workflowId]?[step.nodeId]
        let hostRequirement = nodeHostRequirements[current.workflowId]?[step.nodeId]
        let isAddonNode = currentWorkflow.nodeRegistry.contains { $0.id == step.nodeId && $0.addon != nil }
        guard payload != nil || hostRequirement != nil || isAddonNode else {
          throw WorkflowRequirementResolutionError.unknownNode(
            workflowId: current.workflowId, nodeId: step.nodeId
          )
        }
        if isAddonNode, hostRequirement == nil {
          throw WorkflowRequirementResolutionError.unresolvedAddonExecutable(
            workflowId: current.workflowId, nodeId: step.nodeId
          )
        }
        if step.placement != nil || payload?.executionBackend != nil || payload?.backendPolicy != nil
          || hostRequirement?.addonExecutable != nil
          || hostRequirement?.requiredEnvironment.isEmpty == false
          || payload?.agentEnvironment.values.contains(where: { $0.required }) == true
          || payload?.apiKeyEnvironment != nil {
          let environment = (payload?.agentEnvironment.values.compactMap { binding in
            binding.required ? binding.fromEnv : nil
          } ?? []) + [payload?.apiKeyEnvironment].compactMap { $0 }
            + (hostRequirement?.requiredEnvironment ?? [])
          requirements.append(WorkflowBackendRequirement(
            pin: payload?.executionBackend,
            policy: payload?.backendPolicy,
            explicitModel: payload?.model.isEmpty == false ? payload?.model : nil,
            addonExecutable: hostRequirement?.addonExecutable,
            requiredEnvironment: Array(Set(environment)).sorted(),
            provenance: [.init(workflowId: current.workflowId, stepId: step.id, nodeId: step.nodeId)]
          ))
        }
      }
      var successors: [(workflowId: String, stepId: String)] = []
      for transition in step.transitions ?? [] {
        let targetWorkflowId = transition.toWorkflowId ?? current.workflowId
        successors.append((targetWorkflowId, transition.toStepId))
        if let resumeStepId = transition.resumeStepId, transition.toWorkflowId != nil {
          successors.append((current.workflowId, resumeStepId))
        }
        if let joinStepId = transition.fanout?.joinStepId {
          successors.append((current.workflowId, joinStepId))
        }
      }
      pending.append(contentsOf: successors.reversed())
    }
  }

  private func deduplicated(_ requirements: [WorkflowBackendRequirement]) -> [WorkflowBackendRequirement] {
    var output: [WorkflowBackendRequirement] = []
    for requirement in requirements {
      if let index = output.firstIndex(where: {
        $0.pin == requirement.pin && $0.policy == requirement.policy
          && $0.explicitModel == requirement.explicitModel
          && $0.addonExecutable == requirement.addonExecutable
          && $0.requiredEnvironment == requirement.requiredEnvironment
      }) {
        output[index].provenance.append(contentsOf: requirement.provenance)
      } else {
        output.append(requirement)
      }
    }
    return output
  }
}
