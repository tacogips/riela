import RielaCore

public struct GraphQLExecuteWorkflowInput: Codable, Equatable, Sendable {
  public var workflowName: String
  public var runtimeVariables: JSONObject?
  public var instanceIdentity: String?
  public var nodePatch: JSONObject?
  public var maxSteps: Int?
  public var maxConcurrency: Int?
  public var maxLoopIterations: Int?
  public var disableDefaultLoopGuard: Bool?
  public var defaultTimeoutMs: Int?

  public init(
    workflowName: String,
    runtimeVariables: JSONObject? = nil,
    instanceIdentity: String? = nil,
    nodePatch: JSONObject? = nil,
    maxSteps: Int? = nil,
    maxConcurrency: Int? = nil,
    maxLoopIterations: Int? = nil,
    disableDefaultLoopGuard: Bool? = nil,
    defaultTimeoutMs: Int? = nil
  ) {
    self.workflowName = workflowName
    self.runtimeVariables = runtimeVariables
    self.instanceIdentity = instanceIdentity
    self.nodePatch = nodePatch
    self.maxSteps = maxSteps
    self.maxConcurrency = maxConcurrency
    self.maxLoopIterations = maxLoopIterations
    self.disableDefaultLoopGuard = disableDefaultLoopGuard
    self.defaultTimeoutMs = defaultTimeoutMs
  }
}

public struct GraphQLExecuteWorkflowPayload: Codable, Equatable, Sendable {
  public var workflowExecutionId: String
  public var sessionId: String
  public var status: String
  public var exitCode: Int

  public init(workflowExecutionId: String, sessionId: String, status: String, exitCode: Int) {
    self.workflowExecutionId = workflowExecutionId
    self.sessionId = sessionId
    self.status = status
    self.exitCode = exitCode
  }
}

public struct GraphQLExecutionTransitionSummary: Codable, Equatable, Sendable {
  public var `when`: String?

  public init(when: String?) { self.when = `when` }

  private enum CodingKeys: String, CodingKey { case `when` }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if let value = `when` {
      try container.encode(value, forKey: .when)
    } else {
      try container.encodeNil(forKey: .when)
    }
  }
}

public struct GraphQLWorkflowExecutionNodeSummary: Codable, Equatable, Sendable {
  public var nodeExecId: String

  public init(nodeExecId: String) { self.nodeExecId = nodeExecId }
}

public struct GraphQLWorkflowExecutionSessionSummary: Codable, Equatable, Sendable {
  public var sessionId: String
  public var workflowName: String
  public var workflowId: String
  public var transitions: [GraphQLExecutionTransitionSummary]

  public init(
    sessionId: String,
    workflowName: String,
    workflowId: String,
    transitions: [GraphQLExecutionTransitionSummary]
  ) {
    self.sessionId = sessionId
    self.workflowName = workflowName
    self.workflowId = workflowId
    self.transitions = transitions
  }
}

public struct GraphQLWorkflowExecutionSummary: Codable, Equatable, Sendable {
  public var session: GraphQLWorkflowExecutionSessionSummary
  public var nodeExecutions: [GraphQLWorkflowExecutionNodeSummary]

  public init(
    session: GraphQLWorkflowExecutionSessionSummary,
    nodeExecutions: [GraphQLWorkflowExecutionNodeSummary]
  ) {
    self.session = session
    self.nodeExecutions = nodeExecutions
  }
}

public protocol WorkflowExecutionGraphQLProviding: Sendable {
  func executeWorkflow(_ input: GraphQLExecuteWorkflowInput) async throws -> GraphQLExecuteWorkflowPayload
  func workflowExecution(workflowExecutionId: String) async throws -> GraphQLWorkflowExecutionSummary?
}
