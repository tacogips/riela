struct WorkflowExecutionPlan: Sendable {
  private let stepsById: [String: WorkflowStepRef]
  private let registryNodesById: [String: WorkflowNodeRegistryRef]

  init(workflow: WorkflowDefinition) {
    self.stepsById = Dictionary(workflow.steps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    self.registryNodesById = Dictionary(workflow.nodeRegistry.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  func step(id: String) -> WorkflowStepRef? {
    stepsById[id]
  }

  func registryNode(id: String) -> WorkflowNodeRegistryRef? {
    registryNodesById[id]
  }
}
