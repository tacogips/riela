import Foundation
import RielaSQLite
import XCTest
@testable import RielaCore

final class RuntimePayloadBenchmarkTests: XCTestCase {
  func testReducedPayloadsAreAtLeastFiveTimesSmallerForLoopSession() throws {
    let baseline = try measure(reduced: false)
    let reduced = try measure(reduced: true)
    let ratio = Double(baseline.bytes) / Double(reduced.bytes)
    print("ssg4 benchmark baselineBytes=\(baseline.bytes) reducedBytes=\(reduced.bytes) ratio=\(String(format: "%.2f", ratio))")
    XCTAssertGreaterThanOrEqual(baseline.bytes, 5 * reduced.bytes)
    XCTAssertEqual(baseline.session, reduced.session)
  }

  private func measure(reduced: Bool) throws -> (bytes: Int64, session: WorkflowSession) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    var session = WorkflowSession(workflowId: "workflow", sessionId: "root", status: .running,
      entryStepId: "step", createdAt: date, updatedAt: date, executions: [])
    var upstream: JSONObject = [:]
    try SQLiteWorkflowRuntimePersistenceStore.$writesReducedExecutionPayloadsOverride.withValue(reduced) {
      for index in 1...24 {
        let id = String(format: "exec-%02d", index)
        let output = String(format: "%02d", index) + String(repeating: "x", count: 16_382)
        session.executions.append(WorkflowStepExecution(executionId: id, stepId: "step", nodeId: "node", attempt: 1,
          inputSnapshot: ["upstream": .object(upstream)], status: .completed, streamedResponseText: output,
          createdAt: date, updatedAt: date))
        upstream[id] = .string(output)
        try store.save(WorkflowRuntimePersistenceSnapshot(session: session))
      }
      session.status = .completed
      try store.save(WorkflowRuntimePersistenceSnapshot(session: session))
    }
    let db = try SQLiteDatabase.open(path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path),
      mode: .readWriteCreate, options: .writableRuntimeStoreDefault)
    let payload = try XCTUnwrap(db.query("SELECT coalesce(sum(length(bytes)),0) AS n FROM workflow_runtime_payloads WHERE root_session_id='root'").first?["n"])
    let refs = try XCTUnwrap(db.query("SELECT coalesce(sum(length(root_session_id)+length(parent_digest)+length(digest)),0) AS n FROM workflow_runtime_payload_refs WHERE root_session_id='root'").first?["n"])
    return (try XCTUnwrap(Int64(payload)) + (reduced ? try XCTUnwrap(Int64(refs)) : 0), try store.load(sessionId: "root").session)
  }
}
