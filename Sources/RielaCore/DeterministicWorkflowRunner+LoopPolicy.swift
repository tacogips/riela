extension DeterministicWorkflowRunner {
  func enforceRequiredLoopPolicyPreflight(_ request: DeterministicWorkflowRunRequest) throws {
    guard request.workflow.loop?.required == true else {
      return
    }
    let evidence = loopPolicyEvaluator.preflight(workflow: request.workflow, nodePayloads: request.nodePayloads)
    guard let denial = evidence.denials.first else {
      return
    }
    throw AdapterExecutionError(.policyBlocked, "loop policy denied \(denial.policy): \(denial.reason ?? denial.decision)")
  }

  func stdioPolicyContext(
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    payload: AgentNodePayload,
    request: DeterministicWorkflowRunRequest
  ) -> LoopPolicyStepDecision? {
    guard workflow.loop?.policies != nil else {
      return nil
    }
    let evidence = loopPolicyEvaluator.preflight(workflow: workflow, nodePayloads: request.nodePayloads)
    return loopPolicyEvaluator.evaluateStep(step: step, node: payload, workflowPolicy: evidence.effective)
  }
}
