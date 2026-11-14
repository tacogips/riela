import Foundation

public struct WorkflowRunResult: Codable, Equatable, Sendable {
  public var workflowId: String
  public var session: WorkflowSession
  public var rootOutput: JSONObject?
  public var exitCode: Int32
  public var status: WorkflowSessionStatus
  public var nodeExecutions: Int
  public var transitions: Int
  public var loopEvidence: LoopEvidenceSummary?
  public var recovery: LoopRecoveryLineage?

  public init(
    workflowId: String,
    session: WorkflowSession,
    rootOutput: JSONObject?,
    exitCode: Int32,
    transitions: Int,
    loopEvidence: LoopEvidenceSummary? = nil,
    recovery: LoopRecoveryLineage? = nil
  ) {
    self.workflowId = workflowId
    self.session = session
    self.rootOutput = rootOutput
    self.exitCode = exitCode
    self.status = session.status
    self.nodeExecutions = session.newExecutionCount
    self.transitions = transitions
    self.loopEvidence = loopEvidence
    self.recovery = recovery
  }
}

public protocol DeterministicWorkflowRunning: Sendable {
  func run(_ request: DeterministicWorkflowRunRequest) async throws -> WorkflowRunResult
}
