#if os(macOS)
import Foundation
import RielaAppSupport
import RielaCLI
import RielaCore
import RielaServer
import RielaWorkflowRegistry
import SQLite3
@testable import RielaApp
import XCTest

private final class ReloadTestHandle: WorkflowServeEventSourceHandle, @unchecked Sendable {
  var status: WorkflowServeEventSourceStatus { .init(sourceId: "fixture", status: "running", generationId: "g") }
  func shutdown() async throws {}
}

private struct ReloadTestFactory: WorkflowServeEventSourceFactory {
  func startEventSources(for resolvedWorkflow: WorkflowServeResolvedWorkflow, request: WorkflowServeStartRequest,
                         generationId: String) async throws -> [any WorkflowServeEventSourceHandle] { [ReloadTestHandle()] }
}

@MainActor
final class RielaAppInstanceReloadRouteTests: XCTestCase {
  func testRouteAndReloadLifecycle() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/reload-route-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    let replacement = root.appendingPathComponent("replacement")
    let mismatch = root.appendingPathComponent("mismatch")
    try fixture(source, workflowId: "reload-test")
    try fixture(replacement, workflowId: "reload-test")
    try fixture(mismatch, workflowId: "other-test")
    let candidate = try XCTUnwrap(RielaAppDaemonWorkflowDiscovery().discoverSelectedWorkflowDirectory(source.path))
    let app = RielaApp()
    app.appHomeDirectory = root
    app.profileStore = RielaAppProfileStore(appRootURL: root.appendingPathComponent("app"))
    try app.profileStore.prepareInitialProfile(.default, persistsSelection: false)
    app.webSessionStoreRootOverride = root.appendingPathComponent("sessions").path
    let preference = RielaAppDaemonWorkflowPreference(identity: "selected", sourceIdentity: candidate.id, available: true, active: false)
    app.daemonState = .init(preferences: ["selected": preference], workflowDirectories: [source.path])
    app.daemonWorkflowSources = [candidate]
    app.daemonInstances = [.configured(identity: "selected", source: candidate, preference: preference)]
    let router = RielaAppWebRouter(app: app, assetRoot: root, configuredPort: 19091)
    XCTAssertTrue(RielaWebAPIRouteTable.desktopOnly.contains { $0.path == "/api/v1/instances/{identity}/reload" })

    func call(_ identity: String = "selected", method: String = "POST", profile: String = "default",
              directory: String? = nil, extra: Bool = false) async throws -> RielaHTTPResponse {
      var body: JSONObject = ["expectedProfile": .string("default"), "expectedRevision": .number(Double(app.webRevision)),
        "reason": .string("test reload"), "workflowDirectory": directory.map(JSONValue.string) ?? .null, "interruptRunning": .bool(false)]
      if extra { body["extra"] = .bool(true) }
      let request = RielaHTTPRequest(method: method, path: "/api/v1/instances/\(identity)/reload",
        headers: ["x-riela-profile": profile, "host": "127.0.0.1:19091", "origin": "http://127.0.0.1:19091",
          "x-riela-csrf": router.csrfToken, "content-type": "application/json"], body: try JSONEncoder().encode(body))
      return await router.response(for: request)
    }
    let insecure = RielaHTTPRequest(method: "POST", path: "/api/v1/instances/selected/reload",
      headers: ["host": "127.0.0.1:19091"], body: Data())
    let insecureResponse = await router.response(for: insecure)
    XCTAssertEqual(insecureResponse.status, 403)
    let wrongMethod = try await call(method: "GET")
    XCTAssertEqual(wrongMethod.status, 405)
    let invalid = try await call(extra: true)
    XCTAssertEqual(invalid.status, 400)
    let wrongProfile = try await call(profile: "wrong")
    XCTAssertEqual(wrongProfile.status, 409)
    let missing = try await call("missing")
    XCTAssertEqual(missing.status, 404)
    let seeded = try await call()
    XCTAssertEqual(seeded.status, 200, (String(data: seeded.body, encoding: .utf8) ?? ""))
    XCTAssertTrue((String(data: seeded.body, encoding: .utf8) ?? "").contains("seeded"))
    let unchanged = try await call()
    XCTAssertEqual(unchanged.status, 200)
    XCTAssertTrue((String(data: unchanged.body, encoding: .utf8) ?? "").contains("unchanged"))
    let revisionBefore = app.webRevision
    let relink = try await call(directory: replacement.path)
    XCTAssertEqual(relink.status, 200, (String(data: relink.body, encoding: .utf8) ?? ""))
    XCTAssertTrue((String(data: relink.body, encoding: .utf8) ?? "").contains("\"sourceChanged\":true"))
    XCTAssertEqual(app.daemonState.preferences["selected"]?.active, false)
    XCTAssertEqual(app.daemonState.preferences["selected"]?.available, true)
    XCTAssertTrue(app.daemonState.workflowDirectories.contains(replacement.path))
    XCTAssertEqual(app.webRevision, revisionBefore + 1)
    let persisted = app.makeDaemonStore(profileName: .default).load()
    XCTAssertEqual(persisted.preferences["selected"]?.sourceIdentity,
      RielaAppDaemonWorkflowDiscovery().discoverSelectedWorkflowDirectory(replacement.path)?.id)
    XCTAssertTrue(persisted.workflowDirectories.contains(replacement.path))
    let configURL = app.makeDaemonStore(profileName: .default).stateURL
    let configBefore = try Data(contentsOf: configURL)
    let service = WorkflowDefinitionService(storeRoot: app.daemonSessionStoreRoot(profileName: .default),
      fileResolver: FileSystemWorkflowBundleResolver())
    let historyBefore = try service.history(workflowName: "reload-test", nodeId: nil, limit: nil)
    let versionsBefore = try versionCount(root: app.daemonSessionStoreRoot(profileName: .default))
    let before = app.daemonState
    let rejected = try await call(directory: mismatch.path)
    XCTAssertEqual(rejected.status, 422, (String(data: rejected.body, encoding: .utf8) ?? ""))
    XCTAssertTrue((String(data: rejected.body, encoding: .utf8) ?? "").contains("workflow_id_mismatch"))
    XCTAssertEqual(app.daemonState, before)
    XCTAssertEqual(try Data(contentsOf: configURL), configBefore)
    XCTAssertEqual(try service.history(workflowName: "reload-test", nodeId: nil, limit: nil).count, historyBefore.count)
    XCTAssertEqual(try versionCount(root: app.daemonSessionStoreRoot(profileName: .default)), versionsBefore)
  }

  func testStartRecordProviderIsInstalledBeforeFakeStart() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/reload-provider-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    try fixture(source, workflowId: "reload-test")
    let candidate = RielaAppDaemonWorkflowCandidate(id: "fixture", workflowId: "reload-test", displayName: "fixture",
      sourceDescription: "fixture", workflowDirectory: source.path, workingDirectory: root.path,
      eventRoot: root.appendingPathComponent(".riela-events").path, eventSources: [.init(id: "fixture", kind: "cron")])
    let sessions = root.appendingPathComponent("sessions").path
    _ = try InstanceReloadSupport.importDefinition(storeRoot: sessions, workflowDirectory: source.path,
      workflowId: "reload-test", reason: "test", workingDirectory: root.path)
    XCTAssertNotNil(RielaApp.reloadStartRecord(candidate: candidate, storeRoot: sessions))
    let runtime = RielaAppDaemonWorkflowRuntime(eventSourceFactory: ReloadTestFactory(), monitorIntervalNanoseconds: 0)
    runtime.setStartRecordProvider(RielaApp.reloadStartRecord)
    await runtime.start(candidate, configuration: .init(workingDirectory: root.path), server: .init(),
      sessionStoreRoot: sessions)
    XCTAssertEqual(runtime.snapshot(for: candidate.id).status, .running)
    XCTAssertNotNil(runtime.installedStartRecord(identity: candidate.id))
    await runtime.stop(identity: candidate.id)
  }

  private func versionCount(root: String) throws -> Int {
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open_v2(SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root), &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM definition_versions", -1, &statement, nil), SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
    return Int(sqlite3_column_int(statement, 0))
  }

  private func fixture(_ directory: URL, workflowId: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let workflow = """
    {"workflowId":"\(workflowId)","description":"fixture","defaults":{"nodeTimeoutMs":120000,"maxLoopIterations":3},
     "entryStepId":"check","nodes":[{"id":"check","nodeFile":"check.json"}],
     "steps":[{"id":"check","nodeId":"check","role":"worker"}]}
    """
    try Data(workflow.utf8).write(to: directory.appendingPathComponent("workflow.json"))
    try Data(#"{"id":"check","nodeType":"command","variables":{},"command":{"executable":"/usr/bin/true","arguments":[]}}"#.utf8)
      .write(to: directory.appendingPathComponent("check.json"))
  }
}
#endif
