import Foundation
import XCTest
import RielaServer
@testable import RielaAppSupport

private actor ReloadPortsFake: RielaAppInstanceReloadPorts {
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
}

final class RielaAppInstanceReloadCoordinatorTests: XCTestCase {
  private func reload(_ ports: ReloadPortsFake, interrupt: Bool = false) async -> Result<RielaAppInstanceReloadResponse, RielaAppInstanceReloadError> {
    let request = RielaAppInstanceReloadRequest(expectedProfile: "default", expectedRevision: 1, reason: "test", workflowDirectory: nil, interruptRunning: interrupt)
    return await RielaAppInstanceReloadCoordinator(ports: ports, makeRequestId: { "request" }).reload(identity: "id", request: request)
  }
  func testDefinitionOnly() async throws {
    let ports = ReloadPortsFake(); await ports.configure("same")
    let response = try await reload(ports).get(); let calls = await ports.history()
    XCTAssertEqual(response.handoff, "none"); XCTAssertTrue(response.committed)
    XCTAssertFalse(calls.contains { $0.hasPrefix("admission-") }); XCTAssertFalse(calls.contains("replace"))
    XCTAssertEqual(calls.filter { $0 == "import" }.count, 1)
  }
  func testBusyRejectsBeforeImport() async {
    let ports = ReloadPortsFake(); await ports.configure("running")
    let result = await reload(ports); let calls = await ports.history()
    guard case .failure(let error) = result else { return XCTFail("expected failure") }
    XCTAssertEqual(error.code, .instanceRunInFlight); XCTAssertFalse(error.committed); XCTAssertEqual(error.running, 1)
    XCTAssertEqual(calls.filter { $0.hasPrefix("admission-") }, ["admission-close", "admission-open"])
    XCTAssertFalse(calls.contains("import")); XCTAssertFalse(calls.contains("replace"))
  }
  func testChildCountsWithoutHistory() async {
    let ports = ReloadPortsFake(); await ports.configure("running")
    let result = await reload(ports)
    guard case .failure(let error) = result else { return XCTFail("expected failure") }
    XCTAssertEqual(error.code, .instanceRunInFlight); XCTAssertEqual(error.queued, 0)
  }
  func testUnsupportedHandoff() async {
    let ports = ReloadPortsFake(); await ports.configure("unsupported")
    let result = await reload(ports); let calls = await ports.history()
    guard case .failure(let error) = result else { return XCTFail("expected failure") }
    XCTAssertEqual(error.code, .instanceHandoffUnavailable); XCTAssertFalse(error.committed)
    XCTAssertTrue(calls.contains("admission-open")); XCTAssertFalse(calls.contains("import"))
  }
  func testInterruptBusy() async throws {
    let ports = ReloadPortsFake(); await ports.configure("running")
    let response = try await reload(ports, interrupt: true).get(); let calls = await ports.history()
    XCTAssertEqual(response.handoff, "interrupted"); XCTAssertTrue(response.eventBindings.respawned)
    XCTAssertEqual(calls.filter { ["import", "refresh", "admission-confirm", "replace"].contains($0) }, ["import", "refresh", "admission-confirm", "replace"])
  }
  func testExpiredConfirm() async throws {
    let ports = ReloadPortsFake(); await ports.configure("expired")
    let response = try await reload(ports).get(); let calls = await ports.history()
    XCTAssertEqual(response.handoff, "lost"); XCTAssertFalse(response.eventBindings.respawned); XCTAssertTrue(response.committed)
    XCTAssertTrue(calls.contains("admission-open")); XCTAssertFalse(calls.contains("replace"))
  }
  func testTriggerDefaultsLostHandoffRecovery() async throws {
    let ports = ReloadPortsFake(); await ports.configure("trigger"); await ports.configure("expired")
    let first = try await reload(ports).get(); XCTAssertEqual(first.handoff, "lost")
    await ports.configure("recover"); await ports.clear()
    let second = try await reload(ports).get(); let secondCalls = await ports.history()
    XCTAssertEqual(second.definition.outcome, "unchanged"); XCTAssertTrue(second.eventBindings.respawned)
    XCTAssertTrue(secondCalls.contains("admission-close")); XCTAssertTrue(secondCalls.contains("replace"))
    await ports.clear(); let third = try await reload(ports).get(); let thirdCalls = await ports.history()
    XCTAssertEqual(third.handoff, "none"); XCTAssertFalse(thirdCalls.contains { $0.hasPrefix("admission-") })
  }
  func testImportConflictReopens() async {
    let ports = ReloadPortsFake(); await ports.configure("conflict")
    let result = await reload(ports); let calls = await ports.history()
    guard case .failure(let error) = result else { return XCTFail("expected failure") }
    XCTAssertEqual(error.code, .definitionConflict); XCTAssertFalse(error.committed)
    XCTAssertTrue(calls.contains("admission-open")); XCTAssertFalse(calls.contains("relink")); XCTAssertFalse(calls.contains("replace"))
  }
  func testRelinkFailureReopens() async {
    let ports = ReloadPortsFake(); await ports.configure("relink")
    let result = await reload(ports); let calls = await ports.history()
    guard case .failure(let error) = result else { return XCTFail("expected failure") }
    XCTAssertEqual(error.code, .configurationIOFailure); XCTAssertTrue(error.committed); XCTAssertEqual(error.partial, "definition")
    XCTAssertTrue(calls.contains("admission-open")); XCTAssertFalse(calls.contains("replace"))
  }
  func testReplaceFailureCommitted() async {
    let ports = ReloadPortsFake(); await ports.configure("replace")
    let result = await reload(ports)
    guard case .failure(let error) = result else { return XCTFail("expected failure") }
    XCTAssertEqual(error.code, .instanceStartFailed); XCTAssertTrue(error.committed)
  }
  func testInvalidBindingsStopsBeforeAdmission() async {
    let ports = ReloadPortsFake(); await ports.configure("invalid")
    let result = await reload(ports); let calls = await ports.history()
    guard case .failure(let error) = result else { return XCTFail("expected failure") }
    XCTAssertEqual(error.code, .invalidEventBindings); XCTAssertEqual(calls, ["revision", "instance", "discover", "validate"])
  }
  func testUnknownInstance() async {
    let ports = ReloadPortsFake(); await ports.configure("missing")
    let result = await reload(ports)
    guard case .failure(let error) = result else { return XCTFail("expected failure") }
    XCTAssertEqual(error.code, .instanceNotFound); XCTAssertFalse(error.committed)
  }
}
