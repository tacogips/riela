#if os(macOS)
import Foundation
import RielaAppSupport
import RielaCore
import RielaCLI
import RielaGraphQL
import RielaServer
@testable import RielaApp
import XCTest

@MainActor
final class WorkflowEditorLiveAgentTests: XCTestCase {
  func testLiveCodexProducesIntermediateGraph() async throws {
    guard ProcessInfo.processInfo.environment["RIELA_TEST_LIVE_EDITOR_AGENT"] == "1" else {
      throw XCTSkip("Opt-in live provider check")
    }
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/workflow-graph-studio/live-\(UUID().uuidString)")
    let app = RielaApp()
    app.profileStore = RielaAppProfileStore(appRootURL: root)
    app.daemonState.assistant.vendor = .codexCLI
    let definition: JSONObject = ["workflowId": .string("live-editor-test"), "description": .string(""),
      "defaults": .object(["nodeTimeoutMs": .number(120000), "maxLoopIterations": .number(3)]),
      "entryStepId": .string(""), "nodes": .array([]), "steps": .array([])]
    let body: JSONObject = ["definition": .object(definition), "message": .string(
      "Create a research then summary workflow with two agent steps. "
        + "Emit a complete definition after adding the first step, then another after adding and connecting the second. "
        + "Use the specified NDJSON protocol. Do not run tools."
    )]
    let response = await app.webWorkflowEditorGeneration(request: RielaHTTPRequest(
      method: "POST", path: "/api/v1/workflow-editor/generations",
      headers: ["x-riela-profile": app.daemonProfileName.rawValue], body: try JSONEncoder().encode(body)
    ))
    XCTAssertEqual(response.status, 200)
    let started = try JSONDecoder().decode(WorkflowEditorGenerationSnapshot.self, from: response.body)
    var sawIntermediate = false
    var final: WorkflowEditorGenerationSnapshot?
    for _ in 0..<600 {
      if let snapshot = await app.workflowEditorGenerations.snapshot(id: started.id, profile: started.profile) {
        if snapshot.status == .running, case let .array(steps)? = snapshot.definition["steps"], steps.count == 1 {
          sawIntermediate = true
        }
        if snapshot.status != .running { final = snapshot; break }
      }
      try await Task.sleep(for: .milliseconds(500))
    }
    if final == nil {
      _ = await app.workflowEditorGenerations.cancel(id: started.id, profile: started.profile)
    }
    let result = try XCTUnwrap(final, "Live provider timed out")
    XCTAssertEqual(result.status, .completed, result.error ?? "")
    guard case let .array(steps) = result.definition["steps"] else { return XCTFail("Missing generated steps") }
    XCTAssertEqual(steps.count, 2)
    XCTAssertTrue(sawIntermediate, "Expected an actual one-step graph before completion, not just chat text")
    // Validate and persist the actual generated document through the same
    // registry contract used by the editor, without modifying the user's home.
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": root.path]) {
      let bundle = root.appendingPathComponent("generated")
      try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
      try JSONEncoder().encode(result.definition).write(to: bundle.appendingPathComponent("workflow.json"))
      let provider = FileWorkflowRegistryGraphQLProvider(workingDirectory: root.path,
        webPrincipalId: RielaAppWebRegistryAuthorizer.principalId, authoringProjection: true)
      let saved = try await provider.registerMutableWorkflow(
        input: GraphQLRegisterMutableWorkflowInput(definition: result.definition), resolvedBundleURL: bundle)
      XCTAssertTrue(saved.accepted)
      let identity = try XCTUnwrap(saved.workflow)
      let reopened = try await provider.workflow(target: WorkflowRegistryTarget(
        workflowId: identity.workflowId, scope: .user, originId: identity.originId))
      XCTAssertNotNil(reopened.definitionRevision)
      guard case let .array(reopenedSteps)? = reopened.definition?["steps"] else { return XCTFail("Saved graph missing") }
      XCTAssertEqual(reopenedSteps.count, 2)
    }
    try FileManager.default.removeItem(at: root)
  }
}
#endif
