import Foundation
@testable import RielaCore
import XCTest

final class StepRetryPolicyTests: XCTestCase {
  func testRetryableFailureThenSuccess() async throws {
    let clock = ManualWorkflowRetryClock()
    let resolver = RetryScriptResolver(failures: [AdapterExecutionError(.providerError, "limited", isRetryable: true)])
    let runner = DeterministicWorkflowRunner(addonResolver: resolver, retryClock: clock)
    let result = try await runner.run(retryRequest(deadline: 10_000,
      policy: WorkflowStepRetryPolicy(maxAttempts: 3, initialDelayMs: 0)))
    XCTAssertEqual(result.status, .completed)
    let count = await resolver.count()
    XCTAssertEqual(count, 2)
  }

  func testExpiredBeforeDispatchDoesNotCallAddon() async throws {
    let clock = ManualWorkflowRetryClock(now: Date(timeIntervalSince1970: 10))
    let resolver = RetryScriptResolver(failures: [])
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 0)))
    var request = retryRequest(deadline: 1_000, policy: nil)
    request.runStartedAt = Date(timeIntervalSince1970: 0)
    do {
      _ = try await DeterministicWorkflowRunner(store: store, addonResolver: resolver, retryClock: clock).run(request)
      XCTFail("expected deadline failure")
    } catch { }
    let session = await store.latestSession(workflowId: "retry-test")
    XCTAssertTrue(session?.executions.first?.failureReason?.contains("attempts=0") == true)
    let count = await resolver.count()
    XCTAssertEqual(count, 0)
  }

  func testNewRunDeadlineAnchorsAtRunStart() async throws {
    let now = Date(timeIntervalSince1970: 10)
    let clock = ManualWorkflowRetryClock(now: now)
    let resolver = RetryScriptResolver(failures: [])
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 0)))
    var request = retryRequest(deadline: 1_000, policy: nil)
    request.runStartedAt = now
    _ = try await DeterministicWorkflowRunner(store: store, addonResolver: resolver, retryClock: clock).run(request)
    let deadlines = await resolver.capturedDeadlines()
    XCTAssertEqual(deadlines.first!, now.addingTimeInterval(1))
  }

  func testUnknownOutcomeIsNeverRetried() async throws {
    try await assertFailure(
      AdapterExecutionError(.providerError, "unknown", isRetryable: true, effectOutcome: .unknown),
      reason: "outcome-unknown", calls: 1
    )
  }

  func testPermanentFailureIsNotRetried() async throws {
    try await assertFailure(AdapterExecutionError(.providerError, "permanent", isRetryable: false),
                            reason: "non-retryable", calls: 1)
  }

  func testRetriesExhausted() async throws {
    try await assertFailure(AdapterExecutionError(.providerError, "transient", isRetryable: true),
                            reason: "retry-exhausted", calls: 3)
  }

  func testRetryAfterExceedingMaximumStops() async throws {
    try await assertFailure(
      AdapterExecutionError(.providerError, "limited", isRetryable: true, retryAfter: .seconds(120)),
      reason: "retry-after-exceeds-max-delay", calls: 1
    )
  }

  func testDelayExceedingBudgetStopsWithoutRetry() async throws {
    let clock = ManualWorkflowRetryClock()
    let resolver = RetryScriptResolver(failures: [AdapterExecutionError(.providerError, "limited", isRetryable: true)])
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(clock.now()))
    let runner = DeterministicWorkflowRunner(store: store, addonResolver: resolver, retryClock: clock)
    var request = retryRequest(deadline: 1_000, policy: WorkflowStepRetryPolicy(maxAttempts: 3, initialDelayMs: 2_000))
    request.runStartedAt = clock.now()
    do {
      _ = try await runner.run(request)
      XCTFail("expected failure")
    } catch { }
    let session = await store.latestSession(workflowId: "retry-test")
    XCTAssertTrue(session?.executions.first?.failureReason?.contains("stopReason=deadline-exhausted") == true)
    let count = await resolver.count()
    XCTAssertEqual(count, 1)
  }

  func testLegacyStepRunsOnceWithoutSupervisorEvents() async throws {
    let clock = ManualWorkflowRetryClock()
    let resolver = RetryScriptResolver(failures: [])
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(clock.now()))
    let result = try await DeterministicWorkflowRunner(store: store, addonResolver: resolver, retryClock: clock)
      .run(retryRequest(deadline: nil, policy: nil))
    XCTAssertEqual(result.status, .completed)
    let count = await resolver.count()
    XCTAssertEqual(count, 1)
    XCTAssertFalse(result.session.executions.flatMap { $0.recentBackendEvents ?? [] }
      .contains { $0.eventType.hasPrefix("riela.step.") })
  }

  func testNonCooperativeAttemptExpiresWithoutWaitingForAdapter() async throws {
    let clock = ManualWorkflowRetryClock()
    let resolver = BlockingRetryResolver()
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(clock.now()))
    var request = retryRequest(deadline: 1_000, policy: nil)
    request.runStartedAt = clock.now()
    let runner = DeterministicWorkflowRunner(store: store, addonResolver: resolver, retryClock: clock)
    let task = Task { try await runner.run(request) }
    await resolver.waitUntilStarted()
    await clock.waitForSleepers(count: 2)
    clock.advance(byMs: 6_000)
    do {
      _ = try await task.value
      XCTFail("expected timeout")
    } catch { }
    let session = await store.latestSession(workflowId: "retry-test")
    let reason = session?.executions.first?.failureReason ?? ""
    XCTAssertTrue(reason.contains("timeoutKind=step-deadline"))
    XCTAssertTrue(reason.contains("effectOutcome=unknown"))
    let calls = await resolver.count()
    XCTAssertEqual(calls, 1)
    await resolver.release()
  }

  func testCancellationOfBlockedAttemptDoesNotPublishSuccess() async throws {
    let clock = ManualWorkflowRetryClock()
    let resolver = BlockingRetryResolver()
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(clock.now()))
    let runner = DeterministicWorkflowRunner(store: store, addonResolver: resolver, retryClock: clock)
    let task = Task { try await runner.run(retryRequest(deadline: 10_000, policy: nil)) }
    await resolver.waitUntilStarted()
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("expected cancellation")
    } catch is CancellationError {
      // Expected: the supervisor does not wait for the cancellation-ignoring adapter.
    } catch {
      XCTFail("expected CancellationError, got \(error)")
    }
    await resolver.release()
    let session = await store.latestSession(workflowId: "retry-test")
    XCTAssertNotEqual(session?.status, .completed)
  }

  func testRetryAfterRaisesBackoffAndRecordsAttempts() async throws {
    let clock = ObservedRetryClock()
    let resolver = RetryScriptResolver(failures: [AdapterExecutionError(.providerError, "limited",
      isRetryable: true, retryAfter: .seconds(3), effectOutcome: .rejected)])
    let runner = DeterministicWorkflowRunner(addonResolver: resolver, retryClock: clock)
    let task = Task { try await runner.run(retryRequest(deadline: 10_000,
      policy: WorkflowStepRetryPolicy(maxAttempts: 3, initialDelayMs: 1_000))) }
    await clock.waitForSleep(at: 3)
    let before = await resolver.count()
    XCTAssertEqual(before, 1)
    clock.advance(to: 3)
    let result = try await task.value
    let after = await resolver.count()
    XCTAssertEqual(after, 2)
    XCTAssertEqual(result.status, .completed)
    let events = result.session.executions.flatMap { $0.recentBackendEvents ?? [] }
    XCTAssertEqual(events.filter { $0.eventType == "riela.step.attempt.finished" }.count, 2)
    XCTAssertTrue(events.contains { $0.eventType == "riela.step.retry.stopped" && $0.metadata?["stopReason"] == .string("succeeded") })
  }

  func testCancellationDuringBackoffStopsWithoutAnotherDispatch() async throws {
    let clock = ObservedRetryClock()
    let resolver = RetryScriptResolver(failures: [AdapterExecutionError(.providerError, "limited", isRetryable: true)])
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(clock.now()))
    let runner = DeterministicWorkflowRunner(store: store, addonResolver: resolver, retryClock: clock)
    let task = Task { try await runner.run(retryRequest(deadline: 20_000,
      policy: WorkflowStepRetryPolicy(maxAttempts: 3, initialDelayMs: 8_000))) }
    await clock.waitForSleep(at: 8)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("expected cancellation")
    } catch is CancellationError { } catch { XCTFail("expected cancellation, got \(error)") }
    let count = await resolver.count()
    XCTAssertEqual(count, 1)
    let session = await store.latestSession(workflowId: "retry-test")
    XCTAssertNotEqual(session?.status, .completed)
    let events: [WorkflowBackendEventRecord] = session?.executions.flatMap { $0.recentBackendEvents ?? [] } ?? []
    let cancelled = events.contains { event in
      event.eventType == "riela.step.retry.stopped" && event.metadata?["stopReason"] == JSONValue.string("cancelled")
    }
    XCTAssertTrue(cancelled)
  }

  func testCooperativeSlowAttemptExpiresAtStepBackstop() async throws {
    let clock = ObservedRetryClock()
    let resolver = SleepingRetryResolver(clock: clock, delay: 20)
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(clock.now()))
    let runner = DeterministicWorkflowRunner(store: store, addonResolver: resolver, retryClock: clock)
    let task = Task { try await runner.run(retryRequest(deadline: 1_000, policy: nil)) }
    await clock.waitForSleep(at: 20)
    await clock.waitForSleep(at: 6)
    clock.advance(to: 6)
    do { _ = try await task.value; XCTFail("expected timeout") } catch { }
    let session = await store.latestSession(workflowId: "retry-test")
    XCTAssertTrue(session?.executions.first?.failureReason?.contains("timeoutKind=step-deadline") == true)
    XCTAssertNotEqual(session?.status, .completed)
  }

  func testBlockedProjectionExpiresWithoutDispatch() async throws {
    let clock = ObservedRetryClock()
    let projector = BlockingRetryProjector()
    let resolver = RetryScriptResolver(failures: [])
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(clock.now()))
    let runner = DeterministicWorkflowRunner(store: store, addonResolver: resolver,
      attachmentProjector: projector, retryClock: clock)
    let task = Task { try await runner.run(retryRequest(deadline: 1_000, policy: nil)) }
    await projector.waitUntilStarted()
    await clock.waitForSleep(at: 6)
    clock.advance(to: 6)
    do { _ = try await task.value; XCTFail("expected timeout") } catch { }
    let session = await store.latestSession(workflowId: "retry-test")
    XCTAssertTrue(session?.executions.first?.failureReason?.contains("timeoutKind=step-deadline") == true)
    let count = await resolver.count()
    XCTAssertEqual(count, 0)
    await projector.release()
  }

  func testLateProjectionCannotDispatchOrChangeFailure() async throws {
    let clock = ObservedRetryClock()
    let projector = BlockingRetryProjector()
    let resolver = RetryScriptResolver(failures: [])
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(clock.now()))
    let runner = DeterministicWorkflowRunner(store: store, addonResolver: resolver,
      attachmentProjector: projector, retryClock: clock)
    let task = Task { try await runner.run(retryRequest(deadline: 1_000, policy: nil)) }
    await projector.waitUntilStarted()
    await clock.waitForSleep(at: 6)
    clock.advance(to: 6)
    do { _ = try await task.value; XCTFail("expected timeout") } catch { }
    let before = await store.latestSession(workflowId: "retry-test")
    await projector.release()
    await projector.waitUntilReturned()
    let after = await store.latestSession(workflowId: "retry-test")
    let count = await resolver.count()
    XCTAssertEqual(count, 0)
    XCTAssertEqual(after?.executions.first?.failureReason, before?.executions.first?.failureReason)
    XCTAssertNotEqual(after?.status, .completed)
  }

  func testLateAdapterSuccessDoesNotReplaceTimeout() async throws {
    let clock = ObservedRetryClock()
    let resolver = BlockingRetryResolver()
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(clock.now()))
    let runner = DeterministicWorkflowRunner(store: store, addonResolver: resolver, retryClock: clock)
    let task = Task { try await runner.run(retryRequest(deadline: 1_000, policy: nil)) }
    await resolver.waitUntilStarted()
    await clock.waitForSleep(at: 6)
    clock.advance(to: 6)
    do { _ = try await task.value; XCTFail("expected timeout") } catch { }
    let before = await store.latestSession(workflowId: "retry-test")
    await resolver.release()
    await resolver.waitUntilReturned()
    let after = await store.latestSession(workflowId: "retry-test")
    XCTAssertTrue(before?.executions.first?.failureReason?.contains("effectOutcome=unknown") == true)
    XCTAssertEqual(after?.executions.first?.failureReason, before?.executions.first?.failureReason)
    XCTAssertNotEqual(after?.status, .completed)
  }

  func testStaleAttemptTimerDoesNotExpireBackoffOrNextAttempt() async throws {
    let clock = ObservedRetryClock()
    let resolver = TimedRetryResolver(clock: clock)
    let runner = DeterministicWorkflowRunner(addonResolver: resolver, retryClock: clock)
    var request = retryRequest(deadline: 600_000,
      policy: WorkflowStepRetryPolicy(maxAttempts: 3, initialDelayMs: 8_000, maxDelayMs: 8_000))
    request.workflow.steps[0].timeoutMs = 2_000
    let task = Task { try await runner.run(request) }
    await clock.waitForSleep(at: 1)
    clock.advance(to: 1)
    await clock.waitForSleep(at: 9)
    clock.advance(to: 7)
    let before = await resolver.count()
    XCTAssertEqual(before, 1)
    clock.advance(to: 9)
    await clock.waitForSleep(at: 10.5)
    clock.advance(to: 10.5)
    let result = try await task.value
    let after = await resolver.count()
    XCTAssertEqual(after, 2)
    XCTAssertEqual(result.status, .completed)
    let events = result.session.executions.flatMap { $0.recentBackendEvents ?? [] }
    XCTAssertFalse(events.contains { $0.metadata?["timeoutSource"] == .string("runner-backstop") })
  }

  func testUnknownOutcomeFanoutBranchFailsAndAdvisoryContinues() async throws {
    for advisory in [false, true] {
      let adapter = RetryFanoutAdapter()
      let resolver = RetryScriptResolver(failures: [AdapterExecutionError(.providerError, "ambiguous",
        isRetryable: true, effectOutcome: .unknown)])
      let workflow = retryFanoutWorkflow(advisory: advisory)
      let payloads = Dictionary(uniqueKeysWithValues: ["source", "downstream", "join"].map {
        ($0, AgentNodePayload(id: $0, executionBackend: .codexAgent, model: "test", agentSandbox: .readOnly))
      })
      let runner = DeterministicWorkflowRunner(adapter: adapter, addonResolver: resolver)
      let result = try await runner.run(.init(workflow: workflow, nodePayloads: payloads))
      XCTAssertEqual(result.status, .completed)
      let capturedJoin = await adapter.latestJoin()
      let join = try XCTUnwrap(capturedJoin)
      guard case let .array(branches)? = join["branches"], case let .object(branch)? = branches.first else {
        return XCTFail("missing fanout branch")
      }
      XCTAssertEqual(branch["status"], .string(advisory ? "completed" : "failed"))
      XCTAssertNotNil(branch["item"])
      if !advisory {
        guard case let .string(reason)? = branch["failureReason"] else { return XCTFail("missing failure reason") }
        XCTAssertTrue(reason.contains("[rielaRetry"))
      }
      let downstreamCalls = await adapter.downstreamCount()
      XCTAssertEqual(downstreamCalls, advisory ? 1 : 0)
    }
  }

  func testSuccessfulEffectIsPublishedAfterSlowPublicationCrossesDeadline() async throws {
    let clock = ObservedRetryClock()
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(clock.now()))
    let publisher = SlowRetryPublisher(store: store, clock: clock)
    let resolver = RetryScriptResolver(failures: [])
    let runner = DeterministicWorkflowRunner(store: store, addonResolver: resolver, publisher: publisher, retryClock: clock)
    let task = Task { try await runner.run(retryRequest(deadline: 1_000, policy: nil)) }
    await clock.waitForSleep(at: 2)
    clock.advance(to: 2)
    let result = try await task.value
    XCTAssertEqual(result.status, .completed)
    let session = await store.latestSession(workflowId: "retry-test")
    let events = session?.executions.flatMap { $0.recentBackendEvents ?? [] } ?? []
    XCTAssertTrue(events.contains { $0.eventType == "riela.step.deadline.exceededAfterSuccess" })
  }

  private func assertFailure(_ error: AdapterExecutionError, reason: String, calls: Int) async throws {
    let clock = ManualWorkflowRetryClock()
    let resolver = RetryScriptResolver(failures: Array(repeating: error, count: 3))
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(clock.now()))
    let runner = DeterministicWorkflowRunner(store: store, addonResolver: resolver, retryClock: clock)
    let policy = WorkflowStepRetryPolicy(maxAttempts: 3, initialDelayMs: 0, maxDelayMs: 60_000)
    do {
      _ = try await runner.run(retryRequest(deadline: 10_000, policy: policy))
      XCTFail("expected failure")
    } catch { }
    let session = await store.latestSession(workflowId: "retry-test")
    XCTAssertTrue(session?.executions.first?.failureReason?.contains("stopReason=\(reason)") == true)
    let count = await resolver.count()
    XCTAssertEqual(count, calls)
  }
}

private func retryRequest(deadline: Int?, policy: WorkflowStepRetryPolicy?) -> DeterministicWorkflowRunRequest {
  let addon = WorkflowNodeAddonRef(name: "test/retry")
  return DeterministicWorkflowRunRequest(workflow: WorkflowDefinition(
    workflowId: "retry-test", defaults: WorkflowDefaults(nodeTimeoutMs: 0, maxLoopIterations: 3),
    entryStepId: "save", nodeRegistry: [WorkflowNodeRegistryRef(id: "save-node", addon: addon)],
    steps: [WorkflowStepRef(id: "save", nodeId: "save-node", deadlineMs: deadline, retry: policy)],
    nodes: [WorkflowNodeRef(id: "save-node", addon: addon)]
  ))
}

private actor RetryScriptResolver: WorkflowAddonResolving {
  private var failures: [AdapterExecutionError]
  private var callCount = 0
  private var deadlines: [Date?] = []
  init(failures: [AdapterExecutionError]) { self.failures = failures }
  func count() -> Int { callCount }
  func capturedDeadlines() -> [Date?] { deadlines }
  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    callCount += 1
    deadlines.append(context.deadline)
    if !failures.isEmpty { throw failures.removeFirst() }
    return AdapterExecutionOutput(provider: "test", model: input.addon.name, promptText: "", completionPassed: true,
                                  payload: ["status": .string("ok")])
  }
}

private actor BlockingRetryResolver: WorkflowAddonResolving {
  private var calls = 0
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var completion: CheckedContinuation<Void, Never>?
  private var released = false
  private var returned = false
  private var returnWaiters: [CheckedContinuation<Void, Never>] = []

  func waitUntilReturned() async {
    if returned { return }
    await withCheckedContinuation { returnWaiters.append($0) }
  }

  func count() -> Int { calls }

  func waitUntilStarted() async {
    if calls > 0 { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func release() {
    released = true
    completion?.resume()
    completion = nil
  }

  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    calls += 1
    startWaiters.forEach { $0.resume() }
    startWaiters.removeAll()
    if !released {
      await withCheckedContinuation { completion = $0 }
    }
    returned = true
    returnWaiters.forEach { $0.resume() }
    returnWaiters.removeAll()
    return AdapterExecutionOutput(provider: "test", model: input.addon.name, promptText: "", completionPassed: true,
                                  payload: ["status": .string("late")])
  }
}

private final class ObservedRetryClock: WorkflowRetryClock, @unchecked Sendable {
  private let clock = ManualWorkflowRetryClock()
  private let lock = NSLock()
  private var targets = Set<Date>()
  private var waiters: [(Date, CheckedContinuation<Void, Never>)] = []

  func now() -> Date { clock.now() }
  func advance(to seconds: TimeInterval) { clock.advance(to: Date(timeIntervalSince1970: seconds)) }

  func sleep(until: Date) async throws {
    let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      targets.insert(until)
      let found = waiters.filter { $0.0 == until }.map(\.1)
      waiters.removeAll { $0.0 == until }
      return found
    }
    ready.forEach { $0.resume() }
    try await clock.sleep(until: until)
  }

  func waitForSleep(at seconds: TimeInterval) async {
    let target = Date(timeIntervalSince1970: seconds)
    await withCheckedContinuation { continuation in
      let ready = lock.withLock { () -> Bool in
        if targets.contains(target) { return true }
        waiters.append((target, continuation))
        return false
      }
      if ready { continuation.resume() }
    }
  }
}

private actor BlockingRetryProjector: WorkflowAddonAttachmentProjecting {
  private var started = false
  private var returned = false
  private var released = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var returnWaiters: [CheckedContinuation<Void, Never>] = []
  private var completion: CheckedContinuation<Void, Never>?

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }
  func waitUntilReturned() async {
    if returned { return }
    await withCheckedContinuation { returnWaiters.append($0) }
  }
  func release() { released = true; completion?.resume(); completion = nil }
  func project(_ request: WorkflowAddonAttachmentProjectionRequest) async throws -> [String: WorkflowAddonAttachmentValue] {
    started = true
    startWaiters.forEach { $0.resume() }
    startWaiters.removeAll()
    if !released { await withCheckedContinuation { completion = $0 } }
    returned = true
    returnWaiters.forEach { $0.resume() }
    returnWaiters.removeAll()
    return [:]
  }
}

private actor SleepingRetryResolver: WorkflowAddonResolving {
  let clock: ObservedRetryClock
  let delay: TimeInterval
  init(clock: ObservedRetryClock, delay: TimeInterval) { self.clock = clock; self.delay = delay }
  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    try await clock.sleep(until: clock.now().addingTimeInterval(delay))
    return AdapterExecutionOutput(provider: "test", model: input.addon.name, promptText: "", completionPassed: true, payload: [:])
  }
}

private actor TimedRetryResolver: WorkflowAddonResolving {
  let clock: ObservedRetryClock
  private var calls = 0
  init(clock: ObservedRetryClock) { self.clock = clock }
  func count() -> Int { calls }
  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    calls += 1
    let call = calls
    try await clock.sleep(until: clock.now().addingTimeInterval(call == 1 ? 1 : 1.5))
    if call == 1 { throw AdapterExecutionError(.providerError, "transient", isRetryable: true) }
    return AdapterExecutionOutput(provider: "test", model: input.addon.name, promptText: "", completionPassed: true, payload: [:])
  }
}

private struct SlowRetryPublisher: WorkflowOutputPublishing {
  let backing: InMemoryWorkflowOutputPublisher
  let clock: ObservedRetryClock
  init(store: any WorkflowRuntimeStore, clock: ObservedRetryClock) {
    self.backing = InMemoryWorkflowOutputPublisher(store: store)
    self.clock = clock
  }
  func publishAcceptedOutput(_ request: WorkflowPublicationRequest) async throws -> WorkflowPublicationResult {
    try await clock.sleep(until: clock.now().addingTimeInterval(2))
    return try await backing.publishAcceptedOutput(request)
  }
}

private actor RetryFanoutAdapter: NodeAdapter {
  private var join: JSONObject?
  private var downstreamCalls = 0
  func latestJoin() -> JSONObject? { join }
  func downstreamCount() -> Int { downstreamCalls }
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    var payload: JSONObject = [:]
    if input.node.id == "source" {
      payload = ["payload": .object(["items": .array([.object(["id": .string("one")])])])]
    } else if input.node.id == "downstream" {
      downstreamCalls += 1
    } else if input.node.id == "join" {
      let variables = input.mergedVariables
      if case let .object(runtime)? = variables["runtimeVariables"], case let .object(value)? = runtime["fanoutJoin"] {
        join = value
      } else if case let .object(value)? = variables["fanoutJoin"] { join = value }
    }
    return AdapterExecutionOutput(provider: "test", model: input.node.model, promptText: input.promptText,
      completionPassed: true, payload: payload)
  }
}

private func retryFanoutWorkflow(advisory: Bool) -> WorkflowDefinition {
  let addon = WorkflowNodeAddonRef(name: "test/retry")
  let ordinary = ["source", "downstream", "join"]
  return WorkflowDefinition(workflowId: "retry-fanout", defaults: WorkflowDefaults(nodeTimeoutMs: 0, maxLoopIterations: 3),
    entryStepId: "source", nodeRegistry: ordinary.map { WorkflowNodeRegistryRef(id: $0, nodeFile: "nodes/\($0).json") }
      + [WorkflowNodeRegistryRef(id: "save", addon: addon)], steps: [
        WorkflowStepRef(id: "source", nodeId: "source", transitions: [
          WorkflowStepTransition(toStepId: "save", fanout: WorkflowStepFanout(groupId: "save-group",
            itemsFrom: "/payload/items", itemVariable: "feature", concurrency: 1, joinStepId: "join",
            failurePolicy: .collectPartial, resultOrder: .input, writeOwnership: WorkflowFanoutWriteOwnership(mode: .readOnly)))
        ]),
        WorkflowStepRef(id: "save", nodeId: "save", failurePolicy: advisory ? .advisory : nil,
          transitions: [WorkflowStepTransition(toStepId: "downstream")], deadlineMs: 10_000),
        WorkflowStepRef(id: "downstream", nodeId: "downstream", transitions: [WorkflowStepTransition(toStepId: "join")]),
        WorkflowStepRef(id: "join", nodeId: "join")
      ], nodes: ordinary.map { WorkflowNodeRef(id: $0, nodeFile: "nodes/\($0).json") } + [WorkflowNodeRef(id: "save", addon: addon)])
}
