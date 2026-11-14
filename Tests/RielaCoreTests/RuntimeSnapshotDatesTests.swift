import Foundation
import XCTest
@testable import RielaCore

final class RuntimeSnapshotDatesTests: XCTestCase {
  func testSubsecondExecutionTimingSurvivesFullAndWebSnapshotReads() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/runtime-snapshot-dates/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let start = Date(timeIntervalSince1970: 100.125)
    let end = Date(timeIntervalSince1970: 100.375)
    let session = WorkflowSession(
      workflowId: "timing", sessionId: "timing-session", status: .completed,
      entryStepId: "worker", createdAt: start, updatedAt: end,
      executions: [WorkflowStepExecution(executionId: "execution", stepId: "worker", nodeId: "worker",
        attempt: 1, status: .completed, createdAt: start, updatedAt: end)]
    )
    try store.save(WorkflowRuntimePersistenceSnapshot(session: session, workflowMessages: []))
    let full = try store.loadStrictReadOnly(sessionId: session.sessionId)
    let web = try store.loadWebSessionDetail(sessionId: session.sessionId, messageLimit: 10)
    for loaded in [full.session, web.session] {
      let execution = try XCTUnwrap(loaded.executions.first)
      XCTAssertEqual(execution.createdAt.timeIntervalSince1970, 100.125, accuracy: 0.001)
      XCTAssertEqual(execution.updatedAt.timeIntervalSince(execution.createdAt), 0.25, accuracy: 0.001)
    }
  }

  func testLegacyWholeSecondSnapshotDatesRemainReadable() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = RuntimeSnapshotDates.decoding
    let date = try decoder.decode(Date.self, from: Data(#""1970-01-01T00:01:40Z""#.utf8))
    XCTAssertEqual(date.timeIntervalSince1970, 100)
    XCTAssertThrowsError(try decoder.decode(Date.self, from: Data(#""not-a-date""#.utf8)))
  }
}
