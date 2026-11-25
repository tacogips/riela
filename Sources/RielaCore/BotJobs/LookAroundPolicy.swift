public enum LookAroundPolicy {
  public static func violations(workflow: WorkflowDefinition, nodePayloads: [String: AgentNodePayload]) -> [String] {
    var issues: [String] = []
    if workflow.steps.count != 1 {
      issues.append("Look-around requires exactly one step (found \(workflow.steps.count))")
    }

    var nodeIssues: [String: Set<String>] = [:]
    var nodeIds = Set(nodePayloads.keys)
    for node in workflow.nodeRegistry {
      nodeIds.insert(node.id)
      if node.addon != nil { nodeIssues[node.id, default: []].insert("uses an add-on") }
    }
    // Normalized workflow nodes are keyed by step ID, while payloads use registry IDs.
    for node in workflow.nodes {
      let nodeId = workflow.steps.first { $0.id == node.id }?.nodeId ?? node.id
      nodeIds.insert(nodeId)
      if node.addon != nil { nodeIssues[nodeId, default: []].insert("uses an add-on") }
    }
    for step in workflow.steps {
      nodeIds.insert(step.nodeId)
      if step.transitions?.contains(where: callsWorkflow) == true {
        nodeIssues[step.nodeId, default: []].insert("can call another workflow")
      }
    }

    for nodeId in nodeIds.sorted() {
      var reasons = nodeIssues[nodeId] ?? []
      if let payload = nodePayloads[nodeId] {
        if payload.command != nil { reasons.insert("has a command payload") }
        if payload.container != nil { reasons.insert("has a container payload") }
        if payload.sleep != nil || (payload.nodeType ?? .agent) != .agent {
          reasons.insert("is not an agent node")
        }
      } else if !reasons.contains("uses an add-on") {
        reasons.insert("has no agent payload")
      }
      if !reasons.isEmpty {
        issues.append("Node '\(nodeId)' \(reasons.sorted().joined(separator: ", "))")
      }
    }
    return issues
  }

  private static func callsWorkflow(_ transition: WorkflowStepTransition) -> Bool {
    transition.toWorkflowId != nil || transition.dynamicWorkflow != nil || transition.fanout != nil
  }
}
