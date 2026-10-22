import Crypto
import Foundation
import XCTest
@testable import RielaCore

final class PromptOverflowGuardIntegrationTests: XCTestCase {
  func testThreeBranchJoinSpillsBoundedObservationEvidenceAndCompletes() async throws {
    let root = try integrationScratch("fanout")
    let adapter = PromptOverflowIntegrationAdapter(root: root)
    let runner = DeterministicWorkflowRunner(
      store: InMemoryWorkflowRuntimeStore(), adapter: adapter, fanoutWorkspaceRoot: root
    )
    let request = integrationRequest(promptMaxBytes: 50_000)

    let result = try await runner.run(request)

    XCTAssertEqual(result.session.status, .completed)
    let capturedJoin = await adapter.joinInput()
    let joinInput = try XCTUnwrap(capturedJoin)
    let joinInvocationCount = await adapter.joinInvocationCount()
    XCTAssertEqual(joinInvocationCount, 1)
    guard case let .object(runtimeVariables)? = joinInput.mergedVariables["runtimeVariables"],
          case let .object(fanoutJoin)? = runtimeVariables["fanoutJoin"],
          case let .object(evidence)? = fanoutJoin["changeEvidence"],
          case let .array(observations)? = evidence["observations"] else {
      return XCTFail("expected fanout change evidence in join input")
    }
    XCTAssertEqual(evidence["observationsTruncated"], .bool(true))
    XCTAssertEqual(observations.count, 50)
    guard case let .integer(observationCount)? = evidence["observationCount"] else {
      return XCTFail("expected total aggregated observation count")
    }
    XCTAssertGreaterThanOrEqual(observationCount, 360)

    let joinExecution = try XCTUnwrap(result.session.executions.first { $0.stepId == "join" })
    XCTAssertEqual(joinExecution.status, .completed)
    guard case let .object(compaction)? = joinExecution.inputSnapshot?["promptCompaction"],
          case let .array(spills)? = compaction["spills"] else {
      return XCTFail("expected prompt spill evidence on join execution")
    }
    XCTAssertEqual(compaction["outcome"], .string("spilled"))
    XCTAssertFalse(spills.isEmpty)
    for value in spills {
      guard case let .object(spill) = value,
            case let .string(path)? = spill["path"],
            case let .string(expectedDigest)? = spill["sha256"] else {
        return XCTFail("spill evidence must include path and sha256")
      }
      let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
      let actualDigest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      XCTAssertEqual(actualDigest, expectedDigest)
    }
  }

  func testPromptTooLargeCanBeRetriedAfterRaisingBudget() async throws {
    let root = try integrationScratch("recovery")
    let store = InMemoryWorkflowRuntimeStore()
    let adapter = PromptOverflowIntegrationAdapter(root: root)
    let runner = DeterministicWorkflowRunner(store: store, adapter: adapter, fanoutWorkspaceRoot: root)
    var request = recoveryRequest(promptMaxBytes: 100)

    do {
      _ = try await runner.run(request)
      XCTFail("the 100-byte prompt budget should reject before adapter invocation")
    } catch {
      // The failed session is persisted for the explicit retry below.
    }
    let loadedFailedSession = await store.latestSession(workflowId: "prompt-overflow-recovery")
    let failed = try XCTUnwrap(loadedFailedSession)
    XCTAssertEqual(failed.status, .failed)
    XCTAssertEqual(failed.failureKind, .promptTooLarge)
    let failedInvocationCount = await adapter.joinInvocationCount()
    XCTAssertEqual(failedInvocationCount, 0)

    request.nodePayloads["join-node"]?.promptMaxBytes = 20_000
    request.resumeSessionId = failed.sessionId
    request.retryFailedStep = true
    let resumed = try await runner.run(request)
    XCTAssertEqual(resumed.session.status, .completed)
    XCTAssertEqual(resumed.session.sessionId, failed.sessionId)
    XCTAssertEqual(resumed.session.executions.map(\.status), [.failed, .completed])
    let retriedInvocationCount = await adapter.joinInvocationCount()
    XCTAssertEqual(retriedInvocationCount, 1)
  }

  private func integrationRequest(promptMaxBytes: Int) -> DeterministicWorkflowRunRequest {
    return DeterministicWorkflowRunRequest(
      workflow: integrationWorkflow(workflowId: "prompt-overflow-integration"),
      nodePayloads: [
        "source-node": AgentNodePayload(id: "source-node", model: "source"),
        "branch-node": AgentNodePayload(id: "branch-node", model: "branch"),
        "join-node": AgentNodePayload(
          id: "join-node", executionBackend: .codexAgent, model: "test", agentSandbox: .readOnly,
          promptTemplate: "Review the joined branch results.", promptMaxBytes: promptMaxBytes
        )
      ]
    )
  }

  private func recoveryRequest(promptMaxBytes: Int) -> DeterministicWorkflowRunRequest {
    let workflow = WorkflowDefinition(
      workflowId: "prompt-overflow-recovery",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "join",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "join-node", nodeFile: "nodes/join.json")],
      steps: [WorkflowStepRef(id: "join", nodeId: "join-node")],
      nodes: [WorkflowNodeRef(id: "join-node", nodeFile: "nodes/join.json")]
    )
    return DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["join-node": AgentNodePayload(
        id: "join-node", executionBackend: .codexAgent, model: "test", agentSandbox: .readOnly,
        promptTemplate: "Review the input.", promptMaxBytes: promptMaxBytes
      )],
      variables: ["large": .string(String(repeating: "overflow-data-", count: 600))]
    )
  }

  private func integrationWorkflow(workflowId: String) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: workflowId,
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "source",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "source-node", nodeFile: "nodes/source.json"),
        WorkflowNodeRegistryRef(id: "branch-node", nodeFile: "nodes/branch.json"),
        WorkflowNodeRegistryRef(id: "join-node", nodeFile: "nodes/join.json")
      ],
      steps: [
        WorkflowStepRef(id: "source", nodeId: "source-node", transitions: [
          WorkflowStepTransition(toStepId: "branch", fanout: WorkflowStepFanout(
            groupId: "prompt-overflow-branches", itemsFrom: "/payload/items", itemVariable: "branch",
            concurrency: 3, joinStepId: "join", failurePolicy: .failFast, resultOrder: .input,
            writeOwnership: WorkflowFanoutWriteOwnership(mode: .sharedWorkspace),
            dependencies: WorkflowFanoutDependencies(branchIdFrom: "/branchId", dependsOnFrom: "/dependsOn"),
            changeTracking: WorkflowFanoutChangeTracking(pathsFrom: "/trackedPaths", observationInlineLimit: 50)
          ))
        ]),
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

  private func integrationScratch(_ name: String) throws -> URL {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/prompt-overflow/pog-05-integration/test-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return root
  }
}

private actor PromptOverflowIntegrationAdapter: NodeAdapter {
  private let root: URL
  private var join: AdapterExecutionInput?
  private var joinCalls = 0

  init(root: URL) { self.root = root }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    switch input.node.id {
    case "source":
      let items = (0..<3).map { index in
        JSONValue.object([
          "branchId": .string("branch-\(index)"),
          "dependsOn": .array([]),
          "trackedPaths": .array([.string("logs/branch-\(index)")])
        ])
      }
      return output(input, payload: ["payload": .object(["items": .array(items)])])
    case "branch":
      guard case let .object(branch)? = input.arguments["branch"],
            case let .string(branchId)? = branch["branchId"] else {
        throw AdapterExecutionError(.invalidInput, "fanout branch identifier is missing")
      }
      let directory = root.appendingPathComponent("logs/\(branchId)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      for index in 0..<120 {
        try Data("evidence \(branchId) \(index)".utf8)
          .write(to: directory.appendingPathComponent(String(format: "entry-%03d.log", index)))
      }
      return output(input, payload: [
        "branchId": .string(branchId),
        "continuation": .string(String(repeating: "branch-result-\(branchId)-", count: 2_000))
      ])
    case "join":
      join = input
      joinCalls += 1
      return output(input, payload: ["joined": .bool(true)])
    default:
      throw AdapterExecutionError(.invalidInput, "unexpected node '\(input.node.id)'")
    }
  }

  func joinInput() -> AdapterExecutionInput? { join }
  func joinInvocationCount() -> Int { joinCalls }

  private func output(_ input: AdapterExecutionInput, payload: JSONObject) -> AdapterExecutionOutput {
    AdapterExecutionOutput(provider: "test", model: input.node.model, promptText: input.promptText, completionPassed: true, payload: payload)
  }
}
