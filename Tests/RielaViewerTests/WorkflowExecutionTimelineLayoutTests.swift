import Foundation
import RielaCore
import RielaViewer
import XCTest

final class WorkflowExecutionTimelineLayoutTests: XCTestCase {
  func testLayoutOrdersRowsByFirstStartAndNormalizesBars() {
    let origin = Date(timeIntervalSince1970: 100)
    let workflow = workflowDefinition(stepIds: ["first", "second"])
    let layout = WorkflowExecutionTimelineLayout(
      entries: [
        entry(id: "exec-2", stepId: "second", nodeId: "worker", start: origin.addingTimeInterval(5), end: origin.addingTimeInterval(10)),
        entry(id: "exec-1", stepId: "first", nodeId: "input", start: origin, end: origin.addingTimeInterval(2))
      ],
      workflow: workflow,
      now: origin.addingTimeInterval(12)
    )

    XCTAssertEqual(layout.rows.map(\.stepId), ["first", "second"])
    XCTAssertEqual(layout.timeOrigin, origin)
    XCTAssertEqual(layout.timeSpan, 10)
    XCTAssertEqual(try XCTUnwrap(layout.bars.first { $0.entryId == "exec-1" }).startFraction, 0, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(layout.bars.first { $0.entryId == "exec-2" }).startFraction, 0.5, accuracy: 0.0001)
    XCTAssertFalse(layout.axisTicks.isEmpty)
  }

  func testLayoutUsesInjectedNowForRunningExecutionsAndClampsMinimumSpan() {
    let origin = Date(timeIntervalSince1970: 200)
    let layout = WorkflowExecutionTimelineLayout(
      entries: [
        entry(id: "running", stepId: "work", nodeId: "work", status: .running, start: origin, end: nil)
      ],
      now: origin.addingTimeInterval(0.2)
    )

    XCTAssertEqual(layout.timeSpan, 1)
    XCTAssertEqual(try XCTUnwrap(layout.bars.first).endFraction, 0.2, accuracy: 0.0001)
  }

  func testLayoutDerivesConnectorsFromMessages() {
    let origin = Date(timeIntervalSince1970: 300)
    let layout = WorkflowExecutionTimelineLayout(
      entries: [
        entry(id: "exec-source", stepId: "source", nodeId: "source", start: origin, end: origin.addingTimeInterval(1)),
        entry(id: "exec-target", stepId: "target", nodeId: "target", start: origin.addingTimeInterval(2), end: origin.addingTimeInterval(3))
      ],
      messages: [
        WorkflowViewerMessage(
          id: "message-1",
          direction: .outbox,
          fromStepId: "source",
          toStepId: "target",
          sourceStepExecutionId: "exec-source",
          status: .created,
          payloadPreview: "{}",
          createdOrder: 1,
          createdAt: origin.addingTimeInterval(1)
        )
      ],
      now: origin.addingTimeInterval(3)
    )

    XCTAssertEqual(layout.connectors.map { "\($0.fromEntryId)->\($0.toEntryId)" }, ["exec-source->exec-target"])
  }

  func testLayoutFallsBackToExecutionOrderConnectorsWithoutMessages() {
    let origin = Date(timeIntervalSince1970: 400)
    let layout = WorkflowExecutionTimelineLayout(
      entries: [
        entry(id: "one", stepId: "one", nodeId: "one", start: origin, end: origin.addingTimeInterval(1)),
        entry(id: "two", stepId: "two", nodeId: "two", start: origin.addingTimeInterval(1), end: origin.addingTimeInterval(2)),
        entry(id: "three", stepId: "three", nodeId: "three", start: origin.addingTimeInterval(2), end: origin.addingTimeInterval(3))
      ],
      now: origin.addingTimeInterval(3)
    )

    XCTAssertEqual(layout.connectors.map { "\($0.fromEntryId)->\($0.toEntryId)" }, ["one->two", "two->three"])
  }

  func testTimelineEntryGanttLogSummaryUsesLatestBackendEventContent() {
    let origin = Date(timeIntervalSince1970: 500)
    let entry = WorkflowViewerTimelineEntry(
      id: "exec-log",
      stepId: "worker",
      nodeId: "worker",
      attempt: 1,
      status: .completed,
      startedAt: origin,
      endedAt: origin.addingTimeInterval(1),
      backendEvents: [
        WorkflowViewerBackendEvent(sequence: 1, at: origin, eventType: "response.started", content: "starting"),
        WorkflowViewerBackendEvent(
          sequence: 2,
          at: origin.addingTimeInterval(1),
          eventType: "response.delta",
          content: "  final\nanswer\tfrom backend  "
        )
      ]
    )

    XCTAssertEqual(entry.ganttLogSummary(), "final answer from backend")
  }

  func testTimelineEntryGanttLogSummaryPrefersFailureAndTruncates() {
    let origin = Date(timeIntervalSince1970: 600)
    let entry = WorkflowViewerTimelineEntry(
      id: "exec-failed",
      stepId: "worker",
      nodeId: "worker",
      attempt: 1,
      status: .failed,
      startedAt: origin,
      endedAt: origin.addingTimeInterval(1),
      backendEvents: [
        WorkflowViewerBackendEvent(sequence: 1, at: origin, eventType: "response.delta", content: "backend text")
      ],
      failureReason: "the provider returned a very long error message"
    )

    XCTAssertEqual(entry.ganttLogSummary(maxLength: 24), "Failure: the provider...")
  }

  private func entry(
    id: String,
    stepId: String,
    nodeId: String,
    status: WorkflowStepExecutionStatus = .completed,
    start: Date,
    end: Date?
  ) -> WorkflowViewerTimelineEntry {
    WorkflowViewerTimelineEntry(
      id: id,
      stepId: stepId,
      nodeId: nodeId,
      attempt: 1,
      status: status,
      startedAt: start,
      endedAt: end
    )
  }

  private func workflowDefinition(stepIds: [String]) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "timeline-layout",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 3),
      entryStepId: stepIds.first ?? "first",
      nodeRegistry: stepIds.map { WorkflowNodeRegistryRef(id: $0) },
      steps: stepIds.map { WorkflowStepRef(id: $0, nodeId: $0) },
      nodes: stepIds.map { WorkflowNodeRef(id: $0, nodeFile: "nodes/\($0).json") }
    )
  }
}
