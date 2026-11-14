#if os(macOS)
import Foundation
import RielaAppSupport
import RielaCore
import RielaServer
import RielaViewer
import XCTest

// The suite name matches the assigned focused verification filter.
@MainActor
// swiftlint:disable:next type_name
final class RielaAppInstanceExecutionsProjectionTests: XCTestCase {
  func testExecutionTimestampsAndLegacySnapshots() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/instance-control/instance-control-02-executions-projection")
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workflow = root.appendingPathComponent("workflow")
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("prompts"), withIntermediateDirectories: true)
    try Data("""
      {"workflowId":"review-loop","defaults":{"nodeTimeoutMs":120000,"maxLoopIterations":3},
       "entryStepId":"review","nodes":[{"id":"reviewer","nodeFile":"nodes/reviewer.json"}],
       "steps":[{"id":"review","nodeId":"reviewer","role":"worker"}]}
      """.utf8).write(to: workflow.appendingPathComponent("workflow.json"))
    try Data("""
      {"id":"reviewer","executionBackend":"codex-agent","agentSandbox":"read-only",
       "model":"gpt-5.6","promptTemplateFile":"prompts/reviewer.md","variables":{}}
      """.utf8).write(to: workflow.appendingPathComponent("nodes/reviewer.json"))
    try Data("Review".utf8).write(to: workflow.appendingPathComponent("prompts/reviewer.md"))
    let sessions = root.appendingPathComponent("sessions")
    let storeRoot = sessions.appendingPathComponent("runtime-records")
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: storeRoot.path)
    let statuses: [WorkflowSessionStatus] = [.created, .running, .suspended, .completed, .failed, .cancelled]
    for (index, status) in statuses.enumerated() {
      let session = WorkflowSession(workflowId: "review-loop", sessionId: "session-\(index)", status: status,
                                    entryStepId: "review", createdAt: Date(timeIntervalSince1970: 100),
                                    updatedAt: Date(timeIntervalSince1970: 200 + Double(index)))
      try store.save(WorkflowRuntimePersistenceSnapshot(session: session))
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: storeRoot.path),
      """
      UPDATE workflow_runtime_snapshots SET session_json=jsonb_remove(session_json, '$.createdAt')
      WHERE workflow_execution_id='session-0';
      UPDATE workflow_runtime_snapshots SET session_json=jsonb_set(session_json, '$.createdAt', 'invalid')
      WHERE workflow_execution_id='session-1';
      """]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    let candidate = RielaAppDaemonWorkflowCandidate(id: "source", workflowId: "review-loop", displayName: "Review",
      sourceDescription: "project", workflowDirectory: workflow.path, workingDirectory: root.path,
      eventRoot: nil, eventSources: [], requiredEnvironment: [])
    let preference = RielaAppDaemonWorkflowPreference(identity: "instance", sourceIdentity: candidate.id,
                                                       available: true, active: false)
    let projection = RielaWebAPIProjection(profile: .default, state: RielaAppDaemonWorkflowState(),
      instances: [.configured(identity: "instance", source: candidate, preference: preference)], sources: [candidate],
      revision: 1, sessionStoreRoot: sessions.path, serverSettings: [:])
    let response = projection.response(for: RielaHTTPRequest(method: "GET", path: "/api/v1/instances/instance/executions"),
                                       csrfToken: "test")
    XCTAssertEqual(response.status, 200)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    XCTAssertEqual(body["truncated"] as? Bool, false)
    let items = try XCTUnwrap(body["items"] as? [[String: Any]])
    XCTAssertEqual(items.count, statuses.count)
    let formatter = ISO8601DateFormatter()
    for (offset, item) in items.enumerated() {
      let index = statuses.count - offset - 1
      let updated = formatter.string(from: Date(timeIntervalSince1970: 200 + Double(index)))
      XCTAssertEqual(Set(item.keys), Set(["sessionId", "workflowId", "status", "currentStepId", "activeStepIds", "updatedAt", "startedAt", "endedAt"]))
      XCTAssertEqual(item["sessionId"] as? String, "session-\(index)")
      XCTAssertEqual(item["workflowId"] as? String, "review-loop")
      XCTAssertEqual(item["status"] as? String, statuses[index].rawValue)
      XCTAssertTrue(item["currentStepId"] is NSNull)
      XCTAssertEqual(item["activeStepIds"] as? [String], [])
      XCTAssertEqual(item["updatedAt"] as? String, updated)
      if index < 2 { XCTAssertTrue(item["startedAt"] is NSNull) } else { XCTAssertEqual(item["startedAt"] as? String, formatter.string(from: Date(timeIntervalSince1970: 100))) }
      if index < 3 { XCTAssertTrue(item["endedAt"] is NSNull) } else { XCTAssertEqual(item["endedAt"] as? String, updated) }
    }
  }

  func testViewerSummaryDecodesWithoutStartedAt() throws {
    let data = Data("""
      {"sessionId":"s","workflowId":"w","status":"running","activeStepIds":[],"updatedAt":0}
      """.utf8)
    XCTAssertNil(try JSONDecoder().decode(WorkflowViewerSessionSummary.self, from: data).startedAt)
  }
}
#endif
