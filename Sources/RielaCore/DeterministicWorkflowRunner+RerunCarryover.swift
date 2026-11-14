import Foundation

extension DeterministicWorkflowRunner {
  func rerunCarriedInbox(source: WorkflowSession, targetStepId: String) async throws -> WorkflowHistoryImportInput? {
    guard let target = source.executions.last(where: { $0.stepId == targetStepId }),
          case let .object(mergedVariables)? = target.inputSnapshot?["mergedVariables"],
          case let .object(rielaInput)? = mergedVariables["_rielaInput"],
          case let .array(rawIds)? = rielaInput["communicationIds"] else {
      return nil
    }
    let communicationIds = rawIds.compactMap { value -> String? in
      guard case let .string(id) = value else { return nil }
      return id
    }
    guard communicationIds.count == rawIds.count else { return nil }

    let sourceMessages = try await store.listMessages(for: source.sessionId, toStepId: nil)
    var carriedMessages: [WorkflowMessageRecord] = []
    for communicationId in communicationIds {
      guard let message = sourceMessages.first(where: { $0.communicationId == communicationId }),
            message.toStepId == targetStepId,
            message.routingScope == .workflow,
            message.lifecycleStatus == .delivered || message.lifecycleStatus == .consumed else {
        throw DeterministicWorkflowRunnerError.rerunValidation(
          "cannot carry rerun input: recorded inbox communication \(communicationId) is missing or unaccepted; " +
            "use --preserve-history or rerun an earlier step")
      }
      carriedMessages.append(message)
    }

    let acceptedProducerIds = Set(source.executions.compactMap { execution -> String? in
      execution.status == .completed && execution.acceptedOutput != nil ? execution.executionId : nil
    })
    carriedMessages = carriedMessages.filter { acceptedProducerIds.contains($0.sourceStepExecutionId) }
    guard !carriedMessages.isEmpty else { return nil }

    let producerIds = Set(carriedMessages.map(\.sourceStepExecutionId))
    let producerExecutions = source.executions.filter { producerIds.contains($0.executionId) }
    let orderedMessages = carriedMessages.sorted { $0.createdOrder < $1.createdOrder }
    return WorkflowHistoryImportInput(
      sessionId: "",
      sourceSessionId: source.sessionId,
      executions: producerExecutions,
      messages: orderedMessages
    )
  }
}
