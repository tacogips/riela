import Foundation
import RielaCore
import XCTest

final class SQLitePersistenceSessionExistsTests: XCTestCase {
  func testSessionExistsReportsOnlyPersistedSnapshots() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-session-exists-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)

    XCTAssertFalse(try store.sessionExists(sessionId: "wf-session-1"), "no database yet")

    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let session = WorkflowSession(
      workflowId: "wf", sessionId: "wf-session-1", status: .completed,
      entryStepId: "entry", createdAt: date, updatedAt: date
    )
    try store.save(WorkflowRuntimePersistenceSnapshot(session: session))

    XCTAssertTrue(try store.sessionExists(sessionId: "wf-session-1"))
    XCTAssertFalse(try store.sessionExists(sessionId: "wf-session-2"))
    XCTAssertThrowsError(try store.sessionExists(sessionId: "../escape"))
  }
}
