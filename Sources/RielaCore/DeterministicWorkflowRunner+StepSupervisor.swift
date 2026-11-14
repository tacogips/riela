import Foundation
import RielaObservability

extension DeterministicWorkflowRunner {
  func supervisedAddonReadyAt(
    sessionId: String,
    step: WorkflowStepRef,
    resolvedInputPayload: JSONObject,
    request: DeterministicWorkflowRunRequest
  ) async throws -> Date {
    let runStartedAt = request.runStartedAt ?? retryClock.now()
    let messages = try await store.listMessages(for: sessionId, toStepId: step.id)
    var communicationId: String?
    if case let .object(input) = resolvedInputPayload["_rielaInput"],
       case let .object(latest) = input["latest"],
       case let .string(value) = latest["communicationId"] {
      communicationId = value
    }
    let matched = messages.first { $0.communicationId == communicationId }?.createdAt
    let inputReadyAt = matched ?? messages.map(\.createdAt).max() ?? runStartedAt
    return max(inputReadyAt, runStartedAt)
  }
}

private struct SupervisedSuccess: Sendable {
  let output: AdapterExecutionOutput
  let metadata: JSONObject
}

private struct StepRaceTasks {
  var continuation: CheckedContinuation<SupervisedSuccess, any Error>?
  var child: Task<Void, Never>?
  var stepTimer: Task<Void, Never>?
  var attemptTimer: Task<Void, Never>?
  var inFlight: Bool
  var attempt: Int?
  var startedAt: Date?
}

private struct SupervisedRegionArguments {
  let addon: WorkflowNodeAddonRef
  let session: WorkflowSession
  let sessionId: String
  let workflow: WorkflowDefinition
  let step: WorkflowStepRef
  let resolvedInputPayload: JSONObject
  let request: DeterministicWorkflowRunRequest
  let executionIndex: Int
  let started: WorkflowStepStartedExecutionRecord
  let context: AdapterExecutionContext
  let readyAt: Date
  let stepDeadline: Date?
  let queueWait: Int
  let recordDuration: Int
}

// The continuation is resolved once; child work is deliberately not awaited on expiry.
private final class StepSupervisorRace: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<SupervisedSuccess, any Error>?
  private var finished = false
  private var expired = false
  private var child: Task<Void, Never>?
  private var stepTimer: Task<Void, Never>?
  private var attemptTimer: Task<Void, Never>?
  private var inFlight: Int?
  private var attemptStartedAt: Date?
  private(set) var attempts = 0

  var isExpired: Bool { lock.withLock { expired } }
  var attemptCount: Int { lock.withLock { attempts } }
  var isInFlight: Bool { lock.withLock { inFlight != nil } }

  func install(_ continuation: CheckedContinuation<SupervisedSuccess, any Error>) {
    let cancel = lock.withLock {
      if finished { return true }
      self.continuation = continuation
      return false
    }
    if cancel { continuation.resume(throwing: CancellationError()) }
  }

  func setChild(_ task: Task<Void, Never>) {
    let cancel = lock.withLock { if finished { return true }; child = task; return false }
    if cancel { task.cancel() }
  }

  func setStepTimer(_ task: Task<Void, Never>) {
    let cancel = lock.withLock { if finished { return true }; stepTimer = task; return false }
    if cancel { task.cancel() }
  }

  func startAttempt(_ number: Int, deadline: Date?, stepDeadline: Date?, clock: any WorkflowRetryClock) {
    let old = lock.withLock { () -> Task<Void, Never>? in
      let old = attemptTimer
      attemptTimer = nil
      if !finished { inFlight = number; attempts = number; attemptStartedAt = clock.now() }
      return old
    }
    old?.cancel()
    guard let deadline else { return }
    let timer = Task {
      do { try await clock.sleep(until: deadline.addingTimeInterval(5)) } catch { return }
      self.finishTimer(attempt: number, isStepDeadline: deadline == stepDeadline)
    }
    let cancel = lock.withLock { () -> Bool in
      guard !finished, inFlight == number else { return true }
      attemptTimer = timer
      return false
    }
    if cancel { timer.cancel() }
  }

  func endAttempt(_ number: Int) -> Bool {
    let result = lock.withLock { () -> (Bool, Task<Void, Never>?) in
      guard !finished, inFlight == number else { return (false, nil) }
      inFlight = nil
      defer { attemptTimer = nil }
      return (true, attemptTimer)
    }
    result.1?.cancel()
    return result.0
  }

  func finishTimer(attempt: Int?, isStepDeadline: Bool = true) {
    let state = lock.withLock { () -> StepRaceTasks? in
      guard !finished, attempt == nil || inFlight == attempt else { return nil }
      finished = true; expired = true
      return StepRaceTasks(continuation: continuation, child: child, stepTimer: stepTimer, attemptTimer: attemptTimer, inFlight: inFlight != nil, attempt: inFlight, startedAt: attemptStartedAt)
    }
    guard let state else { return }
    state.child?.cancel(); state.stepTimer?.cancel(); state.attemptTimer?.cancel()
    state.continuation?.resume(throwing: StepSupervisorExpired(inFlight: state.inFlight, attemptTimer: attempt != nil && !isStepDeadline,
      attempt: state.attempt, startedAt: state.startedAt))
  }

  func finish(_ result: Result<SupervisedSuccess, any Error>, cancelled: Bool = false) {
    let state = lock.withLock { () -> StepRaceTasks? in
      guard !finished else { return nil }
      finished = true; expired = cancelled
      return StepRaceTasks(continuation: continuation, child: child, stepTimer: stepTimer, attemptTimer: attemptTimer, inFlight: inFlight != nil, attempt: inFlight, startedAt: attemptStartedAt)
    }
    guard let state else { return }
    state.child?.cancel(); state.stepTimer?.cancel(); state.attemptTimer?.cancel()
    state.continuation?.resume(with: result)
  }
}

private struct StepSupervisorExpired: Error {
  let inFlight: Bool
  let attemptTimer: Bool
  let attempt: Int?
  let startedAt: Date?
}

private struct StepSupervisedFailure: Error {
  var error: AdapterExecutionError
  var reason: StepRetryStopReason
  var attempts: Int
  var timeoutKind: StepTimeoutKind?
}

extension DeterministicWorkflowRunner {
  func executeSupervisedAddonAndPublish(
    addon: WorkflowNodeAddonRef, session: WorkflowSession, sessionId: String,
    workflow: WorkflowDefinition, step: WorkflowStepRef, resolvedInputPayload: JSONObject,
    transitions: [WorkflowStepTransition], request: DeterministicWorkflowRunRequest, executionIndex: Int
  ) async throws -> WorkflowPublicationResult {
    let readyAt = try await supervisedAddonReadyAt(sessionId: sessionId, step: step,
      resolvedInputPayload: resolvedInputPayload, request: request)
    let stepDeadline = step.deadlineMs.map { readyAt.addingTimeInterval(Double($0) / 1_000) }
    let queueWait = max(0, Int(retryClock.now().timeIntervalSince(readyAt) * 1_000))
    let recordStart = retryClock.now()
    let started = try await recordStepStartedExecution(workflowId: workflow.workflowId, sessionId: sessionId,
      step: step, attempt: executionIndex, backend: nil, inputSnapshot: [
        "variables": .object(request.variables),
        "resolvedInputPayload": .object(workflowAddonResolvedInputPayload(resolvedInputPayload, session: session))
      ], handler: request.eventHandler)
    let recordDuration = max(0, Int(retryClock.now().timeIntervalSince(recordStart) * 1_000))
    let context = adapterExecutionContext(deadline: nil, workflowId: workflow.workflowId, step: step,
      execution: started.execution, eventContext: started.backendEventContext, handler: request.eventHandler)
    let race = StepSupervisorRace()
    let success: SupervisedSuccess
    do {
      if let stepDeadline, retryClock.now() >= stepDeadline {
        throw StepSupervisedFailure(error: AdapterExecutionError(.timeout, "\(addon.name) step deadline exceeded before dispatch"),
          reason: .stepDeadline, attempts: 0, timeoutKind: .stepDeadline)
      }
      success = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          race.install(continuation)
          let child = Task {
            do {
              let arguments = SupervisedRegionArguments(addon: addon, session: session, sessionId: sessionId,
                workflow: workflow, step: step, resolvedInputPayload: resolvedInputPayload, request: request,
                executionIndex: executionIndex, started: started, context: context, readyAt: readyAt,
                stepDeadline: stepDeadline, queueWait: queueWait, recordDuration: recordDuration)
              let result = try await supervisedAddonRegion(arguments, race: race)
              race.finish(.success(result))
            } catch { race.finish(.failure(error)) }
          }
          race.setChild(child)
          if let stepDeadline {
            let timer = Task {
              do { try await retryClock.sleep(until: stepDeadline.addingTimeInterval(5)) } catch { return }
              race.finishTimer(attempt: nil)
            }
            race.setStepTimer(timer)
          }
        }
      } onCancel: { race.finish(.failure(CancellationError()), cancelled: true) }
    } catch {
      if isWorkflowRunCancellation(error) {
        await context.backendEventHandler?(AdapterBackendEvent(provider: addon.name, eventType: "riela.step.retry.stopped",
          metadata: ["attempts": .integer(Int64(race.attemptCount)), "stopReason": .string("cancelled"),
                     "elapsedMs": .integer(Int64(max(0, Int(retryClock.now().timeIntervalSince(readyAt) * 1_000))))]))
        throw error
      }
      let failure: StepSupervisedFailure
      if let value = error as? StepSupervisedFailure { failure = value } else if let expiry = error as? StepSupervisorExpired {
        let kind: StepTimeoutKind = expiry.attemptTimer ? .attempt : .stepDeadline
        if let attempt = expiry.attempt, let attemptStart = expiry.startedAt {
          var metadata = attemptMetadata(attempt: attempt, maxAttempts: step.retry?.maxAttempts ?? 1,
            startedAt: attemptStart, readyAt: readyAt, deadline: stepDeadline,
            queueWait: max(0, Int(attemptStart.timeIntervalSince(readyAt) * 1_000)), recordDuration: recordDuration)
          metadata["outcome"] = .string("failed")
          metadata["errorCode"] = .string(AdapterExecutionErrorCode.timeout.rawValue)
          metadata["retryable"] = .bool(false)
          metadata["effectOutcome"] = .string(AdapterEffectOutcome.unknown.rawValue)
          metadata["timeoutKind"] = .string(kind.rawValue)
          metadata["timeoutSource"] = .string("runner-backstop")
          await context.backendEventHandler?(AdapterBackendEvent(provider: addon.name,
            eventType: "riela.step.attempt.finished", metadata: metadata))
        }
        failure = StepSupervisedFailure(error: AdapterExecutionError(.timeout, "\(addon.name) exceeded its \(kind == .attempt ? "attempt timeout" : "step deadline")",
          isRetryable: false, effectOutcome: expiry.inFlight ? .unknown : nil),
          reason: .stepDeadline, attempts: race.attemptCount, timeoutKind: kind)
      } else {
        failure = StepSupervisedFailure(error: (error as? AdapterExecutionError) ?? AdapterExecutionError(.providerError, String(describing: error)),
          reason: .nonRetryable, attempts: race.attemptCount, timeoutKind: nil)
      }
      let elapsed = max(0, Int(retryClock.now().timeIntervalSince(readyAt) * 1_000))
      var adapterError = failure.error
      adapterError.message += StepRetryDiagnostics.suffix(attempts: failure.attempts, stopReason: failure.reason,
        elapsedMs: elapsed, timeoutKind: failure.timeoutKind, effectOutcome: adapterError.effectOutcome, queueWaitMs: queueWait)
      await context.backendEventHandler?(AdapterBackendEvent(provider: addon.name, eventType: "riela.step.retry.stopped",
        metadata: ["attempts": .integer(Int64(failure.attempts)), "stopReason": .string(failure.reason.rawValue),
                   "elapsedMs": .integer(Int64(elapsed))]))
      let publicationStart = retryClock.now()
      do {
        if step.failurePolicy == .advisory {
          let result = try await publishAdvisoryFailure(adapterError, sessionId: sessionId, step: step,
            attempt: executionIndex, transitions: transitions)
          await recordStepPublicationDuration(since: publicationStart, deadline: stepDeadline)
          return result
        }
        try await publishFailureAndThrow(adapterError, sessionId: sessionId, step: step,
          attempt: executionIndex, transitions: transitions)
      } catch {
        await recordStepPublicationDuration(since: publicationStart, deadline: stepDeadline)
        throw error
      }
    }
      await context.backendEventHandler?(AdapterBackendEvent(provider: addon.name, eventType: "riela.step.attempt.finished",
        metadata: success.metadata))
      await context.backendEventHandler?(AdapterBackendEvent(provider: addon.name, eventType: "riela.step.retry.stopped",
        metadata: ["attempts": .integer(Int64(race.attemptCount)), "stopReason": .string("succeeded"),
                   "elapsedMs": .integer(Int64(max(0, Int(retryClock.now().timeIntervalSince(readyAt) * 1_000))))]))
      try await checkpointNestedEffectCompletion(request)
      let publicationStart = retryClock.now()
      let result = try await publisher.publishAcceptedOutput(WorkflowPublicationRequest(
        sessionId: sessionId, stepId: step.id, nodeId: step.nodeId, attempt: executionIndex,
        body: .adapterOutput(success.output), routingReconciler: workflowRoutingReconciler(workflow: workflow, step: step,
          disableDefaultLoopGuard: request.disableDefaultLoopGuard), transitions: transitions,
        publishesRootOutput: transitions.isEmpty,
        prePersistenceRoutingDecider: workflowPrePersistenceRoutingDecider(workflow: workflow, step: step, request: request),
        preCommitPublicationHook: nestedInvocationPreCommitPublicationHook(workflow: workflow, step: step, request: request),
        carriedPayloadFields: carriedLoopGuardPayload(from: request)))
      if let stepDeadline, retryClock.now() > stepDeadline {
        await context.backendEventHandler?(AdapterBackendEvent(provider: addon.name,
          eventType: "riela.step.deadline.exceededAfterSuccess"))
      }
      await recordStepPublicationDuration(since: publicationStart, deadline: stepDeadline)
      return result
  }

  private func supervisedAddonRegion(
    _ arguments: SupervisedRegionArguments, race: StepSupervisorRace
  ) async throws -> SupervisedSuccess {
    let addon = arguments.addon, session = arguments.session, sessionId = arguments.sessionId
    let workflow = arguments.workflow, step = arguments.step, resolvedInputPayload = arguments.resolvedInputPayload
    let request = arguments.request, executionIndex = arguments.executionIndex, started = arguments.started
    let context = arguments.context, stepDeadline = arguments.stepDeadline
    let recordDuration = arguments.recordDuration
    let attachments = try await projectedAddonAttachments(addon: addon, sessionId: sessionId,
      workflow: workflow, step: step, request: request)
    guard addonResolver != nil || (step.placement != nil && distributedExecutor != nil) else {
      throw AdapterExecutionError(.providerError, "missing add-on resolver for '\(addon.name)'")
    }
    let predecessors = retryPredecessorExecutionIds(session: session, step: step)
    let operationId: String
    do {
      operationId = try WorkflowAddonExecutionIdentity.deriveOperationExecutionId(
        stepExecutionId: started.execution.executionId, predecessorStepExecutionId: predecessors.first,
        predecessorStepExecutionIds: predecessors)
    } catch let error as WorkflowAddonOperationIdentityError { throw AdapterExecutionError(.invalidInput, error.diagnosticCode) }
    let retentions = effectiveMemoryDeclarations(workflow: workflow, step: step, payload: nil)
      .compactMap { memory in memory.historyRetention.map { (memory.id, $0) } }
    let input = WorkflowAddonExecutionInput(workflowId: workflow.workflowId, stepId: step.id, nodeId: step.nodeId,
      addon: addon, variables: request.variables,
      resolvedInputPayload: workflowAddonResolvedInputPayload(resolvedInputPayload, session: session), attachments: attachments,
      executionIdentity: WorkflowAddonExecutionIdentity(workflowExecutionId: sessionId,
        stepExecutionId: started.execution.executionId, operationExecutionId: operationId, attempt: executionIndex,
        predecessorStepExecutionId: predecessors.first, predecessorStepExecutionIds: predecessors),
      memoryHistoryRetentions: retentions.isEmpty ? nil : Dictionary(uniqueKeysWithValues: retentions))
    let maxAttempts = step.retry?.maxAttempts ?? 1
    for attempt in 1...maxAttempts {
      let now = retryClock.now()
      let timeout = request.timeoutMs ?? step.timeoutMs ?? request.defaultTimeoutMs ?? request.workflow.defaults.nodeTimeoutMs
      let attemptDeadline = timeout > 0 ? min(now.addingTimeInterval(Double(timeout) / 1_000), stepDeadline ?? .distantFuture) : stepDeadline
      guard !race.isExpired, !Task.isCancelled, stepDeadline.map({ now < $0 }) ?? true,
            attemptDeadline.map({ now < $0 }) ?? true else {
        throw StepSupervisedFailure(error: AdapterExecutionError(.timeout, "\(addon.name) step deadline exceeded before dispatch"),
          reason: .stepDeadline, attempts: attempt - 1, timeoutKind: .stepDeadline)
      }
      race.startAttempt(attempt, deadline: attemptDeadline, stepDeadline: stepDeadline, clock: retryClock)
      guard !race.isExpired, !Task.isCancelled,
            stepDeadline.map({ retryClock.now() < $0 }) ?? true,
            attemptDeadline.map({ retryClock.now() < $0 }) ?? true else {
        _ = race.endAttempt(attempt)
        if Task.isCancelled { throw CancellationError() }
        throw StepSupervisedFailure(error: AdapterExecutionError(.timeout, "\(addon.name) step deadline exceeded before dispatch"),
          reason: .stepDeadline, attempts: attempt - 1, timeoutKind: .stepDeadline)
      }
      do {
        var attemptContext = context
        attemptContext.deadline = attemptDeadline
        let output = try await executePlacedAddon(input, step: step,
          executionId: "\(sessionId)/\(started.execution.executionId)", context: attemptContext)
        guard race.endAttempt(attempt) else { throw CancellationError() }
        var metadata = attemptMetadata(attempt: attempt, maxAttempts: maxAttempts, startedAt: now,
          readyAt: arguments.readyAt, deadline: stepDeadline,
          queueWait: max(0, Int(now.timeIntervalSince(arguments.readyAt) * 1_000)), recordDuration: recordDuration)
        metadata["outcome"] = .string("succeeded")
        let success = SupervisedSuccess(output: output, metadata: metadata)
        race.finish(.success(success))
        return success
      } catch {
        guard race.endAttempt(attempt) else { throw CancellationError() }
        if isWorkflowRunCancellation(error) { throw error }
        let failure = (error as? AdapterExecutionError) ?? AdapterExecutionError(.providerError, String(describing: error))
        var reason: StepRetryStopReason?
        var delay = 0
        if failure.effectOutcome == .unknown {
          reason = .outcomeUnknown
        } else if failure.isRetryable != true {
          reason = .nonRetryable
        } else if attempt >= maxAttempts {
          reason = .retryExhausted
        } else if let policy = step.retry {
          delay = StepRetryBackoff.delayMs(policy: policy, failedAttempt: attempt,
            sessionId: sessionId, executionId: started.execution.executionId)
          if let retryAfter = failure.retryAfter {
            let parts = retryAfter.components
            let ms = Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
            if ms > policy.effectiveMaxDelayMs { reason = .retryAfterExceedsMaxDelay }
            delay = max(delay, ms)
          }
          if reason == nil, let stepDeadline, retryClock.now().addingTimeInterval(Double(delay) / 1_000) >= stepDeadline {
            reason = .deadlineExhausted
          }
        }
        var metadata = attemptMetadata(attempt: attempt, maxAttempts: maxAttempts, startedAt: now,
          readyAt: arguments.readyAt, deadline: stepDeadline,
          queueWait: max(0, Int(now.timeIntervalSince(arguments.readyAt) * 1_000)), recordDuration: recordDuration)
        metadata["outcome"] = .string("failed")
        metadata["errorCode"] = .string(failure.code.rawValue)
        if let retryable = failure.isRetryable { metadata["retryable"] = .bool(retryable) }
        if let effectOutcome = failure.effectOutcome { metadata["effectOutcome"] = .string(effectOutcome.rawValue) }
        if failure.code == .timeout {
          metadata["timeoutKind"] = .string(attemptDeadline == stepDeadline ? "step-deadline" : "attempt")
          metadata["timeoutSource"] = .string("adapter")
        }
        if let retryAfter = failure.retryAfter {
          let parts = retryAfter.components
          metadata["retryAfterMs"] = .integer(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
        }
        if reason == nil { metadata["nextDelayMs"] = .integer(Int64(delay)) }
        await context.backendEventHandler?(AdapterBackendEvent(provider: addon.name, eventType: "riela.step.attempt.finished",
          metadata: metadata))
        if let reason { throw StepSupervisedFailure(error: failure, reason: reason, attempts: attempt, timeoutKind: nil) }
        if delay > 0 { try await retryClock.sleep(until: retryClock.now().addingTimeInterval(Double(delay) / 1_000)) }
      }
    }
    throw AdapterExecutionError(.providerError, "retry loop exhausted")
  }

  private func attemptMetadata(attempt: Int, maxAttempts: Int, startedAt: Date, readyAt: Date,
                               deadline: Date?, queueWait: Int, recordDuration: Int) -> JSONObject {
    let now = retryClock.now()
    var metadata: JSONObject = [
      "attempt": .integer(Int64(attempt)), "maxAttempts": .integer(Int64(maxAttempts)),
      "attemptDurationMs": .integer(Int64(max(0, Int(now.timeIntervalSince(startedAt) * 1_000)))),
      "elapsedMs": .integer(Int64(max(0, Int(now.timeIntervalSince(readyAt) * 1_000))))
    ]
    if let deadline { metadata["budgetRemainingMs"] = .integer(Int64(max(0, Int(deadline.timeIntervalSince(now) * 1_000)))) }
    if attempt == 1 {
      metadata["queueWaitMs"] = .integer(Int64(queueWait))
      metadata["recordStartedDurationMs"] = .integer(Int64(recordDuration))
    }
    return metadata
  }

  private func recordStepPublicationDuration(since start: Date, deadline: Date?) async {
    let now = retryClock.now()
    await telemetry.recordLog(RielaTelemetryLog(name: "riela.step.publication.duration", severity: "INFO",
      attributes: ["duration_ms": String(max(0, Int(now.timeIntervalSince(start) * 1_000))),
                   "status": (deadline.map { now > $0 } ?? false) ? "exceededDeadline" : "withinDeadline"]))
  }

}
