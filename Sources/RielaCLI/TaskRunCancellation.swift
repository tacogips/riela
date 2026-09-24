import Foundation
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

/// Owns observation and interruption for one reserved task run.
enum TaskRunCancellation {
  static func run(
    runner: WorkflowRunCommand,
    options: WorkflowRunOptions,
    reservation: AttemptReservation,
    store: WorkStore,
    context: TaskPlacementExecutionContext,
    signalState: TaskRunSignalState? = nil,
    afterObserverJoin: (@Sendable () throws -> Void)? = nil,
    afterCancellationObservation: (@Sendable () throws -> Void)? = nil,
    afterSelectedHostProofRequired: (@Sendable () async -> Void)? = nil
  ) async throws -> CLICommandResult {
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
      await runner.runTaskReservation(options, reservation: reservation, store: store, context: context)
    }
    if pendingAtStart { execution.cancel() }
    let observer = Task {
      while !Task.isCancelled {
        do {
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
