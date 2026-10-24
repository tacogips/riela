import Foundation
import RielaAppSupport
import RielaCore
import RielaGraphQL
import RielaServer
import XCTest
@testable import RielaCLI

/// `riela serve` runs `RielaAppDaemonWorkflowRuntime` with loaders, so the
/// `reloadEnvironment` action and the status read must go through that runtime
/// (never a bare 200 no-op) and the console must project the same status.
@MainActor
final class ServeWebHostRuntimeEnvironmentTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    root = repository.appendingPathComponent("tmp/serve-web-host-runtime-environment-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testReloadEnvironmentRunsLoadersAndStatusRouteAndConsoleReportTheGeneration() async throws {
    let fixture = try await makeFixture(loader: ["/bin/echo", #"{"SERVE_TOKEN":"serve-loader-canary-value"}"#])
    let host = fixture.host

    let before = await fixture.status()
    XCTAssertEqual(before.status, 200)
    XCTAssertEqual(try object(before)["readiness"] as? String, "unprepared")

    let reloaded = try await fixture.action("reloadEnvironment")
    XCTAssertEqual(reloaded.status, 200, String(data: reloaded.body, encoding: .utf8) ?? "")
    let body = try object(reloaded)
    // A real status, not the bare `{profile, revision}` no-op acknowledgement.
    XCTAssertNil(body["revision"])
    XCTAssertEqual(body["readiness"] as? String, "ready")
    XCTAssertEqual(body["generation"] as? Int, 1)
    XCTAssertEqual(body["names"] as? [String], ["SERVE_TOKEN"])
    XCTAssertEqual(body["configuredNames"] as? [String], ["SERVE_TOKEN"])
    XCTAssertFalse(String(bytes: reloaded.body, encoding: .utf8)?.contains("serve-loader-canary-value") ?? true)

    let again = try await fixture.action("reloadEnvironment")
    XCTAssertEqual(try object(again)["generation"] as? Int, 2)
    let status = await fixture.status()
    XCTAssertEqual(status.status, 200)
    XCTAssertEqual(try object(status)["generation"] as? Int, 2)

    // The console projection reads the same runtime status (no longer `unprepared`/0).
    let item = try XCTUnwrap(host.consoleGraphQLProvider().consoleInstanceDetail(identity: fixture.identity).item)
    XCTAssertEqual(item.environmentStatus?["generation"], .integer(2))
    XCTAssertEqual(item.environmentStatus?["readiness"], .string("ready"))
    // Reload saves no preference.
    XCTAssertEqual(host.stateStore.load().preferences[fixture.identity]?.active, false)
  }

  func testFailedReloadAnswers422WithTheSafeCodeAndStatusRouteKeepsIt() async throws {
    let fixture = try await makeFixture(loader: ["/usr/bin/false"])
    let failed = try await fixture.action("reloadEnvironment")
    XCTAssertEqual(failed.status, 422)
    let body = try object(failed)
    XCTAssertEqual(body["lastError"] as? String, "environment_source_failed")
    XCTAssertEqual(body["readiness"] as? String, "failed")
    let statusResponse = await fixture.status()
    let status = try object(statusResponse)
    XCTAssertEqual(status["lastError"] as? String, "environment_source_failed")
  }

  func testStatusRouteRequiresTheCurrentProfileAndAKnownInstance() async throws {
    let fixture = try await makeFixture(loader: ["/bin/echo", #"{"SERVE_TOKEN":"value-value"}"#])
    let otherProfile = await fixture.status(profile: "other")
    XCTAssertEqual(otherProfile.status, 409)
    let unknown = await fixture.status(identity: "missing-instance")
    XCTAssertEqual(unknown.status, 409)
    var post = fixture.statusRequest(profile: "default", identity: fixture.identity)
    post.method = "POST"
    post.headers["content-type"] = "application/json"
    let wrongMethod = await fixture.host.response(for: post)
    XCTAssertEqual(wrongMethod.status, 405)
  }

  func testProfileSwitchEvictsThePreviousProfilesSnapshot() async throws {
    let fixture = try await makeFixture(loader: ["/bin/echo", #"{"SERVE_TOKEN":"value-value"}"#])
    let host = fixture.host
    let reloaded = try await fixture.action("reloadEnvironment")
    XCTAssertEqual(reloaded.status, 200)
    XCTAssertEqual(host.runtime.cachedEnvironmentStatus(identity: fixture.identity, profile: "default").generation, 1)

    try host.profileStore.createProfileDirectories(RielaAppProfileName("other"))
    try host.profileStore.saveActiveProfileName(RielaAppProfileName("other"))
    // The next request observes the external switch, stops, evicts, restarts.
    _ = await host.response(for: get("/api/v1/bootstrap"))
    XCTAssertEqual(host.profile.rawValue, "other")
    XCTAssertEqual(host.runtime.cachedEnvironmentStatus(identity: fixture.identity, profile: "default"), RuntimeEnvironmentStatus())
    let evicted = await host.runtime.environmentStatus(identity: fixture.identity, profile: "default")
    XCTAssertEqual(evicted.readiness, .unprepared)
    XCTAssertEqual(evicted.generation, 0)
  }

  // MARK: - Fixture

  private struct Fixture {
    let host: ServeWebHost
    let identity: String
    let csrf: String

    func statusRequest(profile: String, identity: String) -> RielaHTTPRequest {
      let encoded = identity.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? identity
      return RielaHTTPRequest(
        method: "GET", path: "/api/v1/instances/\(identity)/environment",
        percentEncodedPath: "/api/v1/instances/\(encoded)/environment",
        headers: ["host": "127.0.0.1:8787", "origin": "http://127.0.0.1:8787",
                  "x-riela-csrf": csrf, "x-riela-profile": profile]
      )
    }

    @MainActor
    func status(profile: String = "default", identity: String? = nil) async -> RielaHTTPResponse {
      await host.response(for: statusRequest(profile: profile, identity: identity ?? self.identity))
    }

    @MainActor
    func action(_ action: String) async throws -> RielaHTTPResponse {
      let encoded = identity.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? identity
      return await host.response(for: RielaHTTPRequest(
        method: "POST", path: "/api/v1/instances/\(identity)/actions",
        percentEncodedPath: "/api/v1/instances/\(encoded)/actions",
        headers: ["host": "127.0.0.1:8787", "origin": "http://127.0.0.1:8787",
                  "content-type": "application/json", "x-riela-csrf": csrf],
        body: try JSONSerialization.data(withJSONObject: [
          "action": action, "expectedRevision": host.revision, "expectedProfile": host.profile.rawValue
        ])
      ))
    }
  }

  private func makeFixture(loader: [String]) async throws -> Fixture {
    let workflow = root.appendingPathComponent("project/.riela/workflows/serve-env")
    try FileManager.default.createDirectory(at: workflow, withIntermediateDirectories: true)
    try Data(#"{"workflowId":"serve-env","defaults":{"nodeTimeoutMs":1000,"maxLoopIterations":3},"entryStepId":"wait","nodes":[{"id":"wait","nodeFile":"wait.json"}],"steps":[{"id":"wait","nodeId":"wait"}]}"#.utf8)
      .write(to: workflow.appendingPathComponent("workflow.json"))
    try Data(#"{"id":"wait","nodeType":"sleep","sleep":{"durationMs":1},"variables":{}}"#.utf8)
      .write(to: workflow.appendingPathComponent("wait.json"))
    let home = root.appendingPathComponent("home")
    let host = ServeWebHost(
      homeDirectory: home, workingDirectory: root.appendingPathComponent("project"),
      sessionStoreRoot: root.appendingPathComponent("sessions").path,
      host: "127.0.0.1", port: 8787, fallback: DeterministicServerHTTPAdapter(),
      environment: ["HOME": home.path]
    )
    let instance = try XCTUnwrap(host.instances.first { $0.source.workflowId == "serve-env" })
    var state = host.stateStore.load()
    var preference = instance.preference
    preference.sourceIdentity = instance.sourceIdentity
    preference.active = false
    preference.configuration.environmentResolution = RuntimeEnvironmentConfiguration(sources: [
      RuntimeEnvironmentCommandSource(id: "serve-loader", names: ["SERVE_TOKEN"], command: loader, timeoutSeconds: 10)
    ])
    state.preferences[instance.identity] = preference
    try host.stateStore.save(state)
    host.refreshConfigurationState()
    let bootstrap = try object(await host.response(for: get("/api/v1/bootstrap")))
    return Fixture(host: host, identity: instance.identity, csrf: try XCTUnwrap(bootstrap["csrfToken"] as? String))
  }

  private func get(_ path: String) -> RielaHTTPRequest {
    RielaHTTPRequest(method: "GET", path: path, headers: ["host": "127.0.0.1:8787"])
  }

  private func object(_ response: RielaHTTPResponse) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
  }
}
