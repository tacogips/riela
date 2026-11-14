import Foundation

/// A callee workflow resolved for live cross-workflow dispatch, carrying the
/// same materialized shape (workflow definition plus hydrated node payloads)
/// that top-level runs receive from workflow bundle resolution.
public struct ResolvedWorkflowCallee: Sendable {
  public var workflow: WorkflowDefinition
  public var nodePayloads: [String: AgentNodePayload]

  public init(
    workflow: WorkflowDefinition,
    nodePayloads: [String: AgentNodePayload] = [:]
  ) {
    self.workflow = workflow
    self.nodePayloads = nodePayloads
  }
}

/// Resolves callee workflows referenced by cross-workflow step transitions
/// (`toWorkflowId`) so live runs can dispatch the callee instead of echoing
/// the handoff into the caller's resume step.
public protocol WorkflowCalleeResolving: Sendable {
  func resolveCallee(workflowId: String) async throws -> ResolvedWorkflowCallee
}
