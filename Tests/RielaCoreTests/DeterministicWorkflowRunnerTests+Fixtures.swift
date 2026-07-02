@testable import RielaCore

extension DeterministicWorkflowRunnerTests {
  func request(
    workflow: WorkflowDefinition? = nil,
    nodePayload: AgentNodePayload? = nil,
    maxLoopIterations: Int? = nil,
    timeoutMs: Int? = nil,
    eventHandler: WorkflowRunEventHandler? = nil
  ) -> DeterministicWorkflowRunRequest {
    let resolvedWorkflow = workflow ?? self.workflow()
    return DeterministicWorkflowRunRequest(
      workflow: resolvedWorkflow,
      nodePayloads: ["node": nodePayload ?? payload()],
      maxLoopIterations: maxLoopIterations,
      timeoutMs: timeoutMs,
      eventHandler: eventHandler
    )
  }

  func workflow(
    defaults: WorkflowDefaults = WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
    transitions: [WorkflowStepTransition]? = nil
  ) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "runner",
      defaults: defaults,
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [WorkflowStepRef(id: "step", nodeId: "node", transitions: transitions)],
      nodes: [WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json")]
    )
  }

  func twoStepWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "rerun-runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step-a",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "node-a", nodeFile: "nodes/a.json"),
        WorkflowNodeRegistryRef(id: "node-b", nodeFile: "nodes/b.json")
      ],
      steps: [
        WorkflowStepRef(id: "step-a", nodeId: "node-a", transitions: [WorkflowStepTransition(toStepId: "step-b")]),
        WorkflowStepRef(id: "step-b", nodeId: "node-b")
      ],
      nodes: [
        WorkflowNodeRef(id: "step-a", nodeFile: "nodes/a.json"),
        WorkflowNodeRef(id: "step-b", nodeFile: "nodes/b.json")
      ]
    )
  }

  func nodePayloads(for workflow: WorkflowDefinition) -> [String: AgentNodePayload] {
    Dictionary(uniqueKeysWithValues: workflow.nodeRegistry.map { ref in
      (ref.id, AgentNodePayload(id: ref.id, executionBackend: .codexAgent, model: "gpt-5.5"))
    })
  }

  func addonWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "addon-runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "addon-step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(
          id: "addon-node",
          addon: WorkflowNodeAddonRef(name: "riela/native-runner", version: "1.0.0")
        )
      ],
      steps: [WorkflowStepRef(id: "addon-step", nodeId: "addon-node")],
      nodes: [
        WorkflowNodeRef(
          id: "addon-node",
          addon: WorkflowNodeAddonRef(name: "riela/native-runner", version: "1.0.0")
        )
      ]
    )
  }

  func payload(output: NodeOutputContract? = nil) -> AgentNodePayload {
    AgentNodePayload(id: "node", executionBackend: .codexAgent, model: "gpt-5.5", output: output)
  }

  func commandPayload(output: NodeOutputContract? = nil) -> AgentNodePayload {
    AgentNodePayload(
      id: "node",
      nodeType: .command,
      model: "",
      command: WorkflowCommandExecution(executable: "/bin/sh", arguments: ["-c", "true"]),
      output: output
    )
  }

  func output(
    completionPassed: Bool = true,
    payload: JSONObject = ["status": .string("ok")],
    when: [String: Bool] = ["always": true]
  ) -> AdapterExecutionOutput {
    AdapterExecutionOutput(
      provider: "test",
      model: "gpt-5.5",
      promptText: "prompt",
      completionPassed: completionPassed,
      when: when,
      payload: payload
    )
  }
}
