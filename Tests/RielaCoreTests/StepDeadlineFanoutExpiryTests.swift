import Foundation
@testable import RielaCore
import XCTest

final class StepDeadlineFanoutExpiryTests: XCTestCase {
  func testQueuedBranchesExpireWhileRunningBranchContinues() async throws {
    let clock = ManualWorkflowRetryClock()
    let gate = ExpiryGate()
    let tracker = FanoutBranchTracker(delaysByIndex: [:])
    let resolver = ExpiryAddonResolver()
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 0)))
    let runner = DeterministicWorkflowRunner(
      store: store, adapter: ExpiryAdapter(gate: gate, tracker: tracker),
      addonResolver: resolver, retryClock: clock
    )
    let task = Task { try await runner.run(expiryRequest(deadline: 1_000)) }
    await gate.waitUntilEntered()
    await clock.waitForSleepers(count: 1)
    clock.advance(byMs: 1_000)
    let sessionsBeforeRelease = await store.sessions.count
    XCTAssertEqual(sessionsBeforeRelease, 2)
    await gate.release()
    _ = try await task.value
    let capturedJoin = await tracker.joinRuntimeFanout()
    let join = try XCTUnwrap(capturedJoin)
    guard case let .array(branches)? = join["branches"] else { return XCTFail("missing branches") }
    XCTAssertEqual(branches.count, 3)
    for index in 0..<3 {
      guard case let .object(record) = branches[index] else { return XCTFail("invalid branch") }
      XCTAssertEqual(record["index"], .integer(Int64(index)))
      if index == 0 {
        XCTAssertEqual(record["status"], .string("completed"))
      } else {
        XCTAssertEqual(record["status"], .string("failed"))
        XCTAssertEqual(record["item"], .object(["index": .integer(Int64(index))]))
        XCTAssertNil(record["sessionId"])
        guard case let .string(reason)? = record["failureReason"] else { return XCTFail("missing reason") }
        XCTAssertTrue(reason.contains("attempts=0"))
        XCTAssertTrue(reason.contains("stopReason=step-deadline"))
      }
    }
    let count = await resolver.count()
    XCTAssertEqual(count, 1)
  }

  func testNoDeadlineAndAllBranchesBeforeDeadline() async throws {
    var baseline: [JSONObject]?
    for deadline: Int? in [nil, 1_000] {
      let clock = CountingExpiryClock()
      let gate = ExpiryGate()
      let tracker = FanoutBranchTracker(delaysByIndex: [:])
      let resolver = ExpiryAddonResolver()
      let runner = DeterministicWorkflowRunner(
        store: InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 0))), adapter: ExpiryAdapter(gate: gate, tracker: tracker),
        addonResolver: resolver, retryClock: clock
      )
      let task = Task { try await runner.run(expiryRequest(deadline: deadline)) }
      await gate.waitUntilEntered()
      await gate.release()
      _ = try await task.value
      let captured = await tracker.joinRuntimeFanout()
      let join = try XCTUnwrap(captured)
      guard case let .array(branches)? = join["branches"] else { return XCTFail("missing branches") }
      XCTAssertEqual(branches.count, 3)
      for branch in branches {
        guard case let .object(record) = branch else { return XCTFail("invalid branch") }
        XCTAssertEqual(record["status"], .string("completed"))
      }
      let count = await resolver.count()
      XCTAssertEqual(count, 3)
      XCTAssertEqual(clock.activeSleepers(), 0)
      let normalized = branches.compactMap { value -> JSONObject? in
        guard case var .object(record) = value else { return nil }
        record.removeValue(forKey: "sessionId")
        return record
      }
      if let baseline { XCTAssertEqual(normalized, baseline) } else { baseline = normalized }
    }
  }

  func testFailFastWithDeadlineDoesNotReportTimerCancellation() async throws {
    let clock = ManualWorkflowRetryClock()
    let resolver = ExpiryAddonResolver(fail: true)
    let tracker = FanoutBranchTracker(delaysByIndex: [:])
    let runner = DeterministicWorkflowRunner(
      store: InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 0))), adapter: ExpiryAdapter(gate: ExpiryGate(), tracker: tracker),
      addonResolver: resolver, retryClock: clock
    )
    var request = expiryRequest(deadline: 1_000)
    request.workflow.steps[0].transitions?[0].fanout?.failurePolicy = .failFast
    do {
      _ = try await runner.run(request)
      XCTFail("expected fanout failure")
    } catch DeterministicWorkflowRunnerError.fanoutDispatchFailed(_, let reason) {
      XCTAssertTrue(reason.contains("branch 0 failed"), reason)
    }
    let count = await resolver.count()
    XCTAssertEqual(count, 1)
  }

  func testBranchEntryDeadlineAnchoredAtFanoutDispatch() async throws {
    let clock = ManualWorkflowRetryClock()
    let gate = ExpiryGate()
    let tracker = FanoutBranchTracker(delaysByIndex: [:])
    let resolver = ExpiryAddonResolver()
    let runner = DeterministicWorkflowRunner(
      store: InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 0))), adapter: ExpiryAdapter(gate: gate, tracker: tracker, itemCount: 2),
      addonResolver: resolver, retryClock: clock
    )
    let task = Task { try await runner.run(expiryRequest(deadline: 1_000)) }
    await gate.waitUntilEntered()
    clock.advance(byMs: 400)
    await gate.release()
    _ = try await task.value
    let deadlines = await resolver.deadlines()
    guard deadlines.count >= 2 else { return XCTFail("missing second branch deadline") }
    XCTAssertEqual(deadlines[1], Date(timeIntervalSince1970: 1))
  }
}

private func expiryRequest(deadline: Int?) -> DeterministicWorkflowRunRequest {
  var workflow = fanoutWorkflow(concurrency: 1, failurePolicy: .collectPartial)
  workflow.defaults.nodeTimeoutMs = 0
  workflow.nodeRegistry[1] = WorkflowNodeRegistryRef(id: "branch-node", addon: WorkflowNodeAddonRef(name: "test/entry"))
  workflow.nodes[1] = WorkflowNodeRef(id: "branch-node", addon: WorkflowNodeAddonRef(name: "test/entry"))
  workflow.nodeRegistry.append(WorkflowNodeRegistryRef(id: "gate-node", nodeFile: "nodes/gate.json"))
  workflow.nodes.append(WorkflowNodeRef(id: "gate-node", nodeFile: "nodes/gate.json"))
  workflow.steps[1] = WorkflowStepRef(id: "branch", nodeId: "branch-node",
    transitions: [WorkflowStepTransition(toStepId: "gate")], deadlineMs: deadline)
  workflow.steps.append(WorkflowStepRef(id: "gate", nodeId: "gate-node", transitions: [WorkflowStepTransition(toStepId: "join")]))
  var payloads = fanoutPayloads()
  payloads.removeValue(forKey: "branch-node")
  payloads["gate-node"] = AgentNodePayload(id: "gate", executionBackend: .codexAgent, model: "test", agentSandbox: .readOnly)
  return DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: payloads)
}

private actor ExpiryGate {
  private var entered = false
  private var released = false
  private var entryWaiter: CheckedContinuation<Void, Never>?
  private var releaseWaiter: CheckedContinuation<Void, Never>?
  func wait() async {
    guard !entered else { return }
    entered = true
    entryWaiter?.resume()
    if !released { await withCheckedContinuation { releaseWaiter = $0 } }
  }
  func waitUntilEntered() async {
    if !entered { await withCheckedContinuation { entryWaiter = $0 } }
  }
  func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}

private actor ExpiryAddonResolver: WorkflowAddonResolving {
  private var values: [Date?] = []
  private let fail: Bool
  init(fail: Bool = false) { self.fail = fail }
  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    values.append(context.deadline)
    if fail { throw AdapterExecutionError(.providerError, "forced failure") }
    return AdapterExecutionOutput(provider: "test", model: input.addon.name, promptText: "", completionPassed: true,
      payload: ["status": .string("ok")])
  }
  func count() -> Int { values.count }
  func deadlines() -> [Date?] { values }
}

private struct ExpiryAdapter: NodeAdapter {
  let gate: ExpiryGate
  let tracker: FanoutBranchTracker
  var itemCount: Int = 3
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    if input.node.id == "source", itemCount == 2 {
      return AdapterExecutionOutput(provider: "test", model: input.node.model, promptText: input.promptText,
        completionPassed: true, payload: ["payload": .object(["items": .array([
          .object(["index": .integer(0)]), .object(["index": .integer(1)])
        ])])])
    }
    if input.node.id == "gate" {
      await gate.wait()
      return AdapterExecutionOutput(provider: "test", model: input.node.model, promptText: input.promptText,
        completionPassed: true, payload: ["status": .string("ok")])
    }
    return try await FanoutTestAdapter(tracker: tracker).execute(input, context: context)
  }
}

private final class CountingExpiryClock: WorkflowRetryClock, @unchecked Sendable {
  private let clock = ManualWorkflowRetryClock()
  private let lock = NSLock()
  private var count = 0
  func now() -> Date { clock.now() }
  func sleep(until date: Date) async throws {
    lock.withLock { count += 1 }
    defer { lock.withLock { count -= 1 } }
    try await clock.sleep(until: date)
  }
  func activeSleepers() -> Int { lock.withLock { count } }
}
