import XCTest
@testable import RielaCore

final class TerminalReservePreconditionTests: XCTestCase {
  func testTwoLabelledStepsRun() async throws {
    let result = try await runChain(["check", "remediate"])
    XCTAssertEqual(result.session.executions.map(\.stepId), ["check", "remediate"])
    XCTAssertNil(result.rootOutput?["loopGuardOutcome"])
  }

  func testFifteenLabelledStepsRun() async throws {
    let ids = (1...15).map { "s\($0)" }
    let result = try await runChain(ids)
    XCTAssertEqual(result.session.executions.map(\.stepId), ids)
    XCTAssertNil(result.rootOutput?["loopGuardOutcome"])
  }

  func testReachableGraphBounds() {
    let selector = LoopTerminalCorridorSelector()
    func bound(_ steps: [WorkflowStepRef], _ origin: String) -> Int? {
      selector.acyclicRemainingStepBound(workflow: workflow(steps), originStepId: origin)
    }
    XCTAssertNil(bound([step("a", ["a"])], "a"))
    XCTAssertNil(bound([step("a", ["b"]), step("b", ["c"]), step("c", ["b"])], "a"))
    XCTAssertEqual(bound([
      step("a", ["b", "c"]), step("b", ["d"]), step("c", ["x"]), step("x", ["d"]), step("d")
    ], "a"), 4)
    XCTAssertEqual(bound([step("a", ["b"]), step("b", ["c"]), step("c")], "a"), 3)
    XCTAssertEqual(bound([step("a")], "a"), 1)
    XCTAssertNil(bound([step("a")], "unknown"))
  }

  func testInsufficientBudgetStillReservesTerminalStep() async throws {
    let result = try await runChain((1...5).map { "s\($0)" }, maxSteps: 4)
    guard case let .object(outcome)? = result.rootOutput?["loopGuardOutcome"] else {
      return XCTFail("expected reserve outcome")
    }
    XCTAssertEqual(outcome["trigger"], .string("terminal-step-reserve"))
  }

  private func runChain(_ ids: [String], maxSteps: Int? = nil) async throws -> WorkflowRunResult {
    let steps = ids.enumerated().map { index, id in
      step(id, index + 1 < ids.count ? [ids[index + 1]] : [])
    }
    let definition = workflow(steps)
    let payloads = Dictionary(uniqueKeysWithValues: steps.map { step in
      (step.nodeId, AgentNodePayload(
        id: step.nodeId, executionBackend: .codexAgent, model: "test", agentSandbox: .readOnly,
        output: NodeOutputContract(jsonSchema: ["type": .string("object")])
      ))
    })
    return try await DeterministicWorkflowRunner(
      store: InMemoryWorkflowRuntimeStore(), adapter: ReserveTestAdapter()
    ).run(DeterministicWorkflowRunRequest(workflow: definition, nodePayloads: payloads, maxSteps: maxSteps))
  }

  private func step(_ id: String, _ destinations: [String] = []) -> WorkflowStepRef {
    WorkflowStepRef(id: id, nodeId: "\(id)-node", role: .worker,
                    transitions: destinations.map { WorkflowStepTransition(toStepId: $0, label: "selected") })
  }

  private func workflow(_ steps: [WorkflowStepRef]) -> WorkflowDefinition {
    let nodes = steps.map { WorkflowNodeRef(id: $0.nodeId, nodeFile: "nodes/\($0.nodeId).json") }
    return WorkflowDefinition(
      workflowId: "reserve-test", defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 1),
      entryStepId: steps[0].id,
      nodeRegistry: steps.map { WorkflowNodeRegistryRef(id: $0.nodeId, nodeFile: "nodes/\($0.nodeId).json") },
      steps: steps, nodes: nodes
    )
  }
}

private actor ReserveTestAdapter: NodeAdapter {
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    AdapterExecutionOutput(provider: "test", model: input.node.model, promptText: input.promptText,
                           completionPassed: true, when: ["selected": true], payload: ["status": .string("ok")])
  }
}
