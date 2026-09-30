import Foundation
import RielaCore
import RielaWork

struct TaskDispatchPreparedPlan {
  var reference: WorkflowReference
  var resolution: WorkflowResolutionOptions
  var bundle: ResolvedWorkflowBundle
  var dispatcher: TaskDispatcher
  var pending: PendingAttemptReservation?
  var entry: AttemptEntry
  var takeoverPacket: HandoverPacket?
  var entryStepId: String
  var maps: ReachableWorkflowMaps
  var topology: TaskHostTopology
  var placement: BackendCapabilityPlacementResult
  var preview: TaskDispatchPreview
}

struct TaskDispatchPreparedExecution {
  var reservation: AttemptReservation
  var context: TaskPlacementExecutionContext
  var runOptions: WorkflowRunOptions
  var variables: JSONObject
}

extension TaskDispatch {
  func sealHandoverIfNeeded(
    snapshot: inout WorkflowRuntimePersistenceSnapshot,
    triggerState: TaskRunHandoverTriggerState,
    reservation: AttemptReservation,
    bundle: ResolvedWorkflowBundle,
    located: TaskCommandRunner.LocatedTask,
    options: TaskStoreOptions,
    taskId: TaskID,
    placement: BackendCapabilityPlacementResult,
    output: WorkflowOutputFormat,
    runOptions: WorkflowRunOptions
  ) async throws -> CLICommandResult? {
    let runtime = TaskHandoverRuntime(located: located, options: options)
    let packet: HandoverPacket
    if let trigger = triggerState.take() {
      let runVariables = try JSONDecoder().decode(
        JSONObject.self, from: Data((runOptions.variables ?? "{}").utf8)
      )
      snapshot.session.status = .failed
      snapshot.session.failureKind = trigger.failureKind
      snapshot.session.failureReason = "task handover trigger: \(trigger.reason.kindName)"
      snapshot.session.failedAt = Date()
      snapshot.session.updatedAt = Date()
      if let cancellation = try located.store.attemptCancellation(
        taskId: taskId, attemptId: reservation.attempt.id,
        sessionId: reservation.attempt.sessionId
      ), !cancellation.acknowledged,
         let decision = try located.store.listDecisions(taskId: taskId)
           .first(where: { $0.id == cancellation.decisionId }),
         case .handover = decision.kind {
        try located.store.acknowledgeHandoverCancellation(
          taskId: taskId, attemptId: reservation.attempt.id
        )
      }
      try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: located.root).save(snapshot)
      packet = try await runtime.sealTriggered(
        taskId: taskId, attempt: reservation.attempt, snapshot: snapshot,
        bundle: bundle, variables: runVariables, reason: trigger.reason
      )
    } else if snapshot.session.status == .suspended {
      let runVariables = try JSONDecoder().decode(
        JSONObject.self, from: Data((runOptions.variables ?? "{}").utf8)
      )
      packet = try await runtime.sealSuspended(
        taskId: taskId, attempt: reservation.attempt, snapshot: snapshot,
        bundle: bundle, variables: runVariables
      )
    } else {
      return nil
    }
    _ = await LoopNotificationDispatcher().dispatchHandover(
      workflow: bundle.workflow,
      payload: HandoverNotificationPayload(
        workflowId: bundle.workflow.workflowId,
        sessionId: reservation.attempt.sessionId,
        taskId: taskId.rawValue,
        handoverId: packet.id.rawValue,
        reasonKind: packet.reason.kindName,
        brief: packet.brief,
        locators: packet.sinks.map { $0.serialized }
      ),
      workflowDirectory: bundle.workflowDirectory,
      workingDirectory: options.workingDirectory
    )
    return try render(TaskRunCommandResult(
      taskId: taskId.rawValue, statusKind: .suspended,
      attemptId: reservation.attempt.id.rawValue,
      sessionId: reservation.attempt.sessionId,
      waitReason: nil, handoverId: packet.id.rawValue,
      placement: placement
    ), output: output, exitCode: .suspended)
  }

  func prepareTaskExecution(
    reservation originalReservation: AttemptReservation,
    taskContext originalContext: TaskPlacementExecutionContext,
    resolution originalResolution: WorkflowResolutionOptions,
    reference: WorkflowReference,
    takeoverPacket: HandoverPacket?,
    options: TaskStoreOptions,
    output: WorkflowOutputFormat,
    taskId: TaskID,
    store: WorkStore,
    located: TaskCommandRunner.LocatedTask
  ) async throws -> TaskDispatchPreparedExecution {
    var reservation = originalReservation
    var context = originalContext
    var resolution = originalResolution
    let sessionRoot = URL(fileURLWithPath: located.root).deletingLastPathComponent().path
    var workingDirectory = options.workingDirectory
    if case let .repository(repository)? = reservation.task.context {
      let workspace = GitBranchWorkspaceRuntime()
      let policy = reservation.task.guardPolicy.handover?.publish ?? PublicationPolicy()
      let isolation: IsolationRef
      if case .takeover = reservation.attempt.entry,
         let deliverable = takeoverPacket?.deliverables.compactMap({ value -> RepositoryDeliverable? in
           if case let .repository(repositoryValue) = value { return repositoryValue }
           return nil
         }).first {
        guard case .published = deliverable.state else {
          throw WorkStoreError("takeover repository deliverable is not published")
        }
        isolation = try await workspace.materialize(
          deliverable, into: options.workingDirectory,
          worktree: repository.isolation == .worktree,
          attempt: reservation.attempt.id
        )
      } else {
        isolation = try await workspace.ensureBranch(
          root: repository.root, attempt: reservation.attempt.id,
          task: reservation.task.id, generation: reservation.attempt.generation,
          base: repository.baseRevision, isolation: repository.isolation,
          template: policy.branchTemplate
        )
      }
      guard try store.updateAttemptIsolation(
        attemptId: reservation.attempt.id, isolation: isolation
      ) else {
        throw WorkStoreError("task attempt isolation could not be recorded")
      }
      reservation.attempt.isolation = isolation
      workingDirectory = isolation.path
      resolution.workingDirectory = isolation.path
    }
    let taskIdentifier = reservation.task.id
    let attemptIdentifier = reservation.attempt.id
    if let isolation = reservation.attempt.isolation {
      let workspace = GitBranchWorkspaceRuntime()
      let checkpointCoordinator = TaskHandoverCheckpointCoordinator()
      let repositoryWriteScopes: [String]?
      if case let .repository(repository)? = reservation.task.context,
         !repository.writeScopes.isEmpty {
        repositoryWriteScopes = repository.writeScopes
      } else {
        repositoryWriteScopes = nil
      }
      context.isolation = isolation
      context.checkpoint = { suffix, message in
        do {
          try await checkpointCoordinator.checkpoint(
            workspace: workspace, isolation: isolation, attemptId: attemptIdentifier,
            message: message, trailerSuffix: suffix, paths: repositoryWriteScopes
          )
        } catch {
          let message = "task checkpoint failed: \(error)\n"
          FileHandle.standardError.write(Data(message.utf8))
        }
      }
      let checkpointPolicy = reservation.task.guardPolicy.handover?.checkpoint ?? .stepBoundary
      let checkpoint = context.checkpoint
      context.stepBoundaryHook = { event in
        guard case .stepBoundary = checkpointPolicy,
              event.type == .stepCompleted,
              let stepId = event.stepId,
              let executionId = event.executionId else { return }
        await checkpoint?(executionId, "riela: checkpoint \(taskIdentifier.rawValue) \(stepId)")
      }
    }
    context.boundaryHandover = { nextStepId in
      guard let request = try? store.pendingHandoverRequest(attemptId: attemptIdentifier),
            !request.immediate else { return nil }
      try? store.consumeHandoverRequest(requestId: request.requestId, now: Date())
      return SuspendRecord(
        reasonKind: .operatorMove, stepId: nextStepId,
        progressNote: request.reason, suspendedAt: Date(),
        producer: .human(principal: "task-handover-request")
      )
    }
    var variables: JSONObject = ["rielaTask": .object([
      "taskId": .string(taskId.rawValue),
      "attemptId": .string(reservation.attempt.id.rawValue),
      "fence": .integer(Int64(try store.loadLease(attemptId: reservation.attempt.id)?.fence ?? 0))
    ])]
    if case let .takeover(_, handoverId) = reservation.attempt.entry,
       let takeoverPacket {
      try await importTakeoverHistory(
        packet: takeoverPacket, handoverId: handoverId,
        reservation: reservation, sessionRoot: located.root, store: store
      )
      let answer = try store.latestAnswer(handoverId: handoverId)
      var handover: JSONObject = [
        "id": .string(handoverId.rawValue),
        "reasonKind": .string(takeoverPacket.reason.kindName),
        "brief": .string(takeoverPacket.brief),
        "deliverables": try Self.jsonValue(takeoverPacket.deliverables)
      ]
      switch takeoverPacket.reason {
      case let .userInputRequired(question): handover["question"] = try Self.jsonValue(question)
      case let .userPresenceRequired(presence): handover["presence"] = try Self.jsonValue(presence)
      default: break
      }
      if let answer {
        handover["answer"] = .object(answer.payload)
        variables["delivered"] = .object(["handover": .object(["answer": .object(answer.payload)])])
      }
      variables["handover"] = .object(handover)
    }
    let runOptions = WorkflowRunOptions(
      target: reference.name,
      resolution: resolution,
      variables: try jsonString(variables),
      nodePatch: nodePatch,
      mockScenarioPath: mockScenarioPath,
      output: output,
      sessionStore: sessionRoot,
      workingDirectory: workingDirectory,
      resumeSessionId: reservation.attempt.sessionId
    )
    return TaskDispatchPreparedExecution(
      reservation: reservation, context: context,
      runOptions: runOptions, variables: variables
    )
  }

  func prepareDispatchPlan(
    taskId: TaskID,
    task: WorkTask,
    options: TaskStoreOptions,
    store: WorkStore,
    localTraits: [HostTrait],
    packetOverride: HandoverPacket?
  ) async throws -> TaskDispatchPreparedPlan {
    guard let plan = task.plan else { throw WorkStoreError("task '\(taskId.rawValue)' has no executable plan") }
    guard case let .workflow(reference) = plan else {
      throw WorkStoreError("temporary task workflows are not yet executable")
    }
    guard let scope = reference.scope.map(WorkflowScope.init(rawValue:)) ?? .auto else {
      throw WorkStoreError("task '\(taskId.rawValue)' has an invalid workflow scope")
    }
    let resolution = WorkflowResolutionOptions(
      workflowName: reference.name,
      scope: scope,
      workflowDefinitionDir: reference.workflowDefinitionDir,
      workingDirectory: options.workingDirectory
    )
    let bundle = try resolver.resolve(resolution)
    guard bundle.workflow.workflowId == reference.name else {
      throw WorkStoreError("task workflow reference and resolved workflow ID differ")
    }
    let diagnostics = DefaultWorkflowValidator().validate(bundle.workflow, nodePayloads: bundle.nodePayloads)
    if let diagnostic = diagnostics.first(where: { $0.severity == .error }) {
      throw WorkStoreError("task workflow is invalid: \(diagnostic.path): \(diagnostic.message)")
    }
    let dispatcher = TaskDispatcher(store: store)
    let pending = try dispatcher.pendingReservation(taskId: taskId)
    let entry = pending?.entry ?? .start
    let takeoverPacket: HandoverPacket?
    if case .takeover = entry {
      takeoverPacket = try packetOverride ?? store.latestHandover(taskId: taskId)
      guard takeoverPacket != nil else { throw WorkStoreError("takeover reservation has no sealed handover packet") }
    } else {
      takeoverPacket = packetOverride
    }
    let entryStepId: String
    if case .takeover = entry, let takeoverPacket {
      entryStepId = takeoverPacket.contract.resumeStepId
      guard bundle.workflow.steps.contains(where: { $0.id == entryStepId }) else {
        throw WorkStoreError("handover resume step '\(entryStepId)' does not exist in the workflow")
      }
    } else {
      entryStepId = try selectedEntryStep(entry, task: task, workflow: bundle.workflow)
    }
    var maps = try await reachableWorkflowMaps(
      bundle: bundle, resolution: resolution, resolver: resolver, entryStepId: entryStepId
    )
    maps.bundles[bundle.workflow.workflowId]?.workflow.entryStepId = entryStepId
    let requirements = try WorkflowRequirementResolver().resolve(
      workflowId: bundle.workflow.workflowId, entryStepId: entryStepId,
      workflows: maps.workflows, nodePayloads: maps.nodePayloads,
      nodeHostRequirements: maps.nodeHostRequirements
    )
    var topology = try await hostResolver.taskTopology(
      store: store, scope: resolution.scope,
      workingDirectory: options.workingDirectory,
      localAddonExecutables: maps.localAddonExecutables
    )
    topology.local.traits = Array(Set(topology.local.traits + localTraits)).sorted()
    let requiredTraits: [HostTrait]
    if case let .userPresenceRequired(presence)? = takeoverPacket?.reason {
      requiredTraits = presence.traits
    } else {
      requiredTraits = []
    }
    let assignments = Self.placementAssignments(requirements: requirements, maps: maps)
    var placement = BackendCapabilityPlacementResolver().resolve(
      requirements: requirements, local: topology.local, workers: topology.workers,
      assignments: assignments, requiredTraits: requiredTraits
    )
    if !requiredTraits.isEmpty, requirements.isEmpty,
       !([topology.local] + topology.workers).contains(where: {
         Set($0.traits).isSuperset(of: Set(requiredTraits))
       }) {
      let missing = requiredTraits.sorted().map(\.rawValue).joined(separator: ",")
      let provenance = WorkflowRequirementProvenance(
        workflowId: bundle.workflow.workflowId, stepId: entryStepId,
        nodeId: bundle.workflow.steps.first(where: { $0.id == entryStepId })?.nodeId ?? ""
      )
      placement.failures.append(BackendPlacementFailure(
        provenance: provenance, reason: "host-traits-unavailable: \(missing)"
      ))
    }
    let preview = try dispatcher.preview(
      taskId: taskId, workflowId: reference.name, entryStepId: entryStepId,
      entry: entry, placement: placement
    )
    return TaskDispatchPreparedPlan(
      reference: reference, resolution: resolution, bundle: bundle, dispatcher: dispatcher,
      pending: pending, entry: entry, takeoverPacket: takeoverPacket,
      entryStepId: entryStepId, maps: maps, topology: topology,
      placement: placement, preview: preview
    )
  }

  private static func placementAssignments(
    requirements: [WorkflowBackendRequirement],
    maps: ReachableWorkflowMaps
  ) -> [WorkflowRequirementProvenance: DistributedWorkerTarget] {
    var assignments: [WorkflowRequirementProvenance: DistributedWorkerTarget] = [:]
    for requirement in requirements {
      for provenance in requirement.provenance {
        if let target = maps.workflows[provenance.workflowId]?
          .steps.first(where: { $0.id == provenance.stepId })?.placement?.target {
          assignments[provenance] = target
        }
      }
    }
    return assignments
  }

  func importTakeoverHistory(
    packet: HandoverPacket,
    handoverId: HandoverID,
    reservation: AttemptReservation,
    sessionRoot: String,
    store: WorkStore
  ) async throws {
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: sessionRoot)
    let target = try persistence.load(sessionId: reservation.attempt.sessionId)
    let runtime = InMemoryWorkflowRuntimeStore()
    await runtime.seedSession(target.session)
    await runtime.seedWorkflowMessages(target.workflowMessages)
    let imported = try await runtime.importAcceptedHistory(WorkflowHistoryImportInput(
      sessionId: reservation.attempt.sessionId,
      sourceSessionId: packet.fromSessionId,
      bundle: packet.history,
      handoverId: handoverId.rawValue
    ))
    var messages = try await runtime.listMessages(for: reservation.attempt.sessionId, toStepId: nil)
    if let answer = try store.latestAnswer(handoverId: handoverId),
       let sourceExecution = imported.executions.last {
      let answerMessage = WorkflowMessageRecord(
        communicationId: "handover-answer-\(handoverId.rawValue)-\(reservation.attempt.id.rawValue)",
        workflowExecutionId: reservation.attempt.sessionId,
        fromStepId: nil,
        toStepId: packet.contract.resumeStepId,
        sourceStepExecutionId: sourceExecution.executionId,
        payload: ["handover": .object(["answer": .object(answer.payload)])],
        lifecycleStatus: .delivered,
        createdOrder: (messages.map(\.createdOrder).max() ?? 0) + 1,
        createdAt: answer.answeredAt
      )
      messages.append(answerMessage)
    }
    let snapshot = WorkflowRuntimePersistenceProjector.snapshot(
      session: imported, workflowMessages: messages,
      loopEvidence: target.loopEvidence, loopMetadata: target.loopMetadata
    )
    try persistence.save(snapshot)
  }

  static func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }

  func reconcileExternalTerminal(
    attemptId: AttemptID,
    snapshot: WorkflowRuntimePersistenceSnapshot,
    deliverables: [DeliverableRef],
    store: WorkStore,
    storeRoot: String
  ) async throws -> TaskRunCommandResult {
    guard let attempt = try store.loadAttempt(id: attemptId),
          let task = try store.loadTask(id: attempt.taskId),
          case let .workflow(reference)? = task.plan else {
      throw WorkStoreError("reported task attempt or workflow plan is missing")
    }
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: storeRoot)
    try persistence.save(snapshot)
    let resolution = WorkflowResolutionOptions(
      workflowName: reference.name,
      scope: reference.scope.flatMap(WorkflowScope.init(rawValue:)) ?? .auto,
      workflowDefinitionDir: reference.workflowDefinitionDir,
      workingDirectory: storeRoot
    )
    let bundle = try resolver.resolve(resolution)
    if snapshot.session.status == .suspended {
      let located = TaskCommandRunner.LocatedTask(task: task, store: store, root: storeRoot)
      let packet = try await TaskHandoverRuntime(
        located: located,
        options: TaskStoreOptions(scope: .auto, workingDirectory: storeRoot, sessionStore: storeRoot)
      ).sealSuspended(
        taskId: task.id, attempt: attempt, snapshot: snapshot, bundle: bundle, variables: [:]
      )
      return TaskRunCommandResult(
        taskId: task.id.rawValue, statusKind: .suspended,
        attemptId: attempt.id.rawValue, sessionId: attempt.sessionId,
        waitReason: nil, handoverId: packet.id.rawValue, placement: nil
      )
    }
    try store.saveEvidence(Evidence(
      id: EvidenceID("evidence-publication-report-\(attempt.id.rawValue)"),
      taskId: task.id, attemptId: attempt.id, kind: .publication,
      producedBy: .runtime,
      payloadRef: .inline(["deliverables": try Self.jsonValue(deliverables)]),
      createdAt: snapshot.session.updatedAt
    ))
    guard let decision = try store.listDecisions(taskId: task.id).last(where: { $0.attemptId == attempt.id }) else {
      throw WorkStoreError("reported task attempt has no recorded decision")
    }
    let reservation = AttemptReservation(task: task, attempt: attempt, decision: decision, launchToken: "")
    let view = try await reconcileTerminal(
      snapshot: snapshot, reservation: reservation, store: store,
      taskId: task.id, remoteChoices: []
    )
    let current = try store.loadTask(id: task.id) ?? task
    let status: TaskRunStatus = view != nil ? .waiting
      : snapshot.session.status == .completed && current.state.isTerminal ? .completed : .failed
    return TaskRunCommandResult(
      taskId: task.id.rawValue, statusKind: status,
      attemptId: attempt.id.rawValue, sessionId: attempt.sessionId,
      waitReason: nil, handoverId: nil, placement: nil
    )
  }
}
