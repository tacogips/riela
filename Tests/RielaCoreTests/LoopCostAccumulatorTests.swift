import Foundation
import RielaCore
import XCTest

final class LoopCostAccumulatorTests: XCTestCase {
  func testCodexStyleSingleTotalUsageEvent() {
    var accumulator = LoopCostAccumulator()
    accumulator.recordUsage(
      stepExecutionId: "impl-exec",
      backend: "codex",
      model: "gpt-5.5",
      usage: ["total_token_usage": .integer(165)]
    )

    let evidence = accumulator.evidence()
    XCTAssertEqual(evidence.count, 1)
    XCTAssertEqual(evidence[0].stepExecutionId, "impl-exec")
    XCTAssertEqual(evidence[0].backend, "codex")
    XCTAssertEqual(evidence[0].totalTokens, 165)
    XCTAssertEqual(evidence[0].diagnostics, [])

    let summary = accumulator.summary()
    XCTAssertEqual(summary.totalTokens, 165)
    XCTAssertEqual(summary.stepsWithUsage, 1)
    XCTAssertEqual(summary.stepsWithoutUsage, 0)
    XCTAssertFalse(summary.isPartial)
  }

  func testCumulativeSnapshotsAreLastValueWinsNotSummed() {
    var accumulator = LoopCostAccumulator()
    // Anthropic-style cumulative snapshots for one step.
    accumulator.recordUsage(stepExecutionId: "s", usage: ["input_tokens": .integer(100), "output_tokens": .integer(5)])
    accumulator.recordUsage(stepExecutionId: "s", usage: ["input_tokens": .integer(100), "output_tokens": .integer(40)])
    accumulator.recordUsage(stepExecutionId: "s", usage: ["input_tokens": .integer(100), "output_tokens": .integer(45), "total_tokens": .integer(145)])

    let evidence = accumulator.evidence()
    XCTAssertEqual(evidence.count, 1)
    XCTAssertEqual(evidence[0].inputTokens, 100)
    XCTAssertEqual(evidence[0].outputTokens, 45)
    XCTAssertEqual(evidence[0].totalTokens, 145)
  }

  func testStepWithoutUsageIsCountedAndDiagnosed() {
    var accumulator = LoopCostAccumulator()
    accumulator.recordStep(stepExecutionId: "no-usage", backend: "mock")

    let evidence = accumulator.evidence()
    XCTAssertEqual(evidence.count, 1)
    XCTAssertNil(evidence[0].totalTokens)
    XCTAssertEqual(evidence[0].diagnostics, ["no usage events recorded for step"])

    let summary = accumulator.summary()
    XCTAssertEqual(summary.stepsWithUsage, 0)
    XCTAssertEqual(summary.stepsWithoutUsage, 1)
    XCTAssertTrue(summary.isPartial)
  }

  func testMixedSessionPreservesInsertionOrderAndPartialTotals() {
    var accumulator = LoopCostAccumulator()
    accumulator.recordUsage(stepExecutionId: "a", usage: ["input_tokens": .integer(100), "total_tokens": .integer(140)])
    accumulator.recordStep(stepExecutionId: "b")
    accumulator.recordUsage(stepExecutionId: "c", usage: ["input_tokens": .integer(10), "total_tokens": .integer(15)])

    let evidence = accumulator.evidence()
    XCTAssertEqual(evidence.map(\.stepExecutionId), ["a", "b", "c"])

    let summary = accumulator.summary()
    XCTAssertEqual(summary.totalInputTokens, 110)
    XCTAssertEqual(summary.totalTokens, 155)
    XCTAssertEqual(summary.stepsWithUsage, 2)
    XCTAssertEqual(summary.stepsWithoutUsage, 1)
    XCTAssertTrue(summary.isPartial)
  }

  func testDurationDerivedFromUsageEventTimestampsWhenNoExplicitDuration() {
    var accumulator = LoopCostAccumulator()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    accumulator.recordUsage(stepExecutionId: "s", usage: ["input_tokens": .integer(1)], at: start)
    accumulator.recordUsage(stepExecutionId: "s", usage: ["output_tokens": .integer(2)], at: start.addingTimeInterval(9))

    XCTAssertEqual(accumulator.evidence()[0].durationMs, 9_000)
  }

  func testExplicitDurationOverridesDerived() {
    var accumulator = LoopCostAccumulator()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    accumulator.recordUsage(stepExecutionId: "s", usage: ["input_tokens": .integer(1)], at: start)
    accumulator.recordUsage(stepExecutionId: "s", usage: ["output_tokens": .integer(2)], at: start.addingTimeInterval(9))
    accumulator.recordStep(stepExecutionId: "s", durationMs: 5_000)

    XCTAssertEqual(accumulator.evidence()[0].durationMs, 5_000)
  }

  func testEvidenceFromExecutionsFoldsBackendEventUsage() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let executions = [
      Self.execution(
        executionId: "impl",
        backend: .codexAgent,
        model: "gpt-5.5",
        events: [Self.usageEvent(["input_tokens": .integer(100), "output_tokens": .integer(40), "total_tokens": .integer(140)], at: date)]
      ),
      // Agent step with no usage → counts as stepsWithoutUsage.
      Self.execution(executionId: "review", backend: .codexAgent, model: "gpt-5.5", events: []),
      // Non-agent execution (no backend) → skipped entirely.
      Self.execution(executionId: "build", backend: nil, model: nil, events: [])
    ]

    let evidence = LoopCostAccumulator.evidence(from: executions)
    XCTAssertEqual(evidence.map(\.stepExecutionId), ["impl", "review"])
    XCTAssertEqual(evidence.first?.totalTokens, 140)
    XCTAssertEqual(evidence.first?.backend, "codex-agent")

    let summary = LoopCostSummary.make(from: evidence)
    XCTAssertEqual(summary.totalTokens, 140)
    XCTAssertEqual(summary.stepsWithUsage, 1)
    XCTAssertEqual(summary.stepsWithoutUsage, 1)
    XCTAssertTrue(summary.isPartial)
  }

  // MARK: - Persisted-record eviction (100-event recentBackendEvents cap)

  /// Usage events arriving after long delta streams survive the 100-record
  /// eviction window, so re-projection from persisted records keeps the cost.
  func testEvictionKeepsUsageThatArrivesAfterLongDeltaStream() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let session = try await store.createSession(
      WorkflowSessionCreateInput(workflowId: "wf-eviction", entryStepId: "impl")
    )
    let execution = try await store.recordStepExecution(WorkflowStepExecutionRecordInput(
      sessionId: session.sessionId, stepId: "impl", nodeId: "impl-node", attempt: 1, backend: .codexAgent
    ))
    for index in 0..<120 {
      _ = try await store.recordStepBackendEventReceipt(WorkflowStepBackendEventInput(
        sessionId: session.sessionId,
        executionId: execution.executionId,
        eventType: "agent_message_delta",
        channel: .assistant,
        contentDelta: "chunk-\(index)",
        isDelta: true
      ))
    }
    _ = try await store.recordStepBackendEventReceipt(WorkflowStepBackendEventInput(
      sessionId: session.sessionId,
      executionId: execution.executionId,
      eventType: "usage",
      channel: .usage,
      usage: ["total_tokens": .integer(220)]
    ))

    let reloaded = try await store.loadSession(id: session.sessionId)
    let executions = try XCTUnwrap(reloaded).executions
    let events = try XCTUnwrap(executions.first?.recentBackendEvents)
    XCTAssertEqual(events.count, 100, "recentBackendEvents caps at 100 records")
    XCTAssertEqual(events.last?.usage?["total_tokens"], .integer(220), "usage payload persists on the record")

    let evidence = LoopCostAccumulator.evidence(from: executions)
    XCTAssertEqual(evidence.first?.totalTokens, 220)
    XCTAssertEqual(LoopCostSummary.make(from: evidence).stepsWithUsage, 1)
  }

  /// A usage event evicted by 100+ later records undercounts honestly: the
  /// step degrades to stepsWithoutUsage with nil totals, never a fabricated
  /// number. This is why the live accumulator stays authoritative.
  func testEvictionOfEarlyUsageDegradesToHonestNoUsage() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let session = try await store.createSession(
      WorkflowSessionCreateInput(workflowId: "wf-eviction", entryStepId: "impl")
    )
    let execution = try await store.recordStepExecution(WorkflowStepExecutionRecordInput(
      sessionId: session.sessionId, stepId: "impl", nodeId: "impl-node", attempt: 1, backend: .codexAgent
    ))
    _ = try await store.recordStepBackendEventReceipt(WorkflowStepBackendEventInput(
      sessionId: session.sessionId,
      executionId: execution.executionId,
      eventType: "usage",
      channel: .usage,
      usage: ["total_tokens": .integer(220)]
    ))
    for index in 0..<120 {
      _ = try await store.recordStepBackendEventReceipt(WorkflowStepBackendEventInput(
        sessionId: session.sessionId,
        executionId: execution.executionId,
        eventType: "agent_message_delta",
        channel: .assistant,
        contentDelta: "chunk-\(index)",
        isDelta: true
      ))
    }

    let reloaded = try await store.loadSession(id: session.sessionId)
    let executions = try XCTUnwrap(reloaded).executions
    let evidence = LoopCostAccumulator.evidence(from: executions)
    XCTAssertNil(evidence.first?.totalTokens)
    let summary = LoopCostSummary.make(from: evidence)
    XCTAssertNil(summary.totalTokens)
    XCTAssertEqual(summary.stepsWithoutUsage, 1)
    XCTAssertTrue(summary.isPartial)
  }

  private static func usageEvent(_ usage: JSONObject, at: Date) -> WorkflowBackendEventRecord {
    WorkflowBackendEventRecord(sequence: 1, at: at, eventType: "usage", channel: .usage, usage: usage)
  }

  private static func execution(
    executionId: String,
    backend: NodeExecutionBackend?,
    model: String?,
    events: [WorkflowBackendEventRecord]
  ) -> WorkflowStepExecution {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return WorkflowStepExecution(
      executionId: executionId,
      stepId: executionId,
      nodeId: executionId,
      attempt: 1,
      backend: backend,
      status: .completed,
      adapterOutput: model.map { WorkflowAdapterOutputMetadata(provider: "codex-agent", model: $0, completionPassed: true, when: ["always": true]) },
      recentBackendEvents: events.isEmpty ? nil : events,
      createdAt: date,
      updatedAt: date
    )
  }

  func testBackendAndModelBackfilledFromFirstNonNil() {
    var accumulator = LoopCostAccumulator()
    accumulator.recordUsage(stepExecutionId: "s", usage: ["input_tokens": .integer(1)])
    accumulator.recordUsage(stepExecutionId: "s", backend: "codex", model: "gpt-5.5", usage: ["output_tokens": .integer(2)])

    XCTAssertEqual(accumulator.evidence()[0].backend, "codex")
    XCTAssertEqual(accumulator.evidence()[0].model, "gpt-5.5")
  }
}
