import Foundation
import RielaCore
import RielaWork

extension WorkflowRunCommand {
  func runTaskReservation(
    _ options: WorkflowRunOptions,
    reservation: AttemptReservation,
    store: WorkStore,
    placement: BackendCapabilityPlacementResult
  ) async -> CLICommandResult {
    guard options.endpoint == nil, !options.autoImprove,
          options.resumeSessionId == reservation.attempt.sessionId else {
      return CLICommandResult(exitCode: .usage, stderr: "task run requires its local reserved session")
    }
    return await runWithoutSpecialistMonitor(
      options, taskReservation: (reservation, store), taskPlacement: placement
    )
  }

  func applyingTaskPlacement(
    _ placement: BackendCapabilityPlacementResult,
    to original: ResolvedWorkflowBundle
  ) throws -> ResolvedWorkflowBundle {
    guard placement.complete else { throw WorkStoreError("task placement is incomplete") }
    var bundle = original
    var choiceByNode: [String: BackendPlacementChoice] = [:]
    for choice in placement.choices {
      guard choice.provenance.workflowId == bundle.workflow.workflowId,
            choice.hostId == "local" else {
        throw WorkStoreError("task placement cannot execute on the selected host")
      }
      let nodeId = choice.provenance.nodeId
      if let existing = choiceByNode[nodeId],
         existing.hostId != choice.hostId || existing.backend != choice.backend || existing.model != choice.model {
        throw WorkStoreError("task node has conflicting placement choices")
      }
      choiceByNode[nodeId] = choice
    }
    for (nodeId, choice) in choiceByNode {
      guard var payload = bundle.nodePayloads[nodeId] else {
        if choice.backend == nil { continue }
        throw WorkStoreError("task placement refers to an unknown agent node")
      }
      if let backend = choice.backend {
        payload.executionBackend = backend
        payload.backendPolicy = nil
      }
      if let model = choice.model { payload.model = model }
      bundle.nodePayloads[nodeId] = payload
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
