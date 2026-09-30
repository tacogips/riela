import Foundation
import RielaCore
import RielaWork

actor TaskHandoverCheckpointCoordinator {
  private var nextTimerCheckpoint = 0
  private var tail: Task<Void, Error>?

  func checkpoint(
    workspace: any WorkspaceHandoverRuntime,
    isolation: IsolationRef,
    attemptId: AttemptID,
    message: String,
    trailerSuffix: String,
    paths: [String]?
  ) async throws {
    let suffix: String
    if trailerSuffix == "timer" {
      nextTimerCheckpoint += 1
      suffix = "timer-\(nextTimerCheckpoint)"
    } else {
      suffix = trailerSuffix
    }
    let prior = tail
    let current = Task {
      _ = try? await prior?.value
      _ = try await workspace.checkpoint(
        isolation, message: message,
        trailer: "Riela-Checkpoint: \(attemptId.rawValue)/\(suffix)", paths: paths
      )
    }
    tail = current
    try await current.value
  }
}

struct TaskDeliverablePublisher: DeliverablePublisher {
  var store: WorkStore
  var reservationFence: Int?
  var workspace: any WorkspaceHandoverRuntime = GitBranchWorkspaceRuntime()
  var workflow: WorkflowDefinition
  var nodePayloads: [String: AgentNodePayload]

  func publish(
    task: WorkTask,
    attempt: Attempt,
    snapshot: WorkflowRuntimePersistenceSnapshot,
    ownerAlive: Bool
  ) async -> [DeliverableRef] {
    var deliverables: [DeliverableRef] = []
    guard case let .repository(repository)? = task.context else { return deliverables }
    let policy = task.guardPolicy.handover?.publish ?? PublicationPolicy()
    guard let isolation = attempt.isolation,
          let branch = isolation.branch,
          let baseRevision = isolation.baseRevision else {
      deliverables.append(.repository(RepositoryDeliverable(
        root: repository.root, remote: policy.remote,
        branch: "", baseRevision: repository.baseRevision ?? "",
        state: .checkpointFailed(reason: "attempt isolation is unavailable")
      )))
      return deliverables
    }
    if ownerAlive {
      if let reservationFence,
         (try? store.loadLease(attemptId: attempt.id)?.fence) != reservationFence {
        deliverables.append(.repository(RepositoryDeliverable(
          root: isolation.path, remote: policy.remote, branch: branch,
          baseRevision: baseRevision, state: .checkpointFailed(reason: "fenced")
        )))
        return deliverables
      }
      do {
        _ = try await workspace.checkpoint(
          isolation,
          message: "riela: handover checkpoint \(task.id.rawValue)",
          trailer: "Riela-Checkpoint: \(attempt.id.rawValue)/handover",
          paths: repository.writeScopes.isEmpty ? nil : repository.writeScopes
        )
        let published = try await workspace.publish(
          isolation, remote: policy.remote, allowCreate: policy.allowCreateBranch,
          branchAllowlist: policy.branchAllowlist
        )
        deliverables.append(.repository(RepositoryDeliverable(
          root: isolation.path, remote: published.remote, branch: published.branch,
          baseRevision: baseRevision, headCommit: published.sha, state: .published
        )))
      } catch {
        deliverables.append(.repository(RepositoryDeliverable(
          root: isolation.path, remote: policy.remote, branch: branch,
          baseRevision: baseRevision, state: .checkpointFailed(reason: String(describing: error))
        )))
      }
    } else {
      let dirty = (try? await workspace.dirtyPaths(isolation)) ?? []
      deliverables.append(.repository(RepositoryDeliverable(
        root: isolation.path, remote: policy.remote, branch: branch,
        baseRevision: baseRevision, state: .unpublished(lastKnown: nil), dirtyPaths: dirty
      )))
    }
    return deliverables
  }
}

enum TaskHandoverSupport {
  static func redactionRules(
    workflow: WorkflowDefinition,
    nodePayloads: [String: AgentNodePayload],
    environment: [String: String]
  ) -> HandoverRedactionRules {
    var names = Set<String>()
    for node in workflow.nodeRegistry {
      if let env = node.addon?.env {
        for (_, binding) in env {
          if case let .object(values) = binding,
             case let .string(name)? = values["fromEnv"], !name.isEmpty {
            names.insert(name)
          }
        }
      }
      for (_, binding) in nodePayloads[node.id]?.agentEnvironment ?? [:] {
        if let name = binding.fromEnv, !name.isEmpty { names.insert(name) }
      }
    }
    return HandoverRedactionRules(
      boundValues: Dictionary(uniqueKeysWithValues: names.compactMap { name in
        environment[name].map { ($0, name) }
      })
    )
  }
}
