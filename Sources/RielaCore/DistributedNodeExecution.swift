import Foundation

public struct DistributedExecutionPlacement: Codable, Equatable, Sendable {
  public var target: DistributedWorkerTarget
  public var workspace: String
  public var exports: [String]?

  public init(target: DistributedWorkerTarget, workspace: String, exports: [String]? = nil) {
    self.target = target
    self.workspace = workspace
    self.exports = exports
  }
}

public enum DistributedNodeInvocation: Codable, Equatable, Sendable {
  case adapter(AdapterExecutionInput)
  case addon(WorkflowAddonExecutionInput)
  case stdio(WorkflowStdioNodeExecutionInput)
}

public enum DistributedNodeOutput: Codable, Equatable, Sendable {
  case adapter(AdapterExecutionOutput)
  case stdio(WorkflowStdioNodeExecutionResult)
}

public struct DistributedNodeRequest: Codable, Equatable, Sendable {
  public let invocation: DistributedNodeInvocation
  public let workspace: String
  public let timeoutSeconds: Double
  public let exports: [String]?

  public init(invocation: DistributedNodeInvocation, workspace: String, timeoutSeconds: Double, exports: [String]? = nil) {
    self.invocation = invocation
    self.workspace = workspace
    self.timeoutSeconds = timeoutSeconds
    self.exports = exports
  }
}

public protocol DistributedNodeExecuting: Sendable {
  func execute(
    _ invocation: DistributedNodeInvocation, executionId: String,
    placement: DistributedExecutionPlacement, context: AdapterExecutionContext
  ) async throws -> DistributedNodeOutput
}

/// Controller-side dispatcher; only the workflow runner publishes the result
/// and advances transitions. An explicit placement never falls back locally.
public struct QueuedDistributedNodeExecutor: DistributedNodeExecuting {
  private let controller: DistributedJobController

  public init(controller: DistributedJobController) { self.controller = controller }

  public func execute(
    _ invocation: DistributedNodeInvocation, executionId: String,
    placement: DistributedExecutionPlacement, context: AdapterExecutionContext
  ) async throws -> DistributedNodeOutput {
    let deadline = context.deadline ?? Date().addingTimeInterval(300)
    guard deadline > Date(), !placement.workspace.isEmpty else {
      throw AdapterExecutionError(.invalidInput, "remote workspace and a future execution deadline are required")
    }
    try DistributedArtifact.validatePaths(placement.exports ?? [])
    let request = DistributedNodeRequest(
      invocation: invocation, workspace: placement.workspace, timeoutSeconds: deadline.timeIntervalSinceNow, exports: placement.exports
    )
    let attachment = try await controller.attachNode(id: executionId, target: placement.target, request: request)
    do {
      var publishedWorkerId: String?
      var eventSequence = 0
      while true {
        try Task.checkCancellation()
        guard Date() < deadline else { throw AdapterExecutionError(.timeout, "remote execution deadline exceeded") }
        guard let job = try await controller.job(id: executionId, now: Date()) else {
          throw AdapterExecutionError(.providerError, "remote execution disappeared")
        }
        if let workerId = job.lease?.workerId, workerId != publishedWorkerId {
          await context.backendEventHandler?(AdapterBackendEvent(
            provider: "riela-worker", eventType: "remote.assignment", channel: .lifecycle,
            contentSnapshot: "Executing on worker \(workerId)",
            metadata: ["workerId": .string(workerId), "workspace": .string(placement.workspace), "jobId": .string(job.id)]
          ))
          publishedWorkerId = workerId
        }
        for event in job.events ?? [] where event.sequence > eventSequence {
          if event.sequence > eventSequence + 1 {
            await context.backendEventHandler?(AdapterBackendEvent(
              provider: "riela-worker", eventType: "remote.event_gap", channel: .lifecycle,
              contentSnapshot: "Earlier remote events are no longer retained.",
              metadata: ["missingCount": .integer(Int64(event.sequence - eventSequence - 1))]
            ))
          }
          await context.backendEventHandler?(event.event)
          eventSequence = event.sequence
        }
        switch job.status {
        case .succeeded:
          guard let result = job.result else { throw AdapterExecutionError(.invalidOutput, "remote result missing") }
          for artifact in try await controller.artifacts(jobId: executionId) {
            await context.backendEventHandler?(AdapterBackendEvent(
              provider: "riela-worker", eventType: "remote.artifact", channel: .lifecycle,
              metadata: ["path": .string(artifact.path), "localPath": .string(artifact.url.path),
                "sha256": .string(artifact.sha256), "size": .integer(Int64(artifact.size))]
            ))
          }
          return try JSONDecoder().decode(DistributedNodeOutput.self, from: JSONEncoder().encode(result.payload))
        case .failed:
          let failure = job.result?.failure ?? DistributedJobFailure(code: .providerError)
          throw AdapterExecutionError(failure.code, failure.message, isRetryable: false)
        case .cancelled, .lost:
          throw AdapterExecutionError(.providerError, "remote execution \(job.status.rawValue)", isRetryable: false)
        case .queued, .leased:
          try await Task.sleep(for: .milliseconds(100))
        }
      }
    } catch {
      try await controller.cancel(jobId: executionId, attachment: attachment)
      throw error
    }
  }
}
