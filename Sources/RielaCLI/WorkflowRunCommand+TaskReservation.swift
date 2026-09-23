import Foundation
import RielaCore
import RielaWork

struct TaskPlacementExecutionContext: Sendable {
  var bundles: [String: ResolvedWorkflowBundle]
  var placement: BackendCapabilityPlacementResult
  var defaultWorkspace: String?
}

extension WorkflowRunCommand {
  func runTaskReservation(
    _ options: WorkflowRunOptions,
    reservation: AttemptReservation,
    store: WorkStore,
    context: TaskPlacementExecutionContext
  ) async -> CLICommandResult {
    guard options.endpoint == nil, !options.autoImprove,
          options.resumeSessionId == reservation.attempt.sessionId else {
      return CLICommandResult(exitCode: .usage, stderr: "task run requires its local reserved session")
    }
    return await runWithoutSpecialistMonitor(
      options, taskReservation: (reservation, store), taskContext: context
    )
  }

  func applyingTaskPlacement(
    _ context: TaskPlacementExecutionContext,
    to original: ResolvedWorkflowBundle
  ) throws -> ResolvedWorkflowBundle {
    guard context.placement.complete else { throw WorkStoreError("task placement is incomplete") }
    var bundle = original
    let choices = context.placement.choices.filter {
      $0.provenance.workflowId == bundle.workflow.workflowId
    }
    var seen: Set<WorkflowRequirementProvenance> = []
    for (index, choice) in choices.enumerated() {
      guard seen.insert(choice.provenance).inserted,
            let stepIndex = bundle.workflow.steps.firstIndex(where: {
              $0.id == choice.provenance.stepId && $0.nodeId == choice.provenance.nodeId
            }),
            let registryNode = bundle.workflow.nodeRegistry.first(where: {
              $0.id == choice.provenance.nodeId
            }) else {
        throw WorkStoreError("task placement does not match an admitted executable step")
      }
      let originalStep = bundle.workflow.steps[stepIndex]
      if choice.hostId == "local" {
        guard originalStep.placement == nil else {
          throw WorkStoreError("task placement cannot move an explicitly remote step to local")
        }
      } else {
        guard let workspace = originalStep.placement?.workspace.isEmpty == false
          ? originalStep.placement?.workspace : context.defaultWorkspace else {
          throw WorkStoreError("remote task placement requires a controller default workspace")
        }
        let target = DistributedWorkerTarget(
          workerId: choice.hostId,
          group: originalStep.placement?.target.group
        )
        bundle.workflow.steps[stepIndex].placement = DistributedExecutionPlacement(
          target: target, workspace: workspace, exports: originalStep.placement?.exports
        )
      }
      let alias = "__task_placement_\(index)_\(choice.provenance.nodeId)"
      guard bundle.workflow.nodeRegistry.allSatisfy({ $0.id != alias }),
            bundle.nodePayloads[alias] == nil else {
        throw WorkStoreError("task placement alias conflicts with an authored node")
      }
      var placedRegistry = registryNode
      placedRegistry.id = alias
      bundle.workflow.nodeRegistry.append(placedRegistry)
      if let node = bundle.workflow.nodes.first(where: { $0.id == choice.provenance.nodeId }) {
        var placedNode = node
        placedNode.id = alias
        bundle.workflow.nodes.append(placedNode)
      }
      bundle.workflow.steps[stepIndex].nodeId = alias
      guard var payload = bundle.nodePayloads[choice.provenance.nodeId] else {
        if choice.backend != nil || choice.model != nil {
          throw WorkStoreError("task placement refers to an unknown agent node")
        }
        continue
      }
      payload.id = alias
      if let backend = choice.backend {
        payload.executionBackend = backend
        payload.backendPolicy = nil
      }
      if let model = choice.model { payload.model = model }
      bundle.nodePayloads[alias] = payload
    }
    return bundle
  }

  func makeTaskAdmission(
    _ taskReservation: (AttemptReservation, WorkStore)?,
    processAdmission: @escaping @Sendable (String) throws -> Void
  ) -> (@Sendable (String) throws -> Void)? {
    guard let (reservation, store) = taskReservation else { return nil }
    return { sessionId in
      try processAdmission(sessionId)
      // The runner invokes this hook for reachable callees as well. Only the
      // root session consumes the task's one-use launch token; child sessions
      // retain the ordinary process admission fence.
      guard sessionId == reservation.attempt.sessionId else { return }
      _ = try store.authorizeAttemptLaunch(
        attemptId: reservation.attempt.id,
        launchToken: reservation.launchToken
      )
      _ = try store.markAttemptNodeStarted(attemptId: reservation.attempt.id)
    }
  }
}
