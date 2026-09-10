#if os(macOS)
import Foundation
import RielaCLI
import RielaAppSupport
import RielaCore
import RielaGraphQL
import RielaServer
@testable import RielaApp
import XCTest

@MainActor
final class WorkflowEditorDefinitionTests: XCTestCase {
  func testEditableCopyPreservesBundleAndRejectsDuplicateWithoutOverwriting() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/workflow-graph-studio/copy-\(UUID().uuidString)")
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: source.appendingPathComponent("prompts"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let definition = #"""
      {"workflowId":"editor-copy","defaults":{"nodeTimeoutMs":120000,"maxLoopIterations":3},"entryStepId":"work",
       "nodes":[{"id":"work","nodeFile":"nodes/work.json"}],"steps":[{"id":"work","nodeId":"work","role":"worker"}]}
      """#
    let node = #"{"id":"work","executionBackend":"codex-agent","promptTemplateFile":"prompts/work.md","variables":{}}"#
    let prompt = "Preserve this prompt and its formatting.\n\nSecond paragraph.\n"
    try Data(definition.utf8).write(to: source.appendingPathComponent("workflow.json"))
    try Data(node.utf8).write(to: source.appendingPathComponent("nodes/work.json"))
    try Data(prompt.utf8).write(to: source.appendingPathComponent("prompts/work.md"))
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": root.path]) {
      let app = RielaApp()
      app.appHomeDirectory = root
      app.daemonWorkflowSources = [RielaAppDaemonWorkflowCandidate(
        id: "copy-source", workflowId: "editor-copy", displayName: "Copy source", sourceDescription: "Test source",
        workflowDirectory: source.path, workingDirectory: root.path, eventRoot: nil, eventSources: [])]
      var request = RielaHTTPRequest(method: "POST", path: "/api/v1/workflows/sources/copy-source/editable-copy",
        headers: ["x-riela-profile": app.daemonProfileName.rawValue], body: Data("{}".utf8))
      let copied = await app.webAPIResponse(for: request, csrfToken: "unused")
      XCTAssertEqual(copied.status, 200, String(data: copied.body, encoding: .utf8) ?? "")
      let result = try JSONDecoder().decode(GraphQLWorkflowMutationPayload.self, from: copied.body)
      XCTAssertTrue(result.accepted)
      XCTAssertEqual(result.workflow?.activationState, "DEACTIVATED")
      XCTAssertNotNil(result.workflow?.definitionRevision)
      let destination = root.appendingPathComponent(".riela/temporary-workflows/editor-copy")
      for path in ["workflow.json", "nodes/work.json", "prompts/work.md"] {
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(path)),
          try Data(contentsOf: source.appendingPathComponent(path)))
      }
      let duplicate = await app.webAPIResponse(for: request, csrfToken: "unused")
      XCTAssertEqual(duplicate.status, 422)
      XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("prompts/work.md"), encoding: .utf8), prompt)
      let identity = try XCTUnwrap(result.workflow)
      var settingsBody: JSONObject = ["action": .string("load"), "workflowId": .string(identity.workflowId),
        "originId": .string(identity.originId), "nodeId": .string("work"),
        "definitionRevision": .string(try XCTUnwrap(identity.definitionRevision))]
      var settingsRequest = RielaHTTPRequest(method: "POST", path: "/api/v1/workflow-editor/node-settings",
        headers: request.headers, body: try JSONEncoder().encode(settingsBody))
      let loaded = await app.webAPIResponse(for: settingsRequest, csrfToken: "unused")
      XCTAssertEqual(loaded.status, 200)
      let settings = try JSONDecoder().decode(WorkflowEditorNodeSettings.self, from: loaded.body)
      XCTAssertEqual(settings.prompt, prompt)
      settingsBody["action"] = .string("save")
      settingsBody["assetRevision"] = .string(settings.assetRevision)
      settingsBody["prompt"] = .string("Edited through the graph settings dialog.")
      // An external resource edit changes the asset digest even when the
      // workflow definition revision has not changed.
      try Data((prompt + "external change").utf8).write(to: destination.appendingPathComponent("prompts/work.md"))
      settingsRequest.body = try JSONEncoder().encode(settingsBody)
      let staleAsset = await app.webAPIResponse(for: settingsRequest, csrfToken: "unused")
      XCTAssertEqual(staleAsset.status, 409)
      let latestSettings = try WorkflowRegistryService().editorNodeSettings(
        target: WorkflowRegistryTarget(workflowId: identity.workflowId, scope: .user, originId: identity.originId),
        nodeId: "work", definitionRevision: try XCTUnwrap(identity.definitionRevision), workingDirectory: root.path)
      settingsBody["assetRevision"] = .string(latestSettings.assetRevision)
      settingsRequest.body = try JSONEncoder().encode(settingsBody)
      let saved = await app.webAPIResponse(for: settingsRequest, csrfToken: "unused")
      XCTAssertEqual(saved.status, 200, String(data: saved.body, encoding: .utf8) ?? "")
      let savedWorkflow = try JSONDecoder().decode(GraphQLWorkflowRegistryEntry.self, from: saved.body)
      XCTAssertNotEqual(savedWorkflow.definitionRevision, identity.definitionRevision)
      let bundle = try WorkflowRegistryBundleLoader().loadBundle(at: destination,
        rootDirectory: destination.deletingLastPathComponent(), scope: .user)
      XCTAssertEqual(bundle.nodePayloads["work"]?.promptTemplate, "Edited through the graph settings dialog.")
      XCTAssertNil(bundle.nodePayloads["work"]?.promptTemplateFile)
      XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("nodes/work.json"), encoding: .utf8), node)
      XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("prompts/work.md"), encoding: .utf8), prompt + "external change")
      let staleDefinition = await app.webAPIResponse(for: settingsRequest, csrfToken: "unused")
      XCTAssertEqual(staleDefinition.status, 409)
      request.headers["x-riela-profile"] = "other-profile"
      let rejected = await app.webAPIResponse(for: request, csrfToken: "unused")
      XCTAssertEqual(rejected.status, 409)
    }
  }

  func testEditorProjectionEditsSettingsAndRebasesRetainedNodesWithoutLeakingSecrets() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/workflow-graph-studio/definition-\(UUID().uuidString)")
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let raw = #"""
      {"workflowId":"editor-settings","defaults":{"nodeTimeoutMs":120000,"maxLoopIterations":3},"entryStepId":"first",
       "nodes":[
         {"id":"first","addon":{"name":"riela/codex-sdk-worker","version":"1","config":{"promptTemplate":"First prompt"},"env":{"API_KEY":{"fromEnv":"FIRST_SECRET_CANARY"}}}},
         {"id":"second","addon":{"name":"riela/codex-sdk-worker","version":"1","config":{"promptTemplate":"Second prompt\n\nLine two"},"env":{"API_KEY":{"fromEnv":"SECOND_SECRET_CANARY"}}}}],
       "steps":[{"id":"first","nodeId":"first","role":"worker","transitions":[{"toStepId":"second","label":"secret-route-A"},{"toStepId":"second","label":"secret-route-B"}]},
                {"id":"second","nodeId":"second","role":"worker","description":"password=STEP_SECRET_CANARY"}]}
      """#
    try Data(raw.utf8).write(to: source.appendingPathComponent("workflow.json"))
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": root.path]) {
      let provider = FileWorkflowRegistryGraphQLProvider(workingDirectory: root.path,
        webPrincipalId: RielaAppWebRegistryAuthorizer.principalId)
      let registered = try await FileWorkflowRegistryGraphQLProvider(workingDirectory: root.path).registerMutableWorkflow(
        input: GraphQLRegisterMutableWorkflowInput(definition: [:]), resolvedBundleURL: source)
      let identity = try XCTUnwrap(registered.workflow)
      XCTAssertNil(identity.definitionRevision, "Mutation results are metadata-only")
      let target = GraphQLWorkflowTargetInput(workflowId: identity.workflowId, scope: .user, originId: identity.originId)
      let app = RielaApp()
      app.appHomeDirectory = root
      var request = RielaHTTPRequest(method: "POST", path: "/api/v1/workflow-editor/definition",
        headers: ["x-riela-profile": app.daemonProfileName.rawValue], body: try JSONEncoder().encode([
          "workflowId": identity.workflowId, "originId": identity.originId
        ]))
      let response = await app.webAPIResponse(for: request, csrfToken: "unused")
      XCTAssertEqual(response.status, 200, String(data: response.body, encoding: .utf8) ?? "")
      XCTAssertEqual(response.headers["Cache-Control"], "no-store")
      XCTAssertFalse(try XCTUnwrap(String(data: response.body, encoding: .utf8)).contains("SECRET_CANARY"))
      var entry = try JSONDecoder().decode(GraphQLWorkflowRegistryEntry.self, from: response.body)
      var definition = try XCTUnwrap(entry.definition)
      guard case var .array(routeSteps)? = definition["steps"], case var .object(routeStep) = routeSteps[0],
            case let .array(routes)? = routeStep["transitions"] else { return XCTFail("Missing transitions") }
      routeStep["transitions"] = .array([routes[1]])
      routeSteps[0] = .object(routeStep)
      definition["steps"] = .array(routeSteps)
      try JSONEncoder().encode(definition).write(to: source.appendingPathComponent("workflow.json"))
      let routeUpdate = try await provider.updateMutableWorkflow(input: GraphQLUpdateMutableWorkflowInput(
        target: target, definition: definition, expectedDefinitionRevision: entry.definitionRevision), resolvedBundleURL: source)
      XCTAssertTrue(routeUpdate.accepted, "Deleting an earlier route must retain the surviving route's protected fields")
      let routeData = try String(contentsOf: root.appendingPathComponent(".riela/temporary-workflows/editor-settings/workflow.json"), encoding: .utf8)
      XCTAssertFalse(routeData.contains("secret-route-A"))
      XCTAssertTrue(routeData.contains("secret-route-B"))
      let afterRoute = await app.webAPIResponse(for: request, csrfToken: "unused")
      entry = try JSONDecoder().decode(GraphQLWorkflowRegistryEntry.self, from: afterRoute.body)
      definition = try XCTUnwrap(entry.definition)
      guard case let .array(nodes)? = definition["nodes"], case let .array(steps)? = definition["steps"],
            case var .object(second) = nodes[1], case var .object(addon)? = second["addon"],
            case var .object(config)? = addon["config"] else { return XCTFail("Missing editable node settings") }
      XCTAssertEqual(config["promptTemplate"], .string("Second prompt\n\nLine two"))
      config["promptTemplate"] = .string("Changed in the graph")
      addon["config"] = .object(config)
      second["addon"] = .object(addon)
      // Deleting the first step/node shifts indices but must retain the second
      // node's secrets, authenticated against that node's original identity.
      definition["nodes"] = .array([.object(second)])
      definition["steps"] = .array([steps[1]])
      definition["entryStepId"] = .string("second")
      guard case let .object(first) = nodes[0], case let .object(firstAddon)? = first["addon"] else {
        return XCTFail("Missing first-node configuration")
      }
      var forged = definition
      var reboundNode = second
      var reboundAddon = addon
      reboundAddon["env"] = firstAddon["env"]
      reboundNode["addon"] = .object(reboundAddon)
      forged["nodes"] = .array([.object(reboundNode)])
      try JSONEncoder().encode(forged).write(to: source.appendingPathComponent("workflow.json"))
      do {
        _ = try await provider.updateMutableWorkflow(input: GraphQLUpdateMutableWorkflowInput(
          target: target, definition: forged, expectedDefinitionRevision: entry.definitionRevision), resolvedBundleURL: source)
        XCTFail("A retained value must not move to another node")
      } catch let error as WorkflowRegistryError {
        XCTAssertEqual(error.code, .invalidWorkflow)
      }
      try JSONEncoder().encode(definition).write(to: source.appendingPathComponent("workflow.json"))
      let updated = try await provider.updateMutableWorkflow(input: GraphQLUpdateMutableWorkflowInput(
        target: target, definition: definition, expectedDefinitionRevision: entry.definitionRevision), resolvedBundleURL: source)
      XCTAssertTrue(updated.accepted)
      let persisted = try String(contentsOf: root.appendingPathComponent(".riela/temporary-workflows/editor-settings/workflow.json"), encoding: .utf8)
      XCTAssertTrue(persisted.contains("Changed in the graph"))
      XCTAssertTrue(persisted.contains("SECOND_SECRET_CANARY"))
      XCTAssertTrue(persisted.contains("STEP_SECRET_CANARY"))
      XCTAssertFalse(persisted.contains("FIRST_SECRET_CANARY"))
      let refreshed = await app.webAPIResponse(for: request, csrfToken: "unused")
      let latest = try JSONDecoder().decode(GraphQLWorkflowRegistryEntry.self, from: refreshed.body)
      XCTAssertNotEqual(latest.definitionRevision, entry.definitionRevision)
      try JSONEncoder().encode(try XCTUnwrap(latest.definition)).write(to: source.appendingPathComponent("workflow.json"))
      let savedAgain = try await provider.updateMutableWorkflow(input: GraphQLUpdateMutableWorkflowInput(
        target: target, definition: latest.definition, expectedDefinitionRevision: latest.definitionRevision), resolvedBundleURL: source)
      XCTAssertTrue(savedAgain.accepted, "Freshly issued handles must support consecutive saves")
      request.headers["x-riela-profile"] = "different-profile"
      let rejected = await app.webAPIResponse(for: request, csrfToken: "unused")
      XCTAssertEqual(rejected.status, 409)
    }
  }
}
#endif
