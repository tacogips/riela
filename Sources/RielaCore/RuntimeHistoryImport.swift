import Foundation

public struct WorkflowImportedExecutionSource: Codable, Equatable, Sendable {
  public var sessionId: String
  public var executionId: String
  /// New communication identity to its source identity, scoped by sessionId.
  public var communicationIds: [String: String] = [:]
}

public struct WorkflowHistoryImportInput: Sendable {
  public var sessionId: String
  public var sourceSessionId: String
  public var executions: [WorkflowStepExecution]
  public var messages: [WorkflowMessageRecord]

  public init(sessionId: String, sourceSessionId: String, executions: [WorkflowStepExecution], messages: [WorkflowMessageRecord]) {
    self.sessionId = sessionId
    self.sourceSessionId = sourceSessionId
    self.executions = executions
    self.messages = messages
  }
}

extension InMemoryWorkflowRuntimeStore {
  /// Import evidence atomically in memory, without publication hooks or backend events.
  public func importAcceptedHistory(_ input: WorkflowHistoryImportInput) async throws -> WorkflowSession {
    guard var session = sessions[input.sessionId], session.status == .created,
          let sourceSession = sessions[input.sourceSessionId],
          sourceSession.status == .failed,
          sourceSession.workflowId == session.workflowId,
          session.executions.isEmpty, messagesBySession[input.sessionId, default: []].isEmpty,
          input.sessionId != input.sourceSessionId else {
      throw WorkflowRuntimeStoreError.messageAppendRejected("history import requires an empty new session")
    }
    guard Set(input.messages.map(\.communicationId)).count == input.messages.count,
          input.messages.allSatisfy({ messagesBySession[input.sourceSessionId, default: []].contains($0) }) else {
      throw WorkflowRuntimeStoreError.messageAppendRejected("history import must reference canonical source evidence")
    }
    var executionMap: [String: String] = [:]
    var executions: [WorkflowStepExecution] = []
    for source in input.executions {
      guard let canonical = sourceSession.executions.first(where: { $0.executionId == source.executionId }),
            canonical.stepId == source.stepId, canonical.nodeId == source.nodeId,
            canonical.attempt == source.attempt, canonical.status == source.status,
            canonical.inputSnapshot == source.inputSnapshot, canonical.acceptedOutput == source.acceptedOutput else {
        throw WorkflowRuntimeStoreError.messageAppendRejected("history execution metadata differs from canonical source")
      }
      guard source.status == .completed, source.acceptedOutput != nil,
            executionMap[source.executionId] == nil else {
        throw WorkflowRuntimeStoreError.messageAppendRejected("history import requires unique accepted executions")
      }
      // Caller-provided live-tail projections can differ from storage. Import
      // only canonical evidence; backend/live-tail data is cleared below.
      var imported = canonical
      imported.executionId = "import-\(UUID().uuidString)"
      imported.importedFrom = WorkflowImportedExecutionSource(sessionId: input.sourceSessionId, executionId: source.executionId)
      imported.backend = nil
      imported.backendSessionId = nil
      imported.backendWorkingDirectory = nil
      imported.adapterOutput = nil
      imported.usage = nil
      imported.backendEventCount = nil
      imported.recentBackendEvents = nil
      imported.lastBackendEventAt = nil
      imported.lastBackendEventType = nil
      imported.streamedResponseText = nil
      imported.pendingRoutePublication = nil
      imported.acceptedOutput?.runtimeFinalizationToken = nil
      executionMap[source.executionId] = imported.executionId
      executions.append(imported)
    }
    var messages: [WorkflowMessageRecord] = []
    for source in input.messages {
      guard let executionId = executionMap[source.sourceStepExecutionId],
            source.workflowExecutionId == input.sourceSessionId else {
        throw WorkflowRuntimeStoreError.messageAppendRejected("history message lacks an accepted source execution")
      }
      var imported = source
      imported.communicationId = try idGenerator.nextCommunicationId()
      imported.workflowExecutionId = input.sessionId
      imported.sourceStepExecutionId = executionId
      if let index = executions.firstIndex(where: { $0.executionId == executionId }) {
        executions[index].importedFrom?.communicationIds[imported.communicationId] = source.communicationId
      }
      messages.append(imported)
    }
    session.executions = executions
    session.parentSessionId = input.sourceSessionId
    sessions[input.sessionId] = session
    messagesBySession[input.sessionId] = messages
    createdOrder = max(createdOrder, messages.map(\.createdOrder).max() ?? 0)
    return session
  }
}
