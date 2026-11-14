import Foundation
import XCTest
import RielaCore
import RielaServer
@testable import RielaAppSupport

private actor ServiceReloadPorts: RielaAppInstanceReloadPorts {
  var calls: [String] = []
  var installed = RielaAppInstanceStartRecord(workflowDirectory: "/workflow", eventRoot: "/events", eventRootDigest: "old", triggerDefaultsFingerprint: "A")
  var candidate = RielaAppInstanceReloadCandidate(sourceId: "source", workflowDirectory: "/workflow", eventRoot: "/events", sourceChanged: false)
  var validated = RielaAppInstanceReloadValidated(workflowId: "workflow", triggerDefaultsFingerprint: "A", eventRootDigest: "new")
  var missing = false
  var closeError = false
  var running = 0
  var confirmExpired = false
  var importError = false
  var relinkError = false
  var replaceError = false
  var definitionOutcome = "forced"

  func configure(_ key: String) {
    switch key {
    case "same": installed.eventRootDigest = "new"
    case "running": running = 1
    case "unsupported": closeError = true
    case "expired": confirmExpired = true
    case "recover": confirmExpired = false; definitionOutcome = "unchanged"
    case "conflict": importError = true
    case "relink": candidate.sourceChanged = true; relinkError = true
    case "replace": replaceError = true
    case "invalid": validated.workflowId = "invalid"
    case "missing": missing = true
    case "trigger": installed.eventRootDigest = "new"; validated.triggerDefaultsFingerprint = "B"
    default: break
    }
  }
  func history() -> [String] { calls }
  func clear() { calls = [] }
  func currentInstance(identity: String) async -> RielaAppInstanceReloadInstance? {
    calls.append("instance")
    return missing ? nil : .init(identity: identity, workflowId: "workflow", sourceId: "source", workflowDirectory: "/workflow", eventRoot: "/events")
  }
  func validateRevision(expectedRevision: Int, expectedProfile: String) async throws { calls.append("revision") }
  func discoverCandidate(instance: RielaAppInstanceReloadInstance, requestedDirectory: String?) async throws -> RielaAppInstanceReloadCandidate {
    calls.append("discover"); return candidate
  }
  func validate(candidate: RielaAppInstanceReloadCandidate, instance: RielaAppInstanceReloadInstance) async throws -> RielaAppInstanceReloadValidated {
    calls.append("validate")
    if validated.workflowId == "invalid" { throw RielaAppInstanceReloadError(code: .invalidEventBindings) }
    return validated
  }
  func installedStartRecord(identity: String) async -> RielaAppInstanceStartRecord? { calls.append("installed"); return installed }
  func childRunning(identity: String) async -> Bool { calls.append("childRunning"); return true }
  func admission(identity: String, frame: WorkflowServeAdmissionFrame) async throws -> WorkflowServeAdmissionAcknowledgement {
    calls.append(frame.type)
    if frame.type == "admission-close" && closeError { throw WorkflowServeAdmissionError.unsupported }
    let state: WorkflowServeAdmissionState = frame.type == "admission-confirm" && confirmExpired ? .expired : .closed
    return .init(requestId: frame.requestId, state: state, running: running, queued: 0)
  }
  func importDefinition(candidate: RielaAppInstanceReloadCandidate, reason: String) async throws -> RielaAppInstanceReloadResponse.Definition {
    calls.append("import")
    if importError { throw RielaAppInstanceReloadError(code: .definitionConflict) }
    return .init(outcome: definitionOutcome, versionId: nil, digest: nil)
  }
  func relink(identity: String, candidate: RielaAppInstanceReloadCandidate) async throws -> Int {
    calls.append("relink")
    if relinkError { throw RielaAppInstanceReloadError(code: .configurationIOFailure) }
    return 2
  }
  func refreshCache() async { calls.append("refresh") }
  func replaceChild(identity: String, interrupt: Bool) async throws -> String {
    calls.append("replace")
    if replaceError { throw RielaAppInstanceReloadError(code: .instanceStartFailed) }
    installed = .init(workflowDirectory: candidate.workflowDirectory, eventRoot: candidate.eventRoot,
                      eventRootDigest: validated.eventRootDigest, triggerDefaultsFingerprint: validated.triggerDefaultsFingerprint)
    return "running"
  }
  func profile() async -> String { "default" }
  func revision() async -> Int { 1 }
  var omitRevision = false
  func setOmitRevision() { omitRevision = true }
  func liveRevision() async -> Int? { omitRevision ? nil : 1 }
}

private struct CallSnapshot {
  var appCalls: Int
  var frames: [WorkflowServeSessionControlFrame]
  var storeCalls: Int
}

private struct SoleScenario {
  var app: RielaAppLiveSessionInventory
  var child: RielaAppLiveSessionInventory
  var running: Bool
  var throwsControl: Bool
  var expected: RielaAppInstanceCancelCode
}

private actor ServiceCancelPorts: RielaAppInstanceCancelPorts {
  var currentProfile = "default"
  var exists = true
  var appOutcome: WorkflowServeSessionCancelOutcome = .notFound
  var childOutcome: WorkflowServeSessionCancelOutcome = .notFound
  var app = RielaAppLiveSessionInventory(sessionIds: [], pendingRunCount: 0)
  var child = RielaAppLiveSessionInventory(sessionIds: [], pendingRunCount: 0)
  var running = false
  var throwsControl = false
  var state: RielaAppStoredSessionState = .absent
  var appCalls = 0
  var frames: [WorkflowServeSessionControlFrame] = []
  var storeCalls = 0
  func configure(profile: String = "default", exists: Bool = true, appOutcome: WorkflowServeSessionCancelOutcome = .notFound,
                 childOutcome: WorkflowServeSessionCancelOutcome = .notFound, app: RielaAppLiveSessionInventory = .init(sessionIds: [], pendingRunCount: 0),
                 child: RielaAppLiveSessionInventory = .init(sessionIds: [], pendingRunCount: 0), running: Bool = false,
                 throwsControl: Bool = false, state: RielaAppStoredSessionState = .absent) {
    currentProfile = profile; self.exists = exists; self.appOutcome = appOutcome; self.childOutcome = childOutcome
    self.app = app; self.child = child; self.running = running; self.throwsControl = throwsControl; self.state = state
  }
  func profile() async -> String { currentProfile }
  func instanceExists(identity: String) async -> Bool { exists }
  func cancelAppLaunch(identity: String, sessionId: String, reason: String, actor: String) async -> WorkflowServeSessionCancelOutcome {
    appCalls += 1; return appOutcome
  }
  func appInventory(identity: String) async -> RielaAppLiveSessionInventory { app }
  func childRunning(identity: String) async -> Bool { running }
  func childSessionControl(identity: String, frame: WorkflowServeSessionControlFrame) async throws -> WorkflowServeSessionControlAcknowledgement {
    frames.append(frame)
    if throwsControl { throw WorkflowServeSessionControlError.unsupported }
    if frame.type == "session-list" { return .listAck(requestId: frame.requestId, sessionIds: child.sessionIds, pendingRunCount: child.pendingRunCount) }
    return .cancelAck(requestId: frame.requestId, sessionId: frame.sessionId ?? "", outcome: childOutcome)
  }
  func storedSessionState(identity: String, sessionId: String) async -> RielaAppStoredSessionState { storeCalls += 1; return state }
  func counts() -> CallSnapshot { .init(appCalls: appCalls, frames: frames, storeCalls: storeCalls) }
}

private actor ServicePorts: RielaAppInstanceControlPorts {
  nonisolated let reload = ServiceReloadPorts()
  nonisolated let cancel = ServiceCancelPorts()
  let snapshot = RuntimeEnvironmentSnapshot(generation: 1, names: ["TOKEN"], environment: ["TOKEN": "secret-value"])
  var runResult = RielaAppControlResult(status: 202, body: .object(["identity": .string("i")]))
  var serializedCount = 0
  var shutdown = false
  var exists = true
  var conflict: RielaAppControlConflict?
  var outcome: RielaAppEnvironmentReloadOutcome = .reloaded(.init(names: ["TOKEN"], readiness: .ready))
  func configure(shutdown: Bool = false, exists: Bool = true, conflict: RielaAppControlConflict? = nil,
                 outcome: RielaAppEnvironmentReloadOutcome = .reloaded(.init(names: ["TOKEN"], readiness: .ready))) {
    self.shutdown = shutdown; self.exists = exists; self.conflict = conflict; self.outcome = outcome
  }
  func setRunResult(_ result: RielaAppControlResult) { runResult = result }
  func serializationCount() -> Int { serializedCount }
  func profile() async -> String { "default" }
  func bootstrap() async -> RielaAppControlBootstrap { .init(profile: "default", revision: 3) }
  func isShuttingDown() async -> Bool { shutdown }
  func serialized(_ body: @escaping @Sendable () async -> RielaAppControlResult) async -> RielaAppControlResult { serializedCount += 1; return await body() }
  nonisolated func reloadPorts() -> any RielaAppInstanceReloadPorts { reload }
  nonisolated func cancelPorts() -> any RielaAppInstanceCancelPorts { cancel }
  func validateRevision(expectedRevision: Int, expectedProfile: String) async -> RielaAppControlConflict? { conflict }
  func instanceExists(identity: String) async -> Bool { exists }
  func environmentStatus(identity: String) async -> RuntimeEnvironmentStatus { .init(names: ["TOKEN"], readiness: .ready) }
  func reloadEnvironment(identity: String) async -> RielaAppEnvironmentReloadOutcome { outcome }
  func launchConfiguredRun(identity: String, input: RielaAppConfiguredRunInput) async -> RielaAppControlResult {
    runResult
  }
  func launchStatus(launchId: String, profile: String) async -> RielaAppControlResult {
    .init(status: 200, body: .object(["profile": .string(profile), "launchId": .string(launchId)]))
  }
}

final class RielaAppInstanceControlServiceTests: XCTestCase {
  private func data(_ string: String) -> Data { Data(string.utf8) }
  private func code(_ result: RielaAppControlResult) -> String? {
    guard case let .object(body) = result.body, case let .object(error) = body["error"], case let .string(code) = error["code"] else { return nil }
    return code
  }
  func testBootstrapRunAndLaunch() async {
    let ports = ServicePorts(); let service = RielaAppInstanceControlService(ports: ports)
    let bootstrap = await service.handle(.bootstrap, profile: nil)
    XCTAssertEqual(bootstrap.status, 200)
    XCTAssertEqual(bootstrap.body, .object(["profile": .string("default"), "revision": .integer(3)]))
    let launch = await service.handle(.launchStatus(launchId: "a"), profile: nil)
    XCTAssertEqual(launch.body, .object(["profile": .string(""), "launchId": .string("a")]))
    let launchProfile = await service.handle(.launchStatus(launchId: "a"), profile: "default")
    XCTAssertEqual(launchProfile.body, .object(["profile": .string("default"), "launchId": .string("a")]))
    let valid = data(#"{"expectedProfile":"default","expectedRevision":3,"variables":{}}"#)
    let run = await service.handle(.run(identity: "i", body: valid), profile: "default")
    XCTAssertEqual(run, .init(status: 202, body: .object(["identity": .string("i")])))
    await ports.setRunResult(.error(status: 422, code: "instance_not_ready"))
    let notReady = await service.handle(.run(identity: "i", body: valid), profile: "default")
    XCTAssertEqual(notReady, .error(status: 422, code: "instance_not_ready"))
    let serialCount = await ports.serializationCount()
    XCTAssertEqual(serialCount, 2)
    for body in [data(#"{"expectedProfile":"default","expectedRevision":3,"variables":{},"extra":1}"#),
                 data(#"{"expectedProfile":"default","expectedRevision":3,"variables":{},"allowOverlap":"x"}"#),
                 Data(repeating: 32, count: 524_289)] {
      let result = await service.handle(.run(identity: "i", body: body), profile: "default")
      XCTAssertEqual(result, .error(status: 400, code: "invalid_configured_run"))
    }
    let mismatch = await service.handle(.run(identity: "i", body: valid), profile: nil)
    XCTAssertEqual(mismatch, .error(status: 400, code: "invalid_configured_run"))
    let other = await service.handle(.run(identity: "i", body: valid), profile: "other")
    XCTAssertEqual(other, .error(status: 400, code: "invalid_configured_run"))
  }
  func testEnvironmentOperations() async throws {
    let ports = ServicePorts(); let service = RielaAppInstanceControlService(ports: ports)
    let status = await service.handle(.environmentStatus(identity: "i"), profile: "default")
    XCTAssertEqual(status.status, 200)
    let snapshot = await ports.snapshot
    XCTAssertEqual(snapshot.runtimeEnvironment()["TOKEN"], "secret-value")
    guard case let .object(statusBody) = status.body else { return XCTFail("status object") }
    XCTAssertEqual(Set(statusBody.keys), Set(["names", "configuredNames", "missingNames", "sourceIDs", "generation", "readiness"]))
    XCTAssertEqual(statusBody["names"], .array([.string("TOKEN")]))
    let bytes = try JSONEncoder().encode(status.body)
    XCTAssertFalse((String(data: bytes, encoding: .utf8) ?? "").contains("secret-value"))
    let noProfile = await service.handle(.environmentStatus(identity: "i"), profile: nil)
    XCTAssertEqual(noProfile, .error(status: 409, code: "profile_or_instance_conflict", message: "Select the current profile and instance."))
    await ports.configure(exists: false)
    let missing = await service.handle(.environmentStatus(identity: "i"), profile: "default")
    XCTAssertEqual(code(missing), "profile_or_instance_conflict")
    await ports.configure()
    let body = data(#"{"action":"reloadEnvironment","expectedProfile":"default","expectedRevision":1}"#)
    let mismatch = await service.handle(.environmentReload(identity: "i", body: body), profile: "other")
    XCTAssertEqual(mismatch, .error(status: 409, code: "configuration_conflict", message: "Configuration changed. Refresh before continuing."))
    let ok = await service.handle(.environmentReload(identity: "i", body: body), profile: nil)
    XCTAssertEqual(ok.status, 200)
    await ports.configure(outcome: .failed(.init(lastError: .sourceFailed)))
    let failed = await service.handle(.environmentReload(identity: "i", body: body), profile: nil)
    XCTAssertEqual(failed.status, 422)
    XCTAssertTrue((String(data: try JSONEncoder().encode(failed.body), encoding: .utf8) ?? "").contains("environment_source_failed"))
    await ports.configure(outcome: .notReady)
    let notReady = await service.handle(.environmentReload(identity: "i", body: body), profile: nil)
    XCTAssertEqual(notReady, .error(status: 422, code: "instance_not_ready", message: "Configuration is not ready."))
    await ports.configure(conflict: .init(code: "conflict", message: "conflict", status: 409))
    let conflict = await service.handle(.environmentReload(identity: "i", body: body), profile: nil)
    XCTAssertEqual(conflict, .error(status: 409, code: "conflict", message: "conflict"))
    let wrong = await service.handle(.environmentReload(identity: "i", body: data(#"{"action":"start","expectedProfile":"default","expectedRevision":1}"#)), profile: nil)
    XCTAssertEqual(wrong, .error(status: 400, code: "invalid_request", message: "Provide a valid configuration request, profile and revision."))
    await ports.configure(exists: false)
    let absent = await service.handle(.environmentReload(identity: "i", body: body), profile: nil)
    XCTAssertEqual(code(absent), "instance_not_found")
    await ports.configure(shutdown: true)
    let shutdown = await service.handle(.environmentReload(identity: "i", body: body), profile: nil)
    XCTAssertEqual(shutdown, .error(status: 409, code: "instance_busy", message: "The app is shutting down."))
  }
  func testReloadAndCancel() async throws {
    let ports = ServicePorts(); let service = RielaAppInstanceControlService(ports: ports)
    let reload = data(#"{"expectedProfile":"default","expectedRevision":1,"reason":"test","workflowDirectory":null,"interruptRunning":false}"#)
    let ok = await service.handle(.reload(identity: "i", body: reload), profile: "default")
    XCTAssertEqual(ok.status, 200)
    guard case let .object(body) = ok.body else { return XCTFail("object") }
    XCTAssertEqual(body["revision"], .integer(1))
    XCTAssertEqual(Set(body.keys), Set(["profile", "revision", "identity", "workflowId", "workflowDirectory", "sourceChanged", "definition", "eventBindings", "handoff", "runtimeStatus", "committed"]))
    let mismatch = await service.handle(.reload(identity: "i", body: reload), profile: "other")
    XCTAssertEqual(mismatch.status, 409)
    XCTAssertEqual(code(mismatch), "configuration_conflict")
    guard case let .object(mismatchBody) = mismatch.body else { return XCTFail("object") }
    XCTAssertEqual(mismatchBody["committed"], .bool(false))
    let invalid = await service.handle(.reload(identity: "i", body: data("{}")), profile: nil)
    XCTAssertEqual(invalid.status, 400)
    XCTAssertEqual(code(invalid), "invalid_reload_request")
    let extra = await service.handle(.reload(identity: "i", body: data(#"{"expectedProfile":"default","expectedRevision":1,"reason":"test","workflowDirectory":null,"interruptRunning":false,"extra":1}"#)), profile: nil)
    XCTAssertEqual(code(extra), "invalid_reload_request")
    let large = await service.handle(.reload(identity: "i", body: Data(repeating: 32, count: 65_537)), profile: nil)
    XCTAssertEqual(large.status, 400)
    XCTAssertEqual(code(large), "invalid_reload_request")
    let busyPorts = ServicePorts()
    await busyPorts.reload.configure("running")
    let busy = await RielaAppInstanceControlService(ports: busyPorts).handle(.reload(identity: "i", body: reload), profile: nil)
    XCTAssertEqual(busy.status, 409)
    XCTAssertEqual(code(busy), "instance_run_in_flight")
    guard case let .object(busyBody) = busy.body else { return XCTFail("object") }
    XCTAssertEqual(busyBody["running"], .integer(1)); XCTAssertEqual(busyBody["queued"], .integer(0))
    XCTAssertEqual(busyBody["committed"], .bool(false))
    let cancel = try JSONEncoder().encode(RielaAppInstanceCancelRequest(expectedProfile: "default", reason: "test"))
    await ports.cancel.configure(appOutcome: .cancelRequested)
    let cancelled = await service.handle(.cancel(identity: "i", sessionId: "s", body: cancel), profile: nil)
    XCTAssertEqual(cancelled.status, 202)
    guard case let .object(cancelBody) = cancelled.body else { return XCTFail("object") }
    XCTAssertEqual(cancelBody, ["identity": .string("i"), "profile": .string("default"), "sessionId": .string("s"), "owner": .string("app"), "outcome": .string("cancelRequested")])
    await ports.cancel.configure(app: .init(sessionIds: ["a", "b"], pendingRunCount: 0))
    let ambiguous = await service.handle(.cancel(identity: "i", sessionId: nil, body: cancel), profile: nil)
    XCTAssertEqual(ambiguous.status, 409)
    XCTAssertEqual(code(ambiguous), "ambiguous_running_sessions")
    guard case let .object(ambiguousBody) = ambiguous.body else { return XCTFail("object") }
    XCTAssertEqual(ambiguousBody["sessionIds"], .array([.string("a"), .string("b")]))
    XCTAssertEqual(ambiguousBody["pendingRunCount"], .integer(0))
    let badCancel = await service.handle(.cancel(identity: "i", sessionId: nil, body: data("{}")), profile: nil)
    XCTAssertEqual(badCancel.status, 400)
    XCTAssertEqual(code(badCancel), "invalid_cancel_request")
    await ports.configure(shutdown: true)
    let shutdown = await service.handle(.reload(identity: "i", body: reload), profile: nil)
    XCTAssertEqual(code(shutdown), "instance_busy")
    let cancelShutdown = await service.handle(.cancel(identity: "i", sessionId: "s", body: cancel), profile: nil)
    XCTAssertEqual(code(cancelShutdown), "instance_busy")
    let cancelMismatch = await service.handle(.cancel(identity: "i", sessionId: "s", body: cancel), profile: "other")
    XCTAssertEqual(code(cancelMismatch), "configuration_conflict")
  }
  func testReloadOptionalRevisionAndPartialCommit() async throws {
    let ports = ServicePorts(); let service = RielaAppInstanceControlService(ports: ports)
    await ports.reload.setOmitRevision()
    let bytes = data(#"{"expectedProfile":"default","expectedRevision":1,"reason":"test","workflowDirectory":null,"interruptRunning":false}"#)
    let response = await service.handle(.reload(identity: "i", body: bytes), profile: nil)
    XCTAssertEqual(response.status, 200)
    guard case let .object(body) = response.body else { return XCTFail("object") }
    XCTAssertNil(body["revision"])
    await ports.reload.configure("relink")
    let failure = await service.handle(.reload(identity: "i", body: bytes), profile: nil)
    XCTAssertEqual(failure.status, 500)
    guard case let .object(errorBody) = failure.body else { return XCTFail("object") }
    XCTAssertEqual(errorBody["committed"], .bool(true))
    XCTAssertEqual(errorBody["partial"], .string("definition"))
  }

  func testReloadRevisionEncoding() throws {
    var response = RielaAppInstanceReloadResponse(profile: "default", revision: nil, identity: "i", workflowId: "w",
      workflowDirectory: "/workflow", sourceChanged: false, definition: .init(outcome: "unchanged", versionId: nil, digest: nil),
      eventBindings: .init(respawnRequired: false, respawned: false), handoff: "none", runtimeStatus: "stopped", committed: true)
    let omitted = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(response))
    XCTAssertNil(omitted["revision"])
    response.revision = 3
    let included = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(response))
    XCTAssertEqual(included["revision"], .integer(3))
  }

}
