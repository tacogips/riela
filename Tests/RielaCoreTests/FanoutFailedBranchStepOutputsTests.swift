import Foundation
import XCTest
@testable import RielaCore

/// Failed and cancelled `collect-partial` branch records keep the included step outputs that were
/// accepted before the branch stopped, so a join can fall back to them (for example the raw
/// transcript when the per-segment summarizer fails).
final class FanoutFailedBranchStepOutputsTests: XCTestCase {
  func testFailedAndCancelledRecordsCarryStepOutputsAcceptedBeforeTheFailure() async throws {
    let joins = FanoutPartialJoinRecorder()
    let store = InMemoryWorkflowRuntimeStore()
    let result = try await DeterministicWorkflowRunner(store: store, adapter: TranscribeSummarizeAdapter(joins: joins))
      .run(.init(workflow: transcribeSummarizeWorkflow(), nodePayloads: transcribeSummarizePayloads()))
    XCTAssertEqual(result.status, .completed)
    let captured = await joins.latest()
    let join = try XCTUnwrap(captured)
    try assertPartialBranches(join)
  }

  func testFailedRecordStepOutputsSurviveTerminalCheckpointRecovery() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("tmp/fanout-failed-step-outputs/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = InMemoryWorkflowRuntimeStore()
    let adapter = TranscribeSummarizeAdapter(joins: FanoutPartialJoinRecorder())
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let workflow = transcribeSummarizeWorkflow(concurrency: 1)
    let interrupted = DeterministicWorkflowRunner(store: store, adapter: adapter,
      nestedInvocationPersistenceStore: persistence,
      nestedInvocationRecoveryCheckpointer: InterruptAtCheckpoint(target: .childTerminalPersisted))
    await XCTAssertThrowsErrorAsync(
      try await interrupted.run(.init(workflow: workflow, nodePayloads: transcribeSummarizePayloads())))
    let latestSession = await store.latestSession(workflowId: workflow.workflowId)
    let latest = try XCTUnwrap(latestSession)
    let loadedParent = try await store.loadSession(id: latest.parentSessionId ?? latest.sessionId)
    let parent = try XCTUnwrap(loadedParent)

    let resumed = try await DeterministicWorkflowRunner(store: store, adapter: adapter,
      nestedInvocationPersistenceStore: persistence)
      .run(.init(workflow: workflow, nodePayloads: transcribeSummarizePayloads(), resumeSessionId: parent.sessionId))

    XCTAssertEqual(resumed.status, .completed)
    let messages = try SQLiteWorkflowMessageLog(
      databasePath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    ).listMessages(workflowExecutionId: parent.sessionId, toStepId: "join")
    XCTAssertEqual(messages.count, 1)
    guard case let .object(join)? = messages.first?.payload["fanoutJoin"] else { return XCTFail("missing join") }
    try assertPartialBranches(join)
  }

  private func assertPartialBranches(_ join: JSONObject) throws {
    guard case let .array(branches)? = join["branches"] else { return XCTFail("missing branches") }
    let records = try branches.map { branch -> JSONObject in
      guard case let .object(record) = branch else { throw TranscribeSummarizeError.malformedRecord }
      return record
    }
    XCTAssertEqual(records.map { $0["status"] }, [
      .string("completed"), .string("failed"), .string("failed"), .string("cancelled")
    ])
    XCTAssertEqual(records[0]["stepOutputs"], .object([
      "transcribe": .object(["transcript": .string("t0")]),
      "summarize": .object(["summary": .string("s0")])
    ]))
    // summarize failed: only the accepted transcribe output is kept.
    XCTAssertEqual(records[1]["stepOutputs"], .object(["transcribe": .object(["transcript": .string("t1")])]))
    // transcribe failed: no included step was accepted, so the key is omitted.
    XCTAssertNil(records[2]["stepOutputs"])
    XCTAssertEqual(records[3]["stepOutputs"], .object(["transcribe": .object(["transcript": .string("t3")])]))
  }
}

private enum TranscribeSummarizeError: Error { case malformedRecord }

private struct InterruptAtCheckpoint: NestedRecoveryCheckpointing {
  let target: NestedRecoveryCheckpoint

  func reached(_ checkpoint: NestedRecoveryCheckpoint) async throws {
    guard checkpoint == target else { return }
    throw NestedRecoveryInterruption()
  }
}

private actor FanoutPartialJoinRecorder {
  private var join: JSONObject?

  func record(_ value: JSONObject?) { join = value }
  func latest() -> JSONObject? { join }
}

/// Item 0 succeeds, item 1 fails in `summarize`, item 2 fails in `transcribe`, item 3 is cancelled
/// in `summarize`.
private struct TranscribeSummarizeAdapter: NodeAdapter {
  let joins: FanoutPartialJoinRecorder

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    let index = itemIndex(input.arguments["feature"])
    switch input.node.id {
    case "source":
      return output(input, ["payload": .object(["items": .array((0..<4).map { .object(["index": .integer(Int64($0))]) })])])
    case "transcribe":
      if index == 2 { throw AdapterExecutionError(.providerError, "forced transcribe failure") }
      return output(input, ["transcript": .string("t\(index)")])
    case "summarize":
      if index == 1 { throw AdapterExecutionError(.providerError, "forced summarize failure") }
      if index == 3 { throw CancellationError() }
      return output(input, ["summary": .string("s\(index)")])
    default:
      let variables = input.mergedVariables
      if case let .object(runtime)? = variables["runtimeVariables"], case let .object(join)? = runtime["fanoutJoin"] {
        await joins.record(join)
      } else if case let .object(join)? = variables["fanoutJoin"] {
        await joins.record(join)
      }
      return output(input, ["joined": .bool(true)])
    }
  }

  private func output(_ input: AdapterExecutionInput, _ payload: JSONObject) -> AdapterExecutionOutput {
    AdapterExecutionOutput(provider: "test", model: input.node.model, promptText: input.promptText,
      completionPassed: true, payload: payload)
  }

  private func itemIndex(_ value: JSONValue?) -> Int {
    guard case let .object(object)? = value, let index = object["index"]?.asInt64 else { return -1 }
    return Int(index)
  }
}

private func transcribeSummarizeWorkflow(concurrency: Int = 2) -> WorkflowDefinition {
  let nodeIds = ["source", "transcribe", "summarize", "join"]
  return WorkflowDefinition(
    workflowId: "fanout-failed-step-outputs",
    defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
    entryStepId: "source",
    nodeRegistry: nodeIds.map { WorkflowNodeRegistryRef(id: $0, nodeFile: "nodes/\($0).json") },
    steps: [
      WorkflowStepRef(id: "source", nodeId: "source", transitions: [
        WorkflowStepTransition(toStepId: "transcribe", fanout: WorkflowStepFanout(
          groupId: "segments", itemsFrom: "/payload/items", itemVariable: "feature",
          concurrency: concurrency, joinStepId: "join", failurePolicy: .collectPartial, resultOrder: .input,
          writeOwnership: WorkflowFanoutWriteOwnership(mode: .readOnly),
          includeStepOutputs: ["transcribe", "summarize"]))
      ]),
      WorkflowStepRef(id: "transcribe", nodeId: "transcribe", transitions: [WorkflowStepTransition(toStepId: "summarize")]),
      WorkflowStepRef(id: "summarize", nodeId: "summarize", transitions: [WorkflowStepTransition(toStepId: "join")]),
      WorkflowStepRef(id: "join", nodeId: "join")
    ],
    nodes: nodeIds.map { WorkflowNodeRef(id: $0, nodeFile: "nodes/\($0).json") }
  )
}

private func transcribeSummarizePayloads() -> [String: AgentNodePayload] {
  Dictionary(uniqueKeysWithValues: ["source", "transcribe", "summarize", "join"].map {
    ($0, AgentNodePayload(id: $0, executionBackend: .codexAgent, model: "gpt-5.5", agentSandbox: .readOnly))
  })
}
