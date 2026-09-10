#if os(macOS)
import Foundation
import RielaCLI
import RielaCore
import RielaGraphQL
import RielaServer
@testable import RielaApp
import XCTest

@MainActor
final class WorkflowEditorLaunchTests: XCTestCase {
  func testLaunchesRealSavedWorkflowAndReadsRecordedInputs() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/workflow-graph-studio/launch-\(UUID().uuidString)")
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"""
      {"workflowId":"editor-launch-test","description":"Editor run test",
       "defaults":{"nodeTimeoutMs":120000,"maxLoopIterations":3},"entryStepId":"wait",
       "nodes":[{"id":"wait","nodeFile":"wait.json"}],"steps":[{"id":"wait","nodeId":"wait","role":"worker"}]}
      """#.utf8)
      .write(to: source.appendingPathComponent("workflow.json"))
    try Data(#"{"id":"wait","nodeType":"sleep","sleep":{"durationMs":1},"variables":{}}"#.utf8)
      .write(to: source.appendingPathComponent("wait.json"))
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": root.path]) {
      let registered = try await FileWorkflowRegistryGraphQLProvider(workingDirectory: root.path).registerMutableWorkflow(
        input: GraphQLRegisterMutableWorkflowInput(activationState: .active), resolvedBundleURL: source
      )
      let agentSource = root.appendingPathComponent("agent-source")
      try FileManager.default.createDirectory(at: agentSource, withIntermediateDirectories: true)
      let agentDefinition = #"""
        {"workflowId":"new-workflow","description":"","defaults":{"nodeTimeoutMs":120000,"maxLoopIterations":3},
         "entryStepId":"step-1","nodes":[{"id":"step-1","addon":{"name":"riela/codex-sdk-worker","version":"1",
         "config":{"promptTemplate":"Describe the task for this step."}}}],
         "steps":[{"id":"step-1","nodeId":"step-1","role":"worker","transitions":[]}]}
        """#
      try Data(agentDefinition.utf8).write(to: agentSource.appendingPathComponent("workflow.json"))
      let inlineAgent = try await FileWorkflowRegistryGraphQLProvider(workingDirectory: root.path,
        webPrincipalId: RielaAppWebRegistryAuthorizer.principalId).registerMutableWorkflow(
          input: GraphQLRegisterMutableWorkflowInput(definition: [:], activationState: .active), resolvedBundleURL: agentSource
        )
      XCTAssertTrue(inlineAgent.accepted, "The graph editor's default agent shape must pass real registry validation")
      let created = try XCTUnwrap(registered.workflow)
      let target = WorkflowRegistryTarget(workflowId: created.workflowId, scope: .user, originId: created.originId)
      let workflow = try await FileWorkflowRegistryGraphQLProvider(workingDirectory: root.path,
        webPrincipalId: RielaAppWebRegistryAuthorizer.principalId).workflow(target: target)
      let app = RielaApp()
      app.appHomeDirectory = root
      app.webSessionStoreRootOverride = root.appendingPathComponent("sessions").path
      let body: JSONObject = ["workflowId": .string(workflow.workflowId), "originId": .string(workflow.originId),
        "definitionRevision": .string(try XCTUnwrap(workflow.definitionRevision)), "workingDirectory": .string(source.path),
        "variables": .object(["sentinelInput": .string("actual web input")])]
      var request = RielaHTTPRequest(method: "POST", path: "/api/v1/workflow-editor/launches",
        headers: ["x-riela-profile": app.daemonProfileName.rawValue], body: try JSONEncoder().encode(body))
      var staleBody = body
      staleBody["definitionRevision"] = .string("stale")
      request.body = try JSONEncoder().encode(staleBody)
      XCTAssertEqual(app.webWorkflowEditorLaunch(request: request).status, 409)
      XCTAssertTrue(app.webWorkflowLaunches.isEmpty)
      request.body = try JSONEncoder().encode(body)
      let launched = app.webWorkflowEditorLaunch(request: request)
      XCTAssertEqual(launched.status, 202, String(data: launched.body, encoding: .utf8) ?? "")
      let job = try XCTUnwrap(app.webWorkflowLaunches.values.first)
      for _ in 0..<200 where job.snapshot["status"] == .string("running") {
        try await Task.sleep(for: .milliseconds(50))
      }
      XCTAssertEqual(job.snapshot["status"], .string("completed"), String(describing: job.snapshot))
      guard case let .string(sessionId) = job.snapshot["sessionId"] else { return XCTFail("Missing real session ID") }
      let persisted = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.appendingPathComponent("sessions/runtime-records").path)
        .loadStrictReadOnly(sessionId: sessionId)
      XCTAssertEqual(persisted.session.executions.count, 1)
      XCTAssertEqual(persisted.session.executions.first?.inputSnapshot?["arguments"], .object(["sentinelInput": .string("actual web input")]))
      XCTAssertEqual(persisted.session.executions.first?.acceptedOutput?.payload["status"], .string("completed"))
    }
  }
}
#endif
