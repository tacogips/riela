import Foundation

public enum WorkflowStdioNodeExecutionKind: String, Codable, Equatable, Sendable {
  case command
  case container
}

public struct WorkflowStdioNodeExecutionInput: Equatable, Sendable {
  public var workflowId: String
  public var sessionId: String
  public var stepId: String
  public var nodeId: String
  public var executionIndex: Int
  public var kind: WorkflowStdioNodeExecutionKind
  public var node: AgentNodePayload
  public var variables: JSONObject
  public var resolvedInputPayload: JSONObject
  public var memoryRootDirectory: String?
  public var availableMemories: [WorkflowMemoryDeclaration]
  public var policy: LoopPolicyStepDecision?

  public init(
    workflowId: String,
    sessionId: String,
    stepId: String,
    nodeId: String,
    executionIndex: Int,
    kind: WorkflowStdioNodeExecutionKind,
    node: AgentNodePayload,
    variables: JSONObject,
    resolvedInputPayload: JSONObject,
    memoryRootDirectory: String? = nil,
    availableMemories: [WorkflowMemoryDeclaration] = [],
    policy: LoopPolicyStepDecision? = nil
  ) {
    self.workflowId = workflowId
    self.sessionId = sessionId
    self.stepId = stepId
    self.nodeId = nodeId
    self.executionIndex = executionIndex
    self.kind = kind
    self.node = node
    self.variables = variables
    self.resolvedInputPayload = resolvedInputPayload
    self.memoryRootDirectory = memoryRootDirectory
    self.availableMemories = availableMemories
    self.policy = policy
  }
}

public struct WorkflowStdioNodeExecutionResult: Equatable, Sendable {
  public var payload: JSONObject?
  public var commandEvidence: LoopCommandEvidence?

  public init(payload: JSONObject? = nil, commandEvidence: LoopCommandEvidence? = nil) {
    self.payload = payload
    self.commandEvidence = commandEvidence
  }
}

public struct WorkflowStdioNodeInvocationEnvelope: Codable, Equatable, Sendable {
  public var workflowId: String
  public var workflowExecutionId: String
  public var stepId: String
  public var nodeId: String
  public var executionIndex: Int
  public var nodeType: String
  public var variables: JSONObject
  public var input: JSONObject
  public var memoryRootDirectory: String?
  public var availableMemories: [WorkflowMemoryDeclaration]
  public var policy: LoopPolicyStepDecision?

  public init(
    workflowId: String,
    workflowExecutionId: String,
    stepId: String,
    nodeId: String,
    executionIndex: Int,
    nodeType: String,
    variables: JSONObject,
    input: JSONObject,
    memoryRootDirectory: String? = nil,
    availableMemories: [WorkflowMemoryDeclaration] = [],
    policy: LoopPolicyStepDecision? = nil
  ) {
    self.workflowId = workflowId
    self.workflowExecutionId = workflowExecutionId
    self.stepId = stepId
    self.nodeId = nodeId
    self.executionIndex = executionIndex
    self.nodeType = nodeType
    self.variables = variables
    self.input = input
    self.memoryRootDirectory = memoryRootDirectory
    self.availableMemories = availableMemories
    self.policy = policy
  }
}

public protocol WorkflowStdioNodeExecuting: Sendable {
  func execute(_ input: WorkflowStdioNodeExecutionInput, context: AdapterExecutionContext) async throws -> WorkflowStdioNodeExecutionResult
}

public func workflowStdioNodeExecutionKind(for payload: AgentNodePayload) -> WorkflowStdioNodeExecutionKind? {
  switch payload.nodeType {
  case .command:
    return .command
  case .container:
    return .container
  case .agent, .sleep, .userAction, .addon, nil:
    return nil
  }
}
