import Foundation
import XCTest
@testable import RielaCore

final class BotMemoryPromptInjectionTests: XCTestCase {
  func testOnlyNonemptyBotMemoryChangesPrompt() async throws {
    let plain = try await capture().input
    for block in [nil, ""] {
      let input = try await capture(context: BotRunContext(botId: "bot", permissionWaitMs: 0, memoryBlock: block)).input
      XCTAssertEqual(input.systemPromptText, plain.systemPromptText)
      XCTAssertEqual(input.promptText, plain.promptText)
    }
    let input = try await capture(context: .init(botId: "bot", permissionWaitMs: 0, memoryBlock: "Keep releases small.")).input
    XCTAssertEqual(input.systemPromptText, [plain.systemPromptText, "Keep releases small."].compactMap { $0 }.joined(separator: "\n\n"))
    XCTAssertEqual(input.promptText, plain.promptText)
  }

  func testSuccessfulSpillRetainsMemoryInFinalPromptAndMeasurement() async throws {
    let baseline = try await capture(budget: 2_000, largeVariable: true)
    let block = "Bot memory: 日本語"
    let context = BotRunContext(botId: "bot", permissionWaitMs: 0, memoryBlock: block)
    let result = try await capture(context: context, budget: 2_000, largeVariable: true)
    XCTAssertEqual(result.evidence["outcome"], .string("spilled"))
    let system = try XCTUnwrap(result.input.systemPromptText)
    XCTAssertTrue(system.contains("$rielaSpilled"))
    XCTAssertTrue(system.hasSuffix("\n\n" + block))
    let fresh = result.input.resolvedFreshPromptText
    let resumed = result.input.resolvedResumedPromptText
    XCTAssertEqual(result.evidence["finalBytes"], .integer(Int64(system.utf8.count + max(fresh.utf8.count, resumed.utf8.count))))
    guard case let .integer(unlinkedBytes)? = baseline.evidence["measuredBytes"] else {
      return XCTFail("Missing initial prompt measurement")
    }
    XCTAssertEqual(result.evidence["measuredBytes"], .integer(unlinkedBytes + Int64(block.utf8.count + 2)))
  }

  func testMemoryAloneCanExceedBudgetBeforeAdapterRuns() async throws {
    _ = try await capture(budget: 2_000)
    let adapter = BotMemoryCapturingAdapter()
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(store: store, adapter: adapter)
    var request = request(budget: 2_000)
    request.botContext = .init(botId: "bot", permissionWaitMs: 0, memoryBlock: String(repeating: "記", count: 1_000))

    await XCTAssertThrowsErrorAsync(try await runner.run(request))
    let input = await adapter.input
    let session = await store.latestSession(workflowId: request.workflow.workflowId)
    XCTAssertNil(input)
    XCTAssertEqual(session?.failureKind, .promptTooLarge)
  }

  private func capture(
    context: BotRunContext? = nil, budget: Int? = nil, largeVariable: Bool = false
  ) async throws -> (input: AdapterExecutionInput, evidence: JSONObject) {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/bots-overview/bots-15-memory-surfaces/spill-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter = BotMemoryCapturingAdapter()
    let runner = DeterministicWorkflowRunner(adapter: adapter, fanoutWorkspaceRoot: root)
    var request = request(budget: budget)
    request.botContext = context
    if largeVariable { request.variables["large"] = .string(String(repeating: "large-input-", count: 5_000)) }
    let result = try await runner.run(request)
    let input = await adapter.input
    let captured = try XCTUnwrap(input)
    guard case let .object(evidence)? = result.session.executions.first?.inputSnapshot?["promptCompaction"] else {
      return (captured, [:])
    }
    return (captured, evidence)
  }

  private func request(budget: Int?) -> DeterministicWorkflowRunRequest {
    let workflow = WorkflowDefinition(
      workflowId: "bot-memory-prompt", description: "Bot memory prompt test",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3), entryStepId: "worker-step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "worker", nodeFile: "nodes/worker.json")],
      steps: [WorkflowStepRef(id: "worker-step", nodeId: "worker", role: .worker)],
      nodes: [WorkflowNodeRef(id: "worker-step", nodeFile: "nodes/worker.json")]
    )
    let payload = AgentNodePayload(
      id: "worker", executionBackend: .codexAgent, model: "test", agentSandbox: .readOnly,
      promptTemplate: "Proceed", promptMaxBytes: budget
    )
    return DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: ["worker": payload])
  }
}

private actor BotMemoryCapturingAdapter: NodeAdapter {
  private(set) var input: AdapterExecutionInput?

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    self.input = input
    return AdapterExecutionOutput(
      provider: "test", model: input.node.model, promptText: input.promptText,
      completionPassed: true, payload: ["ok": .bool(true)]
    )
  }
}
