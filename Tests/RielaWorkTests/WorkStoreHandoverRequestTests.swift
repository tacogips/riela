import Foundation
import RielaCore
import XCTest
@testable import RielaWork

final class WorkStoreHandoverRequestTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("riela-work-handover-request-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  func testRequestRequiresRunningAttemptIsIdempotentAndCanBeConsumed() throws {
    let store = WorkStore(rootDirectory: root.path)
    try store.saveTask(sampleTask())
    XCTAssertThrowsError(try store.requestHandover(taskId: TaskID("task-1"), reason: "move", immediate: true, target: nil, sinks: [], now: Date()))

    let reservation = try store.reserveAttempt(AttemptReservationRequest(
      taskId: TaskID("task-1"), expectedTaskVersion: 1, attemptId: AttemptID("attempt-1"), sessionId: "session-1",
      workflowId: "flow", entryStepId: "start", entry: .start, decisionId: DecisionID("decision-1"),
      producer: .policy(rule: "start"), reason: "start", now: Date(timeIntervalSince1970: 1_800_000_000)
    ))
    _ = try store.authorizeAttemptLaunch(attemptId: reservation.attempt.id, launchToken: reservation.launchToken)
    let requestedAt = Date(timeIntervalSince1970: 1_800_000_001)
    let first = try store.requestHandover(taskId: TaskID("task-1"), reason: "user presence", immediate: true,
                                          target: "host-east", sinks: [.file, .gitRef], now: requestedAt)
    let replay = try store.requestHandover(taskId: TaskID("task-1"), reason: "different retry", immediate: false,
                                           target: nil, sinks: [], now: requestedAt.addingTimeInterval(1))
    XCTAssertEqual(replay, first)
    XCTAssertEqual(try store.pendingHandoverRequest(attemptId: AttemptID("attempt-1")), first)
    try store.consumeHandoverRequest(requestId: first.requestId, now: requestedAt.addingTimeInterval(2))
    XCTAssertNil(try store.pendingHandoverRequest(attemptId: AttemptID("attempt-1")))
    XCTAssertThrowsError(try store.consumeHandoverRequest(requestId: first.requestId, now: requestedAt.addingTimeInterval(3)))
  }

  private func sampleTask() -> WorkTask {
    WorkTask(id: TaskID("task-1"), intentId: IntentID("intent-1"), title: "Task", instruction: "Work",
             plan: .workflow(WorkflowReference(name: "flow")), state: .ready)
  }
}
