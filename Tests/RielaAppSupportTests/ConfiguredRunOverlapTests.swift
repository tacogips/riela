#if os(macOS)
import Foundation
import RielaAppSupport
import RielaCore
import RielaServer
@testable import RielaApp
@testable import RielaCLI
import XCTest

@MainActor
final class ConfiguredRunOverlapTests: XCTestCase {
  private func exercise(_ scenario: String) async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/configured-overlap-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("bundle")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let workflow = #"{"workflowId":"configured-test","description":"fixture","defaults":{"nodeTimeoutMs":120000,"maxLoopIterations":3},"#
      + #""entryStepId":"check","nodes":[{"id":"check","nodeFile":"check.json"}],"steps":[{"id":"check","nodeId":"check","role":"worker"}]}"#
    try Data(workflow.utf8)
      .write(to: source.appendingPathComponent("workflow.json"))
    let node: JSONObject = ["id": .string("check"), "nodeType": .string("command"), "variables": .object([:]),
      "command": .object(["executable": .string("/usr/bin/true"), "arguments": .array([])])]
    try JSONEncoder().encode(node).write(to: source.appendingPathComponent("check.json"))
    let candidate = try XCTUnwrap(RielaAppDaemonWorkflowDiscovery().discoverSelectedWorkflowDirectory(source.path))
    let app = RielaApp()
    app.appHomeDirectory = root
    app.kaibaCatalogLoader = { _ in .init() }
    app.profileStore = RielaAppProfileStore(appRootURL: root.appendingPathComponent("profile"))
    try app.profileStore.prepareInitialProfile(.default, persistsSelection: false)
    let storeRoot = root.appendingPathComponent("sessions").path
    app.webSessionStoreRootOverride = storeRoot
    let preference = RielaAppDaemonWorkflowPreference(identity: "selected", sourceIdentity: candidate.id,
      available: true, active: false, workingDirectory: root.path)
    app.daemonState = .init(preferences: ["selected": preference])
    app.daemonWorkflowSources = [candidate]
    app.daemonCandidates = [candidate]
    app.daemonInstances = [.configured(identity: "selected", source: candidate, preference: preference)]
    let owner = SessionExecutionLockRegistry(sessionStoreRoot: storeRoot)
    if scenario == "store" || scenario == "orphan" {
      let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: storeRoot))
      let session = WorkflowSession(workflowId: "configured-test", sessionId: "live", status: .running, entryStepId: "check", createdAt: Date(), updatedAt: Date())
      try store.save(WorkflowRuntimePersistenceSnapshot(session: session))
      try owner.acquire(sessionId: "live")
      if scenario == "orphan" { owner.release(sessionId: "live") }
    }
    if scenario == "memory" || scenario == "allow" {
      let job = WebWorkflowLaunch(profile: app.daemonProfileName.rawValue, identity: "selected")
      app.webWorkflowRuntime.launches[job.id] = job
    }
    let before = app.webWorkflowLaunches.count
    var body: JSONObject = ["expectedProfile": .string(app.daemonProfileName.rawValue),
      "expectedRevision": .number(Double(app.webRevision)), "variables": .object([:])]
    if scenario == "allow" { body["allowOverlap"] = .bool(true) }
    if scenario == "extra" { body["extra"] = .bool(true) }
    if scenario == "invalid" { body["allowOverlap"] = .string("yes") }
    let request = RielaHTTPRequest(method: "POST", path: "/api/v1/instances/selected/runs",
      headers: ["x-riela-profile": app.daemonProfileName.rawValue], body: try JSONEncoder().encode(body))
    let responseValue = await app.webConfiguredRunResponse(for: request)
    let response = try XCTUnwrap(responseValue)
    let object = try JSONDecoder().decode(JSONObject.self, from: response.body)
    if scenario == "memory" || scenario == "store" {
      XCTAssertEqual(response.status, 409)
      XCTAssertEqual(object["error"], .object(["code": .string("instance_busy"),
        "runningSessionId": .string(scenario == "memory" ? "pending" : "live")]))
      XCTAssertEqual(app.webWorkflowLaunches.count, before)
    } else if scenario == "extra" || scenario == "invalid" {
      XCTAssertEqual(response.status, 400)
      XCTAssertEqual(object["error"], .object(["code": .string("invalid_configured_run")]))
      XCTAssertEqual(app.webWorkflowLaunches.count, before)
    } else {
      XCTAssertEqual(response.status, 202, String(data: response.body, encoding: .utf8) ?? "invalid UTF-8")
    }
    owner.release(sessionId: "live")
    await app.webWorkflowRuntime.shutdown()
  }

  func testInMemoryBusy() async throws { try await exercise("memory") }
  func testStoreBusy() async throws { try await exercise("store") }
  func testOrphanDoesNotBlock() async throws { try await exercise("orphan") }
  func testAllowOverlap() async throws { try await exercise("allow") }
  func testUnknownKeyRejected() async throws { try await exercise("extra") }
  func testNonBooleanRejected() async throws { try await exercise("invalid") }
}
#endif
