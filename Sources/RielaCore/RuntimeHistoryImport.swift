import Foundation

public enum HistoryImportSource: Sendable {
  case session
  case bundle(HandoverHistoryBundle, handoverId: String)
}

public struct WorkflowImportedExecutionSource: Codable, Equatable, Sendable {
  public var sessionId: String
  public var executionId: String
  /// New communication identity to its source identity, scoped by sessionId.
  public var communicationIds: [String: String] = [:]
  public var handoverId: String?

  public init(sessionId: String, executionId: String, communicationIds: [String: String] = [:], handoverId: String? = nil) {
    self.sessionId = sessionId
    self.executionId = executionId
    self.communicationIds = communicationIds
    self.handoverId = handoverId
  }
}

public struct WorkflowHistoryImportInput: Sendable {
  public var sessionId: String
  public var sourceSessionId: String
  public var executions: [WorkflowStepExecution]
  public var messages: [WorkflowMessageRecord]
  public var source: HistoryImportSource

  public init(sessionId: String, sourceSessionId: String, executions: [WorkflowStepExecution], messages: [WorkflowMessageRecord]) {
    self.sessionId = sessionId
    self.sourceSessionId = sourceSessionId
    self.executions = executions
    self.messages = messages
    source = .session
  }

  public init(sessionId: String, sourceSessionId: String, bundle: HandoverHistoryBundle, handoverId: String) {
    self.sessionId = sessionId
    self.sourceSessionId = sourceSessionId
    executions = bundle.executions
    messages = bundle.messages
    source = .bundle(bundle, handoverId: handoverId)
  }
}

extension InMemoryWorkflowRuntimeStore {
  /// Import evidence atomically in memory, without publication hooks or backend events.
  public func importAcceptedHistory(_ input: WorkflowHistoryImportInput) async throws -> WorkflowSession {
    guard var session = sessions[input.sessionId], session.status == .created,
          session.executions.isEmpty, messagesBySession[input.sessionId, default: []].isEmpty,
          input.sessionId != input.sourceSessionId else {
      throw WorkflowRuntimeStoreError.messageAppendRejected("history import requires an empty new session")
    }

    let sourceSession: WorkflowSession?
    let importedHandoverId: String?
    switch input.source {
    case .session:
      guard let canonicalSource = sessions[input.sourceSessionId],
            canonicalSource.status == .failed || canonicalSource.status == .suspended,
            canonicalSource.workflowId == session.workflowId else {
        throw WorkflowRuntimeStoreError.messageAppendRejected("history import requires a failed or suspended source session in the same workflow")
      }
      guard input.messages.allSatisfy({ messagesBySession[input.sourceSessionId, default: []].contains($0) }) else {
        throw WorkflowRuntimeStoreError.messageAppendRejected("history import must reference canonical source evidence")
      }
      sourceSession = canonicalSource
      importedHandoverId = nil
    case let .bundle(bundle, handoverId):
      guard !bundle.truncated else {
        throw WorkflowRuntimeStoreError.messageAppendRejected(
          "history bundle for handover \(handoverId) is truncated; read the packet from the controller store")
      }
      guard input.executions == bundle.executions, input.messages == bundle.messages else {
        throw WorkflowRuntimeStoreError.messageAppendRejected("history import input differs from its history bundle")
      }
      guard Set(bundle.executions.map(\.stepId)).count == bundle.executions.count,
            bundle.executions.allSatisfy({ $0.status == .completed && $0.acceptedOutput != nil }) else {
        throw WorkflowRuntimeStoreError.messageAppendRejected("history bundle requires unique accepted completed executions")
      }
      let bundleExecutionIds = Set(bundle.executions.map(\.executionId))
      guard bundleExecutionIds.count == bundle.executions.count,
            bundle.messages.allSatisfy({ $0.workflowExecutionId == input.sourceSessionId && bundleExecutionIds.contains($0.sourceStepExecutionId) }) else {
        throw WorkflowRuntimeStoreError.messageAppendRejected("history bundle message lacks an accepted source execution")
      }
      sourceSession = nil
      importedHandoverId = handoverId
    }

    guard Set(input.messages.map(\.communicationId)).count == input.messages.count else {
      throw WorkflowRuntimeStoreError.messageAppendRejected("history import requires unique communication ids")
    }
    var executionMap: [String: String] = [:]
    var executions: [WorkflowStepExecution] = []
    for source in input.executions {
      let canonical: WorkflowStepExecution
      if let sourceSession {
        guard let stored = sourceSession.executions.first(where: { $0.executionId == source.executionId }),
              stored.stepId == source.stepId, stored.nodeId == source.nodeId,
              stored.attempt == source.attempt, stored.status == source.status,
              stored.inputSnapshot == source.inputSnapshot, stored.acceptedOutput == source.acceptedOutput else {
          throw WorkflowRuntimeStoreError.messageAppendRejected("history execution metadata differs from canonical source")
        }
        canonical = stored
      } else {
        canonical = source
      }
      guard source.status == .completed, source.acceptedOutput != nil,
            executionMap[source.executionId] == nil else {
        throw WorkflowRuntimeStoreError.messageAppendRejected("history import requires unique accepted executions")
      }
      // Caller-provided live-tail projections can differ from storage. Import
      // only canonical evidence; backend/live-tail data is cleared below.
      var imported = canonical
      imported.executionId = "import-\(UUID().uuidString)"
      imported.importedFrom = WorkflowImportedExecutionSource(
        sessionId: input.sourceSessionId, executionId: source.executionId, handoverId: importedHandoverId)
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
