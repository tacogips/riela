struct WorkflowExecutionPlan: Sendable {
  private let stepsById: [String: WorkflowStepRef]
  private let registryNodesById: [String: WorkflowNodeRegistryRef]

  init(workflow: WorkflowDefinition) {
    self.stepsById = Dictionary(uniqueKeysWithValues: workflow.steps.map { ($0.id, $0) })
    self.registryNodesById = Dictionary(uniqueKeysWithValues: workflow.nodeRegistry.map { ($0.id, $0) })
  }

  func step(id: String) -> WorkflowStepRef? {
    stepsById[id]
  }

  func registryNode(id: String) -> WorkflowNodeRegistryRef? {
    registryNodesById[id]
  }
}
