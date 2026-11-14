import XCTest
@testable import RielaCore

final class DeterministicWorkflowRunnerFanoutTests: XCTestCase {
  func testFanoutJoinOrdersBranchesByInputAndCapsConcurrency() async throws {
    let tracker = FanoutBranchTracker(delaysByIndex: [0: 120_000_000, 1: 20_000_000, 2: 60_000_000])
    let adapter = FanoutTestAdapter(tracker: tracker)
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter)

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: fanoutWorkflow(concurrency: 2),
      nodePayloads: fanoutPayloads(),
      maxConcurrency: 2
    ))

    XCTAssertEqual(result.exitCode, 0)
    let maxActive = await tracker.maxActiveCount()
    XCTAssertEqual(maxActive, 2)
    let capturedJoin = await tracker.joinRuntimeFanout()
    let join = try XCTUnwrap(capturedJoin)
    guard case let .array(branches)? = join["branches"] else {
      return XCTFail("fanoutJoin branches should be an array")
    }
    XCTAssertEqual(branches.compactMap(branchIndex), [0, 1, 2])
    XCTAssertEqual(branches.compactMap(branchOutputIndex), [0, 1, 2])
    XCTAssertEqual(join["fanoutGroupRunId"], .string("group:source-attempt-1-exec-1"))
    XCTAssertEqual(join["resultOrder"], .string("input"))
    let identities = await tracker.branchIdentities()
    XCTAssertEqual(identities.count, 3)
    XCTAssertEqual(Set(identities.map(\.workflowRunId)), [result.session.sessionId])
    XCTAssertEqual(Set(identities.map(\.workflowSessionId)).count, 3)
    XCTAssertEqual(Set(identities.map(\.stepId)), ["branch"])
  }

  func testFanoutFailFastCancelsOutstandingBranchesAndStopsScheduling() async throws {
    let tracker = FanoutBranchTracker(
      delaysByIndex: [0: 20_000_000, 1: 2_000_000_000, 2: 2_000_000_000],
      failingIndexes: [0]
    )
    let adapter = FanoutTestAdapter(tracker: tracker)
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter)

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: fanoutWorkflow(concurrency: 2),
        nodePayloads: fanoutPayloads()
      ))
      XCTFail("expected fanout failure")
    } catch DeterministicWorkflowRunnerError.fanoutDispatchFailed(let groupId, let reason) {
      XCTAssertEqual(groupId, "group")
      XCTAssertTrue(reason.contains("branch 0 failed"), reason)
    }

    let started = await tracker.startedIndexes()
    XCTAssertEqual(started.sorted(), [0, 1])
    let observedCancellation = await tracker.observedCancellation()
    XCTAssertTrue(observedCancellation)
  }

  func testFanoutCollectAllRunsEveryBranchBeforeFailing() async throws {
    let tracker = FanoutBranchTracker(
      delaysByIndex: [0: 20_000_000, 1: 10_000_000, 2: 30_000_000],
      failingIndexes: [1]
    )
    let adapter = FanoutTestAdapter(tracker: tracker)
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter)

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: fanoutWorkflow(concurrency: 2, failurePolicy: .collectAll),
        nodePayloads: fanoutPayloads()
      ))
      XCTFail("expected fanout failure")
    } catch DeterministicWorkflowRunnerError.fanoutDispatchFailed(let groupId, let reason) {
      XCTAssertEqual(groupId, "group")
      XCTAssertTrue(reason.contains("collect-all fanout recorded 1 failed branch"), reason)
    }

    let started = await tracker.startedIndexes()
    XCTAssertEqual(started.sorted(), [0, 1, 2])
  }

  func testCrossWorkflowFanoutRunsCalleesAndJoinsInParent() async throws {
    let tracker = FanoutBranchTracker(delaysByIndex: [0: 30_000_000, 1: 10_000_000, 2: 20_000_000])
    let adapter = FanoutTestAdapter(tracker: tracker)
    let payloads = fanoutPayloads()
    let branchPayload = try XCTUnwrap(payloads["branch-node"])
    let resolver = FanoutCalleeResolver(callee: ResolvedWorkflowCallee(
      workflow: fanoutCalleeWorkflow(),
      nodePayloads: ["branch-node": branchPayload]
    ))
    let runner = DeterministicWorkflowRunner(
      store: InMemoryWorkflowRuntimeStore(),
      adapter: adapter,
      calleeResolver: resolver
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: fanoutWorkflow(concurrency: 2, toWorkflowId: "fanout-callee"),
      nodePayloads: payloads,
      maxConcurrency: 2
    ))

    XCTAssertEqual(result.exitCode, 0)
    let capturedJoin = await tracker.joinRuntimeFanout()
    let join = try XCTUnwrap(capturedJoin, "executions: \(result.session.executions.map(\.stepId))")
    guard case let .array(branches)? = join["branches"] else {
      return XCTFail("fanoutJoin branches should be an array")
    }
    XCTAssertEqual(branches.compactMap(branchOutputIndex), [0, 1, 2])
    let identities = await tracker.branchIdentities()
    XCTAssertEqual(identities.count, 3)
    XCTAssertEqual(Set(identities.map(\.workflowRunId)), [result.session.sessionId])
    XCTAssertEqual(Set(identities.map(\.workflowSessionId)).count, 3)
    XCTAssertEqual(Set(identities.map(\.stepId)), ["branch"])
  }

  private func branchIndex(_ value: JSONValue) -> Int? {
    guard case let .object(object) = value,
          let index = object["index"]?.asInt64 else {
      return nil
    }
    return Int(index)
  }

  private func branchOutputIndex(_ value: JSONValue) -> Int? {
    guard case let .object(object) = value,
          case let .object(output)? = object["output"],
          let index = output["branchIndex"]?.asInt64 else {
      return nil
    }
    return Int(index)
  }
}

private actor FanoutBranchTracker {
  private let delaysByIndex: [Int: UInt64]
  private let failingIndexes: Set<Int>
  private var activeCount = 0
  private var maxActive = 0
  private var started: [Int] = []
  private var cancellationObserved = false
  private var joinFanout: JSONObject?
  private var identities: [AdapterExecutionIdentity] = []

  init(delaysByIndex: [Int: UInt64], failingIndexes: Set<Int> = []) {
    self.delaysByIndex = delaysByIndex
    self.failingIndexes = failingIndexes
  }

  func begin(index: Int) -> UInt64 {
    activeCount += 1
    maxActive = max(maxActive, activeCount)
    started.append(index)
    return delaysByIndex[index] ?? 0
  }

  func finish() {
    activeCount = max(0, activeCount - 1)
  }

  func shouldFail(index: Int) -> Bool {
    failingIndexes.contains(index)
  }

  func recordCancellation() {
    cancellationObserved = true
  }

  func recordJoinFanout(_ fanout: JSONObject?) {
    joinFanout = fanout
  }

  func recordIdentity(_ identity: AdapterExecutionIdentity?) {
    if let identity {
      identities.append(identity)
    }
  }

  func maxActiveCount() -> Int {
    maxActive
  }

  func startedIndexes() -> [Int] {
    started
  }

  func observedCancellation() -> Bool {
    cancellationObserved
  }

  func joinRuntimeFanout() -> JSONObject? {
    joinFanout
  }

  func branchIdentities() -> [AdapterExecutionIdentity] {
    identities
  }
}

private struct FanoutTestAdapter: NodeAdapter {
  var tracker: FanoutBranchTracker

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    switch input.node.id {
    case "source":
      return AdapterExecutionOutput(
        provider: "test",
        model: input.node.model,
        promptText: input.promptText,
        completionPassed: true,
        payload: [
          "payload": .object([
            "items": .array([
              .object(["index": .integer(0)]),
              .object(["index": .integer(1)]),
              .object(["index": .integer(2)])
            ])
          ])
        ]
      )
    case "branch":
      let index = branchIndex(from: input.arguments["feature"])
      await tracker.recordIdentity(input.executionIdentity)
      let delay = await tracker.begin(index: index)
      do {
        if delay > 0 {
          try await Task.sleep(nanoseconds: delay)
        }
        if await tracker.shouldFail(index: index) {
          throw AdapterExecutionError(.providerError, "forced branch \(index) failure")
        }
        await tracker.finish()
        return AdapterExecutionOutput(
          provider: "test",
          model: input.node.model,
          promptText: input.promptText,
          completionPassed: true,
          payload: ["branchIndex": .integer(Int64(index))]
        )
      } catch {
        if error is CancellationError {
          await tracker.recordCancellation()
        }
        await tracker.finish()
        throw error
      }
    case "join":
      let fanout = runtimeFanoutJoin(from: input.mergedVariables)
      await tracker.recordJoinFanout(fanout)
      return AdapterExecutionOutput(
        provider: "test",
        model: input.node.model,
        promptText: input.promptText,
        completionPassed: true,
        payload: ["joined": .bool(true)]
      )
    default:
      return AdapterExecutionOutput(
        provider: "test",
        model: input.node.model,
        promptText: input.promptText,
        completionPassed: true,
        payload: ["status": .string("ok")]
      )
    }
  }

  private func branchIndex(from value: JSONValue?) -> Int {
    guard case let .object(object)? = value,
          let index = object["index"]?.asInt64 else {
      return -1
    }
    return Int(index)
  }

  private func runtimeFanoutJoin(from variables: JSONObject) -> JSONObject? {
    guard case let .object(runtimeVariables)? = variables["runtimeVariables"],
          case let .object(fanoutJoin)? = runtimeVariables["fanoutJoin"] else {
      if case let .object(fanoutJoin)? = variables["fanoutJoin"] {
        return fanoutJoin
      }
      return nil
    }
    return fanoutJoin
  }
}

private struct FanoutCalleeResolver: WorkflowCalleeResolving {
  var callee: ResolvedWorkflowCallee

  func resolveCallee(workflowId: String) async throws -> ResolvedWorkflowCallee {
    guard workflowId == callee.workflow.workflowId else {
      throw AdapterExecutionError(.invalidInput, "unknown callee workflow '\(workflowId)'")
    }
    return callee
  }
}

private func fanoutWorkflow(
  concurrency: Int,
  failurePolicy: WorkflowFanoutFailurePolicy = .failFast,
  toWorkflowId: String? = nil
) -> WorkflowDefinition {
  WorkflowDefinition(
    workflowId: "fanout-runner",
    defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
    entryStepId: "source",
    nodeRegistry: [
      WorkflowNodeRegistryRef(id: "source-node", nodeFile: "nodes/source.json"),
      WorkflowNodeRegistryRef(id: "branch-node", nodeFile: "nodes/branch.json"),
      WorkflowNodeRegistryRef(id: "join-node", nodeFile: "nodes/join.json")
    ],
    steps: [
      WorkflowStepRef(
        id: "source",
        nodeId: "source-node",
        transitions: [
          WorkflowStepTransition(
            toStepId: "branch",
            toWorkflowId: toWorkflowId,
            resumeStepId: toWorkflowId == nil ? nil : "join",
            fanout: WorkflowStepFanout(
              groupId: "group",
              itemsFrom: "/payload/items",
              itemVariable: "feature",
              concurrency: concurrency,
              joinStepId: "join",
              failurePolicy: failurePolicy,
              resultOrder: .input,
              writeOwnership: WorkflowFanoutWriteOwnership(mode: .readOnly)
            )
          )
        ]
      ),
      WorkflowStepRef(id: "branch", nodeId: "branch-node", transitions: [WorkflowStepTransition(toStepId: "join")]),
      WorkflowStepRef(id: "join", nodeId: "join-node")
    ],
    nodes: [
      WorkflowNodeRef(id: "source-node", nodeFile: "nodes/source.json"),
      WorkflowNodeRef(id: "branch-node", nodeFile: "nodes/branch.json"),
      WorkflowNodeRef(id: "join-node", nodeFile: "nodes/join.json")
    ]
  )
}

private func fanoutCalleeWorkflow() -> WorkflowDefinition {
  WorkflowDefinition(
    workflowId: "fanout-callee",
    defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
    entryStepId: "branch",
    nodeRegistry: [
      WorkflowNodeRegistryRef(id: "branch-node", nodeFile: "nodes/branch.json")
    ],
    steps: [
      WorkflowStepRef(id: "branch", nodeId: "branch-node")
    ],
    nodes: [
      WorkflowNodeRef(id: "branch-node", nodeFile: "nodes/branch.json")
    ]
  )
}

private func fanoutPayloads() -> [String: AgentNodePayload] {
  [
    "source-node": AgentNodePayload(id: "source-node", executionBackend: .codexAgent, model: "gpt-5.5"),
    "branch-node": AgentNodePayload(id: "branch-node", executionBackend: .codexAgent, model: "gpt-5.5"),
    "join-node": AgentNodePayload(id: "join-node", executionBackend: .codexAgent, model: "gpt-5.5")
  ]
}
