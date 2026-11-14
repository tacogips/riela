import Foundation
import RielaCore

public struct SessionRerunOptions: Equatable, Sendable {
  public var sessionId: String
  public var stepId: String
  public var output: WorkflowOutputFormat
  public var scope: WorkflowScope
  public var workflowDefinitionDir: String?
  public var workingDirectory: String
  public var mockScenarioPath: String?
  public var sessionStore: String?
  public var nestedSuperviser: Bool

  public init(
    sessionId: String,
    stepId: String,
    output: WorkflowOutputFormat = .jsonl,
    scope: WorkflowScope = .auto,
    workflowDefinitionDir: String? = nil,
    workingDirectory: String = FileManager.default.currentDirectoryPath,
    mockScenarioPath: String? = nil,
    sessionStore: String? = nil,
    nestedSuperviser: Bool = false
  ) {
    self.sessionId = sessionId
    self.stepId = stepId
    self.output = output
    self.scope = scope
    self.workflowDefinitionDir = workflowDefinitionDir
    self.workingDirectory = workingDirectory
    self.mockScenarioPath = mockScenarioPath
    self.sessionStore = sessionStore
    self.nestedSuperviser = nestedSuperviser
  }
}

public struct SessionResumeOptions: Equatable, Sendable {
  public var sessionId: String
  public var output: WorkflowOutputFormat
  public var scope: WorkflowScope
  public var workflowDefinitionDir: String?
  public var workingDirectory: String
  public var mockScenarioPath: String?
  public var sessionStore: String?
  public var maxSteps: Int?
  public var variables: String?

  public init(
    sessionId: String,
    output: WorkflowOutputFormat = .jsonl,
    scope: WorkflowScope = .auto,
    workflowDefinitionDir: String? = nil,
    workingDirectory: String = FileManager.default.currentDirectoryPath,
    mockScenarioPath: String? = nil,
    sessionStore: String? = nil,
    maxSteps: Int? = nil,
    variables: String? = nil
  ) {
    self.sessionId = sessionId
    self.output = output
    self.scope = scope
    self.workflowDefinitionDir = workflowDefinitionDir
    self.workingDirectory = workingDirectory
    self.mockScenarioPath = mockScenarioPath
    self.sessionStore = sessionStore
    self.maxSteps = maxSteps
    self.variables = variables
  }
}

public struct SessionRerunCommandResult: Codable, Equatable, Sendable {
  public var sourceSessionId: String
  public var sessionId: String
  public var status: WorkflowSessionStatus
  public var rerunFromStepId: String
  public var exitCode: Int32
  public var recovery: LoopRecoveryLineage?
}

public struct SessionResumeCommandResult: Codable, Equatable, Sendable {
  public var sourceSessionId: String?
  public var sessionId: String
  public var status: WorkflowSessionStatus
  public var exitCode: Int32
  public var recovery: LoopRecoveryLineage?
}

public struct SessionCommandFailureResult: Codable, Equatable, Sendable {
  public var sessionId: String
  public var error: String
  public var exitCode: Int32
}

public struct SessionDiscoveryRow: Codable, Equatable, Sendable {
  public var sessionId: String
  public var workflowName: String
  public var status: WorkflowSessionStatus
  public var failureKind: WorkflowSessionFailureKind?
  public var currentStepId: String?
  public var executionCount: Int
  public var updatedAt: Date
  public var sessionStore: String

  public init(record: PersistedCLIWorkflowSession, sessionStore: String) {
    self.sessionId = record.session.sessionId
    self.workflowName = record.workflowName
    self.status = record.session.status
    self.failureKind = record.session.failureKind
    self.currentStepId = record.session.currentStepId
    self.executionCount = record.session.executions.count
    self.updatedAt = record.session.updatedAt
    self.sessionStore = sessionStore
  }
}
