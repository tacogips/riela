import Foundation
import XCTest
@testable import AgentRuntimeKit

final class AgentToolChildRecoveryTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_700_000_000)

  // MARK: - Classifier

  func testClassifierRequiresUnresolvedCallWithTerminalChildAndLiveHost() {
    let prober = FakeProber(states: [
      100: AgentProbedProcess(state: .running),                       // agent host alive
      200: AgentProbedProcess(state: .zombie, parentProcessId: 100, startIdentity: "s1")
    ])
    let incidents = AgentTerminalToolChildClassifier.classify(
      observations: [observation(childProcessId: 200, startIdentity: "s1")],
      prober: prober,
      policy: policy(mode: .observe, graceMs: 1_000),
      now: base.addingTimeInterval(2)
    )
    XCTAssertEqual(incidents.count, 1)
    XCTAssertEqual(incidents.first?.childState, .zombie)
    XCTAssertTrue(incidents.first?.diagnostic.contains("zombie") == true)
  }

  func testClassifierIsOffWhenPolicyOff() {
    let prober = FakeProber(states: [
      100: AgentProbedProcess(state: .running),
      200: AgentProbedProcess(state: .zombie, parentProcessId: 100, startIdentity: "s1")
    ])
    XCTAssertTrue(AgentTerminalToolChildClassifier.classify(
      observations: [observation(childProcessId: 200, startIdentity: "s1")],
      prober: prober,
      policy: policy(mode: .off, graceMs: 0),
      now: base.addingTimeInterval(10)
    ).isEmpty)
  }

  func testClassifierIgnoresRunningChildAndDeadHost() {
    let runningChild = FakeProber(states: [
      100: AgentProbedProcess(state: .running),
      200: AgentProbedProcess(state: .running, parentProcessId: 100)
    ])
    XCTAssertTrue(AgentTerminalToolChildClassifier.classify(
      observations: [observation(childProcessId: 200)],
      prober: runningChild,
      policy: policy(mode: .observe, graceMs: 0),
      now: base.addingTimeInterval(10)
    ).isEmpty, "a running child is a quiet-but-healthy tool call, never a stall")

    let deadHost = FakeProber(states: [
      100: AgentProbedProcess(state: .missing),
      200: AgentProbedProcess(state: .zombie, parentProcessId: 100, startIdentity: "s1")
    ])
    XCTAssertTrue(AgentTerminalToolChildClassifier.classify(
      observations: [observation(childProcessId: 200, startIdentity: "s1")],
      prober: deadHost,
      policy: policy(mode: .observe, graceMs: 0),
      now: base.addingTimeInterval(10)
    ).isEmpty, "a dead host is an ordinary exit handled by the completion path")
  }

  func testClassifierRejectsPidReuseAndParentMismatch() {
    // Start identity mismatch = PID reuse.
    let reused = FakeProber(states: [
      100: AgentProbedProcess(state: .running),
      200: AgentProbedProcess(state: .zombie, parentProcessId: 100, startIdentity: "different")
    ])
    XCTAssertTrue(AgentTerminalToolChildClassifier.classify(
      observations: [observation(childProcessId: 200, startIdentity: "s1")],
      prober: reused,
      policy: policy(mode: .observe, graceMs: 0),
      now: base.addingTimeInterval(10)
    ).isEmpty, "a start-identity mismatch means PID reuse; never classify")

    // Zombie owned by an unrelated parent.
    let foreign = FakeProber(states: [
      100: AgentProbedProcess(state: .running),
      200: AgentProbedProcess(state: .zombie, parentProcessId: 999, startIdentity: "s1")
    ])
    XCTAssertTrue(AgentTerminalToolChildClassifier.classify(
      observations: [observation(childProcessId: 200, startIdentity: "s1")],
      prober: foreign,
      policy: policy(mode: .observe, graceMs: 0),
      now: base.addingTimeInterval(10)
    ).isEmpty, "a zombie parented elsewhere is not ours to classify")
  }

  func testClassifierWaitsOutGraceAndRequiresPriorTerminalObservationForMissingChild() {
    let prober = FakeProber(states: [
      100: AgentProbedProcess(state: .running),
      200: AgentProbedProcess(state: .zombie, parentProcessId: 100, startIdentity: "s1")
    ])
    // Inside grace: no incident.
    XCTAssertTrue(AgentTerminalToolChildClassifier.classify(
      observations: [observation(childProcessId: 200, startIdentity: "s1", terminalObservedAt: base)],
      prober: prober,
      policy: policy(mode: .observe, graceMs: 30_000),
      now: base.addingTimeInterval(5)
    ).isEmpty)

    // Missing child with no prior terminal observation: cannot distinguish
    // reaped-and-completed from never-started; no incident.
    let missing = FakeProber(states: [
      100: AgentProbedProcess(state: .running),
      200: AgentProbedProcess(state: .missing)
    ])
    XCTAssertTrue(AgentTerminalToolChildClassifier.classify(
      observations: [observation(childProcessId: 200)],
      prober: missing,
      policy: policy(mode: .observe, graceMs: 0),
      now: base.addingTimeInterval(10)
    ).isEmpty)

    // Missing child after a recorded terminal observation classifies.
    XCTAssertEqual(AgentTerminalToolChildClassifier.classify(
      observations: [observation(childProcessId: 200, terminalObservedAt: base)],
      prober: missing,
      policy: policy(mode: .observe, graceMs: 1_000),
      now: base.addingTimeInterval(10)
    ).count, 1)
  }

  func testCompletedCallNeverClassifies() {
    let prober = FakeProber(states: [
      100: AgentProbedProcess(state: .running),
      200: AgentProbedProcess(state: .zombie, parentProcessId: 100, startIdentity: "s1")
    ])
    var completed = observation(childProcessId: 200, startIdentity: "s1")
    completed.completedAt = base.addingTimeInterval(1)
    XCTAssertTrue(AgentTerminalToolChildClassifier.classify(
      observations: [completed],
      prober: prober,
      policy: policy(mode: .observe, graceMs: 0),
      now: base.addingTimeInterval(10)
    ).isEmpty)
  }

  // MARK: - Tracker CAS / duplicate suppression

  func testTrackerIncidentTransitionsAreIdempotent() async {
    let recorder = EventRecorder()
    let tracker = AgentToolChildTracker { recorder.append($0) }
    let incident = AgentToolChildIncident(
      observation: observation(childProcessId: 200),
      childState: .zombie,
      detectedAt: base,
      diagnostic: "diag"
    )
    let began = await tracker.beginIncident(incident)
    XCTAssertTrue(began)
    let duplicate = await tracker.beginIncident(incident)
    XCTAssertFalse(duplicate, "duplicate polls never repeat an incident")
    let cleanupBegan = await tracker.beginCleanup(incidentKey: incident.observation.incidentKey)
    XCTAssertTrue(cleanupBegan)
    let cleanupRepeated = await tracker.beginCleanup(incidentKey: incident.observation.incidentKey)
    XCTAssertFalse(cleanupRepeated, "cleanup runs at most once")
    await tracker.resolveIncident(incidentKey: incident.observation.incidentKey, outcome: "done")
    // Cancellation after resolution never rewinds the terminal state.
    await tracker.cancelIncident(incidentKey: incident.observation.incidentKey)
    let phase = await tracker.incidentPhase(incidentKey: incident.observation.incidentKey)
    XCTAssertEqual(phase, .resolved)
    let events = recorder.snapshot()
    XCTAssertTrue(events.contains(.duplicateSuppressed(incidentKey: incident.observation.incidentKey)))
  }

  func testTrackerCancellationWinsRaces() async {
    let tracker = AgentToolChildTracker()
    let incident = AgentToolChildIncident(
      observation: observation(childProcessId: 200),
      childState: .zombie,
      detectedAt: base,
      diagnostic: "diag"
    )
    _ = await tracker.beginIncident(incident)
    await tracker.cancelIncident(incidentKey: incident.observation.incidentKey)
    let cleanupAfterCancel = await tracker.beginCleanup(incidentKey: incident.observation.incidentKey)
    XCTAssertFalse(cleanupAfterCancel, "cancellation wins; no cleanup after cancel")
    await tracker.resolveIncident(incidentKey: incident.observation.incidentKey, outcome: "late")
    let phase = await tracker.incidentPhase(incidentKey: incident.observation.incidentKey)
    XCTAssertEqual(phase, .cancelled)
  }

  func testTrackerCorrelationLifecycle() async {
    let tracker = AgentToolChildTracker()
    await tracker.recordStarted(observation(childProcessId: nil))
    await tracker.bindChild(toolCallId: "call-1", childProcessId: 222, startIdentity: "id-222")
    var unresolved = await tracker.unresolvedObservations()
    XCTAssertEqual(unresolved.first?.childProcessId, 222)
    XCTAssertEqual(unresolved.first?.childProcessStartIdentity, "id-222")
    await tracker.recordTerminalObservation(toolCallId: "call-1", at: base.addingTimeInterval(1), state: "zombie")
    await tracker.recordCompleted(toolCallId: "call-1", at: base.addingTimeInterval(2))
    unresolved = await tracker.unresolvedObservations()
    XCTAssertTrue(unresolved.isEmpty, "host completion closes the call")
  }

  // MARK: - Cleanup coordinator

  func testCleanupRequestsHostCompletionBeforeSignaling() async {
    let recorder = EventRecorder()
    let tracker = AgentToolChildTracker()
    let incident = AgentToolChildIncident(
      observation: observation(childProcessId: 200),
      childState: .zombie,
      detectedAt: base,
      diagnostic: "diag"
    )
    _ = await tracker.beginIncident(incident)
    let signaler = FakeSignaler()
    let coordinator = AgentToolChildCleanupCoordinator(
      prober: FakeProber(states: [100: AgentProbedProcess(state: .running)]),
      signaler: signaler,
      hostCompletion: FakeHostCompletion(completes: true),
      reapDirectChild: {},
      emit: { recorder.append($0) }
    )
    let outcome = await coordinator.cleanUp(
      incident: incident,
      policy: policy(mode: .recover, graceMs: 10),
      tracker: tracker
    )
    XCTAssertEqual(outcome, .hostCompleted)
    XCTAssertTrue(signaler.snapshot().isEmpty, "host completion means no signals at all")
  }

  func testCleanupEscalatesTermGraceKillAndReaps() async {
    let recorder = EventRecorder()
    let tracker = AgentToolChildTracker()
    let incident = AgentToolChildIncident(
      observation: observation(childProcessId: 200),
      childState: .zombie,
      detectedAt: base,
      diagnostic: "diag"
    )
    _ = await tracker.beginIncident(incident)
    let signaler = FakeSignaler()
    let reaped = EventRecorder()
    let coordinator = AgentToolChildCleanupCoordinator(
      prober: FakeProber(states: [100: AgentProbedProcess(state: .running)]),
      signaler: signaler,
      hostCompletion: FakeHostCompletion(completes: false),
      reapDirectChild: { reaped.append(.cleanupReapedDirectChild(incidentKey: "reap")) },
      emit: { recorder.append($0) }
    )
    let outcome = await coordinator.cleanUp(
      incident: incident,
      policy: AgentToolChildRecoveryPolicy(mode: .recover, terminalObservationGraceMs: 10, cleanupGraceMs: 10),
      tracker: tracker
    )
    XCTAssertEqual(outcome, .escalatedAndReaped)
    let signals = signaler.snapshot()
    XCTAssertEqual(signals, [
      RecordedSignal(groupId: 100, signal: SIGTERM),
      RecordedSignal(groupId: 100, signal: SIGKILL)
    ], "TERM then grace then KILL, group-scoped")
    XCTAssertEqual(reaped.snapshot().count, 1, "the single completion owner reaps the direct child")
    let resolvedPhase = await tracker.incidentPhase(incidentKey: incident.observation.incidentKey)
    XCTAssertEqual(resolvedPhase, .resolved)
  }

  func testCleanupRefusesWithoutOwnershipIdentityOrDeadAgent() async {
    let tracker = AgentToolChildTracker()
    var noIdentity = observation(childProcessId: 200)
    noIdentity.agentProcessId = nil
    noIdentity.agentProcessGroupId = nil
    let incident = AgentToolChildIncident(observation: noIdentity, childState: .zombie, detectedAt: base, diagnostic: "d")
    _ = await tracker.beginIncident(incident)
    let signaler = FakeSignaler()
    let coordinator = AgentToolChildCleanupCoordinator(
      prober: FakeProber(states: [:]),
      signaler: signaler,
      hostCompletion: FakeHostCompletion(completes: false),
      reapDirectChild: {}
    )
    let outcome = await coordinator.cleanUp(
      incident: incident,
      policy: AgentToolChildRecoveryPolicy(mode: .recover, terminalObservationGraceMs: 10, cleanupGraceMs: 10),
      tracker: tracker
    )
    guard case .ownershipRefused = outcome else {
      return XCTFail("expected ownership refusal, got \(outcome)")
    }
    XCTAssertTrue(signaler.snapshot().isEmpty, "never signals without validated ownership")
  }

  func testCleanupRefusedByPolicyModeObserve() async {
    let tracker = AgentToolChildTracker()
    let incident = AgentToolChildIncident(
      observation: observation(childProcessId: 200),
      childState: .zombie,
      detectedAt: base,
      diagnostic: "d"
    )
    _ = await tracker.beginIncident(incident)
    let signaler = FakeSignaler()
    let coordinator = AgentToolChildCleanupCoordinator(
      prober: FakeProber(states: [:]),
      signaler: signaler,
      hostCompletion: FakeHostCompletion(completes: false),
      reapDirectChild: {}
    )
    let outcome = await coordinator.cleanUp(
      incident: incident,
      policy: policy(mode: .observe, graceMs: 10),
      tracker: tracker
    )
    guard case .policyRefused = outcome else {
      return XCTFail("expected policy refusal")
    }
    XCTAssertTrue(signaler.snapshot().isEmpty)
  }

  // MARK: - Recovery decision (fail-closed)

  func testRecoveryDecisionIsFailClosed() {
    XCTAssertEqual(
      AgentToolChildRecoveryDecider.decide(
        policy: policy(mode: .recover, graceMs: 0),
        hostAcknowledgedTerminalResult: true,
        streamIntact: true,
        mutationSafetyProven: true
      ),
      .superviseRetry,
      "continuation stays off without the explicit policy opt-in"
    )
    XCTAssertEqual(
      AgentToolChildRecoveryDecider.decide(
        policy: AgentToolChildRecoveryPolicy(mode: .recover, allowSameAttemptContinuation: true),
        hostAcknowledgedTerminalResult: true,
        streamIntact: true,
        mutationSafetyProven: false
      ),
      .continueSameAttempt
    )
    XCTAssertEqual(
      AgentToolChildRecoveryDecider.decide(
        policy: AgentToolChildRecoveryPolicy(mode: .recover, allowSameAttemptContinuation: true),
        hostAcknowledgedTerminalResult: false,
        streamIntact: true,
        mutationSafetyProven: false
      ),
      .refuse(reason: "mutation safety cannot be proven; refusing retry"),
      "no acknowledged terminal result and unproven mutation safety refuses"
    )
    XCTAssertEqual(
      AgentToolChildRecoveryDecider.decide(
        policy: policy(mode: .recover, graceMs: 0),
        hostAcknowledgedTerminalResult: false,
        streamIntact: false,
        mutationSafetyProven: true
      ),
      .superviseRetry
    )
  }

  // MARK: - Policy serialization

  func testPolicySerializationDefaultsAndRoundTrip() throws {
    let decoded = try JSONDecoder().decode(AgentToolChildRecoveryPolicy.self, from: Data("{}".utf8))
    XCTAssertEqual(decoded.mode, .off)
    XCTAssertEqual(decoded.terminalObservationGraceMs, 30_000)
    XCTAssertEqual(decoded.cleanupGraceMs, 5_000)
    XCTAssertFalse(decoded.allowSameAttemptContinuation)

    let policy = AgentToolChildRecoveryPolicy(
      mode: .recover,
      terminalObservationGraceMs: 1_500,
      cleanupGraceMs: 250,
      allowSameAttemptContinuation: true
    )
    let roundTripped = try JSONDecoder().decode(
      AgentToolChildRecoveryPolicy.self,
      from: JSONEncoder().encode(policy)
    )
    XCTAssertEqual(roundTripped, policy)
  }

  func testCommandFingerprintIsStableAndRedacted() {
    let fingerprint = agentToolCommandFingerprint("swift test --filter Secret")
    XCTAssertEqual(fingerprint, agentToolCommandFingerprint("swift test --filter Secret"))
    XCTAssertNotEqual(fingerprint, agentToolCommandFingerprint("swift test"))
    XCTAssertEqual(fingerprint.count, 16)
    XCTAssertFalse(fingerprint.contains("Secret"))
  }

  // MARK: - Fixtures

  private func policy(mode: AgentToolChildRecoveryMode, graceMs: Int) -> AgentToolChildRecoveryPolicy {
    AgentToolChildRecoveryPolicy(mode: mode, terminalObservationGraceMs: graceMs, cleanupGraceMs: 10)
  }

  private func observation(
    childProcessId: Int32?,
    startIdentity: String? = nil,
    terminalObservedAt: Date? = nil
  ) -> AgentToolProcessObservation {
    AgentToolProcessObservation(
      workflowExecutionId: "wf-exec",
      stepExecutionId: "step-exec",
      attempt: 1,
      toolCallId: "call-1",
      toolType: "command_execution",
      commandFingerprint: agentToolCommandFingerprint("swift test"),
      agentProcessId: 100,
      agentProcessGroupId: 100,
      childProcessId: childProcessId,
      childProcessStartIdentity: startIdentity,
      startedAt: base,
      terminalObservedAt: terminalObservedAt
    )
  }

  private struct FakeProber: AgentProcessStateProbing {
    var states: [Int32: AgentProbedProcess]

    func probe(processId: Int32) -> AgentProbedProcess {
      states[processId] ?? AgentProbedProcess(state: .missing)
    }
  }

  private final class FakeSignaler: AgentProcessSignaling, @unchecked Sendable {
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

  private struct FakeHostCompletion: AgentToolHostCompletionRequesting {
    var completes: Bool

    func requestCompletion(toolCallId: String, graceMs: Int) async -> Bool {
      completes
    }
  }

  private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentToolChildRecoveryEvent] = []

    func append(_ event: AgentToolChildRecoveryEvent) {
      lock.lock()
      defer { lock.unlock() }
      events.append(event)
    }

    func snapshot() -> [AgentToolChildRecoveryEvent] {
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
