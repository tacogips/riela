import Foundation
import RielaCore
import RielaGraphQL
import RielaServer
import XCTest
@testable import RielaCLI

@MainActor
final class ServeWebEditorTests: XCTestCase {
  func testCopiesActivatesRunsAndInspectsActualValuesThroughServerRoutes() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("tmp/serve-editor-tests/\(UUID().uuidString)")
    let project = root.appendingPathComponent("project")
    let home = root.appendingPathComponent("home")
    let source = project.appendingPathComponent(".riela/workflows/server-editor")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"""
      {"workflowId":"server-editor","defaults":{"nodeTimeoutMs":1000,"maxLoopIterations":3},"entryStepId":"wait",
       "nodes":[{"id":"wait","nodeFile":"wait.json"}],"steps":[{"id":"wait","nodeId":"wait","role":"worker"}]}
      """#.utf8).write(to: source.appendingPathComponent("workflow.json"))
    try Data(#"{"id":"wait","nodeType":"sleep","sleep":{"durationMs":1},"variables":{}}"#.utf8)
      .write(to: source.appendingPathComponent("wait.json"))
    let host = ServeWebHost(
      homeDirectory: home, workingDirectory: project, sessionStoreRoot: root.appendingPathComponent("sessions").path,
      host: "127.0.0.1", port: 8787, fallback: DeterministicServerHTTPAdapter(), environment: ["HOME": home.path]
    )
    let bootstrap = try object(await host.response(for: RielaHTTPRequest(
      method: "GET", path: "/api/v1/bootstrap", headers: ["host": "127.0.0.1:8787"]
    )))
    let headers = ["host": "127.0.0.1:8787", "origin": "http://127.0.0.1:8787",
      "x-riela-csrf": try XCTUnwrap(bootstrap["csrfToken"] as? String),
      "x-riela-profile": "default", "content-type": "application/json"]
    let sources = try object(await host.response(for: RielaHTTPRequest(
      method: "GET", path: "/api/v1/workflows/sources", headers: headers
    )))
    let sourceId = try XCTUnwrap((sources["discovered"] as? [[String: Any]])?.first?["id"] as? String)
    let encoded = try XCTUnwrap(sourceId.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
    let copy = await host.response(for: RielaHTTPRequest(
      method: "POST", path: "/api/v1/workflows/sources/\(sourceId)/editable-copy",
      percentEncodedPath: "/api/v1/workflows/sources/\(encoded)/editable-copy", headers: headers, body: Data("{}".utf8)
    ))
    XCTAssertEqual(copy.status, 200)
    let copied = try JSONDecoder().decode(GraphQLWorkflowMutationPayload.self, from: copy.body)
    XCTAssertTrue(copied.accepted)
    let workflow = try XCTUnwrap(copied.workflow)
    let target: [String: Any] = ["workflowId": workflow.workflowId, "originId": workflow.originId, "scope": "USER"]
    let activation = try await post(host, path: "/graphql", headers: headers, body: [
      "query": """
        mutation Activate($input: SetWorkflowActivationInput!) {
          activateWorkflow(input: $input) { accepted errors { code message } }
        }
        """,
      "variables": ["input": ["target": target, "expectedDefinitionRevision": try XCTUnwrap(workflow.definitionRevision),
        "expectedActivationState": "DEACTIVATED"]]
    ])
    let activationJSON = try object(activation)
    XCTAssertEqual(((activationJSON["data"] as? [String: Any])?["activateWorkflow"] as? [String: Any])?["accepted"] as? Bool, true)
    let loaded = try await post(host, path: "/api/v1/workflow-editor/definition", headers: headers, body: target)
    let active = try JSONDecoder().decode(GraphQLWorkflowRegistryEntry.self, from: loaded.body)
    var input: [String: Any] = ["workflowId": active.workflowId, "originId": active.originId,
      "definitionRevision": "stale", "workingDirectory": project.path, "variables": ["sentinel": "actual server input"]]
    let stale = try await post(host, path: "/api/v1/workflow-editor/launches", headers: headers, body: input)
    XCTAssertEqual(stale.status, 409)
    input["definitionRevision"] = try XCTUnwrap(active.definitionRevision)
    let launched = try await post(host, path: "/api/v1/workflow-editor/launches", headers: headers, body: input)
    XCTAssertEqual(launched.status, 202, String(data: launched.body, encoding: .utf8) ?? "")
    let jobId = try XCTUnwrap(try object(launched)["id"] as? String)
    var job: [String: Any] = [:]
    for _ in 0..<200 {
      job = try object(await host.response(for: RielaHTTPRequest(
        method: "GET", path: "/api/v1/workflow-editor/launches/\(jobId)", headers: headers
      )))
      if job["status"] as? String != "running" { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(job["status"] as? String, "completed")
    let sessionId = try XCTUnwrap(job["sessionId"] as? String)
    let run = try object(await host.response(for: RielaHTTPRequest(
      method: "GET", path: "/api/v1/workflow-editor/runs/\(sessionId)", headers: headers
    )))
    let executionId = try XCTUnwrap((run["steps"] as? [[String: Any]])?.first?["executionId"] as? String)
    let evidence = try object(await host.response(for: RielaHTTPRequest(
      method: "GET", path: "/api/v1/workflow-editor/runs/\(sessionId)/steps/\(executionId)", headers: headers
    )))
    XCTAssertEqual(evidence["inputRecorded"] as? Bool, true)
    XCTAssertEqual(evidence["outputRecorded"] as? Bool, true)
    XCTAssertTrue(String(describing: evidence["input"]).contains("actual server input"))
    XCTAssertEqual((evidence["output"] as? [String: Any])?["status"] as? String, "completed")
    var wrongProfile = headers
    wrongProfile["x-riela-profile"] = "other"
    let rejected = await host.response(for: RielaHTTPRequest(
      method: "GET", path: "/api/v1/workflow-editor/runs/\(sessionId)", headers: wrongProfile
    ))
    XCTAssertEqual(rejected.status, 409)
    await host.shutdown()
  }

  private func object(_ response: RielaHTTPResponse) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
  }

  private func post(_ host: ServeWebHost, path: String, headers: [String: String], body: [String: Any]) async throws -> RielaHTTPResponse {
    await host.response(for: RielaHTTPRequest(
      method: "POST", path: path, headers: headers, body: try JSONSerialization.data(withJSONObject: body)
    ))
  }
}
