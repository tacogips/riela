extension DeterministicWorkflowRunner {
  struct LoopConvergenceError: Error, Equatable, Sendable, CustomStringConvertible {
    var violation: LoopConvergenceViolation

    var description: String {
      violation.diagnostic
    }
  }

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

  func workflowRoutingReconciler(
    workflow: WorkflowDefinition,
    step: WorkflowStepRef
  ) -> OutputContractRoutingReconciler? {
    guard workflow.loop != nil else {
      return nil
    }
    guard step.loop?.gateId != nil || step.loop?.role == "gate" else {
      return nil
    }
    return reconcileCompletionReviewRouting
  }

  func enforceLoopConvergenceIfNeeded(
    publishResult: WorkflowPublicationResult,
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    request: DeterministicWorkflowRunRequest
  ) async throws {
    guard let convergence = workflow.loop?.convergence,
          step.loop?.gateId != nil || step.loop?.role == "gate",
          let payload = publishResult.stepExecution.acceptedOutput?.payload,
          case .object = payload["loopGate"] else {
      return
    }

    var tracker = LoopConvergenceTracker(declaration: convergence)
    let parser = loopGateParser(workflow: workflow)
    var currentCheck: LoopConvergenceCheck?
    for execution in publishResult.session.executions {
      guard let output = execution.acceptedOutput?.payload,
            case let .object(loopGate)? = output["loopGate"] else {
        continue
      }
      let result = parser.result(from: loopGate, execution: execution)
      let check = tracker.recordGateVisit(
        gateId: result.gateId,
        decision: result.decision,
        findings: result.blockingFindings
      )
      if execution.executionId == publishResult.stepExecution.executionId {
        currentCheck = check
      }
    }

    guard let violation = currentCheck?.violation else {
      return
    }

    await emitRunEvent(loopStallEvent(
      workflowId: workflow.workflowId,
      session: publishResult.session,
      step: step,
      execution: publishResult.stepExecution,
      violation: violation,
      action: convergence.onStall
    ), handler: request.eventHandler)

    if convergence.onStall == .fail {
      throw LoopConvergenceError(violation: violation)
    }
  }

  private func loopStallEvent(
    workflowId: String,
    session: WorkflowSession,
    step: WorkflowStepRef,
    execution: WorkflowStepExecution,
    violation: LoopConvergenceViolation,
    action: LoopConvergenceStallAction
  ) -> WorkflowRunEvent {
    WorkflowRunEvent(
      type: .loopStall,
      workflowId: workflowId,
      sessionId: session.sessionId,
      status: session.status,
      currentStepId: session.currentStepId,
      stepId: step.id,
      nodeId: step.nodeId,
      executionId: execution.executionId,
      loopStallGateId: violation.gateId,
      loopStallViolationKind: violation.kind.rawValue,
      loopStallAction: action.rawValue,
      loopStallGateVisits: violation.gateVisits,
      loopStallRepeatedRounds: violation.repeatedRounds,
      loopStallFingerprints: violation.fingerprints.map(\.key),
      nodeExecutions: session.executions.count
    )
  }
}
