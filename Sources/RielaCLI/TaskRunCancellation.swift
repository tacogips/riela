import Foundation
import RielaAdapters
import RielaCore
import RielaServer
import RielaWork

/// SIGINT records intent here; the task owner commits it before interruption.
final class TaskRunSignalState: @unchecked Sendable {
  private let lock = NSLock()
  private var requestedSignal: Int32?
  private let decisionId = DecisionID.generate()

  func request(_ signal: Int32) {
    lock.lock()
    if requestedSignal == nil { requestedSignal = signal }
    lock.unlock()
  }

  var isRequested: Bool {
    lock.lock()
    defer { lock.unlock() }
    return requestedSignal != nil
  }

  @discardableResult
  func commitIfRequested(store: WorkStore, taskId: TaskID, attemptId: AttemptID? = nil) throws -> Bool {
    guard isRequested else { return false }
    for _ in 0..<3 {
      if try store.listDecisions(taskId: taskId).contains(where: { $0.id == decisionId }) { return true }
      guard let task = try store.loadTask(id: taskId) else {
        throw WorkStoreError("signal cancellation task is missing")
      }
      let selectedAttempt = try attemptId ?? store.listAttempts(taskId: taskId).last?.id
      let evidenceId: EvidenceID
      if let selectedAttempt {
        guard let existing = try store.listEvidence(taskId: taskId)
          .filter({ $0.attemptId == selectedAttempt })
          .sorted(by: { $0.createdAt < $1.createdAt }).last else {
          throw WorkStoreError("signal cancellation has no reserved causal evidence")
        }
        evidenceId = existing.id
      } else {
        evidenceId = EvidenceID("evidence-signal-\(decisionId.rawValue)-task")
        try store.saveEvidence(Evidence(
          id: evidenceId, taskId: taskId, attemptId: nil,
          kind: .contextSnapshot, producedBy: .runtime,
          payloadRef: .inline(["signal": .string("interrupt")]), createdAt: Date()
        ))
      }
      let decision = Decision(
        id: decisionId, taskId: taskId, attemptId: selectedAttempt,
        producer: .human(principal: "cli-signal"), kind: .cancel,
        reason: "CLI signal requested cancellation", causedBy: [evidenceId], createdAt: Date()
      )
      do {
        _ = try store.applyDecision(
          decision, expectedTaskVersion: task.version, completion: .unmet([]),
          decisionEvidenceId: EvidenceID("evidence-decision-\(decisionId.rawValue)")
        )
        return true
      } catch let error as WorkStoreError where error.isVersionConflict {
        continue
      } catch let error as WorkStoreError where error.isAlreadyTerminal {
        return false
      }
    }
    throw WorkStoreError("signal cancellation could not commit after task version changed")
  }
}

final class TaskRunHandoverTriggerState: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: (reason: HandoverReason, failureKind: WorkflowSessionFailureKind)?
  private var latestBackendEvents: [String: WorkflowBackendEventRecord] = [:]

  func recordBackendEvent(_ event: WorkflowRunEvent) {
    guard event.type == .backendEvent,
          let executionId = event.executionId,
          let eventType = event.backendEventType else { return }
    let channel = event.backendEventChannel.flatMap(AdapterBackendEventChannel.init(rawValue:))
    let record = WorkflowBackendEventRecord(
      sequence: event.backendEventSequence ?? 0,
      at: Date(),
      eventType: eventType,
      channel: channel,
      content: event.backendEventContent,
      toolName: event.backendToolName,
      usage: event.backendEventUsage,
      metadata: event.backendEventMetadata
    )
    lock.lock()
    latestBackendEvents[executionId] = record
    lock.unlock()
  }

  func latestBackendEvent(executionId: String) -> WorkflowBackendEventRecord? {
    lock.lock()
    defer { lock.unlock() }
    return latestBackendEvents[executionId]
  }

  func record(reason: HandoverReason, failureKind: WorkflowSessionFailureKind) {
    lock.lock()
    if stored == nil { stored = (reason, failureKind) }
    lock.unlock()
  }

  func take() -> (reason: HandoverReason, failureKind: WorkflowSessionFailureKind)? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}

/// Owns observation and interruption for one reserved task run.
enum TaskRunCancellation {
  static func run(
    runner: WorkflowRunCommand,
    options: WorkflowRunOptions,
    reservation: AttemptReservation,
    store: WorkStore,
    context: TaskPlacementExecutionContext,
    signalState: TaskRunSignalState? = nil,
    handoverTriggerState: TaskRunHandoverTriggerState? = nil,
    afterObserverJoin: (@Sendable () throws -> Void)? = nil,
    afterInactivityRecheck: (@Sendable () throws -> Void)? = nil,
    afterCancellationObservation: (@Sendable () throws -> Void)? = nil,
    afterSelectedHostProofRequired: (@Sendable () async -> Void)? = nil
  ) async throws -> CLICommandResult {
    var observedContext = context
    observedContext.backendEventObserver = { event in handoverTriggerState?.recordBackendEvent(event) }
    try signalState?.commitIfRequested(
      store: store, taskId: reservation.task.id, attemptId: reservation.attempt.id
    )
    if try persistPreLaunchCancellation(
      options: options, reservation: reservation, store: store, context: context
    ) {
      return CLICommandResult(exitCode: .failure, stderr: "task cancelled before launch")
    }
    let pendingAtStart = try store.attemptCancellation(
      taskId: reservation.task.id,
      attemptId: reservation.attempt.id,
      sessionId: reservation.attempt.sessionId
    ) != nil
    let execution = Task {
      await runner.runTaskReservation(options, reservation: reservation, store: store, context: observedContext)
    }
    let reservedLease = try store.loadLease(attemptId: reservation.attempt.id)
    let leasePolicy = reservation.task.guardPolicy.lease ?? LeasePolicy()
    if pendingAtStart { execution.cancel() }
    let observer = Task {
      var observedInactivity: Set<String> = []
      var lastHeartbeat = Date()
      var lastCheckpoint = Date()
      while !Task.isCancelled {
        do {
          let now = Date()
          if let reservedLease,
             now.timeIntervalSince(lastHeartbeat) * 1_000 >= Double(leasePolicy.heartbeatMs) {
            let alive = try store.heartbeat(
              attemptId: reservation.attempt.id, fence: reservedLease.fence,
              now: now, ttlMs: leasePolicy.ttlMs
            )
            lastHeartbeat = now
            if !alive {
              handoverTriggerState?.record(
                reason: .ownerLost(OwnerLossEvidence(
                  attemptId: reservation.attempt.id,
                  lastHeartbeatAt: reservedLease.heartbeatAt,
                  expiredAt: now,
                  fence: max(reservation.task.fence, reservedLease.fence) + 1,
                  forcedBy: .policy(rule: "task-lease-fence")
                )),
                failureKind: .leaseLost
              )
              execution.cancel()
              return
            }
          }
          if let interval = Self.checkpointIntervalMs(reservation.task.guardPolicy.handover?.checkpoint),
             let checkpoint = context.checkpoint {
            let checkpointTime = Date()
            if checkpointTime.timeIntervalSince(lastCheckpoint) * 1_000 >= Double(interval) {
              lastCheckpoint = checkpointTime
              await checkpoint("timer", "riela: checkpoint \(reservation.task.id.rawValue) timer")
            }
          }
          if let request = try store.pendingHandoverRequest(attemptId: reservation.attempt.id), request.immediate {
            try store.consumeHandoverRequest(requestId: request.requestId, now: now)
            handoverTriggerState?.record(
              reason: .operatorMove(reason: request.reason), failureKind: .cancelled
            )
            execution.cancel()
            return
          }
          try signalState?.commitIfRequested(
            store: store, taskId: reservation.task.id, attemptId: reservation.attempt.id
          )
          if let cancellation = try store.attemptCancellation(
            taskId: reservation.task.id,
            attemptId: reservation.attempt.id,
            sessionId: reservation.attempt.sessionId
          ), !cancellation.acknowledged {
            execution.cancel()
            return
          }
          if try observeInactivity(
            reservation: reservation, store: store, observedKeys: &observedInactivity,
            afterRecheck: afterInactivityRecheck, handoverTriggerState: handoverTriggerState
          ) {
            execution.cancel()
            return
          }
        } catch {
          // A transient read failure must not disable observation for the rest
          // of a long run. Terminal reconciliation remains fail closed.
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
    let result = await execution.value
    observer.cancel()
    await observer.value
    try afterObserverJoin?()
    try signalState?.commitIfRequested(
      store: store, taskId: reservation.task.id, attemptId: reservation.attempt.id
    )
    _ = try persistPreLaunchCancellation(
      options: options, reservation: reservation, store: store, context: context
    )
    let remoteChoices = context.placement.choices.filter { $0.hostId != "local" }
    var selectedHostStopProven = remoteChoices.isEmpty
    if let cancellation = try store.attemptCancellation(
      taskId: reservation.task.id, attemptId: reservation.attempt.id,
      sessionId: reservation.attempt.sessionId
    ), !cancellation.acknowledged {
      try await proveSelectedHostStop(
        choices: remoteChoices,
        sessionId: reservation.attempt.sessionId, store: store
      )
      selectedHostStopProven = true
    }
    try afterCancellationObservation?()
    if let triggerState = handoverTriggerState,
       triggerState.take() != nil,
       let cancellation = try store.attemptCancellation(
         taskId: reservation.task.id, attemptId: reservation.attempt.id,
         sessionId: reservation.attempt.sessionId
       ), !cancellation.acknowledged,
       let decision = try store.listDecisions(taskId: reservation.task.id)
         .first(where: { $0.id == cancellation.decisionId }),
       case .handover = decision.kind {
      return result
    }
    let snapshot: WorkflowRuntimePersistenceSnapshot?
    do {
      snapshot = try store.persistJoinedCancellation(
        taskId: reservation.task.id, attemptId: reservation.attempt.id,
        sessionId: reservation.attempt.sessionId,
        selectedHostStopProven: selectedHostStopProven
      )
    } catch let error as WorkStoreError where error.isSelectedHostStopProofRequired {
      await afterSelectedHostProofRequired?()
      try await proveSelectedHostStop(
        choices: remoteChoices, sessionId: reservation.attempt.sessionId, store: store
      )
      snapshot = try store.persistJoinedCancellation(
        taskId: reservation.task.id, attemptId: reservation.attempt.id,
        sessionId: reservation.attempt.sessionId,
        selectedHostStopProven: true
      )
    }
    if let snapshot {
      try saveCancellationSession(
        snapshot, options: options, reservation: reservation, context: context
      )
      return CLICommandResult(exitCode: .failure, stderr: "task cancellation completed")
    }
    return result
  }

  private static func observeInactivity(
    reservation: AttemptReservation,
    store: WorkStore,
    observedKeys: inout Set<String>,
    afterRecheck: (@Sendable () throws -> Void)?,
    handoverTriggerState: TaskRunHandoverTriggerState?
  ) throws -> Bool {
    let sessionStore = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.rootDirectory)
    let snapshot = try sessionStore.loadStrictReadOnly(sessionId: reservation.attempt.sessionId)
    guard snapshot.session.sessionId == reservation.attempt.sessionId,
          snapshot.session.status == .running,
          let execution = snapshot.session.executions.last(where: { $0.status == .running }),
          let task = try store.loadTask(id: reservation.task.id),
          let attempt = try store.loadAttempt(id: reservation.attempt.id),
          attempt.sessionId == reservation.attempt.sessionId,
          attempt.state == .running else { return false }
    let progressAt = execution.lastBackendEventAt ?? execution.createdAt
    let observationKey = "\(execution.executionId)-\(String(progressAt.timeIntervalSinceReferenceDate.bitPattern, radix: 16))"
    guard !observedKeys.contains(observationKey) else { return false }
    let attempts = try store.listAttempts(taskId: task.id)
    let guardSnapshot = TaskGuardSnapshotAdapter.make(
      attempts: attempts, session: snapshot.session, wallClockMs: 0
    )
    let violations = TaskGuardCoordinator.violations(
      task: task, latestAttempt: attempt, snapshot: guardSnapshot
    )
    guard violations.contains(where: {
      if case .inactivity = $0 { return true }
      return false
    }) else { return false }
    let recentEvents = handoverTriggerState?.latestBackendEvent(executionId: execution.executionId)
      .map { [$0] } ?? execution.recentBackendEvents ?? []
    if task.guardPolicy.handover?.onWaitSignal ?? true, let backend = execution.backend,
       let signal = TableBackendWaitSignalClassifier.default.latestSignal(in: recentEvents, backend: backend) {
      handoverTriggerState?.record(reason: .userPresenceRequired(signal.presence), failureKind: .stalled)
      return true
    }
    let rechecked = try sessionStore.loadStrictReadOnly(sessionId: reservation.attempt.sessionId)
    guard rechecked.session.status == .running,
          rechecked.session.executions.last(where: { $0.executionId == execution.executionId })?
            .lastBackendEventAt == execution.lastBackendEventAt,
          try store.loadTask(id: task.id)?.version == task.version,
          try store.loadAttempt(id: attempt.id)?.state == .running else { return false }
    try afterRecheck?()
    let observation = LiveInactivityObservation(
      taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId,
      executionId: execution.executionId, createdAt: execution.createdAt,
      lastBackendEventAt: execution.lastBackendEventAt
    )
    let suffix = "\(attempt.id.rawValue)-\(observationKey)"
    let result: GuardDirectorApplication
    do {
      result = try TaskGuardCoordinator(store: store).evaluateAndApply(
      task: task, latestAttempt: attempt, snapshot: guardSnapshot,
      completion: .unmet([]), failedStepId: execution.stepId,
      violationEvidenceIds: violations.indices.map {
        EvidenceID("evidence-live-guard-\(suffix)-\($0)")
      },
      decisionId: DecisionID("decision-live-guard-\(suffix)"),
      decisionEvidenceId: EvidenceID("evidence-live-decision-\(suffix)"),
      liveInactivityObservation: observation
      )
    } catch is StaleInactivityObservation {
      observedKeys.insert(observationKey)
      return false
    }
    observedKeys.insert(observationKey)
    if case let .handover(reason)? = result.resolution?.kind {
      handoverTriggerState?.record(reason: reason, failureKind: .stalled)
      return true
    }
    guard result.application != nil else { return false }
    return try store.attemptCancellation(
      taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId
    ) != nil
  }

  private static func checkpointIntervalMs(_ policy: CheckpointPolicy?) -> Int? {
    guard case let .everyMs(interval)? = policy else { return nil }
    return interval
  }

  static func proveSelectedHostStop(
    choices: [BackendPlacementChoice], sessionId: String, store: WorkStore
  ) async throws {
    guard !choices.isEmpty else { return }
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    guard let path = environment[DistributedControllerConfiguration.environmentKey], !path.isEmpty else {
      throw WorkStoreError("pending selected-host cancellation has no configured controller")
    }
    let url = URL(fileURLWithPath: path)
    let controller = try DistributedControllerConfiguration.load(from: url).controller(relativeTo: url)
    var remoteSteps: [String: Set<String>] = [:]
    for choice in choices {
      remoteSteps[choice.provenance.workflowId, default: []].insert(choice.provenance.stepId)
    }
    guard try await controller.provesCancellationStopped(
      sessionId: sessionId, runtimeRoot: store.rootDirectory,
      now: Date(), remoteSteps: remoteSteps
    ) else {
      throw WorkStoreError("pending selected-host cancellation requires proven worker stop")
    }
  }

  private static func persistPreLaunchCancellation(
    options: WorkflowRunOptions,
    reservation: AttemptReservation,
    store: WorkStore,
    context: TaskPlacementExecutionContext
  ) throws -> Bool {
    guard let snapshot = try store.persistPreLaunchCancellation(
      taskId: reservation.task.id,
      attemptId: reservation.attempt.id,
      sessionId: reservation.attempt.sessionId
    ) else { return false }
    try saveCancellationSession(snapshot, options: options, reservation: reservation, context: context)
    return true
  }

  private static func saveCancellationSession(
    _ snapshot: WorkflowRuntimePersistenceSnapshot,
    options: WorkflowRunOptions,
    reservation: AttemptReservation,
    context: TaskPlacementExecutionContext
  ) throws {
    guard snapshot.session.sessionId == reservation.attempt.sessionId,
          let bundle = context.bundles[options.target],
          let resolution = options.resolution,
          let sessionRoot = options.sessionStore else {
      throw WorkStoreError("cancellation has no admitted workflow identity")
    }
    let persistedResolution = CLIWorkflowSessionResolution.resolutionForPersistence(
      resolution: resolution, resolvedSourceScope: bundle.sourceScope
    )
    try CLIWorkflowSessionStore(rootDirectory: sessionRoot).save(
      PersistedCLIWorkflowSession(
        workflowName: bundle.workflow.workflowId,
        session: snapshot.session,
        resolution: persistedResolution,
        mockScenarioPath: options.mockScenarioPath
      ),
      runtimeSnapshot: snapshot
    )
  }
}
