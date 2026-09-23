#if os(macOS)
import Foundation
import RielaCLI
import RielaCore
@testable import RielaApp
import XCTest

@MainActor
final class RielaDesktopWorkflowTests: XCTestCase {
  func testDesktopRegistryRegistrationReadAndRevisionCheckedSave() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/tauri-registry-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": root.path]) {
      let app = RielaApp()
      app.appHomeDirectory = root
      let definition: JSONObject = [
        "workflowId": .string("desktop-contract"),
        "description": .string("Before"),
        "defaults": .object(["nodeTimeoutMs": .number(120000), "maxLoopIterations": .number(3)]),
        "entryStepId": .string("work"),
        "nodes": .array([.object([
          "id": .string("work"),
          "addon": .object([
            "name": .string("riela/codex-sdk-worker"), "version": .string("1"),
            "config": .object(["promptTemplate": .string("Return a short response.")])
          ])
        ])]),
        "steps": .array([.object(["id": .string("work"), "nodeId": .string("work"), "role": .string("worker")])])
      ]
      let registered = try await execute(app,
        query: "mutation($input: RegisterMutableWorkflowInput!) { registerMutableWorkflow(input: $input) { accepted workflow { originId workflowId } errors { message } } }",
        input: ["definition": .object(definition), "activationState": .string("DEACTIVATED")])
      guard case let .object(registration)? = registered["registerMutableWorkflow"],
            case let .object(summary)? = registration["workflow"],
            let originId = summary["originId"] else {
        return XCTFail("Registration failed: \(registered)")
      }
      XCTAssertEqual(registration["accepted"], .bool(true))
      let target: JSONObject = [
        "workflowId": .string("desktop-contract"), "scope": .string("USER"), "originId": originId
      ]
      let read = try await execute(app,
        query: "query($input: WorkflowTargetInput!) { workflow(target: $input) { workflow { definition definitionRevision } errors { message } } }",
        input: target)
      guard case let .object(payload)? = read["workflow"],
            case let .object(workflow)? = payload["workflow"],
            case var .object(editable)? = workflow["definition"],
            let revision = workflow["definitionRevision"] else {
        return XCTFail("Detail failed: \(read)")
      }
      editable["description"] = .string("After")
      let updateInput: JSONObject = [
        "target": .object(target), "definition": .object(editable), "expectedDefinitionRevision": revision
      ]
      let query = "mutation($input: UpdateMutableWorkflowInput!) { updateMutableWorkflow(input: $input) { accepted errors { code message } } }"
      let updated = try await execute(app, query: query, input: updateInput)
      guard case let .object(update)? = updated["updateMutableWorkflow"] else {
        return XCTFail("Save failed: \(updated)")
      }
      XCTAssertEqual(update["accepted"], .bool(true), "\(updated)")
      let data = try Data(contentsOf: root.appendingPathComponent(".riela/temporary-workflows/desktop-contract/workflow.json"))
      XCTAssertEqual(try JSONDecoder().decode(JSONObject.self, from: data)["description"], .string("After"))
      let stale = try await execute(app, query: query, input: updateInput)
      guard case let .object(conflict)? = stale["updateMutableWorkflow"] else {
        return XCTFail("Missing conflict response")
      }
      XCTAssertEqual(conflict["accepted"], .bool(false))
    }
  }

  private func execute(_ app: RielaApp, query: String, input: JSONObject) async throws -> JSONObject {
    let requestBody: JSONObject = ["query": .string(query), "variables": .object(["input": .object(input)])]
    let body = try JSONEncoder().encode(requestBody)
    let response = await app.desktopAPIResponse(
      for: RielaDesktopRequest(
        method: "POST", path: "/graphql",
        headers: ["X-Riela-Profile": app.daemonProfileName.rawValue, "Content-Type": "application/json"],
        body: try XCTUnwrap(String(data: body, encoding: .utf8))
      ),
      csrfToken: ""
    )
    XCTAssertEqual(response.status, 200)
    let document = try JSONDecoder().decode(JSONObject.self, from: response.body)
    XCTAssertNil(document["errors"], "\(document)")
    guard case let .object(data)? = document["data"] else {
      throw CocoaError(.coderReadCorrupt)
    }
    return data
  }
}
#endif
