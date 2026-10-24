import Foundation

private struct RerunFinalizationGraphEdge: Hashable {
  var fromStepId: String
  var toStepId: String
  var label: String?
}

extension DeterministicWorkflowRunner {
  static func rerunFinalizationEvidenceExecutions(
    workflow: WorkflowDefinition,
    source: WorkflowSession,
    targetStepId: String,
    available: [WorkflowStepExecution]
  ) throws -> [WorkflowStepExecution] {
    guard let terminalStep = workflow.steps.first(where: { $0.id == "workflow-output" }),
          let policy = gitFinalizationEvidencePolicy(workflow: workflow, terminalStep: terminalStep) else {
      return []
    }

    let graphEdges = workflow.steps.flatMap { step in
      (step.transitions ?? []).flatMap { transition -> [RerunFinalizationGraphEdge] in
        var edges: [RerunFinalizationGraphEdge] = []
        let destination = transition.toWorkflowId == nil ? transition.toStepId : transition.resumeStepId
        if let destination {
          edges.append(RerunFinalizationGraphEdge(fromStepId: step.id, toStepId: destination, label: transition.label))
        }
        if let joinStepId = transition.fanout?.joinStepId {
          edges.append(RerunFinalizationGraphEdge(fromStepId: step.id, toStepId: joinStepId, label: nil))
        }
        return edges
      }
    }
    let edgesBySource = Dictionary(grouping: graphEdges, by: \.fromStepId)
    let planningPreparationStepIds = Set(workflow.steps.compactMap { step in
      step.transitions?.contains(where: { $0.toStepId == policy.commitStepId }) == true ? step.id : nil
    })
    let planningRoutes = Set(workflow.steps.flatMap { step in
      (step.transitions ?? []).compactMap { transition -> RerunFinalizationGraphEdge? in
        guard policy.planningModeStepIds.contains(step.id),
              planningPreparationStepIds.contains(transition.toStepId),
              transition.label?.contains("planning_only") == true,
              let destination = transition.toWorkflowId == nil ? transition.toStepId : transition.resumeStepId else {
          return nil
        }
        return RerunFinalizationGraphEdge(fromStepId: step.id, toStepId: destination, label: transition.label)
      }
    })

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

    let modeStepIds = Set(policy.planningModeStepIds)
      .union(["step6-implement"])
      .union(policy.implementationReviewStepId.map { [$0] } ?? [])
    let modeExecutions = modeStepIds.compactMap { stepId -> WorkflowStepExecution? in
      guard !reexecuted.contains(stepId) else { return nil }
      return latestBindable(stepId)
    }
    let gitStepIds = Set([
      policy.commitStepId,
      policy.pushStepId,
      policy.integrationStepId,
      policy.planCommitStepId,
      policy.planPushStepId
    ].compactMap { $0 })
    let bindableGitExecutions = gitStepIds.compactMap(latestBindable)

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

    if !failingStepIds.isEmpty {
      let orderedFailures = workflow.steps.map(\.id).filter { failingStepIds.contains($0) }
      let firstFailure = orderedFailures[0]
      throw DeterministicWorkflowRunnerError.rerunValidation(
        "cannot rerun \(targetStepId): protected git finalization evidence for \(orderedFailures.joined(separator: ",")) " +
          "is not bound in the source session; rerun from \(firstFailure) or use session resume --retry-failed-step"
      )
    }

    let boundIds = Set(modeExecutions.map(\.executionId) + bindableGitExecutions.map(\.executionId))
    return available.filter { boundIds.contains($0.executionId) }
  }
}
