import Foundation

public struct WorkflowStepRef: Codable, Equatable, Sendable {
  public var placement: DistributedExecutionPlacement?
  public var id: String
  public var stepFile: String?
  public var nodeId: String
  public var description: String?
  public var role: NodeRole?
  public var promptVariant: String?
  public var timeoutMs: Int?
  public var stallTimeoutMs: Int?
  public var failurePolicy: WorkflowStepFailurePolicy?
  public var sessionPolicy: WorkflowStepSessionPolicy?
  public var transitions: [WorkflowStepTransition]?
  public var loop: WorkflowStepLoopMetadata?

  public init(
    id: String,
    stepFile: String? = nil,
    nodeId: String,
    description: String? = nil,
    role: NodeRole? = nil,
    promptVariant: String? = nil,
    timeoutMs: Int? = nil,
    stallTimeoutMs: Int? = nil,
    failurePolicy: WorkflowStepFailurePolicy? = nil,
    sessionPolicy: WorkflowStepSessionPolicy? = nil,
    transitions: [WorkflowStepTransition]? = nil,
    loop: WorkflowStepLoopMetadata? = nil,
    placement: DistributedExecutionPlacement? = nil
  ) {
    self.placement = placement
    self.id = id
    self.stepFile = stepFile
    self.nodeId = nodeId
    self.description = description
    self.role = role
    self.promptVariant = promptVariant
    self.timeoutMs = timeoutMs
    self.stallTimeoutMs = stallTimeoutMs
    self.failurePolicy = failurePolicy
    self.sessionPolicy = sessionPolicy
    self.transitions = transitions
    self.loop = loop
  }
}
