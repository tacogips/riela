import Foundation
import XCTest
@testable import RielaCore

final class ActivitySettlementRunnerTests: XCTestCase {
  func testRunnerCompletionRecordsZeroClosedCounts() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let result = try await Self.run(.success, root: root)
    let page = try BotStore(sessionStoreRoot: root.path).activityPage(sessionId: result.session.sessionId)
    XCTAssertEqual(page.events.map(\.kind), [.stepStarted, .stepFinished, .settled])
    XCTAssertEqual(page.events.first?.payload["requestedModel"], .string("test-model"))
    XCTAssertEqual(page.events.last?.payload["reason"], .string("completed"))
    XCTAssertEqual(page.events.last?.payload["closed"], .object([
      "toolCalls": .integer(0), "planEntries": .integer(0), "subagents": .integer(0), "permissionRequests": .integer(0)
    ]))
    XCTAssertNil(page.state?.currentExecutionId)
  }

  func testProviderErrorInterruptsOpenTool() async throws {
    try await checkFailure(.providerError, reason: .providerError, status: "failed")
  }

  func testCancellationInterruptsOpenTool() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (signals, signal) = AsyncStream<Void>.makeStream()
    let started: @Sendable () -> Void = { _ = signal.yield(()) }
    let task = Task<WorkflowRunResult, Error> { @Sendable in
      defer { signal.finish() }
      return try await Self.run(.cancel, root: root, started: started)
    }
    var iterator = signals.makeAsyncIterator()
    guard await iterator.next() != nil else {
      _ = await task.result
      return XCTFail("Adapter did not reach the cancellation barrier")
    }
    task.cancel()
    guard case let .failure(error) = await task.result, error is CancellationError else {
      return XCTFail("Workflow did not propagate task cancellation")
    }
    try assertSettlement(root, reason: .cancelled, status: "cancelled")
  }

  func testDeadlineFailureSettlesAsTimeout() async throws {
    try await checkFailure(.timeout, reason: .timeout, status: "failed")
  }

  func testProcessExitSettlesOpenStateOnlyOnce() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = SQLiteWorkflowActivityRecorder(sessionStoreRoot: root.path)
    let store = BotStore(sessionStoreRoot: root.path)
    let at = Date()
    await recorder.stepStarted(
      sessionId: "orphan", executionId: "execution", stepId: "step", nodeId: "node", backend: nil, requestedModel: nil, at: at
    )
    await recorder.record(
      sessionId: "orphan", executionId: "execution", update: .toolCall(.init(toolCallId: "open", status: "pending")), at: at
    )
    XCTAssertTrue(try store.settleOpenActivity(sessionId: "orphan", reason: .processExit, at: at))
    XCTAssertFalse(try store.settleOpenActivity(sessionId: "orphan", reason: .processExit, at: at))
    let page = try store.activityPage(sessionId: "orphan")
    XCTAssertEqual(page.events.map(\.kind), [.stepStarted, .toolCall, .stepFinished, .settled])
    XCTAssertEqual(page.events.last?.payload["reason"], .string("processExit"))
    XCTAssertEqual(page.state?.toolCalls.first?.status, "interrupted")
  }

  func testWithoutRecorderOutputIsTheSameAndJournalIsEmpty() async throws {
    let recordedRoot = temporaryRoot()
    let unrecordedRoot = temporaryRoot()
    defer {
      try? FileManager.default.removeItem(at: recordedRoot)
      try? FileManager.default.removeItem(at: unrecordedRoot)
    }
    let recorded = try await Self.run(.message, root: recordedRoot)
    let unrecorded = try await Self.run(.message, root: unrecordedRoot, withRecorder: false)
    XCTAssertEqual(recorded.rootOutput, unrecorded.rootOutput)
    XCTAssertEqual(recorded.session.status, unrecorded.session.status)
    let store = BotStore(sessionStoreRoot: unrecordedRoot.path)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.databasePath))
    XCTAssertTrue(try store.activityPage(sessionId: unrecorded.session.sessionId).events.isEmpty)
  }

  private func checkFailure(
    _ mode: SettlementAdapter.Mode, reason: ActivitySettleReason, status: String
  ) async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    do {
      _ = try await Self.run(mode, root: root)
      XCTFail("Expected adapter failure")
    } catch {
      try assertSettlement(root, reason: reason, status: status)
    }
  }

  private func assertSettlement(_ root: URL, reason: ActivitySettleReason, status: String) throws {
    let page = try BotStore(sessionStoreRoot: root.path).activityPage(sessionId: "activity-runner-session-1")
    XCTAssertEqual(page.events.map(\.kind), [.stepStarted, .toolCall, .stepFinished, .settled])
    XCTAssertEqual(page.events.first { $0.kind == .stepFinished }?.payload["status"], .string(status))
    XCTAssertEqual(page.events.last?.payload["reason"], .string(reason.rawValue))
    XCTAssertEqual(page.state?.toolCalls.first?.status, "interrupted")
    XCTAssertNil(page.state?.currentExecutionId)
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  private static func run(
    _ mode: SettlementAdapter.Mode, root: URL, withRecorder: Bool = true, started: (@Sendable () -> Void)? = nil
  ) async throws -> WorkflowRunResult {
    let workflow = WorkflowDefinition(
      workflowId: "activity-runner", defaults: .init(nodeTimeoutMs: 120_000, maxLoopIterations: 3), entryStepId: "step",
      nodeRegistry: [.init(id: "node", nodeFile: "nodes/node.json")],
      steps: [.init(id: "step", nodeId: "node")],
      nodes: [.init(id: "step", nodeFile: "nodes/node.json")]
    )
    let runner = DeterministicWorkflowRunner(
      store: InMemoryWorkflowRuntimeStore(), adapter: SettlementAdapter(mode: mode, started: started)
    )
    var request = DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["node": .init(id: "node", executionBackend: .codexAgent, model: "test-model", agentSandbox: .readOnly)],
      timeoutMs: mode == .timeout ? 1 : nil, memoryRootDirectory: root.path
    )
    if withRecorder {
      request.activityRecorder = SQLiteWorkflowActivityRecorder(sessionStoreRoot: root.path)
    }
    return try await runner.run(request)
  }
}

private struct SettlementAdapter: NodeAdapter {
  enum Mode {
    case success, message, providerError, timeout, cancel
  }

  let mode: Mode
  let started: (@Sendable () -> Void)?

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    switch mode {
    case .success:
      break
    case .message:
      await context.backendEventHandler?(.init(
        provider: "test", eventType: "message", activity: .message(messageId: "m", text: "Done", replace: false)
      ))
    case .providerError, .timeout, .cancel:
      await context.backendEventHandler?(.init(
        provider: "test", eventType: "tool", activity: .toolCall(.init(toolCallId: "open", status: "in_progress"))
      ))
      switch mode {
      case .providerError:
        throw AdapterExecutionError(.providerError, "provider failed")
      case .timeout:
        guard let deadline = context.deadline else { throw AdapterExecutionError(.providerError, "missing deadline") }
        let remaining = max(0, deadline.timeIntervalSinceNow)
        try await Task.sleep(for: .seconds(remaining))
        throw AdapterExecutionError(.timeout, "deadline passed")
      case .cancel:
        started?()
        try await Task.sleep(for: .seconds(30))
        throw AdapterExecutionError(.providerError, "task was not cancelled")
      case .success, .message:
        break
      }
    }
    return AdapterExecutionOutput(
      provider: "test", model: input.node.model, promptText: input.promptText,
      completionPassed: true, payload: ["status": .string("ok")]
    )
  }
}
