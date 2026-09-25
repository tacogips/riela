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
    // The instance list moved to GraphQL (`Query.consoleInstances`).
    let instances = host.consoleGraphQLProvider().consoleInstanceList()
    XCTAssertEqual(instances.items.first?.workflowId, "web-example")
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

  func testBrowserExecutionUsesProfileStoreAndGatesSummaryReads() async throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let workflow = root.appendingPathComponent("project/.riela/workflows/browser-example")
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try Data(#"""
      {"workflowId":"browser-example","entryStepId":"work",
       "defaults":{"nodeTimeoutMs":30000,"maxLoopIterations":1},
       "nodes":[{"id":"work","nodeFile":"nodes/work.json"}],
       "steps":[{"id":"work","nodeId":"work","role":"worker"}]}
      """#.utf8).write(to: workflow.appendingPathComponent("workflow.json"))
    try Data(#"""
      {"id":"work","nodeType":"command","modelFreeze":false,
       "command":{"executable":"/bin/echo","arguments":["{\"ok\":true}"]}}
      """#.utf8).write(to: workflow.appendingPathComponent("nodes/work.json"))
    let home = root.appendingPathComponent("home")
    let host = ServeWebHost(
      homeDirectory: home, workingDirectory: root.appendingPathComponent("project"),
      sessionStoreRoot: nil, host: "127.0.0.1", port: 8787,
      fallback: DeterministicServerHTTPAdapter(), environment: ["HOME": home.path]
    )
    let firstStore = host.sessionStoreRoot
    let bootstrap = try object(await host.response(for: get("/api/v1/bootstrap")))
    let csrf = try XCTUnwrap(bootstrap["csrfToken"] as? String)
    var request = RielaHTTPRequest(
      method: "POST", path: "/graphql",
      headers: [
        "host": "127.0.0.1:8787", "origin": "http://127.0.0.1:8787",
        "content-type": "application/json", "x-riela-csrf": csrf,
        "x-riela-profile": "default"
      ],
      body: Data(#"{"query":"mutation { executeWorkflow(input: {workflowName: \"browser-example\"}) { sessionId status exitCode } }"}"#.utf8)
    )
    request.headers["x-riela-csrf"] = "invalid"
    let rejected = await host.response(for: request)
    XCTAssertEqual(rejected.status, 403)
    request.headers["x-riela-csrf"] = csrf
    request.headers.removeValue(forKey: "x-riela-profile")
    let conflict = await host.response(for: request)
    XCTAssertEqual(conflict.status, 409)
    request.headers["x-riela-profile"] = "default"
    let executed = await host.response(for: request)
    XCTAssertEqual(executed.status, 200)
    let data = try XCTUnwrap((try object(executed)["data"] as? [String: Any])?["executeWorkflow"] as? [String: Any])
    let sessionId = try XCTUnwrap(data["sessionId"] as? String)
    XCTAssertEqual(data["status"] as? String, "completed")
    XCTAssertEqual(data["exitCode"] as? Int, 0)
    XCTAssertEqual(try CLIWorkflowSessionStore(rootDirectory: firstStore)
      .loadStrictReadOnly(sessionId: sessionId).session.status, .completed)

    request.body = try JSONSerialization.data(withJSONObject: [
      "query": "query($id: String!) { workflowExecution(workflowExecutionId: $id) { session { sessionId workflowId } } }",
      "variables": ["id": sessionId]
    ])
    let summary = try object(await host.response(for: request))
    let summarySession = ((summary["data"] as? [String: Any])?["workflowExecution"] as? [String: Any])?["session"] as? [String: Any]
    XCTAssertEqual(summarySession?["workflowId"] as? String, "browser-example")

    let ready = root.appendingPathComponent("ready")
    let release = root.appendingPathComponent("release")
    let barrierNode: [String: Any] = [
      "id": "work", "nodeType": "command", "modelFreeze": false,
      "command": [
        "executable": "/bin/sh",
        "arguments": [
          "-c",
          "printf ready > \"$1\"; while [ ! -e \"$2\" ]; do /bin/sleep 0.05; done; printf '{\"ok\":true}\\n'",
          "work", ready.path, release.path
        ]
      ]
    ]
    try JSONSerialization.data(withJSONObject: barrierNode)
      .write(to: workflow.appendingPathComponent("nodes/work.json"))
    var pendingRequest = request
    pendingRequest.body = Data(#"{"query":"mutation { executeWorkflow(input: {workflowName: \"browser-example\"}) { sessionId status exitCode } }"}"#.utf8)
    let pending = Task { await host.response(for: pendingRequest) }
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: ready.path) && Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    guard FileManager.default.fileExists(atPath: ready.path) else {
      try Data().write(to: release)
      _ = await pending.value
      XCTFail("browser execution did not reach the profile-switch barrier")
      return
    }

    let configuration = try await host.configuration()
    let created = try await host.createProfile(input: decode(GraphQLProfileConfigurationInput.self, [
      "expectedRevision": configuration.revision, "expectedProfile": configuration.profile, "name": "second"
    ]))
    _ = try await host.switchProfile(input: decode(GraphQLProfileConfigurationInput.self, [
      "expectedRevision": created.revision, "expectedProfile": created.profile, "name": "second"
    ]))
    XCTAssertNotEqual(host.sessionStoreRoot, firstStore)
    try Data().write(to: release)
    let activeResponse = try object(await pending.value)
    let activeData = try XCTUnwrap((activeResponse["data"] as? [String: Any])?["executeWorkflow"] as? [String: Any])
    let activeSessionId = try XCTUnwrap(activeData["sessionId"] as? String)
    XCTAssertEqual(activeData["status"] as? String, "completed")
    XCTAssertEqual(try CLIWorkflowSessionStore(rootDirectory: firstStore)
      .loadStrictReadOnly(sessionId: activeSessionId).session.status, .completed)
    request.body = try JSONSerialization.data(withJSONObject: [
      "query": "query($id: String!) { workflowExecution(workflowExecutionId: $id) { session { sessionId workflowId } } }",
      "variables": ["id": activeSessionId]
    ])
    request.headers["x-riela-profile"] = "second"
    let isolated = try object(await host.response(for: request))
    XCTAssertNil(isolated["errors"])
    XCTAssertTrue(((isolated["data"] as? [String: Any])?["workflowExecution"]) is NSNull)
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

  func testPublicBrowserRequiresPasskeyAndRejectsLegacyOperatorToken() async throws {
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
    let legacy = await host.response(for: request)
    XCTAssertEqual(legacy.status, 401)
    request = RielaHTTPRequest(method: "POST", path: "/api/v1/auth/login/options", headers: [
      "host": "riela.example", "origin": "https://riela.example", "content-type": "application/json"
    ], body: Data("{}".utf8))
    let options = try object(await host.response(for: request))
    XCTAssertNotNil(options["ceremonyID"])
    XCTAssertEqual((options["publicKey"] as? [String: Any])?["rpId"] as? String, "riela.example")
    let policy = ServeWebAccess(host: "0.0.0.0", environment: ["RIELA_WEB_ORIGIN": "https://riela.example"])
    request = RielaHTTPRequest(method: "POST", path: "/graphql", headers: [
      "host": "riela.example",
      "origin": "https://riela.example", "content-type": "application/json",
      "x-riela-csrf": "csrf", "x-riela-profile": "default"
    ], body: Data(#"{"query":"query { configuration { profile revision } }"}"#.utf8))
    XCTAssertNil(policy.rejection(for: request, localAuthority: "unused", csrfToken: "csrf", authenticated: true))
    for header in ["origin", "host", "x-riela-csrf"] {
      var invalid = request
      invalid.headers[header] = "invalid"
      let rejected = policy.rejection(for: invalid, localAuthority: "unused", csrfToken: "csrf", authenticated: true)
      XCTAssertEqual(rejected?.status, 403, header)
    }
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
    let projected = try XCTUnwrap(String(
      data: JSONEncoder().encode(host.consoleGraphQLProvider().consoleInstanceList()),
      encoding: .utf8
    ))
    XCTAssertFalse(projected.contains("never-project-this-value"))
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

  func testNamedCreationPreservesVirtualDefaultAndRejectsStaleWrites() async throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("project/.riela/workflows/example")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("""
      {"workflowId":"example","entryStepId":"start",
       "nodes":[{"id":"worker","nodeFile":"worker.json"}],
       "steps":[{"id":"start","nodeId":"worker","role":"worker"}]}
      """.utf8).write(to: directory.appendingPathComponent("workflow.json"))
    try Data("{}".utf8).write(to: directory.appendingPathComponent("worker.json"))
    let host = makeHost(root: root)
    let bootstrap = try object(await host.response(for: get("/api/v1/bootstrap")))
    let token = try XCTUnwrap(bootstrap["csrfToken"] as? String)
    // The instance list moved to GraphQL (`Query.consoleInstances`); it is read
    // after the bootstrap handshake, exactly as the console reads it.
    let listing = host.consoleGraphQLProvider().consoleInstanceList()
    let initial = try XCTUnwrap(listing.items.first)
    let sourceId = initial.sourceId
    XCTAssertEqual(initial.isDefault, true)
    XCTAssertTrue(host.state.preferences.isEmpty)
    let revision = listing.revision
    var request = RielaHTTPRequest(method: "POST", path: "/api/v1/instances", headers: [
      "host": "127.0.0.1:8787", "origin": "http://127.0.0.1:8787",
      "x-riela-csrf": token, "content-type": "application/json", "x-riela-profile": "default"
    ], body: try JSONSerialization.data(withJSONObject: [
      "sourceId": sourceId, "name": "  Repository A  ", "expectedProfile": "default", "expectedRevision": revision
    ]))
    var unauthorized = request
    unauthorized.headers["x-riela-csrf"] = "invalid"
    let rejected = await host.response(for: unauthorized)
    XCTAssertEqual(rejected.status, 403)
    let created = await host.response(for: request)
    XCTAssertEqual(created.status, 201, String(data: created.body, encoding: .utf8) ?? "")
    let identity = try XCTUnwrap(try object(created)["identity"] as? String)
    XCTAssertNotEqual(identity, sourceId)
    XCTAssertEqual(host.state.preferences[identity]?.displayName, "Repository A")
    XCTAssertEqual(host.state.preferences[identity]?.active, false)
    XCTAssertEqual(host.state.preferences[identity]?.enabledAtLaunch, false)
    XCTAssertNil(host.state.preferences[sourceId])
    XCTAssertEqual(host.instances.first { $0.isDefault }?.id, sourceId)
    XCTAssertEqual(host.instances.count, 2)
    let stale = await host.response(for: request)
    XCTAssertEqual(stale.status, 409)
    request.body = try JSONSerialization.data(withJSONObject: [
      "sourceId": sourceId, "name": "  ", "expectedProfile": "default", "expectedRevision": host.revision
    ])
    let blank = await host.response(for: request)
    XCTAssertEqual(blank.status, 400)
    let reloaded = makeHost(root: root)
    XCTAssertEqual(reloaded.instances.first { $0.isDefault }?.id, sourceId)
    XCTAssertEqual(reloaded.state.preferences[identity], host.state.preferences[identity])
  }

  private func decode<Value: Decodable>(_ type: Value.Type, _ object: [String: Any]) throws -> Value {
    try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
  }

  /// Transport-level coverage for the migrated console reads: the documents
  /// `web/src/console/client.ts` actually sends, over `/graphql`, with the
  /// browser headers the console attaches. The retired JSON GETs required no
  /// profile header; these reads do, so the negative case is pinned too.
  func testConsoleReadDocumentsResolveOverGraphQLWithBrowserHeaders() async throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let workflow = root.appendingPathComponent("project/.riela/workflows/console-example")
    try FileManager.default.createDirectory(at: workflow, withIntermediateDirectories: true)
    try Data("""
      {"workflowId":"console-example","entryStepId":"start","defaults":{"maxLoopIterations":3,"nodeTimeoutMs":1000},
       "nodes":[{"id":"worker","nodeFile":"worker.json"}],
       "steps":[{"id":"start","nodeId":"worker","role":"worker"}]}
      """.utf8).write(to: workflow.appendingPathComponent("workflow.json"))
    try Data("{}".utf8).write(to: workflow.appendingPathComponent("worker.json"))
    let host = makeHost(root: root)
    let bootstrap = try object(await host.response(for: get("/api/v1/bootstrap")))
    let csrf = try XCTUnwrap(bootstrap["csrfToken"] as? String)
    let identity = try XCTUnwrap(host.instances.first?.identity)
    let saved = try await host.updateWorkflowInstance(input: decode(GraphQLWorkflowInstanceConfigInput.self, [
      "expectedRevision": host.revision, "expectedProfile": "default", "identity": identity,
      "environmentVariableUpdates": ["CONSOLE_SECRET": "never-project-this-value"],
      "workflowVariables": ["greeting": "hello"]
    ]))
    XCTAssertEqual(saved.profile, "default")

    let list = await host.response(for: Self.consoleDocumentRequest(
      Self.webConsoleInstancesDocument,
      operationName: "WebConsoleInstances",
      csrf: csrf
    ))
    XCTAssertEqual(list.status, 200, String(data: list.body, encoding: .utf8) ?? "")
    let listBody = String(data: list.body, encoding: .utf8) ?? ""
    XCTAssertFalse(listBody.contains("never-project-this-value"), "the console projection must not leak stored secrets")
    let payload = try XCTUnwrap(
      (try object(list)["data"] as? [String: Any])?["consoleInstances"] as? [String: Any]
    )
    XCTAssertEqual(payload["profile"] as? String, "default")
    let items = try XCTUnwrap(payload["items"] as? [[String: Any]])
    let first = try XCTUnwrap(items.first)
    XCTAssertEqual(first["workflowId"] as? String, "console-example")
    // The JSONObject scalars and the nested object lists must survive
    // projection; a hand-written four-field selection would not prove this.
    XCTAssertEqual((first["workflowVariables"] as? [String: Any])?["greeting"] as? String, "hello")
    XCTAssertNotNil(first["nodePatches"] as? [String: Any])
    XCTAssertNotNil(first["eventSources"] as? [[String: Any]])
    let environmentVariables = try XCTUnwrap(first["environmentVariables"] as? [[String: Any]])
    XCTAssertEqual(environmentVariables.first?["name"] as? String, "CONSOLE_SECRET")
    XCTAssertEqual(environmentVariables.first?["masked"] as? String, "••••••••")
    XCTAssertNotNil(first["requiredEnvironment"] as? [[String: Any]])

    let detail = await host.response(for: Self.consoleDocumentRequest(
      Self.webConsoleInstanceDocument,
      operationName: "WebConsoleInstance",
      csrf: csrf,
      variables: ["identity": .string(identity)]
    ))
    XCTAssertEqual(detail.status, 200, String(data: detail.body, encoding: .utf8) ?? "")
    let detailItem = try XCTUnwrap(
      ((try object(detail)["data"] as? [String: Any])?["consoleInstance"] as? [String: Any])?["item"] as? [String: Any]
    )
    XCTAssertEqual(detailItem["id"] as? String, identity)

    let overview = await host.response(for: Self.consoleDocumentRequest(
      Self.webOpsOverviewDocument,
      operationName: "WebOpsOverview",
      csrf: csrf
    ))
    XCTAssertEqual(overview.status, 200, String(data: overview.body, encoding: .utf8) ?? "")
    let overviewPayload = try XCTUnwrap(
      (try object(overview)["data"] as? [String: Any])?["opsOverview"] as? [String: Any]
    )
    XCTAssertEqual(overviewPayload["profile"] as? String, "default")
    let overviewWorkflows = try XCTUnwrap(overviewPayload["workflows"] as? [[String: Any]])
    XCTAssertEqual(overviewWorkflows.first?["workflowId"] as? String, "console-example")
    XCTAssertNotNil(overviewWorkflows.first?["steps"] as? [[String: Any]])
    XCTAssertNotNil(overviewPayload["instances"] as? [[String: Any]])
    XCTAssertNotNil(overviewPayload["runs"] as? [[String: Any]])

    var withoutProfile = Self.consoleDocumentRequest(
      Self.webConsoleInstancesDocument,
      operationName: "WebConsoleInstances",
      csrf: csrf
    )
    withoutProfile.headers.removeValue(forKey: "x-riela-profile")
    let rejected = await host.response(for: withoutProfile)
    XCTAssertEqual(rejected.status, 409, "console reads now require the profile header the JSON GET did not")
  }

  // MARK: - Console documents (copied from web/src/console/client.ts)

  private static let consoleInstanceFields = """
    id sourceId isDefault name workflowId source sourceKind status statusDetail
    active enabledAtLaunch workingDirectory environmentFilePath
    environmentVariables { name isSet masked }
    requiredEnvironment { name description required secret source present }
    workflowVariables nodePatchCount nodePatches
    eventSources { id kind }
  """

  private static var webConsoleInstancesDocument: String {
    "query WebConsoleInstances { consoleInstances { profile revision items { \(consoleInstanceFields) } } }"
  }

  private static var webConsoleInstanceDocument: String {
    """
    query WebConsoleInstance($identity: String!) {
      consoleInstance(identity: $identity) { profile revision item { \(consoleInstanceFields) } }
    }
    """
  }

  private static let webOpsOverviewDocument = """
  query WebOpsOverview { opsOverview {
    profile revision workflowsTruncated runsTruncated diagnostics
    workflows {
      sourceId name workflowId scope sourceKind description entryStepId managerStepId stepsTruncated
      steps { id nodeId role description transitions { toStepId label fanoutJoinStepId } }
      nodes { id kind role addon }
    }
    instances { id sourceId isDefault name workflowId status active }
    runs { instanceId sessionId workflowId status currentStepId activeStepIds updatedAt }
  } }
  """

  private static func consoleDocumentRequest(
    _ query: String,
    operationName: String,
    csrf: String,
    variables: JSONObject = [:]
  ) -> RielaHTTPRequest {
    let body = try? JSONEncoder().encode(JSONValue.object([
      "query": .string(query),
      "variables": .object(variables),
      "operationName": .string(operationName)
    ]))
    return RielaHTTPRequest(
      method: "POST",
      path: "/graphql",
      headers: [
        "host": "127.0.0.1:8787",
        "origin": "http://127.0.0.1:8787",
        "content-type": "application/json",
        "x-riela-csrf": csrf,
        "x-riela-profile": "default"
      ],
      body: body ?? Data()
    )
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
