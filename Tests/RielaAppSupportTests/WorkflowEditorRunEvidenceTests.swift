#if os(macOS)
import Foundation
import RielaCore
import RielaServer
@testable import RielaApp
import XCTest

@MainActor
final class WorkflowEditorRunEvidenceTests: XCTestCase {
  func testReadsActualPersistedAttemptValuesAndRejectsOtherProfile() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/workflow-graph-studio/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = RielaApp()
    app.webSessionStoreRootOverride = root.path
    let now = Date()
    let execution = WorkflowStepExecution(
      executionId: "exec-1", stepId: "work", nodeId: "node", attempt: 1,
      inputSnapshot: ["actualInput": .string("exact input")], status: .completed,
      acceptedOutput: WorkflowAcceptedOutputMetadata(payload: ["actualOutput": .string("exact output")], when: [:], acceptedAt: now),
      createdAt: now, updatedAt: now
    )
    var session = WorkflowSession(workflowId: "wf", sessionId: "run-1", status: .completed,
      entryStepId: "work", createdAt: now, updatedAt: now)
    session.executions = [execution]
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.appendingPathComponent("runtime-records").path)
      .save(WorkflowRuntimePersistenceSnapshot(session: session))
    let request = RielaHTTPRequest(method: "GET", path: "/api/v1/workflow-editor/runs/run-1/steps/exec-1",
      headers: ["x-riela-profile": app.daemonProfileName.rawValue])
    let response = app.webWorkflowEditorRunEvidence(request: request)
    XCTAssertEqual(response.status, 200)
    let value = try JSONDecoder().decode(JSONObject.self, from: response.body)
    XCTAssertEqual(value["input"], .object(["actualInput": .string("exact input")]))
    XCTAssertEqual(value["output"], .object(["actualOutput": .string("exact output")]))
    var foreign = request
    foreign.headers["x-riela-profile"] = "other-profile"
    XCTAssertEqual(app.webWorkflowEditorRunEvidence(request: foreign).status, 409)
  }
}
#endif
