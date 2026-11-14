import AgentRuntimeKit
import Foundation
import RielaCore
import XCTest
@testable import CodexAgent

final class CodexToolChildRecoveryTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_700_000_000)

  // MARK: - Event parsing

  func testParserExtractsCommandExecutionLifecycle() {
    let started = CodexToolChildEventParser.parse(
      line: #"{"type":"item.started","item":{"id":"call-1","type":"command_execution","command":"swift test"}}"#
    )
    guard case let .started(toolCallId, fingerprint)? = started else {
      return XCTFail("expected started event")
    }
    XCTAssertEqual(toolCallId, "call-1")
    XCTAssertEqual(fingerprint, agentToolCommandFingerprint("swift test"))

    XCTAssertEqual(
      CodexToolChildEventParser.parse(
        line: #"{"type":"item.completed","item":{"id":"call-1","type":"command_execution","command":"swift test"}}"#
      ),
      .completed(toolCallId: "call-1")
    )
    XCTAssertEqual(
      CodexToolChildEventParser.parse(
        line: #"{"type":"item.updated","item":{"id":"call-1","type":"command_execution","status":"failed"}}"#
      ),
      .completed(toolCallId: "call-1")
    )
    XCTAssertEqual(
      CodexToolChildEventParser.parse(
        line: #"{"type":"item.updated","item":{"id":"call-1","type":"command_execution","status":"in_progress"}}"#
      ),
      .heartbeat(eventType: "item.updated"),
      "non-terminal updates are lifecycle noise, not completions"
    )
  }

  func testParserTreatsGenericEventsAsHeartbeats() {
    XCTAssertEqual(
      CodexToolChildEventParser.parse(line: #"{"type":"turn.status","status":"waiting"}"#),
      .heartbeat(eventType: "turn.status")
    )
    XCTAssertEqual(
      CodexToolChildEventParser.parse(
        line: #"{"type":"item.completed","item":{"id":"m1","type":"agent_message","text":"done"}}"#
      ),
      .heartbeat(eventType: "item.completed"),
      "non-command items never close a command tool call"
    )
    XCTAssertNil(CodexToolChildEventParser.parse(line: "not json"))
  }

  // MARK: - Policy from node variables

  func testPolicyParsesFromNodeVariablesWithDefaults() {
    XCTAssertEqual(codexToolChildRecoveryPolicy([:]).mode, .off)
    let policy = codexToolChildRecoveryPolicy([
      "codexToolRecovery": .string("recover"),
      "codexToolRecoveryGraceMs": .integer(2_000),
      "codexToolRecoveryCleanupGraceMs": .integer(100),
      "codexToolRecoveryAllowContinuation": .bool(true)
    ])
    XCTAssertEqual(policy.mode, .recover)
    XCTAssertEqual(policy.terminalObservationGraceMs, 2_000)
    XCTAssertEqual(policy.cleanupGraceMs, 100)
    XCTAssertTrue(policy.allowSameAttemptContinuation)
    XCTAssertEqual(codexToolChildRecoveryPolicy(["codexToolRecovery": .string("bogus")]).mode, .off)
  }

  // MARK: - Post-summary unreaped-child integration shape

  /// The real failure shape: the command prints its test/lint summary and
  /// exits into an unreaped zombie, the codex host keeps emitting wait/status
  /// events, and no completion arrives. The monitor must classify exactly one
  /// incident, clean up (recover mode) with bounded TERM→KILL, and resolve —
  /// with no duplicate incident on later polls and no leaked monitor task.
  func testMonitorRecoversPostSummaryUnreapedChildOnce() async {
    let prober = MutableProber()
    prober.set(100, AgentProbedProcess(state: .running))
    prober.set(200, AgentProbedProcess(state: .zombie, parentProcessId: 100, startIdentity: "start-200"))
    let signaler = RecordingSignaler()
    let monitor = CodexToolChildRecoveryMonitor(
      policy: AgentToolChildRecoveryPolicy(mode: .recover, terminalObservationGraceMs: 1_000, cleanupGraceMs: 10),
      workflowExecutionId: "wf",
      stepExecutionId: "impl",
      attempt: 1,
      prober: prober,
      discoverer: FixedDiscoverer(children: [200]),
      signaler: signaler,
      autoPoll: false
    )
    let emitted = EventCollector()
    await monitor.startAndAwait { emitted.append($0) }
    await monitor.processSpawnedAndAwait(100)
    await monitor.observeStdoutLineAndAwait(
      #"{"type":"item.started","item":{"id":"call-1","type":"command_execution","command":"swift test"}}"#
    )
    // Post-summary shape: output printed, then only generic wait/status noise.
    await monitor.observeStdoutLineAndAwait(#"{"type":"turn.status","status":"waiting"}"#)
    await monitor.observeStdoutLineAndAwait(#"{"type":"turn.status","status":"waiting"}"#)

    // First tick records the terminal observation; still inside grace.
    await monitor.tick(now: base)
    var events = await monitor.recoveryEvents()
    XCTAssertTrue(events.contains { if case .terminalObserved = $0 { return true }; return false })
    XCTAssertFalse(events.contains { if case .incidentRecorded = $0 { return true }; return false })

    // Past grace: one incident, host-completion request, TERM→KILL, resolve.
    await monitor.tick(now: base.addingTimeInterval(2))
    events = await monitor.recoveryEvents()
    XCTAssertEqual(events.filter { if case .incidentRecorded = $0 { return true }; return false }.count, 1)
    XCTAssertEqual(signaler.snapshot().map(\.signal), [SIGTERM, SIGKILL])
    XCTAssertTrue(events.contains { if case .resolved = $0 { return true }; return false })
    XCTAssertFalse(emitted.snapshot().isEmpty, "incidents surface in the backend event stream for inspection")
    XCTAssertTrue(emitted.snapshot().allSatisfy { ($0.contentSnapshot ?? "").contains("swift test") == false },
                  "diagnostics carry the fingerprint, never the command text")

    // Duplicate polls suppress rather than repeat the incident/cleanup.
    await monitor.tick(now: base.addingTimeInterval(3))
    events = await monitor.recoveryEvents()
    XCTAssertEqual(events.filter { if case .incidentRecorded = $0 { return true }; return false }.count, 1)
    XCTAssertTrue(events.contains { if case .duplicateSuppressed = $0 { return true }; return false })
    XCTAssertEqual(signaler.snapshot().map(\.signal), [SIGTERM, SIGKILL], "no second signal sequence")

    await monitor.stop()
    // After stop, ticks are inert (no leaked evaluation).
    let countAfterStop = events.count
    await monitor.tick(now: base.addingTimeInterval(10))
    let after = await monitor.recoveryEvents()
    XCTAssertEqual(after.count, countAfterStop)
  }

  func testMonitorObserveModeRecordsIncidentWithoutSignals() async {
    let prober = MutableProber()
    prober.set(100, AgentProbedProcess(state: .running))
    prober.set(200, AgentProbedProcess(state: .zombie, parentProcessId: 100, startIdentity: "start-200"))
    let signaler = RecordingSignaler()
    let monitor = CodexToolChildRecoveryMonitor(
      policy: AgentToolChildRecoveryPolicy(mode: .observe, terminalObservationGraceMs: 0, cleanupGraceMs: 10),
      workflowExecutionId: "wf",
      stepExecutionId: "impl",
      attempt: 1,
      prober: prober,
      discoverer: FixedDiscoverer(children: [200]),
      signaler: signaler,
      autoPoll: false
    )
    await monitor.startAndAwait { _ in }
    await monitor.processSpawnedAndAwait(100)
    await monitor.observeStdoutLineAndAwait(
      #"{"type":"item.started","item":{"id":"call-1","type":"command_execution","command":"swift test"}}"#
    )
    await monitor.tick(now: base)
    await monitor.tick(now: base.addingTimeInterval(1))
    let events = await monitor.recoveryEvents()
    XCTAssertEqual(events.filter { if case .incidentRecorded = $0 { return true }; return false }.count, 1)
    XCTAssertTrue(signaler.snapshot().isEmpty, "observe mode never signals")
    await monitor.stop()
  }

  func testMonitorClosesCallOnHostCompletionAndNeverClassifies() async {
    let prober = MutableProber()
    prober.set(100, AgentProbedProcess(state: .running))
    prober.set(200, AgentProbedProcess(state: .zombie, parentProcessId: 100, startIdentity: "start-200"))
    let monitor = CodexToolChildRecoveryMonitor(
      policy: AgentToolChildRecoveryPolicy(mode: .observe, terminalObservationGraceMs: 0, cleanupGraceMs: 10),
      workflowExecutionId: "wf",
      stepExecutionId: "impl",
      attempt: 1,
      prober: prober,
      discoverer: FixedDiscoverer(children: [200]),
      signaler: RecordingSignaler(),
      autoPoll: false
    )
    await monitor.startAndAwait { _ in }
    await monitor.processSpawnedAndAwait(100)
    await monitor.observeStdoutLineAndAwait(
      #"{"type":"item.started","item":{"id":"call-1","type":"command_execution","command":"swift test"}}"#
    )
    await monitor.observeStdoutLineAndAwait(
      #"{"type":"item.completed","item":{"id":"call-1","type":"command_execution"}}"#
    )
    await monitor.tick(now: base.addingTimeInterval(5))
    let events = await monitor.recoveryEvents()
    XCTAssertFalse(events.contains { if case .incidentRecorded = $0 { return true }; return false })
    await monitor.stop()
  }

  func testMonitorDoesNotBindAmbiguousChildren() async {
    let prober = MutableProber()
    prober.set(100, AgentProbedProcess(state: .running))
    let monitor = CodexToolChildRecoveryMonitor(
      policy: AgentToolChildRecoveryPolicy(mode: .observe, terminalObservationGraceMs: 0, cleanupGraceMs: 10),
      workflowExecutionId: "wf",
      stepExecutionId: "impl",
      attempt: 1,
      prober: prober,
      discoverer: FixedDiscoverer(children: [200, 201]),
      signaler: RecordingSignaler(),
      autoPoll: false
    )
    await monitor.startAndAwait { _ in }
    await monitor.processSpawnedAndAwait(100)
    await monitor.observeStdoutLineAndAwait(
      #"{"type":"item.started","item":{"id":"call-1","type":"command_execution","command":"swift test"}}"#
    )
    await monitor.tick(now: base.addingTimeInterval(5))
    let events = await monitor.recoveryEvents()
    XCTAssertFalse(
      events.contains { if case .incidentRecorded = $0 { return true }; return false },
      "an unbound call (ambiguous children) never classifies — a wrong binding could authorize cleanup against the wrong process"
    )
    await monitor.stop()
  }

  // MARK: - Fixtures

  private final class MutableProber: AgentProcessStateProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [Int32: AgentProbedProcess] = [:]

    func set(_ processId: Int32, _ probed: AgentProbedProcess) {
      lock.lock()
      defer { lock.unlock() }
      states[processId] = probed
    }

    func probe(processId: Int32) -> AgentProbedProcess {
      lock.lock()
      defer { lock.unlock() }
      return states[processId] ?? AgentProbedProcess(state: .missing)
    }
  }

  private struct FixedDiscoverer: AgentChildProcessDiscovering {
    var children: [Int32]

    func childProcessIds(of parentProcessId: Int32) -> [Int32] {
      children
    }
  }

  private final class RecordingSignaler: AgentProcessSignaling, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [RecordedSignal] = []

    func signalGroup(_ groupId: Int32, signal: Int32) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      sent.append(RecordedSignal(groupId: groupId, signal: signal))
      return true
    }

    func signalProcess(_ processId: Int32, signal: Int32) -> Bool {
      signalGroup(processId, signal: signal)
    }

    func snapshot() -> [RecordedSignal] {
      lock.lock()
      defer { lock.unlock() }
      return sent
    }
  }

  private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AdapterBackendEvent] = []

    func append(_ event: AdapterBackendEvent) {
      lock.lock()
      defer { lock.unlock() }
      events.append(event)
    }

    func snapshot() -> [AdapterBackendEvent] {
      lock.lock()
      defer { lock.unlock() }
      return events
    }
  }
}

private struct RecordedSignal: Equatable {
  var groupId: Int32
  var signal: Int32
}
