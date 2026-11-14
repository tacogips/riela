import Foundation

public struct TemporaryWorkflowPayload: Codable, Sendable {
  public var workflow: AuthoredWorkflowJSON
  public var nodePayloads: [String: AgentNodePayload]

  public init(workflow: AuthoredWorkflowJSON, nodePayloads: [String: AgentNodePayload]) {
    self.workflow = workflow
    self.nodePayloads = nodePayloads
  }
}

public struct MaterializedTemporaryWorkflow: Sendable {
  public var validation: AuthoredWorkflowValidationResult
  public var nodePayloads: [String: AgentNodePayload]

  public init(validation: AuthoredWorkflowValidationResult, nodePayloads: [String: AgentNodePayload]) {
    self.validation = validation
    self.nodePayloads = nodePayloads
  }
}

public func materializeTemporaryWorkflowPayload(
  _ payload: TemporaryWorkflowPayload
) -> MaterializedTemporaryWorkflow {
  let validation: AuthoredWorkflowValidationResult
  if let data = try? JSONEncoder().encode(payload.workflow) {
    validation = validateAuthoredWorkflowData(data)
  } else {
    validation = AuthoredWorkflowValidationResult(
      workflow: nil,
      diagnostics: [WorkflowValidationDiagnostic(
        severity: .error,
        path: "workflow",
        message: "must be encodable as authored workflow JSON"
      )]
    )
  }
  guard let workflow = validation.workflow else {
    return MaterializedTemporaryWorkflow(validation: validation, nodePayloads: [:])
  }

  var nodePayloads: [String: AgentNodePayload] = [:]
  for registryNode in workflow.nodeRegistry {
    if let nodeFile = registryNode.nodeFile, let nodePayload = payload.nodePayloads[nodeFile] {
      nodePayloads[registryNode.id] = nodePayload
    } else if let nodePayload = payload.nodePayloads[registryNode.id] {
      nodePayloads[registryNode.id] = nodePayload
    }
  }
  return MaterializedTemporaryWorkflow(validation: validation, nodePayloads: nodePayloads)
}
