#if os(macOS)
import Foundation
import RielaCLI
import RielaAppSupport
import RielaCore
import RielaServer
@testable import RielaApp
import XCTest

@MainActor
final class ConfiguredWorkflowLaunchTests: XCTestCase {
  func testSelectedConfigurationRunsRealCommandWithExactEnvironmentDirectoryAndVariables() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/configured-run-\(UUID().uuidString)")
    let source = root.appendingPathComponent("bundle/renamed-source")
    let working = root.appendingPathComponent("working")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"workflowId":"configured-test","description":"fixture","defaults":{"nodeTimeoutMs":120000,"maxLoopIterations":3},"entryStepId":"check","nodes":[{"id":"check","nodeFile":"check.json"}],"steps":[{"id":"check","nodeId":"check","role":"worker"}]}"#.utf8).write(to: source.appendingPathComponent("workflow.json"))
    let node: JSONObject = ["id": .string("check"), "nodeType": .string("command"), "variables": .object([:]),
      "command": .object(["executable": .string("/usr/bin/python3"), "arguments": .array([
        .string("-c"), .string("import os,json; print(json.dumps({'environmentMatched':os.environ.get('CONFIGURED_SENTINEL')=='exact','directoryMatched':os.path.realpath(os.getcwd())==os.path.realpath(os.environ.get('EXPECTED_DIRECTORY','/missing'))}))")])])]
    try JSONEncoder().encode(node).write(to: source.appendingPathComponent("check.json"))
    let candidate = try XCTUnwrap(RielaAppDaemonWorkflowDiscovery().discoverSelectedWorkflowDirectory(source.path))
    let app = RielaApp()
    app.appHomeDirectory = root
    app.kaibaCatalogLoader = { _ in .init() }
    app.profileStore = RielaAppProfileStore(appRootURL: root.appendingPathComponent("profile"))
    try app.profileStore.prepareInitialProfile(.default, persistsSelection: false)
    app.webSessionStoreRootOverride = root.appendingPathComponent("sessions").path
    let preference = RielaAppDaemonWorkflowPreference(identity: "selected", sourceIdentity: candidate.id,
      available: true, active: false, workingDirectory: working.path,
      environmentVariables: ["CONFIGURED_SENTINEL": "exact", "EXPECTED_DIRECTORY": working.path],
      defaultVariables: ["retained": .string("default"), "override": .string("old")])
    app.daemonState = .init(preferences: ["selected": preference])
    app.daemonWorkflowSources = [candidate]
    app.daemonCandidates = [candidate]
    app.daemonInstances = [.configured(identity: "selected", source: candidate, preference: preference)]
    let body: JSONObject = ["expectedProfile": .string(app.daemonProfileName.rawValue), "expectedRevision": .number(Double(app.webRevision)),
      "variables": .object(["override": .string("requested")])]
    let request = RielaHTTPRequest(method: "POST", path: "/api/v1/instances/selected/runs",
      headers: ["x-riela-profile": app.daemonProfileName.rawValue], body: try JSONEncoder().encode(body))
    let responseValue = await app.webConfiguredRunResponse(for: request)
    let response = try XCTUnwrap(responseValue)
    XCTAssertEqual(response.status, 202, "\(String(decoding: response.body, as: UTF8.self)) \(app.status)")
    let job = try XCTUnwrap(app.webWorkflowLaunches.values.first)
    for _ in 0..<200 where job.snapshot["status"] == .string("running") { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertEqual(job.snapshot["status"], .string("completed"))
    guard case let .string(session) = job.snapshot["sessionId"] else { return XCTFail("missing session") }
    let persisted = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.appendingPathComponent("sessions/runtime-records").path).loadStrictReadOnly(sessionId: session)
    XCTAssertEqual(persisted.session.instanceBaseIdentity, "selected")
    XCTAssertEqual(persisted.session.instanceIdentity, "selected+overrides")
    XCTAssertEqual(persisted.session.status.rawValue, "completed", String(describing: persisted.session.failureReason))
    XCTAssertEqual(persisted.session.executions.first?.acceptedOutput?.payload["environmentMatched"], .bool(true))
    XCTAssertEqual(persisted.session.executions.first?.acceptedOutput?.payload["directoryMatched"], .bool(true))
    let arguments = persisted.session.executions.first?.inputSnapshot?["variables"]
    XCTAssertEqual(arguments, .object(["retained": .string("default"), "override": .string("requested")]))
    XCTAssertFalse(String(describing: job.snapshot).contains("CONFIGURED_SENTINEL"))
    XCTAssertEqual(app.daemonState.preferences["selected"], preference)
    await app.webWorkflowRuntime.shutdown()
  }

  func testAppRunRejectsStaleProfileAndCallerEnvironmentBeforeStarting() async throws {
    let app = RielaApp()
    let body: JSONObject = ["expectedProfile": .string("wrong"), "expectedRevision": .number(0), "variables": .object([:])]
    let request = RielaHTTPRequest(method: "POST", path: "/api/v1/instances/missing/runs",
      headers: ["x-riela-profile": app.daemonProfileName.rawValue], body: try JSONEncoder().encode(body))
    let response = await app.webConfiguredRunResponse(for: request)
    XCTAssertEqual(response?.status, 409)
    XCTAssertTrue(app.webWorkflowLaunches.isEmpty)
    var unsafe = body
    unsafe["environment"] = .object(["PRIVATE": .string("never")])
    let unsafeRequest = RielaHTTPRequest(method: "POST", path: "/api/v1/instances/missing/runs",
      headers: request.headers, body: try JSONEncoder().encode(unsafe))
    let rejected = await app.webConfiguredRunResponse(for: unsafeRequest)
    XCTAssertEqual(rejected?.status, 400)
  }
}
#endif
