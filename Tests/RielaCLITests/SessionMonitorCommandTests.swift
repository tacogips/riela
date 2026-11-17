import Foundation
import RielaCore
import RielaEvents
import XCTest
@testable import RielaCLI

/// Issue #194: an App-independent monitor must distinguish App/daemon down,
/// scheduler down, a still-running workflow, stale output and a failed check.
final class SessionMonitorCommandTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testVerdictsFromStoreState() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("session-monitor-store")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)

    var report = await check(root: root, maxAge: 3_600)
    XCTAssertEqual(report.verdict, .staleOutput)
    XCTAssertEqual(report.reasons, ["no completed execution recorded"])

    try save(id: "done", status: .completed, updatedAt: now.addingTimeInterval(-600), store: store)
    try save(id: "nested", status: .completed, updatedAt: now, parent: "done", store: store)
    report = await check(root: root, maxAge: 3_600)
    XCTAssertEqual(report.verdict, .healthy)
    XCTAssertEqual(report.store?.lastCompleted?.sessionId, "done")
    XCTAssertEqual(report.store?.outputAgeSeconds, 600)

    report = await check(root: root, maxAge: 60)
    XCTAssertEqual(report.verdict, .staleOutput)

    try save(id: "orphan", status: .running, updatedAt: now.addingTimeInterval(-300), store: store)
    try save(id: "live", status: .running, updatedAt: now.addingTimeInterval(-30), store: store)
    let owner = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
    try owner.acquire(sessionId: "live")
    defer { owner.release(sessionId: "live") }
    report = await check(root: root, maxAge: 60)
    XCTAssertEqual(report.verdict, .running)
    XCTAssertEqual(report.store?.liveSessionIds, ["live"])
    XCTAssertEqual(report.store?.orphanedSessionIds, ["orphan"])
    XCTAssertTrue(report.reasons.contains { $0.contains("riela session reconcile --apply") }, "\(report.reasons)")
    XCTAssertEqual(report.verdict.exitCode, .success)
  }

  func testSchedulerSilenceAndAppAndCheckFailurePriority() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("session-monitor-scheduler")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    try save(id: "done", status: .completed, updatedAt: now.addingTimeInterval(-60), store: store)
    let eventRoot = root.appendingPathComponent("events")
    let receipts = EventReceiptStore(eventRoot: eventRoot)
    try receipts.save(receipt(id: "tick-1", source: "hourly", at: now.addingTimeInterval(-7_200)))
    try receipts.save(receipt(id: "tick-other", source: "other", at: now.addingTimeInterval(-10)))

    var report = await check(root: root, maxAge: 3_600,
      extra: ["--event-root", eventRoot.path, "--scheduler-max-silence-seconds", "3600", "--event-source", "hourly"])
    XCTAssertEqual(report.verdict, .schedulerUnavailable)
    XCTAssertEqual(report.scheduler?.silenceSeconds, 7_200)
    XCTAssertEqual(report.verdict.exitCode, .gateCheckFailed)

    report = await check(root: root, maxAge: 3_600,
      extra: ["--event-root", eventRoot.path, "--scheduler-max-silence-seconds", "3600"])
    XCTAssertEqual(report.verdict, .healthy)

    report = await check(root: root, maxAge: 3_600, extra: ["--require-app"], app: .init(state: "not_running", detail: nil))
    XCTAssertEqual(report.verdict, .appUnavailable)
    report = await check(root: root, maxAge: 3_600, extra: ["--require-app"], app: .init(state: "running", detail: nil))
    XCTAssertEqual(report.verdict, .healthy)

    // A stalled store yields check_failed, which outranks every other verdict.
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    _ = await BoundedSessionStoreIO.run(key: BoundedSessionStoreIO.key(sessionStoreRoot: root.path), timeout: 0.05) {
      release.wait()
    }
    report = await check(root: root, maxAge: 3_600, extra: ["--require-app"], app: .init(state: "not_running", detail: nil))
    XCTAssertEqual(report.verdict, .checkFailed)
    XCTAssertEqual(report.verdict.exitCode, .failure)
  }

  func testCommandLineContract() async throws {
    let application = RielaCLIApplication()
    let help = await application.run(["session", "monitor", "--help"])
    XCTAssertEqual(help.exitCode, .success)
    XCTAssertTrue(help.stdout.contains("scheduler_unavailable"))
    let usage = await application.run(["session", "monitor", "--workflow", "w", "--max-output-age-seconds", "60",
      "--event-root", "events"])
    XCTAssertEqual(usage.exitCode, .usage)
    let root = try makeRielaCLITestTemporaryDirectory("session-monitor-cli")
    defer { try? FileManager.default.removeItem(at: root) }
    let result = await application.run(["session", "monitor", "--workflow", "w", "--max-output-age-seconds", "60",
      "--session-store", root.path])
    XCTAssertEqual(result.exitCode, .gateCheckFailed, result.stderr)
    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(json["verdict"] as? String, "stale_output")
  }

  private func check(root: URL, maxAge: Int, extra: [String] = [],
                     app: SessionMonitorReport.App? = nil) async -> SessionMonitorReport {
    var runner = SessionMonitorCommandRunner()
    let fixedNow = now
    runner.now = { fixedNow }
    if let app { runner.appProbe = { _, _, _ in app } }
    guard let parsed = try? ParsedSessionMonitorArguments.parse(["--workflow", "flow", "--max-output-age-seconds", String(maxAge),
      "--session-store", root.path, "--timeout-seconds", "2"] + extra) else {
      XCTFail("invalid monitor arguments: \(extra)")
      return SessionMonitorReport(verdict: .checkFailed, reasons: [], workflowId: "flow", checkedAt: now, maxOutputAgeSeconds: maxAge)
    }
    return await runner.check(parsed)
  }

  private func save(id: String, status: WorkflowSessionStatus, updatedAt: Date, parent: String? = nil,
                    store: CLIWorkflowSessionStore) throws {
    let session = WorkflowSession(workflowId: "flow", sessionId: id, status: status, entryStepId: "step",
      createdAt: updatedAt, updatedAt: updatedAt, parentSessionId: parent)
    try store.save(PersistedCLIWorkflowSession(workflowName: "flow", session: session,
      resolution: WorkflowResolutionOptions(workflowName: "flow")),
      runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: session))
  }

  private func receipt(id: String, source: String, at date: Date) -> PersistedEventReceipt {
    PersistedEventReceipt(receiptId: id, sourceId: source, eventId: id, status: "completed", duplicate: false,
      workflowExecutionId: nil, workflowName: "flow", replayedFromReceiptId: nil, reason: nil, updatedAt: date,
      envelope: ExternalEventEnvelope(sourceId: source, eventId: id, provider: "cron", eventType: "schedule",
        receivedAt: date, input: [:]))
  }
}
