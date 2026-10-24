import Foundation
import RielaCore
import RielaEvents
import RielaObservability
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

/// Receipt statuses written for cron overlap fires (design §7.1).
enum CronOverlapReceiptStatus: String, Sendable {
  case queued
  case dispatched
  case skipped
  case discarded
  case cancelled
  case completed
  case failed
}

/// Builders for the machine-readable reason strings of design §7.2. Every
/// reason has the form `overlap-<kind>:<bindingId>[:<detail>]`.
enum CronOverlapReason {
  static func skip(_ bindingId: String, runningSessionId: String?) -> String {
    "overlap-skip:\(bindingId):\(runningSessionId ?? "pending")"
  }

  static func concurrencyCap(_ bindingId: String, cap: Int) -> String {
    "overlap-concurrency-cap:\(bindingId):\(cap)"
  }

  static func queued(_ bindingId: String, position: Int) -> String {
    "overlap-queued:\(bindingId):\(position)"
  }

  static func queueFull(_ bindingId: String, cap: Int) -> String {
    "overlap-queue-full:\(bindingId):\(cap)"
  }

  static func cancelRunning(_ bindingId: String, cancelledSessionId: String?) -> String {
    "overlap-cancel-running:\(bindingId):\(cancelledSessionId ?? "pending")"
  }

  static func cancelled(_ bindingId: String, supersedingReceiptId: String) -> String {
    "overlap-cancelled:\(bindingId):\(supersedingReceiptId)"
  }

  static func shutdownCancelled(_ bindingId: String) -> String {
    "overlap-shutdown-cancelled:\(bindingId)"
  }

  static func cancelTimeout(_ bindingId: String, sessionId: String?) -> String {
    "overlap-cancel-timeout:\(bindingId):\(sessionId ?? "pending")"
  }

  static func cancelPending(_ bindingId: String) -> String {
    "overlap-cancel-pending:\(bindingId)"
  }

  static func superseded(_ bindingId: String) -> String {
    "overlap-superseded:\(bindingId)"
  }

  static func shutdownDiscarded(_ bindingId: String) -> String {
    "overlap-shutdown-discarded:\(bindingId)"
  }

  static func abandoned(_ bindingId: String, sessionId: String? = nil) -> String {
    sessionId.map { "overlap-abandoned:\(bindingId):\($0)" } ?? "overlap-abandoned:\(bindingId)"
  }

  /// The finite kind of a reason (`overlap-skip`, `routine-disabled`, ...),
  /// i.e. the part before the first `:`. Telemetry exports only the kind; the
  /// binding id travels as `binding.id` and session ids stay on the receipt.
  static func kind(of reason: String) -> String {
    String(reason.prefix { $0 != ":" })
  }
}

actor CronOverlapDispatcher {
  /// Why the dispatcher requested cancellation of a run.
  private enum CancelCause {
    /// A `cancelRunning` fire requested it; the id is the receipt of the
    /// newest fire that superseded the run.
    case superseded(receiptId: String)
    /// Signal or error shutdown requested it; no fire supersedes the run.
    case shutdown
  }

  private struct RunHandle {
    var receiptId: String
    var task: Task<Void, Never>
    var sessionId: String?
    var fire: CronOverlapFire
    var cancelCause: CancelCause?

    var cancelRequested: Bool { cancelCause != nil }
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
  private let receipts: EventReceiptStore
  /// Stamped on every receipt this dispatcher writes (`<pid>-<random>`).
  nonisolated let serveInstanceId: String
  private var scopes: [String: Scope] = [:]
  private var drainWaiters: [CheckedContinuation<Void, Never>] = []
  private var drainAbandoned = false
  private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
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
    self.receipts = EventReceiptStore(eventRoot: eventRoot)
    let instanceId = "\(getpid())-\(UUID().uuidString.prefix(8).lowercased())"
    self.serveInstanceId = instanceId
    let abandoned = Self.reconcileAbandonedReceipts(
      store: EventReceiptStore(eventRoot: eventRoot), ownInstanceId: instanceId, now: clock.now()
    )
    if !abandoned.isEmpty {
      Task { [server] in
        for receipt in abandoned {
          await server.telemetry.recordLog(Self.overlapTelemetryLog(
            bindingId: receipt.bindingId ?? "", policy: receipt.overlapPolicy ?? "", reason: receipt.reason ?? ""
          ))
        }
      }
    }
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
      let reason = CronOverlapReason.skip(fire.bindingId, runningSessionId: scope.running.first?.sessionId)
      return recordNonStart(fire, policy: policy, status: .skipped, reason: reason)
    case .concurrent:
      if let cap = policy.maxConcurrentRuns, scope.running.count >= cap {
        return recordNonStart(
          fire, policy: policy, status: .skipped, reason: CronOverlapReason.concurrencyCap(fire.bindingId, cap: cap)
        )
      }
      scopes[fire.bindingId] = scope
      start(fire, policy: policy)
      return .started
    case .queue:
      let cap = policy.maxQueuedRuns ?? defaultEventOverlapMaxQueuedRuns
      guard scope.queue.count < cap else {
        return recordNonStart(
          fire, policy: policy, status: .skipped, reason: CronOverlapReason.queueFull(fire.bindingId, cap: cap)
        )
      }
      scope.queue.append(fire)
      let position = scope.queue.count
      scopes[fire.bindingId] = scope
      let reason = CronOverlapReason.queued(fire.bindingId, position: position)
      writeReceipt(fire, receiptId: receiptId(fire), status: .queued, policy: policy, reason: reason)
      emitOverlapTelemetry(fire, policy: policy, reason: reason)
      return .queued(position: position)
    case .cancelRunning:
      let superseded = scope.pendingAfterCancel
      if let superseded {
        _ = recordNonStart(superseded, policy: policy, status: .skipped, reason: CronOverlapReason.superseded(fire.bindingId))
      }
      let supersedingReceiptId = receiptId(fire)
      for index in scope.running.indices {
        // Only a fire-requested cancel points at the newest superseding fire;
        // the run keeps that id even if the pending fire later times out.
        if case .shutdown? = scope.running[index].cancelCause { continue }
        scope.running[index].cancelCause = .superseded(receiptId: supersedingReceiptId)
        scope.running[index].task.cancel()
      }
      scope.pendingAfterCancel = fire
      scopes[fire.bindingId] = scope
      let reason = CronOverlapReason.cancelPending(fire.bindingId)
      writeReceipt(fire, receiptId: supersedingReceiptId, status: .queued, policy: policy, reason: reason)
      emitOverlapTelemetry(fire, policy: policy, reason: reason)
      // A superseding fire inherits the running settle bound instead of restarting it.
      if superseded == nil {
        scope.settleGeneration += 1
        let generation = scope.settleGeneration
        scopes[fire.bindingId] = scope
        Task { [clock, cancelSettleTimeout, weak self] in
          try? await clock.sleep(for: cancelSettleTimeout)
          await self?.settleTimedOut(bindingId: fire.bindingId, generation: generation)
        }
      }
      return .cancelPending
    }
  }

  /// Records a fire the routine gate stopped at submit time, exactly like the
  /// same gate stopping a deferred start. It is not an overlap outcome, so the
  /// caller still does not count the tick toward `--limit` (design §6.3).
  func recordRoutineGateSkip(_ fire: CronOverlapFire, reason: String) {
    _ = recordNonStart(fire, policy: effectivePolicy(bindingId: fire.bindingId), status: .skipped, reason: reason)
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
        _ = recordNonStart(fire, policy: policy, status: .discarded, reason: CronOverlapReason.shutdownDiscarded(bindingId))
      }
      scope.queue.removeAll()
      if let pending = scope.pendingAfterCancel {
        _ = recordNonStart(pending, policy: policy, status: .discarded, reason: CronOverlapReason.shutdownDiscarded(bindingId))
        scope.pendingAfterCancel = nil
      }
      scope.settleGeneration += 1
      for index in scope.running.indices {
        if scope.running[index].cancelCause == nil {
          scope.running[index].cancelCause = .shutdown
        }
        scope.running[index].task.cancel()
      }
      scopes[bindingId] = scope
    }
    guard hasRunning else { return }
    shutdownToken += 1
    let token = shutdownToken
    await withCheckedContinuation { continuation in
      shutdownWaiters.append(continuation)
      if !hasRunning { resumeShutdownWaiters() }
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
    reason: String? = nil,
    cancelledSessionIds: [String]? = nil
  ) {
    let id = receiptId(fire)
    writeReceipt(
      fire, receiptId: id, status: .dispatched, policy: policy, reason: reason, cancelledSessionIds: cancelledSessionIds
    )
    let dispatcher = self
    let task = Task { [dispatcher, server, parsed] in
      // The session id reaches the actor through its own hop task. `finish`
      // waits for every hop first, so a run that ends right after
      // `session_started` still records its real session id (design §6.5).
      let hops = SessionStartedHops()
      let request = EventWorkflowRunRequest(
        workflowName: fire.workflowName,
        runtimeVariables: fire.runtimeVariables,
        parsed: parsed,
        onSessionStarted: { sessionId in
          hops.append(Task {
            await dispatcher.recordSessionStarted(receiptId: id, sessionId: sessionId, bindingId: fire.bindingId)
          })
        }
      )
      let result: WorkflowRunResult?
      let failure: String?
      do {
        result = try await server.runEventWorkflow(request)
        failure = nil
      } catch {
        result = nil
        failure = String(describing: error)
      }
      await hops.waitAll()
      await dispatcher.finish(receiptId: id, bindingId: fire.bindingId, result: result, error: failure)
    }
    var scope = scopes[fire.bindingId] ?? Scope()
    scope.running.append(RunHandle(receiptId: id, task: task, sessionId: nil, fire: fire, cancelCause: nil))
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
      updateReceipt(receiptId, status: .completed, workflowExecutionId: result.session.sessionId)
      if let routineId = handle.fire.routineId {
        routineStore(handle.fire).record(routineId: routineId, at: handle.fire.firedAt)
      }
      try? server.writeServeRecord(
        eventRoot: eventRoot, status: "ready", pollingTarget: handle.fire.sourceId,
        lastWorkflowName: handle.fire.workflowName
      )
    } else if let cause = handle.cancelCause {
      let reason = switch cause {
      case let .superseded(supersedingReceiptId):
        CronOverlapReason.cancelled(bindingId, supersedingReceiptId: supersedingReceiptId)
      case .shutdown:
        CronOverlapReason.shutdownCancelled(bindingId)
      }
      updateReceipt(receiptId, status: .cancelled, reason: reason)
    } else {
      updateReceipt(receiptId, status: .failed, reason: error)
    }
    // Advance before any suspension so a reentrant submit cannot overtake the FIFO
    // queue; record the failure before waking drain so serve reports it.
    await advanceDeferred(bindingId: bindingId, policy: policy, cancelledSessionIds: cancelledSessionIds)
    if result == nil, !handle.cancelRequested {
      await server.recordWorkflowDispatchFailure(
        eventRoot: eventRoot, sourceKind: "cron", sourceId: handle.fire.sourceId,
        workflowName: handle.fire.workflowName, error: CLIUsageError(error ?? "cron workflow failed")
      )
    }
    resumeDrainWaitersIfNeeded()
    if !hasRunning { resumeShutdownWaiters() }
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
      guard !skipDeferredIfRoutineInactive(pending, policy: policy) else {
        await advanceDeferred(bindingId: bindingId, policy: policy, cancelledSessionIds: cancelledSessionIds)
        return
      }
      start(
        pending, policy: policy,
        reason: CronOverlapReason.cancelRunning(bindingId, cancelledSessionId: ids.first),
        cancelledSessionIds: ids
      )
      return
    }
    guard scope.running.isEmpty, scope.pendingAfterCancel == nil, !scope.queue.isEmpty else { return }
    let next = scope.queue.removeFirst()
    scopes[bindingId] = scope
    guard !skipDeferredIfRoutineInactive(next, policy: policy) else {
      await advanceDeferred(bindingId: bindingId, policy: policy, cancelledSessionIds: cancelledSessionIds)
      return
    }
    start(next, policy: policy)
  }

  /// Returns true when the routine gate stopped the deferred fire (it is then
  /// recorded `skipped` with the gate's reason).
  private func skipDeferredIfRoutineInactive(_ fire: CronOverlapFire, policy: EffectiveEventOverlapPolicy) -> Bool {
    guard let routineId = fire.routineId else { return false }
    let gate = server.routineDispatchGate(routineId: routineId, storeRoot: fire.routineStoreRoot, parsed: parsed)
    guard let reason = gate.skipReason else { return false }
    _ = recordNonStart(fire, policy: policy, status: .skipped, reason: reason)
    return true
  }

  private func settleTimedOut(bindingId: String, generation: Int) {
    guard var scope = scopes[bindingId], scope.settleGeneration == generation,
      let pending = scope.pendingAfterCancel else { return }
    let sid = scope.running.first?.sessionId
    scope.pendingAfterCancel = nil
    scope.settleGeneration += 1
    scopes[bindingId] = scope
    _ = recordNonStart(
      pending, policy: effectivePolicy(bindingId: bindingId), status: .skipped,
      reason: CronOverlapReason.cancelTimeout(bindingId, sessionId: sid)
    )
    resumeDrainWaitersIfNeeded()
  }

  private func shutdownWaitTimedOut(token: Int) {
    guard token == shutdownToken else { return }
    resumeShutdownWaiters()
  }

  private func recordSessionStarted(receiptId: String, sessionId: String, bindingId: String) {
    updateReceipt(receiptId, workflowExecutionId: sessionId)
    guard var scope = scopes[bindingId], let index = scope.running.firstIndex(where: { $0.receiptId == receiptId }) else { return }
    scope.running[index].sessionId = sessionId
    scopes[bindingId] = scope
  }

  private func recordNonStart(
    _ fire: CronOverlapFire,
    policy: EffectiveEventOverlapPolicy,
    status: CronOverlapReceiptStatus,
    reason: String
  ) -> CronOverlapSubmitOutcome {
    writeReceipt(fire, receiptId: receiptId(fire), status: status, policy: policy, reason: reason)
    try? server.writeServeRecord(eventRoot: eventRoot, status: "ready", pollingTarget: fire.sourceId, lastIgnoredReason: reason)
    emitOverlapTelemetry(fire, policy: policy, reason: reason)
    return .skipped(reason: reason)
  }

  /// One `riela.events.cron.overlap` log per non-start outcome, including
  /// `queued` and `cancel-pending` (design §7.3).
  private func emitOverlapTelemetry(_ fire: CronOverlapFire, policy: EffectiveEventOverlapPolicy, reason: String) {
    Task { [server] in
      await server.telemetry.recordLog(Self.overlapTelemetryLog(
        bindingId: fire.bindingId, policy: policy.policy.rawValue, reason: reason
      ))
    }
  }

  static func overlapTelemetryLog(bindingId: String, policy: String, reason: String) -> RielaTelemetryLog {
    RielaTelemetryLog(name: "riela.events.cron.overlap", attributes: [
      "binding.id": bindingId,
      "overlap.policy": policy,
      "overlap.reason": CronOverlapReason.kind(of: reason)
    ])
  }

  private func receiptId(_ fire: CronOverlapFire) -> String {
    cronOverlapReceiptId(sourceId: fire.sourceId, eventId: fire.envelope.eventId, bindingId: fire.bindingId)
  }

  private func writeReceipt(
    _ fire: CronOverlapFire,
    receiptId: String,
    status: CronOverlapReceiptStatus,
    policy: EffectiveEventOverlapPolicy,
    reason: String? = nil,
    cancelledSessionIds: [String]? = nil
  ) {
    do {
      let receipt = PersistedEventReceipt(
        receiptId: receiptId, sourceId: fire.sourceId, eventId: fire.envelope.eventId,
        status: status.rawValue, duplicate: false, workflowExecutionId: nil,
        workflowName: fire.workflowName, replayedFromReceiptId: nil, reason: reason,
        updatedAt: clock.now(), envelope: fire.envelope, readOnlyTriggers: nil, readOnlyDiagnostics: nil,
        bindingId: fire.bindingId, overlapPolicy: policy.policy.rawValue,
        overlapPolicySource: policy.source.rawValue, cancelledSessionIds: cancelledSessionIds,
        coalescedTickCount: fire.coalescedTickCount == 0 ? nil : fire.coalescedTickCount
      )
      var stamped = receipt
      stamped.serveInstanceId = serveInstanceId
      try receipts.save(stamped)
    } catch {
      try? server.writeServeRecord(eventRoot: eventRoot, status: "ready", detail: "cron receipt write failed: \(error)")
    }
  }

  private func updateReceipt(
    _ receiptId: String,
    status: CronOverlapReceiptStatus? = nil,
    reason: String? = nil,
    workflowExecutionId: String? = nil
  ) {
    do {
      guard var receipt = try receipts.load(receiptId) else {
        throw CLIUsageError("event receipt not found: \(receiptId)")
      }
      if let status { receipt.status = status.rawValue }
      if let reason { receipt.reason = reason }
      if let workflowExecutionId { receipt.workflowExecutionId = workflowExecutionId }
      receipt.updatedAt = clock.now()
      receipt.serveInstanceId = receipt.serveInstanceId ?? serveInstanceId
      try receipts.save(receipt)
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

  private func resumeShutdownWaiters() {
    let waiters = shutdownWaiters
    shutdownWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  /// Queued fires live only in the serve process (design §6.7), so after
  /// `kill -9` or a shutdown past its bound their receipts would stay
  /// `queued`/`dispatched` forever. At startup, every binding-scoped receipt
  /// in one of those states that another, no longer running serve instance
  /// stamped (or that predates stamping) is closed: `queued` becomes
  /// `discarded` and `dispatched` becomes `failed`, both with
  /// `overlap-abandoned:<bindingId>[:<sessionId>]`. Receipts stamped by a
  /// live process (including this one) are left alone. The runtime session
  /// referenced by `workflowExecutionId` keeps its own terminal state.
  static func reconcileAbandonedReceipts(
    store: EventReceiptStore,
    ownInstanceId: String,
    now: Date
  ) -> [PersistedEventReceipt] {
    var reconciled: [PersistedEventReceipt] = []
    for entry in store.listSkippingUnreadable() {
      guard let bindingId = entry.bindingId,
            let status = CronOverlapReceiptStatus(rawValue: entry.status),
            status == .queued || status == .dispatched,
            entry.serveInstanceId != ownInstanceId,
            !isServeInstanceAlive(entry.serveInstanceId) else { continue }
      var receipt = entry
      if status == .queued {
        receipt.status = CronOverlapReceiptStatus.discarded.rawValue
        receipt.reason = CronOverlapReason.abandoned(bindingId)
      } else {
        receipt.status = CronOverlapReceiptStatus.failed.rawValue
        receipt.reason = CronOverlapReason.abandoned(bindingId, sessionId: receipt.workflowExecutionId ?? "pending")
      }
      receipt.updatedAt = now
      guard (try? store.save(receipt)) != nil else { continue }
      reconciled.append(receipt)
    }
    return reconciled
  }

  private static func isServeInstanceAlive(_ instanceId: String?) -> Bool {
    guard let instanceId,
          let pidText = instanceId.split(separator: "-").first,
          let pid = pid_t(pidText), pid > 0 else { return false }
    return kill(pid, 0) == 0 || errno == EPERM
  }
}

/// Collects the per-run session-id hop tasks so the run awaits them before
/// reporting completion.
private final class SessionStartedHops: @unchecked Sendable {
  private let lock = NSLock()
  private var tasks: [Task<Void, Never>] = []

  func append(_ task: Task<Void, Never>) {
    lock.withLock { tasks.append(task) }
  }

  func waitAll() async {
    let pending = lock.withLock { tasks }
    for task in pending {
      await task.value
    }
  }
}

private extension RoutineStore {
  func record(routineId: String, at date: Date) {
    _ = try? recordRunCompletion(routineId: routineId, at: date)
  }
}
