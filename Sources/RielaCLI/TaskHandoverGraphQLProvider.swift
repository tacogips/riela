import Foundation
import RielaCore
import RielaGraphQL
import RielaWork

struct TaskHandoverGraphQLProvider: TaskHandoverGraphQLProviding {
  let workingDirectory: String
  let sessionStore: String?
  let scope: WorkflowScope

  init(workingDirectory: String, sessionStore: String?, scope: WorkflowScope = .auto) {
    self.workingDirectory = workingDirectory
    self.sessionStore = sessionStore
    self.scope = scope
  }

  func taskHandover(
    taskId: String,
    handoverId: String?,
    context: GraphQLDocumentRequest
  ) async throws -> GraphQLHandoverPacket? {
    let taskID = TaskID(taskId)
    let located = try locate(taskID, context: context)
    let packet: HandoverPacket?
    if let handoverId {
      packet = try located.store.loadHandover(id: HandoverID(handoverId))
    } else {
      packet = try located.store.latestHandover(taskId: taskID)
    }
    guard let packet else { return nil }
    guard packet.taskId == taskID else {
      throw TaskHandoverGraphQLError(code: "not_found", message: "handover was not found for this task")
    }
    return try graphQLPacket(packet)
  }

  func tasksAwaitingHandover(
    traits: [String]?,
    context: GraphQLDocumentRequest
  ) async throws -> [GraphQLTaskHandoverSummary] {
    let decodedTraits = try traits.map(decodeTraits)
    let store = storeForContext(context)
    return try store.tasksAwaitingHandover(traits: decodedTraits).map { summary in
      GraphQLTaskHandoverSummary(
        taskId: summary.taskId.rawValue,
        handoverId: summary.handoverId.rawValue,
        reasonKind: summary.reasonKind,
        requiredTraits: summary.requiredTraits.map(\.rawValue),
        needsAnswer: summary.needsAnswer,
        questionText: summary.questionText,
        createdAt: Self.timestamp(summary.createdAt)
      )
    }
  }

  func requestTaskHandover(
    _ input: GraphQLRequestTaskHandoverInput,
    context: GraphQLDocumentRequest
  ) async throws -> GraphQLTaskHandoverMutationPayload {
    let located = try locate(TaskID(input.taskId), context: context)
    let sinks = try (input.sinks ?? []).map { rawValue -> HandoverSinkKind in
      guard let sink = HandoverSinkKind(rawValue: rawValue) else {
        throw TaskHandoverGraphQLError(code: "invalid_input", message: "unknown handover sink '\(rawValue)'")
      }
      return sink
    }
    let request = try TaskHandoverRuntime(located: located, options: options(context))
      .requestHandover(
        taskId: located.task.id,
        reason: input.reason,
        immediate: input.immediate ?? false,
        target: input.target,
        sinks: sinks
      )
    return GraphQLTaskHandoverMutationPayload(
      taskId: input.taskId,
      taskState: located.task.state.rawValue,
      decisionKind: "handover",
      requestId: request.requestId
    )
  }

  func answerTask(
    _ input: GraphQLAnswerTaskInput,
    context: GraphQLDocumentRequest
  ) async throws -> GraphQLTaskHandoverMutationPayload {
    let located = try locate(TaskID(input.taskId), context: context)
    let task = try TaskHandoverRuntime(located: located, options: options(context)).answer(
      taskId: located.task.id,
      questionId: input.questionId,
      payload: input.answer,
      producer: .human(principal: input.principal ?? "graphql")
    )
    let answer = try located.store.listDecisions(taskId: task.id).last { $0.kind.kindName == "answer" }
    return GraphQLTaskHandoverMutationPayload(
      taskId: input.taskId,
      taskState: task.state.rawValue,
      decisionKind: answer?.kind.kindName
    )
  }

  func takeoverTask(
    _ input: GraphQLTakeoverTaskInput,
    context: GraphQLDocumentRequest
  ) async throws -> GraphQLTakeoverTaskPayload {
    guard !input.hostId.isEmpty else {
      throw TaskHandoverGraphQLError(code: "invalid_input", message: "hostId must not be empty")
    }
    let traits = try decodeTraits(input.traits)
    let taskID = TaskID(input.taskId)
    let located = try locate(taskID, context: context)
    guard let packet = try located.store.loadHandover(id: HandoverID(input.handoverId)), packet.taskId == taskID else {
      throw TaskHandoverGraphQLError(code: "not_found", message: "handover was not found for this task")
    }
    let requiredTraits: [HostTrait]
    if case let .userPresenceRequired(presence) = packet.reason {
      requiredTraits = presence.traits
    } else {
      requiredTraits = []
    }
    guard Set(traits).isSuperset(of: requiredTraits) else {
      let missing = requiredTraits.filter { !traits.contains($0) }.map(\.rawValue).sorted().joined(separator: ",")
      throw TaskHandoverGraphQLError(code: "conflict", message: "host-traits-unavailable: \(missing)")
    }
    let backend: NodeExecutionBackend?
    if let rawBackend = input.backend {
      guard let parsedBackend = NodeExecutionBackend(rawValue: rawBackend) else {
        throw TaskHandoverGraphQLError(code: "invalid_input", message: "unknown backend '\(rawBackend)'")
      }
      backend = parsedBackend
    } else {
      backend = nil
    }
    _ = try located.store.requestTakeover(
      taskId: taskID,
      placement: TakeoverPlacement(hostId: input.hostId, requiredTraits: traits, backend: backend, model: input.model),
      producer: .human(principal: "graphql"),
      decisionId: .generate(),
      now: Date()
    )
    guard case let .workflow(reference)? = located.task.plan else {
      throw TaskHandoverGraphQLError(code: "conflict", message: "task has no registered workflow plan")
    }
    let dispatcher = TaskDispatcher(store: located.store)
    let placement = BackendCapabilityPlacementResolver().resolve(
      requirements: [],
      local: HostCapabilitySnapshot(hostId: input.hostId, backends: [], refreshedAt: Date()),
      workers: []
    )
    let preview = try dispatcher.preview(
      taskId: taskID,
      workflowId: reference.name,
      entryStepId: packet.contract.resumeStepId,
      entry: .takeover(fromAttemptId: packet.fromAttemptId, handoverId: packet.id),
      placement: placement
    )
    guard case let .ready(ready) = preview else {
      throw TaskHandoverGraphQLError(code: "conflict", message: "task takeover admission is waiting")
    }
    let attemptId = AttemptID.generate()
    let placementEvidence = Evidence(
      id: EvidenceID("evidence-placement-\(attemptId.rawValue)"),
      taskId: taskID,
      attemptId: attemptId,
      kind: .contextSnapshot,
      producedBy: .runtime,
      payloadRef: .inline([
        "remoteHost": .string(input.hostId),
        "traits": .array(traits.map { .string($0.rawValue) })
      ]),
      createdAt: Date()
    )
    let result = try dispatcher.reserve(
      ready,
      attemptId: attemptId,
      sessionId: "task-session-\(UUID().uuidString.lowercased())",
      decisionId: try located.store.listDecisions(taskId: taskID).last(where: { $0.kind.kindName == "takeover" })?.id ?? .generate(),
      producer: .human(principal: "graphql"),
      reason: "remote GraphQL takeover",
      placementEvidence: placementEvidence,
      pendingRequestId: try dispatcher.pendingReservation(taskId: taskID)?.id,
      hostId: input.hostId
    )
    guard case let .reserved(reservation) = result else {
      throw TaskHandoverGraphQLError(code: "conflict", message: "task takeover reservation is waiting")
    }
    _ = try dispatcher.authorize(reservation)
    guard let lease = try located.store.loadLease(attemptId: reservation.attempt.id) else {
      throw WorkStoreError("authorized takeover has no lease")
    }
    return GraphQLTakeoverTaskPayload(
      attemptId: reservation.attempt.id.rawValue,
      sessionId: reservation.attempt.sessionId,
      fence: lease.fence,
      expiresAt: Self.timestamp(lease.expiresAt),
      heartbeatToken: reservation.launchToken,
      heartbeatMs: located.task.guardPolicy.lease?.heartbeatMs ?? LeasePolicy().heartbeatMs,
      packet: try graphQLPacket(packet)
    )
  }

  func heartbeatAttempt(
    attemptId: String,
    token: String,
    context: GraphQLDocumentRequest
  ) async throws -> GraphQLLeaseStatePayload {
    let id = AttemptID(attemptId)
    let store = storeForContext(context)
    guard let lease = try store.loadLease(attemptId: id) else {
      return GraphQLLeaseStatePayload(attemptId: attemptId, fence: 0, expiresAt: nil, fenced: true)
    }
    do {
      _ = try store.verifyLeaseToken(attemptId: id, token: token)
    } catch {
      throw TaskHandoverGraphQLError(code: "unauthorized", message: "lease token does not match")
    }
    guard let task = try store.loadTask(id: lease.taskId) else {
      throw TaskHandoverGraphQLError(code: "not_found", message: "lease task was not found")
    }
    let alive = try store.heartbeat(
      attemptId: id,
      fence: lease.fence,
      now: Date(),
      ttlMs: task.guardPolicy.lease?.ttlMs ?? LeasePolicy().ttlMs
    )
    let refreshed = try store.loadLease(attemptId: id)
    return GraphQLLeaseStatePayload(
      attemptId: attemptId,
      fence: refreshed?.fence ?? lease.fence,
      expiresAt: refreshed.map { Self.timestamp($0.expiresAt) },
      fenced: !alive
    )
  }

  func reportAttempt(
    _ input: GraphQLReportAttemptInput,
    context: GraphQLDocumentRequest
  ) async throws -> GraphQLReportAttemptPayload {
    let attemptId = AttemptID(input.attemptId)
    let located = try locateAttempt(attemptId, context: context)
    do {
      _ = try located.store.verifyLeaseToken(attemptId: attemptId, token: input.token)
    } catch {
      throw TaskHandoverGraphQLError(code: "unauthorized", message: "lease token does not match")
    }
    let snapshotData = try JSONEncoder().encode(JSONValue.object(input.snapshot))
    let snapshot = try JSONCanonical.decoder().decode(WorkflowRuntimePersistenceSnapshot.self, from: snapshotData)
    guard let attempt = try located.store.loadAttempt(id: attemptId),
          snapshot.session.sessionId == attempt.sessionId else {
      throw TaskHandoverGraphQLError(code: "invalid_input", message: "snapshot session does not match attempt")
    }
    let deliverablesData = try JSONEncoder().encode(JSONValue.array(input.deliverables.map(JSONValue.object)))
    let deliverables = try JSONCanonical.decoder().decode([DeliverableRef].self, from: deliverablesData)
    let result = try await TaskDispatch().reconcileExternalTerminal(
      attemptId: attemptId,
      snapshot: snapshot,
      deliverables: deliverables,
      store: located.store,
      storeRoot: located.root
    )
    let task = try located.store.loadTask(id: attempt.taskId)
    let decision = try located.store.listDecisions(taskId: attempt.taskId).last(where: { $0.attemptId == attemptId })
    return GraphQLReportAttemptPayload(
      attemptId: attemptId.rawValue,
      taskState: task?.state.rawValue,
      decisionKind: decision?.kind.kindName,
      handoverId: result.handoverId
    )
  }

  private func locate(_ taskId: TaskID, context: GraphQLDocumentRequest) throws -> TaskCommandRunner.LocatedTask {
    guard let located = try TaskCommandRunner().locateTask(taskId, in: options(context)) else {
      throw TaskHandoverGraphQLError(code: "not_found", message: "task '\(taskId.rawValue)' was not found")
    }
    return located
  }

  private func locateAttempt(_ attemptId: AttemptID, context: GraphQLDocumentRequest) throws -> TaskCommandRunner.LocatedTask {
    for root in TaskCommandRunner().storeRoots(options(context)) {
      let store = WorkStore(rootDirectory: root)
      guard let attempt = try store.loadAttempt(id: attemptId) else { continue }
      guard let task = try store.loadTask(id: attempt.taskId) else { continue }
      return TaskCommandRunner.LocatedTask(task: task, store: store, root: root)
    }
    throw TaskHandoverGraphQLError(code: "not_found", message: "attempt '\(attemptId.rawValue)' was not found")
  }

  private func options(_ context: GraphQLDocumentRequest) -> TaskStoreOptions {
    TaskStoreOptions(
      scope: scope,
      workingDirectory: context.localWorkingDirectory ?? workingDirectory,
      sessionStore: sessionStore
    )
  }

  private func storeForContext(_ context: GraphQLDocumentRequest) -> WorkStore {
    WorkStore(rootDirectory: TaskCommandRunner().storeRoots(options(context)).first ?? workingDirectory)
  }

  private func decodeTraits(_ values: [String]) throws -> [HostTrait] {
    try values.map { value in
      guard let trait = HostTrait(rawValue: value) else {
        throw TaskHandoverGraphQLError(code: "invalid_input", message: "unknown host trait '\(value)'")
      }
      return trait
    }
  }

  private func graphQLPacket(_ packet: HandoverPacket) throws -> GraphQLHandoverPacket {
    let data = try JSONCanonical.encode(packet)
    let object = try JSONCanonical.decoder().decode(JSONObject.self, from: data)
    return GraphQLHandoverPacket(
      handoverId: packet.id.rawValue,
      taskId: packet.taskId.rawValue,
      digest: packet.digest,
      reasonKind: packet.reason.kindName,
      resumeStepId: packet.contract.resumeStepId,
      brief: packet.brief,
      packet: object
    )
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
