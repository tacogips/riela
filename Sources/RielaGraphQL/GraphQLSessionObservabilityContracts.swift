import Foundation
import RielaCore

public struct GraphQLWorkflowSessionSummaryDTO: Codable, Equatable, Sendable {
  public var sessionId: String
  public var parentSessionId: String?
  public var rootSessionId: String?
  public var workflowName: String
  public var status: String
  public var failureKind: String?
  public var currentStepId: String?
  public var instanceIdentity: String?
  public var instanceKind: String?
  public var executionCount: Int
  public var updatedAt: Date
  public var sessionStore: String?

  public init(
    sessionId: String,
    parentSessionId: String? = nil,
    rootSessionId: String? = nil,
    workflowName: String,
    status: String,
    failureKind: String? = nil,
    currentStepId: String? = nil,
    instanceIdentity: String? = nil,
    instanceKind: String? = nil,
    executionCount: Int,
    updatedAt: Date,
    sessionStore: String? = nil
  ) {
    self.sessionId = sessionId
    self.parentSessionId = parentSessionId
    self.rootSessionId = rootSessionId
    self.workflowName = workflowName
    self.status = status
    self.failureKind = failureKind
    self.currentStepId = currentStepId
    self.instanceIdentity = instanceIdentity
    self.instanceKind = instanceKind
    self.executionCount = executionCount
    self.updatedAt = updatedAt
    self.sessionStore = sessionStore
  }
}

public struct GraphQLSessionProgressRequest: Codable, Equatable, Sendable {
  public var sessionId: String
  public var includeChildren: Bool

  public init(sessionId: String, includeChildren: Bool = false) {
    self.sessionId = sessionId
    self.includeChildren = includeChildren
  }
}

public struct GraphQLSessionHealthRequest: Codable, Equatable, Sendable {
  public var sessionId: String

  public init(sessionId: String) {
    self.sessionId = sessionId
  }
}

public struct GraphQLSessionObservabilityResult: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var view: SessionObservabilityView?

  public init(result: GraphQLControlPlaneResult, view: SessionObservabilityView? = nil) {
    self.result = result
    self.view = view
  }
}
