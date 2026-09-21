import XCTest
@testable import RielaCore

struct ProductionNestedCalleeResolver: WorkflowCalleeResolving {
  func resolveCallee(workflowId: String) async throws -> ResolvedWorkflowCallee {
    XCTAssertEqual(workflowId, "production-child")
    return ResolvedWorkflowCallee(
      workflow: WorkflowDefinition(
        workflowId: workflowId,
        defaults: WorkflowDefaults(nodeTimeoutMs: 30_000, maxLoopIterations: 2),
        entryStepId: "child",
        nodeRegistry: [WorkflowNodeRegistryRef(id: "child-node", nodeFile: "nodes/child.json")],
        steps: [WorkflowStepRef(id: "child", nodeId: "child-node")],
        nodes: [WorkflowNodeRef(id: "child-node", nodeFile: "nodes/child.json")]
      ),
      nodePayloads: [
        "child-node": AgentNodePayload(
          id: "child-node", executionBackend: .codexAgent, model: "fixture", agentSandbox: .readOnly
        )
      ]
    )
  }
}

actor ProductionNestedAdapter: NodeAdapter {
  private var childExecutionCount = 0

  func execute(_ input: AdapterExecutionInput, context _: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    if input.node.id == "child" { childExecutionCount += 1 }
    let payload: JSONObject = input.node.id == "dispatch-node"
      ? ["handoff": .string("fixture")]
      : ["result": .string(input.node.id)]
    return AdapterExecutionOutput(
      provider: "fixture", model: "fixture", promptText: "fixture", completionPassed: true,
      payload: payload
    )
  }

  func calleeExecutions() -> Int { childExecutionCount }
}

actor LoopThenNestedAdapter: NodeAdapter {
  private var gateCount = 0
  private var childCount = 0

  func execute(_ input: AdapterExecutionInput, context _: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    switch input.node.id {
    case "gate":
      gateCount += 1
      return AdapterExecutionOutput(
        provider: "fixture", model: "fixture", promptText: "fixture", completionPassed: true,
        when: ["needs_work": gateCount == 1], payload: ["gate": .integer(Int64(gateCount))]
      )
    case "child":
      childCount += 1
      return AdapterExecutionOutput(
        provider: "fixture", model: "fixture", promptText: "fixture", completionPassed: true,
        payload: ["result": .string("child")]
      )
    default:
      return AdapterExecutionOutput(
        provider: "fixture", model: "fixture", promptText: "fixture", completionPassed: true,
        payload: ["result": .string(input.node.id)]
      )
    }
  }

  func gateExecutions() -> Int { gateCount }
  func childExecutions() -> Int { childCount }
}

actor NestedCheckpointRecorder: NestedRecoveryCheckpointing {
  private var checkpoints: [NestedRecoveryCheckpoint] = []

  func reached(_ checkpoint: NestedRecoveryCheckpoint) async throws {
    checkpoints.append(checkpoint)
  }

  func observed() -> [NestedRecoveryCheckpoint] { checkpoints }
}

struct ThrowingNestedCheckpoint: NestedRecoveryCheckpointing {
  let target: NestedRecoveryCheckpoint

  func reached(_ checkpoint: NestedRecoveryCheckpoint) async throws {
    guard checkpoint == target else { return }
    throw NestedRecoveryInterruption()
  }
}

actor CancellingNestedAdapter: NodeAdapter {
  private var childExecutionCount = 0

  func execute(_ input: AdapterExecutionInput, context _: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    if input.node.id == "child" {
      childExecutionCount += 1
      throw CancellationError()
    }
    return AdapterExecutionOutput(
      provider: "fixture", model: "fixture", promptText: "fixture", completionPassed: true,
      payload: ["result": .string(input.node.id)]
    )
  }

  func calleeExecutions() -> Int { childExecutionCount }
}

actor FailingNestedAdapter: NodeAdapter {
  private var childExecutionCount = 0

  func execute(_ input: AdapterExecutionInput, context _: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    if input.node.id == "child" {
      childExecutionCount += 1
      throw AdapterExecutionError(.providerError, "fixture child failure")
    }
    return AdapterExecutionOutput(
      provider: "fixture", model: "fixture", promptText: "fixture", completionPassed: true,
      payload: ["result": .string(input.node.id)]
    )
  }

  func calleeExecutions() -> Int { childExecutionCount }
}
