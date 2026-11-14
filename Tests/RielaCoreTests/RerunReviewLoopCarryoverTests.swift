import XCTest
@testable import RielaCore

/// #135 reproduction topology: `checkpoint -> dispatch -> work -> review`,
/// with `review -(plans_remaining)-> dispatch`. `dispatch` requires exactly
/// one checkpoint message, like the packaged `dispatch-plans` script.
final class RerunReviewLoopCarryoverTests: XCTestCase {
  func testPlainRerunOfReviewCarriesCheckpointIntoSecondDispatchVisit() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    // Source: review asks for another plan once, then fails on its second visit.
    let sourceAdapter = LoopAdapter(reviewScript: [.plansRemaining, .fail])
    await XCTAssertThrowsErrorAsync(try await DeterministicWorkflowRunner(store: store, adapter: sourceAdapter)
      .run(request()))
    let maybeSource = await store.latestSession(workflowId: loopWorkflow.workflowId)
    let source = try XCTUnwrap(maybeSource)
    XCTAssertEqual(source.status, .failed)
    XCTAssertEqual(source.executions.map(\.stepId), ["checkpoint", "dispatch", "work", "review", "dispatch", "work", "review"])

    // Rerun review: it routes back to dispatch, which must still find the
    // checkpoint message, then the loop finishes.
    let rerunAdapter = LoopAdapter(reviewScript: [.plansRemaining, .done])
    let result = try await DeterministicWorkflowRunner(store: store, adapter: rerunAdapter).run(
      request(sourceSessionId: source.sessionId, targetStepId: "review"))
    XCTAssertEqual(result.status, .completed)
    let newSteps = result.session.executions.filter { $0.importedFrom == nil }.map(\.stepId)
    XCTAssertEqual(newSteps, ["review", "dispatch", "work", "review", "done"])
    let dispatchInboxes = await rerunAdapter.dispatchCheckpointCounts
    XCTAssertEqual(dispatchInboxes, [1], "the second dispatch visit sees exactly one checkpoint message")

    // Imported evidence is not an execution of the rerun session (B6): the
    // execution index (RIELA_NODE_EXEC_ID, mock-scenario index) restarts at 1.
    let executionIndexes = await rerunAdapter.executionIndexes
    XCTAssertEqual(executionIndexes["dispatch"], [1])
    XCTAssertEqual(executionIndexes["review"], [1, 2])

    // Only accepted producers of messages up to the target's inbox are imported.
    let imported = result.session.executions.filter { $0.importedFrom != nil }
    XCTAssertTrue(imported.allSatisfy { $0.importedFrom?.sessionId == source.sessionId })
    XCTAssertEqual(Set(imported.map(\.stepId)), ["checkpoint", "dispatch", "work", "review"])
    XCTAssertFalse(imported.contains { $0.importedFrom?.executionId == source.executions.last?.executionId },
      "the failed target execution is never imported")
    XCTAssertEqual(result.session.newExecutionCount, 5)
  }

  func testRerunOfRerunCarriesImportedProducersAgain() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    await XCTAssertThrowsErrorAsync(try await DeterministicWorkflowRunner(
      store: store, adapter: LoopAdapter(reviewScript: [.fail])
    ).run(request()))
    let maybeSource = await store.latestSession(workflowId: loopWorkflow.workflowId)
    let source = try XCTUnwrap(maybeSource)

    // First rerun of review fails again before it can route.
    await XCTAssertThrowsErrorAsync(try await DeterministicWorkflowRunner(
      store: store, adapter: LoopAdapter(reviewScript: [.fail])
    ).run(request(sourceSessionId: source.sessionId, targetStepId: "review")))
    let maybeIntermediate = await store.latestSession(workflowId: loopWorkflow.workflowId)
    let intermediate = try XCTUnwrap(maybeIntermediate)
    XCTAssertNotEqual(intermediate.sessionId, source.sessionId)
    XCTAssertEqual(intermediate.status, .failed)

    // A rerun of that rerun carries the intermediate's imported producers.
    let adapter = LoopAdapter(reviewScript: [.plansRemaining, .done])
    let result = try await DeterministicWorkflowRunner(store: store, adapter: adapter).run(
      request(sourceSessionId: intermediate.sessionId, targetStepId: "review"))
    XCTAssertEqual(result.status, .completed)
    let dispatchInboxes = await adapter.dispatchCheckpointCounts
    XCTAssertEqual(dispatchInboxes, [1])
    let imported = result.session.executions.filter { $0.importedFrom != nil }
    XCTAssertTrue(imported.allSatisfy { $0.importedFrom?.sessionId == intermediate.sessionId })
    XCTAssertEqual(Set(imported.map(\.stepId)), ["checkpoint", "dispatch", "work"])
  }

  private var loopWorkflow: WorkflowDefinition {
    let stepIds = ["checkpoint", "dispatch", "work", "review", "done"]
    let transitions: [String: [WorkflowStepTransition]] = [
      "checkpoint": [WorkflowStepTransition(toStepId: "dispatch")],
      "dispatch": [WorkflowStepTransition(toStepId: "work")],
      "work": [WorkflowStepTransition(toStepId: "review")],
      "review": [
        WorkflowStepTransition(toStepId: "dispatch", label: "plans_remaining"),
        WorkflowStepTransition(toStepId: "done", label: "!(plans_remaining)")
      ]
    ]
    return WorkflowDefinition(
      workflowId: "rerun-review-loop",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "checkpoint",
      nodeRegistry: stepIds.map { WorkflowNodeRegistryRef(id: $0, nodeFile: "\($0).json") },
      steps: stepIds.map { WorkflowStepRef(id: $0, nodeId: $0, transitions: transitions[$0]) },
      nodes: stepIds.map { WorkflowNodeRef(id: $0, nodeFile: "\($0).json") }
    )
  }

  private func request(sourceSessionId: String? = nil, targetStepId: String? = nil) -> DeterministicWorkflowRunRequest {
    let nodePayloads = Dictionary(uniqueKeysWithValues: loopWorkflow.nodes.map { node in
      (node.id, AgentNodePayload(id: node.id, model: "fixture", output: NodeOutputContract(
        jsonSchema: ["type": .string("object")]
      )))
    })
    var request = DeterministicWorkflowRunRequest(
      workflow: loopWorkflow,
      nodePayloads: nodePayloads,
      rerunFromSessionId: sourceSessionId,
      rerunFromStepId: targetStepId
    )
    // Keep the loop away from the default terminal-corridor reservation.
    request.maxSteps = 30
    return request
  }
}

private enum ReviewOutcome: Sendable {
  case plansRemaining
  case done
  case fail
}

private actor LoopAdapter: NodeAdapter {
  private var reviewScript: [ReviewOutcome]
  private(set) var dispatchCheckpointCounts: [Int] = []
  private var callCount = 0
  private(set) var executionIndexes: [String: [Int]] = [:]

  init(reviewScript: [ReviewOutcome]) {
    self.reviewScript = reviewScript
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    executionIndexes[input.node.id, default: []].append(input.executionIndex)
    switch input.node.id {
    case "dispatch":
      guard case let .object(inbox)? = input.mergedVariables["_rielaInput"],
            case let .array(messages)? = inbox["messages"] else {
        throw AdapterExecutionError(.invalidInput, "dispatch has no resolved inbox")
      }
      let checkpoints = messages.filter { message in
        guard case let .object(fields) = message else { return false }
        return fields["fromStepId"] == .string("checkpoint")
      }.count
      dispatchCheckpointCounts.append(checkpoints)
      guard checkpoints == 1 else {
        throw AdapterExecutionError(.invalidInput, "dispatch requires exactly one checkpoint message, found \(checkpoints)")
      }
      return output(input, when: ["always": true])
    case "review":
      let outcome = reviewScript.isEmpty ? .done : reviewScript.removeFirst()
      switch outcome {
      case .fail:
        throw AdapterExecutionError(.providerError, "review failure")
      case .plansRemaining:
        return output(input, when: ["plans_remaining": true])
      case .done:
        return output(input, when: ["plans_remaining": false])
      }
    default:
      return output(input, when: ["always": true])
    }
  }

  private func output(_ input: AdapterExecutionInput, when: [String: Bool]) -> AdapterExecutionOutput {
    // Each visit makes progress, so the default loop guard never redirects.
    callCount += 1
    return AdapterExecutionOutput(
      provider: "test", model: input.node.model, promptText: input.promptText,
      completionPassed: true, when: when,
      payload: ["step": .string(input.node.id), "visit": .integer(Int64(callCount))]
    )
  }
}
