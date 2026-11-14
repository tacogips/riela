import Foundation

/// The result of the protected finalization preflight for one rerun target:
/// the source executions to bind, or the evidence steps that cannot be bound.
private struct RerunFinalizationEvidencePlan {
  var boundExecutionIds: Set<String>
  var failingStepIds: Set<String>
}

extension DeterministicWorkflowRunner {
  /// Validates that a protected-workflow rerun from `targetStepId` can satisfy
  /// git finalization evidence from `available`. Throws the documented
  /// preflight rejection; a no-op for unprotected workflows.
  static func validateRerunFinalizationEvidence(
    workflow: WorkflowDefinition,
    source: WorkflowSession,
    targetStepId: String,
    available: [WorkflowStepExecution]
  ) throws {
    _ = try rerunFinalizationEvidenceExecutions(
      workflow: workflow, source: source, targetStepId: targetStepId, available: available
    )
  }

  /// The source executions a plain rerun binds as finalization evidence (D3),
  /// in source order, after the same preflight `validateRerunFinalizationEvidence`
  /// runs. Empty for unprotected workflows.
  static func rerunFinalizationEvidenceExecutions(
    workflow: WorkflowDefinition,
    source: WorkflowSession,
    targetStepId: String,
    available: [WorkflowStepExecution]
  ) throws -> [WorkflowStepExecution] {
    guard let plan = rerunFinalizationEvidencePlan(
      workflow: workflow, source: source, targetStepId: targetStepId, available: available
    ) else {
      return []
    }
    if !plan.failingStepIds.isEmpty {
      let workflowOrder = workflow.steps.map(\.id).filter { plan.failingStepIds.contains($0) }
      // A failing id that is no longer a workflow step (an upgraded workflow)
      // still has to be reported; never index into an empty ordering.
      let orderedFailures = workflowOrder + plan.failingStepIds.subtracting(workflowOrder).sorted()
      let firstFailure = orderedFailures.first ?? targetStepId
      throw DeterministicWorkflowRunnerError.rerunValidation(
        "cannot rerun \(targetStepId): protected git finalization evidence for \(orderedFailures.joined(separator: ",")) " +
          "is not bound in the source session; rerun from \(firstFailure) or use session resume --retry-failed-step"
      )
    }
    return available.filter { plan.boundExecutionIds.contains($0.executionId) }
  }

  private static func rerunFinalizationEvidencePlan(
    workflow: WorkflowDefinition,
    source: WorkflowSession,
    targetStepId: String,
    available: [WorkflowStepExecution]
  ) -> RerunFinalizationEvidencePlan? {
    guard let terminalStep = workflow.steps.first(where: { $0.id == WorkflowGitFinalizationEvidencePolicy.terminalStepId }),
          let policy = gitFinalizationEvidencePolicy(workflow: workflow, terminalStep: terminalStep) else {
      return nil
    }

    let edgesBySource = Dictionary(grouping: rerunGraphEdges(workflow: workflow), by: \.fromStepId)
    let planningRoutes = Set(policy.planningRoutes(in: workflow))

    func reachable(from start: String, removing removed: String? = nil, filteringPlanningRoutes: Bool = false) -> Set<String> {
      guard start != removed else { return [] }
      var visited: Set<String> = [start]
      var queue = [start]
      while !queue.isEmpty {
        let current = queue.removeFirst()
        for edge in edgesBySource[current, default: []] {
          guard edge.toStepId != removed,
                !(filteringPlanningRoutes && planningRoutes.contains(edge)),
                visited.insert(edge.toStepId).inserted else {
            continue
          }
          queue.append(edge.toStepId)
        }
      }
      return visited
    }

    let reexecuted = reachable(from: targetStepId)
    func isGuaranteed(_ stepId: String, filteringPlanningRoutes: Bool = false) -> Bool {
      stepId == targetStepId || (
        reexecuted.contains(stepId) &&
          !reachable(from: targetStepId, removing: stepId, filteringPlanningRoutes: filteringPlanningRoutes)
            .contains(terminalStep.id)
      )
    }
    func latestBindable(_ stepId: String) -> WorkflowStepExecution? {
      guard let latest = available.last(where: { $0.stepId == stepId }),
            latest.status == .completed, latest.acceptedOutput != nil else {
        return nil
      }
      return latest
    }

    let modeStepIds = policy.modeStepIds(in: workflow)
    let modeExecutions = modeStepIds.compactMap { stepId -> WorkflowStepExecution? in
      guard !reexecuted.contains(stepId) else { return nil }
      return latestBindable(stepId)
    }
    let bindableGitExecutions = policy.gitEvidenceStepIds.compactMap(latestBindable)

    var failingStepIds: Set<String> = []
    for stepId in modeStepIds where !reexecuted.contains(stepId) {
      let hasSourceExecution = available.contains { $0.stepId == stepId }
      if hasSourceExecution && latestBindable(stepId) == nil {
        failingStepIds.insert(stepId)
      }
    }

    var derivedMode: WorkflowGitFinalizationMode?
    if modeStepIds.isDisjoint(with: reexecuted) {
      var modeSession = source
      modeSession.executions = modeExecutions
      do {
        derivedMode = try expectedGitFinalizationMode(session: modeSession, policy: policy)
      } catch {
        failingStepIds.formUnion(modeStepIds)
      }
    }

    let requiredGitStepIds = [policy.commitStepId, policy.pushStepId, policy.integrationStepId].compactMap { $0 }
    for stepId in requiredGitStepIds where latestBindable(stepId) == nil && !isGuaranteed(stepId) {
      failingStepIds.insert(stepId)
    }

    let planEvidenceRequired = !modeStepIds.isDisjoint(with: reexecuted) || derivedMode == .issueResolution
    if planEvidenceRequired {
      for stepId in [policy.planCommitStepId, policy.planPushStepId].compactMap({ $0 })
        where latestBindable(stepId) == nil && !isGuaranteed(stepId, filteringPlanningRoutes: true) {
        failingStepIds.insert(stepId)
      }
    }

    return RerunFinalizationEvidencePlan(
      boundExecutionIds: Set(modeExecutions.map(\.executionId) + bindableGitExecutions.map(\.executionId)),
      failingStepIds: failingStepIds
    )
  }
}
