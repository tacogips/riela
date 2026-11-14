import Foundation
import XCTest
@testable import RielaCore

final class OperatorCancellationReasonFinalizeTests: XCTestCase {
  private let reason = "operator_cancelled by rielaapp-api:default: dup"

  func testTaskCancellationRecordsOperatorReasonOnSessionAndStep() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let adapter = BlockingCancellationAdapter()
    let runner = DeterministicWorkflowRunner(store: store, adapter: adapter)
    var request = makeRequest()
    request.cancellationReason = { "operator_cancelled by rielaapp-api:default: dup" }
    let task = Task { try await runner.run(request) }
    await adapter.waitUntilStarted()
    task.cancel()
    await XCTAssertThrowsErrorAsync(try await task.value)
    let session = try await session(store)
    XCTAssertEqual(session.status, .cancelled)
    XCTAssertEqual(session.failureKind, .cancelled)
    XCTAssertEqual(session.failureReason, reason)
    XCTAssertEqual(session.executions.first?.status, .cancelled)
    XCTAssertEqual(session.executions.first?.failureReason, reason)
  }

  func testMissingAndNilReasonsKeepDefault() async throws {
    for reasonClosure: (@Sendable () -> String?)? in [nil, { nil }] {
      let store = InMemoryWorkflowRuntimeStore()
      var request = makeRequest()
      request.cancellationReason = reasonClosure
      await XCTAssertThrowsErrorAsync(try await DeterministicWorkflowRunner(store: store, adapter: CancellingAdapter()).run(request))
      let result = try await session(store)
      XCTAssertEqual(result.failureKind, .cancelled)
      XCTAssertEqual(result.failureReason, "workflow run cancelled")
    }
  }

  func testHandoverTakesPrecedence() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    var request = makeRequest()
    request.cancellationCause = { .stalled }
    request.cancellationReason = { "operator reason" }
    await XCTAssertThrowsErrorAsync(try await DeterministicWorkflowRunner(store: store, adapter: CancellingAdapter()).run(request))
    let result = try await session(store)
    XCTAssertEqual(result.failureKind, .stalled)
    XCTAssertEqual(result.failureReason, "task handover trigger: stalled")
  }

  func testAdapterFailureDoesNotConsultReason() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let counter = ReasonCounter()
    var request = makeRequest()
    request.cancellationReason = { counter.read() }
    await XCTAssertThrowsErrorAsync(try await DeterministicWorkflowRunner(store: store, adapter: FailingAdapter()).run(request))
    let result = try await session(store)
    XCTAssertEqual(result.failureKind, .adapterFailure)
    XCTAssertEqual(result.failureReason, "provider_error: forced failure")
    XCTAssertEqual(counter.count, 0)
  }

  func testCompletedRunIsFinalizedOnceBeforeLateCancellation() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let recorder = WorkflowRunEventRecorder()
    let counter = ReasonCounter()
    var request = makeRequest()
    request.eventHandler = { event in await recorder.append(event) }
    request.cancellationReason = { counter.read() }
    let output = AdapterExecutionOutput(provider: "test", model: "gpt-5.5", promptText: "prompt", completionPassed: true,
                                        payload: ["status": .string("ok")])
    let runner = DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: output))
    let task = Task { try await runner.run(request) }
    let result = try await task.value
    counter.enable()
    task.cancel()
    let persisted = try await session(store)
    let events = await recorder.events()
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(persisted.status, .completed)
    XCTAssertEqual(events.filter { $0.type == .sessionCompleted }.count, 1)
    XCTAssertEqual(counter.count, 0)
  }

  private func makeRequest() -> DeterministicWorkflowRunRequest {
    let workflow = WorkflowDefinition(
      workflowId: "runner", defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step", nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [WorkflowStepRef(id: "step", nodeId: "node")],
      nodes: [WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json")]
    )
    return DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: [
      "node": AgentNodePayload(id: "node", executionBackend: .codexAgent, model: "gpt-5.5", agentSandbox: .readOnly)
    ])
  }

  private func session(_ store: InMemoryWorkflowRuntimeStore) async throws -> WorkflowSession {
    let result = await store.loadSessionForTest(id: "runner-session-1")
    return try XCTUnwrap(result)
  }
}

private actor BlockingCancellationAdapter: NodeAdapter {
  private var started = false
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    started = true
    try await Task.sleep(for: .seconds(60))
    throw CancellationError()
  }
  func waitUntilStarted() async {
    while !started { await Task.yield() }
  }
}

private final class ReasonCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var reads = 0
  private var enabled = false
  var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
  func read() -> String? {
    lock.lock(); defer { lock.unlock() }
    reads += 1
    return enabled ? "late reason" : nil
  }
  func enable() { lock.lock(); defer { lock.unlock() }; enabled = true }
}
