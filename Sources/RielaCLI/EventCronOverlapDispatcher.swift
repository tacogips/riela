import Crypto
import Foundation
import RielaCore
import RielaEvents
import RielaObservability

struct CronOverlapFire: Sendable {
  var bindingId: String
  var sourceId: String
  var workflowName: String
  var runtimeVariables: JSONObject
  var envelope: ExternalEventEnvelope
  var scheduledAt: Date
  var firedAt: Date
  var routineId: String?
  var routineStoreRoot: String?
  var coalescedTickCount: Int
}

enum CronOverlapSubmitOutcome: Equatable, Sendable {
  case started
  case queued(position: Int)
  case skipped(reason: String)
  case cancelPending
}

actor CronOverlapDispatcher {
  private struct RunHandle {
    var receiptId: String
    var task: Task<Void, Never>
    var sessionId: String?
    var fire: CronOverlapFire
    var cancelRequested: Bool
  }

  private struct Scope {
    var running: [RunHandle] = []
    var queue: [CronOverlapFire] = []
    var pendingAfterCancel: CronOverlapFire?
    var settleGeneration = 0
  }

  private let server: DefaultEventLiveServer
  private let eventRoot: URL
  private let parsed: ParsedParityOptions
  private let policies: [String: EffectiveEventOverlapPolicy]
  private let clock: any EventServeClock
  private let cancelSettleTimeout: Duration
  private var scopes: [String: Scope] = [:]
  private var drainWaiters: [CheckedContinuation<Void, Never>] = []
  private var drainAbandoned = false
  private var shutdownWaiter: CheckedContinuation<Void, Never>?
  private var shutdownToken = 0

  init(
    server: DefaultEventLiveServer,
    eventRoot: URL,
    parsed: ParsedParityOptions,
    policies: [String: EffectiveEventOverlapPolicy],
    clock: any EventServeClock,
    cancelSettleTimeout: Duration
  ) {
    self.server = server
    self.eventRoot = eventRoot
    self.parsed = parsed
    self.policies = policies
    self.clock = clock
    self.cancelSettleTimeout = cancelSettleTimeout
  }

  nonisolated func effectivePolicy(bindingId: String) -> EffectiveEventOverlapPolicy {
    policies[bindingId] ?? EffectiveEventOverlapPolicy(policy: .skip, source: .default)
  }

  @discardableResult
  func submit(_ fire: CronOverlapFire) -> CronOverlapSubmitOutcome {
    var scope = scopes[fire.bindingId] ?? Scope()
    let policy = effectivePolicy(bindingId: fire.bindingId)
    if scope.running.isEmpty && scope.pendingAfterCancel == nil {
      scopes[fire.bindingId] = scope
      start(fire, policy: policy)
      return .started
    }
    switch policy.policy {
    case .skip:
      let sid = scope.running.first?.sessionId ?? "pending"
      return recordNonStart(fire, policy: policy, status: "skipped", reason: "overlap-skip:\(fire.bindingId):\(sid)")
    case .concurrent:
      if let cap = policy.maxConcurrentRuns, scope.running.count >= cap {
        return recordNonStart(fire, policy: policy, status: "skipped", reason: "overlap-concurrency-cap:\(fire.bindingId):\(cap)")
      }
      scopes[fire.bindingId] = scope
      start(fire, policy: policy)
      return .started
    case .queue:
      let cap = policy.maxQueuedRuns ?? defaultEventOverlapMaxQueuedRuns
      guard scope.queue.count < cap else {
        return recordNonStart(fire, policy: policy, status: "skipped", reason: "overlap-queue-full:\(fire.bindingId):\(cap)")
      }
      scope.queue.append(fire)
      let position = scope.queue.count
      scopes[fire.bindingId] = scope
      let reason = "overlap-queued:\(fire.bindingId):\(position)"
      writeReceipt(fire, receiptId: makeReceiptId(fire), status: "queued", policy: policy, reason: reason)
      return .queued(position: position)
    case .cancelRunning:
      if let pending = scope.pendingAfterCancel {
        _ = recordNonStart(pending, policy: policy, status: "skipped", reason: "overlap-superseded:\(fire.bindingId)")
      }
      for index in scope.running.indices {
        scope.running[index].cancelRequested = true
        scope.running[index].task.cancel()
      }
      scope.pendingAfterCancel = fire
      scope.settleGeneration += 1
      let generation = scope.settleGeneration
      scopes[fire.bindingId] = scope
      Task { [clock, cancelSettleTimeout, weak self] in
        try? await clock.sleep(for: cancelSettleTimeout)
        await self?.settleTimedOut(bindingId: fire.bindingId, generation: generation)
      }
      return .cancelPending
    }
  }

  func runningSessionIds(bindingId: String) -> [String?] {
    scopes[bindingId]?.running.map(\.sessionId) ?? []
  }

  func drain() async {
    while !isDrained && !drainAbandoned {
      await withCheckedContinuation { continuation in
        if isDrained || drainAbandoned {
          continuation.resume()
        } else {
          drainWaiters.append(continuation)
        }
      }
    }
  }

  func abandonDrain() {
    drainAbandoned = true
    let waiters = drainWaiters
    drainWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func shutdownCancelling() async {
    for bindingId in Array(scopes.keys) {
      guard var scope = scopes[bindingId] else { continue }
      let policy = effectivePolicy(bindingId: bindingId)
      for fire in scope.queue {
        _ = recordNonStart(fire, policy: policy, status: "discarded", reason: "overlap-shutdown-discarded:\(bindingId)")
      }
      scope.queue.removeAll()
      if let pending = scope.pendingAfterCancel {
        _ = recordNonStart(pending, policy: policy, status: "discarded", reason: "overlap-shutdown-discarded:\(bindingId)")
        scope.pendingAfterCancel = nil
      }
      scope.settleGeneration += 1
      for index in scope.running.indices {
        scope.running[index].cancelRequested = true
        scope.running[index].task.cancel()
      }
      scopes[bindingId] = scope
    }
    guard hasRunning else { return }
    shutdownToken += 1
    let token = shutdownToken
    await withCheckedContinuation { continuation in
      shutdownWaiter = continuation
      if !hasRunning { resumeShutdownWaiter() }
      Task.detached { [clock, cancelSettleTimeout, weak self] in
        try? await clock.sleep(for: cancelSettleTimeout)
        await self?.shutdownWaitTimedOut(token: token)
      }
    }
  }

  private var isDrained: Bool {
    scopes.values.allSatisfy { $0.running.isEmpty && $0.queue.isEmpty && $0.pendingAfterCancel == nil }
  }

  private var hasRunning: Bool {
    scopes.values.contains { !$0.running.isEmpty }
  }

  private func start(
    _ fire: CronOverlapFire,
    policy: EffectiveEventOverlapPolicy,
    status: String = "dispatched",
    reason: String? = nil,
    cancelledSessionIds: [String]? = nil
  ) {
    let id = makeReceiptId(fire)
    writeReceipt(fire, receiptId: id, status: status, policy: policy, reason: reason, cancelledSessionIds: cancelledSessionIds)
    let dispatcher = self
    let task = Task { [dispatcher, server, parsed] in
      let request = EventWorkflowRunRequest(
        workflowName: fire.workflowName,
        runtimeVariables: fire.runtimeVariables,
        parsed: parsed,
        onSessionStarted: { sessionId in
          Task { await dispatcher.recordSessionStarted(receiptId: id, sessionId: sessionId, bindingId: fire.bindingId) }
        }
      )
      do {
        let result = try await server.runEventWorkflow(request)
        await dispatcher.finish(receiptId: id, bindingId: fire.bindingId, result: result, error: nil)
      } catch {
        await dispatcher.finish(receiptId: id, bindingId: fire.bindingId, result: nil, error: String(describing: error))
      }
    }
    var scope = scopes[fire.bindingId] ?? Scope()
    scope.running.append(RunHandle(receiptId: id, task: task, sessionId: nil, fire: fire, cancelRequested: false))
    scopes[fire.bindingId] = scope
  }

  private func finish(receiptId: String, bindingId: String, result: WorkflowRunResult?, error: String?) async {
    guard var scope = scopes[bindingId], let index = scope.running.firstIndex(where: { $0.receiptId == receiptId }) else { return }
    let handle = scope.running[index]
    let policy = effectivePolicy(bindingId: bindingId)
    let cancelledSessionIds = scope.running.filter(\.cancelRequested).compactMap(\.sessionId)
    scope.running.remove(at: index)
    scopes[bindingId] = scope
    if let result {
      updateReceipt(receiptId, status: "completed", workflowExecutionId: result.session.sessionId)
      if let routineId = handle.fire.routineId {
        routineStore(handle.fire).record(routineId: routineId, at: handle.fire.firedAt)
      }
      try? server.writeServeRecord(
        eventRoot: eventRoot, status: "ready", pollingTarget: handle.fire.sourceId,
        lastWorkflowName: handle.fire.workflowName
      )
    } else if handle.cancelRequested {
      updateReceipt(receiptId, status: "cancelled", reason: "overlap-cancelled:\(bindingId):\(scope.pendingAfterCancel.map { makeReceiptId($0) } ?? "pending")")
    } else {
      updateReceipt(receiptId, status: "failed", reason: error)
      await server.recordWorkflowDispatchFailure(
        eventRoot: eventRoot, sourceKind: "cron", sourceId: handle.fire.sourceId,
        workflowName: handle.fire.workflowName, error: CLIUsageError(error ?? "cron workflow failed")
      )
    }
    await advanceDeferred(bindingId: bindingId, policy: policy, cancelledSessionIds: cancelledSessionIds)
    resumeDrainWaitersIfNeeded()
    if !hasRunning { resumeShutdownWaiter() }
  }

  private func advanceDeferred(
    bindingId: String,
    policy: EffectiveEventOverlapPolicy,
    cancelledSessionIds: [String] = []
  ) async {
    guard var scope = scopes[bindingId] else { return }
    if let pending = scope.pendingAfterCancel, !scope.running.contains(where: \.cancelRequested) {
      let ids = cancelledSessionIds + scope.running.compactMap(\.sessionId)
      scope.pendingAfterCancel = nil
      scope.settleGeneration += 1
      scopes[bindingId] = scope
      guard !startDeferredIfRoutineInactive(pending, policy: policy) else {
        await advanceDeferred(bindingId: bindingId, policy: policy, cancelledSessionIds: cancelledSessionIds)
        return
      }
      start(pending, policy: policy, status: "dispatched", reason: "overlap-cancel-running:\(bindingId):\(ids.first ?? "pending")", cancelledSessionIds: ids)
      return
    }
    guard scope.running.isEmpty, scope.pendingAfterCancel == nil, !scope.queue.isEmpty else { return }
    let next = scope.queue.removeFirst()
    scopes[bindingId] = scope
    guard !startDeferredIfRoutineInactive(next, policy: policy) else {
      await advanceDeferred(bindingId: bindingId, policy: policy, cancelledSessionIds: cancelledSessionIds)
      return
    }
    start(next, policy: policy)
  }

  private func startDeferredIfRoutineInactive(_ fire: CronOverlapFire, policy: EffectiveEventOverlapPolicy) -> Bool {
    guard let routineId = fire.routineId else { return false }
    let gate = server.routineDispatchGate(routineId: routineId, storeRoot: fire.routineStoreRoot, parsed: parsed)
    guard let reason = gate.skipReason else { return false }
    _ = recordNonStart(fire, policy: policy, status: "skipped", reason: reason)
    return true
  }

  private func settleTimedOut(bindingId: String, generation: Int) {
    guard var scope = scopes[bindingId], scope.settleGeneration == generation,
      let pending = scope.pendingAfterCancel else { return }
    let sid = scope.running.first?.sessionId ?? "pending"
    scope.pendingAfterCancel = nil
    scope.settleGeneration += 1
    scopes[bindingId] = scope
    _ = recordNonStart(pending, policy: effectivePolicy(bindingId: bindingId), status: "skipped", reason: "overlap-cancel-timeout:\(bindingId):\(sid)")
    resumeDrainWaitersIfNeeded()
  }

  private func shutdownWaitTimedOut(token: Int) {
    guard token == shutdownToken else { return }
    resumeShutdownWaiter()
  }

  private func recordSessionStarted(receiptId: String, sessionId: String, bindingId: String) {
    guard var scope = scopes[bindingId], let index = scope.running.firstIndex(where: { $0.receiptId == receiptId }) else { return }
    scope.running[index].sessionId = sessionId
    scopes[bindingId] = scope
    updateReceipt(receiptId, workflowExecutionId: sessionId)
  }

  private func recordNonStart(
    _ fire: CronOverlapFire,
    policy: EffectiveEventOverlapPolicy,
    status: String,
    reason: String
  ) -> CronOverlapSubmitOutcome {
    writeReceipt(fire, receiptId: makeReceiptId(fire), status: status, policy: policy, reason: reason)
    try? server.writeServeRecord(eventRoot: eventRoot, status: "ready", pollingTarget: fire.sourceId, lastIgnoredReason: reason)
    Task {
      await server.telemetry.recordLog(RielaTelemetryLog(name: "riela.events.cron.overlap", attributes: [
        "binding.id": fire.bindingId,
        "overlap.policy": policy.policy.rawValue,
        "overlap.reason": reason
      ]))
    }
    return .skipped(reason: reason)
  }

  private func makeReceiptId(_ fire: CronOverlapFire) -> String {
    let data = Data((fire.sourceId + "\u{0}" + fire.envelope.eventId + "\u{0}" + fire.bindingId).utf8)
    return "event-cron-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func writeReceipt(
    _ fire: CronOverlapFire,
    receiptId: String,
    status: String,
    policy: EffectiveEventOverlapPolicy,
    reason: String? = nil,
    cancelledSessionIds: [String]? = nil
  ) {
    do {
      let directory = eventRoot.appendingPathComponent("receipts", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let receipt = PersistedEventReceipt(
        receiptId: receiptId, sourceId: fire.sourceId, eventId: fire.envelope.eventId,
        status: status, duplicate: false, workflowExecutionId: nil,
        workflowName: fire.workflowName, replayedFromReceiptId: nil, reason: reason,
        updatedAt: clock.now(), envelope: fire.envelope, readOnlyTriggers: nil, readOnlyDiagnostics: nil,
        bindingId: fire.bindingId, overlapPolicy: policy.policy.rawValue,
        overlapPolicySource: policy.source.rawValue, cancelledSessionIds: cancelledSessionIds,
        coalescedTickCount: fire.coalescedTickCount == 0 ? nil : fire.coalescedTickCount
      )
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let url = directory.appendingPathComponent(receiptId + ".json")
      try encoder.encode(receipt).write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      try? server.writeServeRecord(eventRoot: eventRoot, status: "ready", detail: "cron receipt write failed: \(error)")
    }
  }

  private func updateReceipt(
    _ receiptId: String,
    status: String? = nil,
    reason: String? = nil,
    workflowExecutionId: String? = nil
  ) {
    let url = eventRoot.appendingPathComponent("receipts", isDirectory: true).appendingPathComponent(receiptId + ".json")
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      var receipt = try decoder.decode(PersistedEventReceipt.self, from: Data(contentsOf: url))
      if let status { receipt.status = status }
      if let reason { receipt.reason = reason }
      if let workflowExecutionId { receipt.workflowExecutionId = workflowExecutionId }
      receipt.updatedAt = clock.now()
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(receipt).write(to: url, options: .atomic)
    } catch {
      try? server.writeServeRecord(eventRoot: eventRoot, status: "ready", detail: "cron receipt update failed: \(error)")
    }
  }

  private func routineStore(_ fire: CronOverlapFire) -> RoutineStore {
    let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    return RoutineStore(rootDirectory: RoutineStore.resolveRootDirectory(
      explicit: fire.routineStoreRoot,
      workingDirectory: workingDirectory,
      environment: CLIRuntimeEnvironment.mergedProcessEnvironment()
    ))
  }

  private func resumeDrainWaitersIfNeeded() {
    guard isDrained else { return }
    let waiters = drainWaiters
    drainWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  private func resumeShutdownWaiter() {
    guard let waiter = shutdownWaiter else { return }
    shutdownWaiter = nil
    waiter.resume()
  }
}

private extension RoutineStore {
  func record(routineId: String, at date: Date) {
    _ = try? recordRunCompletion(routineId: routineId, at: date)
  }
}
