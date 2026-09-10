import Foundation
import RielaCore
import RielaGraphQL
import RielaAppSupport
import RielaServer
import XCTest
@testable import RielaCLI

@MainActor
final class ServeWebHostTests: XCTestCase {
  func testDiscoversRealWorkflowAndProjectsDefinition() async throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let workflow = root.appendingPathComponent("project/.riela/workflows/web-example")
    try FileManager.default.createDirectory(at: workflow, withIntermediateDirectories: true)
    try Data("""
      {"workflowId":"web-example","entryStepId":"start", "defaults":{"maxLoopIterations":3,"nodeTimeoutMs":1000},
       "nodes":[{"id":"worker","nodeFile":"worker.json"}],
       "steps":[{"id":"start","nodeId":"worker","role":"worker"}]}
      """.utf8).write(to: workflow.appendingPathComponent("workflow.json"))
    try Data("{}".utf8).write(to: workflow.appendingPathComponent("worker.json"))
    let host = makeHost(root: root)
    let bootstrap = await host.response(for: get("/api/v1/bootstrap"))
    XCTAssertEqual(bootstrap.status, 200)
    XCTAssertEqual(try object(bootstrap)["profile"] as? String, "default")
    let sourcesResponse = await host.response(for: get("/api/v1/workflows/sources"))
    let sources = try XCTUnwrap(try object(sourcesResponse)["discovered"] as? [[String: Any]])
    let source = try XCTUnwrap(sources.first { $0["workflowId"] as? String == "web-example" })
    let identity = try XCTUnwrap(source["id"] as? String)
    let encoded = try XCTUnwrap(identity.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
    let path = "/api/v1/workflows/sources/\(encoded)/definition"
    let definitionResponse = await host.response(for: RielaHTTPRequest(
      method: "GET", path: try XCTUnwrap(path.removingPercentEncoding), percentEncodedPath: path,
      headers: ["host": "127.0.0.1:8787"]
    ))
    XCTAssertEqual(definitionResponse.status, 200, String(data: definitionResponse.body, encoding: .utf8) ?? "")
    let definition = try XCTUnwrap(try object(definitionResponse)["definition"] as? [String: Any])
    XCTAssertEqual(definition["entryStepId"] as? String, "start")
    XCTAssertEqual((definition["nodes"] as? [[String: Any]])?.first?["id"] as? String, "start")
    let instances = await host.response(for: get("/api/v1/instances"))
    XCTAssertEqual((try object(instances)["items"] as? [[String: Any]])?.first?["workflowId"] as? String, "web-example")
  }

  func testLocalRegistryRequiresBrowserProvenanceAndProfile() async throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let host = makeHost(root: root)
    let bootstrap = try object(await host.response(for: get("/api/v1/bootstrap")))
    let token = try XCTUnwrap(bootstrap["csrfToken"] as? String)
    let body = try JSONSerialization.data(withJSONObject: ["query": """
      query { configuration { profile revision appearance { colorScheme } }
        workflows(filter: { provenance: MUTABLE, scope: USER }) {
          workflows { workflowId definitionRevision } errors { code message }
        }
      }
      """])
    var request = RielaHTTPRequest(method: "POST", path: "/graphql", headers: ["host": "127.0.0.1:8787"], body: body)
    let nonBrowser = await host.response(for: request)
    XCTAssertNotEqual(nonBrowser.status, 403)
    XCTAssertTrue((String(data: nonBrowser.body, encoding: .utf8) ?? "").contains("UNAUTHENTICATED"))
    request.headers["x-riela-csrf"] = "invalid"
    let rejected = await host.response(for: request)
    XCTAssertEqual(rejected.status, 403)
    request.headers.merge([
      "origin": "http://127.0.0.1:8787", "x-riela-csrf": token, "content-type": "application/json"
    ]) { _, value in value }
    let conflict = await host.response(for: request)
    XCTAssertEqual(conflict.status, 409)
    request.headers["x-riela-profile"] = "default"
    let response = await host.response(for: request)
    XCTAssertEqual(response.status, 200)
    let json = try object(response)
    XCTAssertNil(json["errors"], (String(data: response.body, encoding: .utf8) ?? ""))
    XCTAssertNotNil((json["data"] as? [String: Any])?["workflows"])
    XCTAssertNotNil((json["data"] as? [String: Any])?["configuration"])
    request.headers["host"] = "attacker.invalid:8787"
    let wrongHost = await host.response(for: request)
    XCTAssertEqual(wrongHost.status, 403)
  }

  func testPublicListenerDoesNotGrantLocalRegistryAuthority() async throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let host = makeHost(root: root, bindHost: "0.0.0.0")
    let response = await host.response(for: RielaHTTPRequest(
      method: "POST", path: "/graphql", headers: ["host": "0.0.0.0:8787"],
      body: Data(#"{"query":"query { workflows { workflows { workflowId } errors { code message } } }"}"#.utf8)
    ))
    XCTAssertTrue((String(data: response.body, encoding: .utf8) ?? "").contains("UNAUTHENTICATED"))
  }

  func testPublicBrowserRequiresTokenAndOriginBeforeConfigurationAccess() async throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let host = ServeWebHost(
      homeDirectory: root.appendingPathComponent("home"), workingDirectory: root,
      sessionStoreRoot: nil, host: "0.0.0.0", port: 8787,
      fallback: DeterministicServerHTTPAdapter(),
      environment: ["HOME": root.appendingPathComponent("home").path,
        "RIELA_WEB_TOKEN": "test-browser-token", "RIELA_WEB_ORIGIN": "https://riela.example"]
    )
    var request = RielaHTTPRequest(method: "GET", path: "/api/v1/bootstrap", headers: ["host": "riela.example"])
    let missing = await host.response(for: request)
    XCTAssertEqual(missing.status, 401)
    XCTAssertEqual(missing.headers["Cache-Control"], "no-store")
    request.headers["authorization"] = "Bearer wrong-token"
    let wrong = await host.response(for: request)
    XCTAssertEqual(wrong.status, 401)
    request.headers["authorization"] = "Bearer test-browser-token"
    let bootstrap = try object(await host.response(for: request))
    let csrf = try XCTUnwrap(bootstrap["csrfToken"] as? String)
    request = RielaHTTPRequest(method: "POST", path: "/graphql", headers: [
      "host": "riela.example", "authorization": "Bearer test-browser-token",
      "origin": "https://riela.example", "content-type": "application/json",
      "x-riela-csrf": csrf, "x-riela-profile": "default"
    ], body: Data(#"{"query":"query { configuration { profile revision } }"}"#.utf8))
    let accepted = try object(await host.response(for: request))
    XCTAssertNotNil((accepted["data"] as? [String: Any])?["configuration"])
    for header in ["authorization", "origin", "host", "x-riela-csrf"] {
      var invalid = request
      invalid.headers[header] = "invalid"
      let rejected = await host.response(for: invalid)
      XCTAssertEqual(rejected.status, header == "authorization" ? 401 : 403, header)
    }
    request.headers["x-riela-profile"] = "other"
    let conflict = await host.response(for: request)
    XCTAssertEqual(conflict.status, 409)
  }

  func testIncompletePublicAccessConfigurationFailsClosed() {
    for environment in [[:], ["RIELA_WEB_TOKEN": "token"],
      ["RIELA_WEB_TOKEN": "token", "RIELA_WEB_ORIGIN": "https://riela.example/path"],
      ["RIELA_WEB_TOKEN": "token", "RIELA_WEB_ORIGIN": "https://user@riela.example"]] {
      let policy = ServeWebAccess(host: "0.0.0.0", environment: environment)
      XCTAssertEqual(policy.rejection(for: get("/api/v1/bootstrap"), localAuthority: "0.0.0.0:8787", csrfToken: "csrf")?.status, 503)
    }
  }

  func testInstanceActionsPersistRunStateAndStopOnProfileSwitch() async throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let workflow = root.appendingPathComponent("project/.riela/workflows/instance-test")
    try FileManager.default.createDirectory(at: workflow, withIntermediateDirectories: true)
    try Data(#"{"workflowId":"instance-test","defaults":{"nodeTimeoutMs":1000,"maxLoopIterations":3},"entryStepId":"wait","nodes":[{"id":"wait","nodeFile":"wait.json"}],"steps":[{"id":"wait","nodeId":"wait"}]}"#.utf8)
      .write(to: workflow.appendingPathComponent("workflow.json"))
    try Data(#"{"id":"wait","nodeType":"sleep","sleep":{"durationMs":1},"variables":{}}"#.utf8)
      .write(to: workflow.appendingPathComponent("wait.json"))
    let host = makeHost(root: root)
    let bootstrap = try object(await host.response(for: get("/api/v1/bootstrap")))
    let identity = try XCTUnwrap(host.instances.first?.identity)
    let encoded = try XCTUnwrap(identity.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
    let csrf = try XCTUnwrap(bootstrap["csrfToken"] as? String)
    func action(_ action: String, revision: Int? = nil, profile: String = "default") async throws -> RielaHTTPResponse {
      await host.response(for: RielaHTTPRequest(
        method: "POST", path: "/api/v1/instances/\(identity)/actions",
        percentEncodedPath: "/api/v1/instances/\(encoded)/actions",
        headers: ["host": "127.0.0.1:8787", "origin": "http://127.0.0.1:8787",
          "content-type": "application/json", "x-riela-csrf": csrf],
        body: try JSONSerialization.data(withJSONObject: [
          "action": action, "expectedRevision": revision ?? host.revision, "expectedProfile": profile
        ])
      ))
    }
    let stale = try await action("start", revision: -1)
    XCTAssertEqual(stale.status, 409)
    let wrongProfile = try await action("start", profile: "other")
    XCTAssertEqual(wrongProfile.status, 409)
    let started = try await action("start")
    XCTAssertEqual(started.status, 200, String(data: started.body, encoding: .utf8) ?? "")
    XCTAssertEqual(host.runtime.snapshot(for: identity).status, .running, host.runtime.snapshot(for: identity).detail)
    XCTAssertEqual(host.stateStore.load().preferences[identity]?.active, true)
    let restarted = try await action("restart")
    XCTAssertEqual(restarted.status, 200)
    let stopped = try await action("stop")
    XCTAssertEqual(stopped.status, 200)
    XCTAssertEqual(host.runtime.snapshot(for: identity).status, .stopped)
    XCTAssertEqual(host.stateStore.load().preferences[identity]?.active, false)
    let startedAgain = try await action("start")
    XCTAssertEqual(startedAgain.status, 200)
    let disabled = try await action("disableAtLaunch")
    XCTAssertEqual(disabled.status, 200)
    XCTAssertEqual(host.runtime.snapshot(for: identity).status, .running)
    _ = try await host.switchProfile(input: decode(GraphQLProfileConfigurationInput.self, [
      "expectedRevision": host.revision, "expectedProfile": "default", "name": "other"
    ]))
    XCTAssertEqual(host.runtime.snapshot(for: identity).status, .stopped)
    XCTAssertEqual(host.runtimeProfile.rawValue, "other")
    _ = try await host.switchProfile(input: decode(GraphQLProfileConfigurationInput.self, [
      "expectedRevision": host.revision, "expectedProfile": "other", "name": "default"
    ]))
    XCTAssertEqual(host.runtime.snapshot(for: identity).status, .stopped)
    let enabled = try await action("enableAtLaunch")
    XCTAssertEqual(enabled.status, 200)
    await host.startConfiguredInstances()
    XCTAssertEqual(host.runtime.snapshot(for: identity).status, .running)
    await host.shutdown()
    XCTAssertEqual(host.runtime.snapshot(for: identity).status, .stopped)
  }

  func testConfigurationWritesPersistAndRejectStaleViews() async throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let host = makeHost(root: root)
    let initial = try await host.configuration()
    XCTAssertEqual(initial.profile, "default")
    let appearance = try await host.updateAppearance(input: GraphQLUpdateAppearanceConfigInput(
      expectedRevision: initial.revision, expectedProfile: initial.profile, colorScheme: "light"
    ))
    XCTAssertGreaterThan(appearance.revision, initial.revision)
    XCTAssertEqual(appearance.appearance.colorScheme, "light")
    do {
      _ = try await host.updateAppearance(input: GraphQLUpdateAppearanceConfigInput(
        expectedRevision: initial.revision, expectedProfile: initial.profile, colorScheme: "dark"
      ))
      XCTFail("Stale configuration must not overwrite the saved appearance")
    } catch let error as RielaConfigurationGraphQLError {
      XCTAssertEqual(error.code, "REVISION_CONFLICT")
    }
    let assistant = try await host.updateAssistant(input: GraphQLUpdateAssistantConfigurationInput(
      expectedRevision: appearance.revision, expectedProfile: appearance.profile,
      assistance: "Use concise replies", vendor: "codex-cli", model: "test-model"
    ))
    XCTAssertEqual(assistant.assistant.assistance, "Use concise replies")
    let directory = root.appendingPathComponent("extra-workflow")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"{"workflowId":"added-workflow","entryStepId":"start","nodes":[{"id":"start","nodeFile":"node.json"}],"steps":[{"id":"start","nodeId":"start"}]}"#.utf8)
      .write(to: directory.appendingPathComponent("workflow.json"))
    let added = try await host.addWorkflowDirectory(input: decode(GraphQLWorkflowDirConfigInput.self, [
      "expectedRevision": assistant.revision, "expectedProfile": assistant.profile, "path": directory.path
    ]))
    let sources = try object(await host.response(for: get("/api/v1/workflows/sources")))
    XCTAssertEqual(sources["revision"] as? Int, added.revision)
    let discovered = try XCTUnwrap(sources["discovered"] as? [[String: Any]])
    let identity = try XCTUnwrap(discovered.first?["id"] as? String)
    XCTAssertEqual(discovered.first?["workflowId"] as? String, "added-workflow")
    let saved = try await host.updateWorkflowInstance(input: decode(GraphQLWorkflowInstanceConfigInput.self, [
      "expectedRevision": added.revision, "expectedProfile": added.profile, "identity": identity,
      "environmentVariableUpdates": ["TEST_SECRET": "never-project-this-value"],
      "workflowVariables": ["greeting": "hello"]
    ]))
    let instanceResponse = await host.response(for: get("/api/v1/instances"))
    XCTAssertFalse((String(data: instanceResponse.body, encoding: .utf8) ?? "").contains("never-project-this-value"))
    let restarted = makeHost(root: root)
    let persisted = try await restarted.configuration()
    XCTAssertEqual(persisted.appearance.colorScheme, "light")
    XCTAssertEqual(persisted.assistant.assistance, "Use concise replies")
    XCTAssertEqual(persisted.workflowDirectories, [directory.path])
    let eventRevision = try await host.registerEventSource(input: decode(GraphQLEventSourceConfigurationInput.self, [
      "expectedRevision": saved.revision, "expectedProfile": saved.profile, "identity": identity,
      "source": ["id": "scheduled", "kind": "cron"],
      "binding": ["id": "schedule-binding", "sourceId": "scheduled", "workflowName": "added-workflow"]
    ]))
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".riela-events/sources/scheduled.json").path))
    let created = try await host.createProfile(input: decode(GraphQLProfileConfigurationInput.self, [
      "expectedRevision": eventRevision.revision, "expectedProfile": eventRevision.profile, "name": "second"
    ]))
    XCTAssertTrue(created.profiles.contains("second"))
    let switched = try await host.switchProfile(input: decode(GraphQLProfileConfigurationInput.self, [
      "expectedRevision": created.revision, "expectedProfile": created.profile, "name": "second"
    ]))
    XCTAssertEqual(switched.profile, "second")
    XCTAssertEqual(switched.workflowDirectories, [])
    XCTAssertTrue(host.sessionStoreRoot.hasSuffix("sessions"))
    do {
      _ = try await host.updateAppearance(input: GraphQLUpdateAppearanceConfigInput(
        expectedRevision: switched.revision, expectedProfile: "default", colorScheme: "dark"
      ))
      XCTFail("Old-profile writes must fail")
    } catch let error as RielaConfigurationGraphQLError {
      XCTAssertEqual(error.code, "PROFILE_CONFLICT")
    }
  }

  private func decode<Value: Decodable>(_ type: Value.Type, _ object: [String: Any]) throws -> Value {
    try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
  }

  private func makeHost(root: URL, bindHost: String = "127.0.0.1") -> ServeWebHost {
    ServeWebHost(
      homeDirectory: root.appendingPathComponent("home"),
      workingDirectory: root.appendingPathComponent("project"),
      sessionStoreRoot: root.appendingPathComponent("sessions").path,
      host: bindHost, port: 8787, fallback: DeterministicServerHTTPAdapter(),
      environment: ["HOME": root.appendingPathComponent("home").path]
    )
  }

  private func get(_ path: String) -> RielaHTTPRequest {
    RielaHTTPRequest(method: "GET", path: path, headers: ["host": "127.0.0.1:8787"])
  }

  private func object(_ response: RielaHTTPResponse) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
  }

  private func fixtureRoot() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/serve-web-host-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
