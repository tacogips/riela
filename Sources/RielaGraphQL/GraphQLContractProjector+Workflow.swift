import Foundation
import RielaCore

extension GraphQLContractProjector {
  public static func project(
    snapshot: WorkflowRuntimePersistenceSnapshot,
    hookEvents: [GraphQLHookEventDTO] = [],
    eventReceipts: [GraphQLEventReceiptDTO] = [],
    replyDispatches: [GraphQLReplyDispatchDTO] = [],
    logs: [GraphQLLogEntryDTO] = [],
    llmSessionMessages: [GraphQLLLMSessionMessageDTO] = []
  ) -> GraphQLWorkflowSessionDTO {
    project(
      session: snapshot.session,
      communications: snapshot.workflowMessages,
      hookEvents: hookEvents,
      eventReceipts: eventReceipts,
      replyDispatches: replyDispatches,
      logs: logs,
      llmSessionMessages: llmSessionMessages,
      loopEvidence: snapshot.loopEvidence
    )
  }

  public static func projectSessionSummary(
    session: WorkflowSession,
    workflowName: String,
    sessionStore: String? = nil
  ) -> GraphQLWorkflowSessionSummaryDTO {
    GraphQLWorkflowSessionSummaryDTO(
      sessionId: session.sessionId,
      parentSessionId: session.parentSessionId,
      rootSessionId: session.rootSessionId,
      workflowName: workflowName,
      status: session.status.rawValue,
      failureKind: session.failureKind?.rawValue,
      currentStepId: session.currentStepId,
      instanceIdentity: session.instanceIdentity,
      instanceKind: session.instanceKind,
      executionCount: session.executions.count,
      updatedAt: session.updatedAt,
      sessionStore: sessionStore
    )
  }

  public static func iso8601String(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}
