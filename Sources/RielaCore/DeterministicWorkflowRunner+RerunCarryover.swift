import Foundation

/// Source evidence a plain step rerun imports through `importAcceptedHistory`.
struct RerunCarriedEvidence: Equatable, Sendable {
  /// Accepted producer executions, in source order.
  var executions: [WorkflowStepExecution]
  /// Carried messages, ordered by `createdOrder`.
  var messages: [WorkflowMessageRecord]
}

/// One static workflow-graph edge used by rerun preflight. Edges are
/// `transitions[].toStepId` when `toWorkflowId` is nil, `resumeStepId` for a
/// cross-workflow transition, and `fanout.joinStepId`.
struct RerunGraphEdge: Hashable, Sendable {
  var fromStepId: String
  var toStepId: String
  var label: String?
}

extension DeterministicWorkflowRunner {
  /// Selects the inbox state a plain step rerun carries from its source (#135).
  ///
  /// `T` is the latest source execution of the target. Its recorded inbox
  /// (`_rielaInput.communicationIds`) is validated strictly: every id must be
  /// a delivered or consumed workflow message addressed to the target, and a
  /// producer that is a source execution must be completed with accepted
  /// output. Ids whose producer is not a source execution (manager, handover
  /// or event injections) are skipped.
  ///
  /// The carry is a time cut, not only the target inbox: every resolvable
  /// workflow message with `createdOrder <= cut` (the newest recorded target
  /// message) that is addressed to another step the rerun can re-execute is
  /// carried too, when its producer is an accepted completed execution. This
  /// reproduces the source inbox of every reachable step as of `T`, so a loop
  /// back-edge such as `integration-review -(plans_remaining)-> dispatch-plans`
  /// still finds the `plan-git-push` checkpoint message.
  func rerunCarriedInbox(
    source: WorkflowSession,
    workflow: WorkflowDefinition,
    targetStepId: String
  ) async throws -> RerunCarriedEvidence? {
    guard let target = source.executions.last(where: { $0.stepId == targetStepId }),
          let communicationIds = Self.recordedInboxCommunicationIds(of: target),
          !communicationIds.isEmpty else {
      return nil
    }

    let sourceMessages = try await store.listMessages(for: source.sessionId, toStepId: nil)
    let messagesById = Dictionary(sourceMessages.map { ($0.communicationId, $0) }) { first, _ in first }
    let executionsById = Dictionary(source.executions.map { ($0.executionId, $0) }) { first, _ in first }

    var carriedById: [String: WorkflowMessageRecord] = [:]
    var cut = Int.min
    for communicationId in communicationIds {
      guard let message = messagesById[communicationId],
            message.toStepId == targetStepId,
            message.routingScope == .workflow,
            message.isResolvableInput else {
        throw Self.unacceptedInboxError(communicationId)
      }
      cut = max(cut, message.createdOrder)
      guard let producer = executionsById[message.sourceStepExecutionId] else {
        continue
      }
      guard Self.isImportableProducer(producer) else {
        throw Self.unacceptedInboxError(
          communicationId,
          detail: "producer \(producer.stepId) execution \(producer.executionId) is \(producer.status.rawValue) without accepted output"
        )
      }
      carriedById[communicationId] = message
    }

    let reexecuted = Self.rerunReachableStepIds(workflow: workflow, from: targetStepId)
    for message in sourceMessages where carriedById[message.communicationId] == nil {
      guard message.createdOrder <= cut,
            let toStepId = message.toStepId,
            toStepId != targetStepId,
            reexecuted.contains(toStepId),
            message.routingScope == .workflow,
            message.isResolvableInput,
            let producer = executionsById[message.sourceStepExecutionId],
            Self.isImportableProducer(producer) else {
        continue
      }
      carriedById[message.communicationId] = message
    }
    guard !carriedById.isEmpty else {
      return nil
    }

    let messages = carriedById.values.sorted {
      $0.createdOrder == $1.createdOrder ? $0.communicationId < $1.communicationId : $0.createdOrder < $1.createdOrder
    }
    let producerIds = Set(messages.map(\.sourceStepExecutionId))
    return RerunCarriedEvidence(
      executions: source.executions.filter { producerIds.contains($0.executionId) },
      messages: messages
    )
  }

  /// The communication ids an execution recorded as its resolved inbox.
  /// Agent invocations record them under `mergedVariables`; command,
  /// container and add-on steps record them under `resolvedInputPayload`.
  /// Returns nil when the execution never resolved its input or the record is
  /// malformed.
  static func recordedInboxCommunicationIds(of execution: WorkflowStepExecution) -> [String]? {
    for key in ["mergedVariables", "resolvedInputPayload"] {
      guard case let .object(container)? = execution.inputSnapshot?[key],
            case let .object(rielaInput)? = container["_rielaInput"] else {
        continue
      }
      guard case let .array(rawIds)? = rielaInput["communicationIds"] else {
        return nil
      }
      let ids = rawIds.compactMap { value -> String? in
        guard case let .string(id) = value else { return nil }
        return id
      }
      return ids.count == rawIds.count ? ids : nil
    }
    return nil
  }

  /// Every step a rerun from `start` can execute: the start step plus every
  /// step reachable from it over `rerunGraphEdges`.
  static func rerunReachableStepIds(workflow: WorkflowDefinition, from start: String) -> Set<String> {
    let edgesBySource = Dictionary(grouping: rerunGraphEdges(workflow: workflow), by: \.fromStepId)
    var visited: Set<String> = [start]
    var queue = [start]
    while !queue.isEmpty {
      let current = queue.removeFirst()
      for edge in edgesBySource[current, default: []] where visited.insert(edge.toStepId).inserted {
        queue.append(edge.toStepId)
      }
    }
    return visited
  }

  static func rerunGraphEdges(workflow: WorkflowDefinition) -> [RerunGraphEdge] {
    workflow.steps.flatMap { step in
      (step.transitions ?? []).flatMap { transition -> [RerunGraphEdge] in
        var edges: [RerunGraphEdge] = []
        if let destination = rerunGraphDestination(of: transition) {
          edges.append(RerunGraphEdge(fromStepId: step.id, toStepId: destination, label: transition.label))
        }
        if let joinStepId = transition.fanout?.joinStepId {
          edges.append(RerunGraphEdge(fromStepId: step.id, toStepId: joinStepId, label: nil))
        }
        return edges
      }
    }
  }

  static func rerunGraphDestination(of transition: WorkflowStepTransition) -> String? {
    transition.toWorkflowId == nil ? transition.toStepId : transition.resumeStepId
  }

  private static func isImportableProducer(_ execution: WorkflowStepExecution) -> Bool {
    execution.status == .completed && execution.acceptedOutput != nil
  }

  private static func unacceptedInboxError(_ communicationId: String, detail: String? = nil) -> DeterministicWorkflowRunnerError {
    let reason = detail.map { " (\($0))" } ?? ""
    return .rerunValidation(
      "cannot carry rerun input: recorded inbox communication \(communicationId) is missing or unaccepted\(reason); " +
        "use --preserve-history or rerun an earlier step"
    )
  }
}
