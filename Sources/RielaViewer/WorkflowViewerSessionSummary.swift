import Foundation
import RielaCore

public struct WorkflowViewerSessionSummary: Codable, Equatable, Sendable {
  public var sessionId: String
  public var workflowId: String
  public var status: WorkflowSessionStatus
  public var currentStepId: String?
  public var activeStepIds: [String]
  public var updatedAt: Date

  public init(
    sessionId: String,
    workflowId: String,
    status: WorkflowSessionStatus,
    currentStepId: String?,
    activeStepIds: [String],
    updatedAt: Date
  ) {
    self.sessionId = sessionId
    self.workflowId = workflowId
    self.status = status
    self.currentStepId = currentStepId
    self.activeStepIds = activeStepIds
    self.updatedAt = updatedAt
  }
}
