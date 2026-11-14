import AgentRuntimeKit
import Foundation
import RielaAdapters
import RielaCore

// MARK: - Node-variable policy surface

/// Parses the tool-child recovery policy from codex node variables. The
/// node-variable surface (like `codexUnifiedExec`) flows through every
/// existing configuration channel — authored workflow JSON (library), CLI
/// `--node-patch`, GraphQL node patches, and remote execution — with the
/// same serialization.
///
/// Variables:
/// - `codexToolRecovery`: "off" (default) | "observe" | "recover"
/// - `codexToolRecoveryGraceMs`: terminal-observation grace (default 30000)
/// - `codexToolRecoveryCleanupGraceMs`: TERM→KILL grace (default 5000)
/// - `codexToolRecoveryAllowContinuation`: same-attempt continuation opt-in
///   (default false; continuation additionally requires an acknowledged
///   terminal tool result, which the current codex host protocol cannot
///   prove, so the decision stays fail-closed).
public func codexToolChildRecoveryPolicy(_ variables: JSONObject) -> AgentToolChildRecoveryPolicy {
  var policy = AgentToolChildRecoveryPolicy()
  if case let .string(mode) = variables["codexToolRecovery"],
     let parsed = AgentToolChildRecoveryMode(rawValue: mode) {
    policy.mode = parsed
  }
  if let grace = variables["codexToolRecoveryGraceMs"]?.asDouble, grace > 0 {
    policy.terminalObservationGraceMs = Int(grace)
  }
  if let grace = variables["codexToolRecoveryCleanupGraceMs"]?.asDouble, grace > 0 {
    policy.cleanupGraceMs = Int(grace)
  }
  if case let .bool(allowed) = variables["codexToolRecoveryAllowContinuation"] {
    policy.allowSameAttemptContinuation = allowed
  }
  return policy
}

// MARK: - Event parsing

public enum CodexToolChildEvent: Equatable, Sendable {
  case started(toolCallId: String, commandFingerprint: String)
  case completed(toolCallId: String)
  /// Generic lifecycle noise (wait/status/poll events) that must never count
  /// as tool-call evidence.
  case heartbeat(eventType: String)
}

/// Parses codex `--json` stdout lines for `command_execution` item lifecycle.
/// `item.started` supplies the stable tool-call id and command identity;
/// `item.completed`/terminal `item.updated` close it. Everything else is a
/// heartbeat.
public enum CodexToolChildEventParser {
  public static func parse(line: String) -> CodexToolChildEvent? {
    guard let data = line.data(using: .utf8),
          let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
          case let .object(object) = decoded,
          case let .string(eventType)? = object["type"] else {
      return nil
    }
    guard eventType.hasPrefix("item."), case let .object(item)? = object["item"] else {
      return .heartbeat(eventType: eventType)
    }
    guard case let .string(itemType)? = item["type"], itemType == "command_execution" else {
      return .heartbeat(eventType: eventType)
    }
    guard case let .string(toolCallId)? = item["id"], !toolCallId.isEmpty else {
      return .heartbeat(eventType: eventType)
    }
    if eventType == "item.started" {
      let command: String
      if case let .string(text)? = item["command"] {
        command = text
      } else {
        command = ""
      }
      return .started(toolCallId: toolCallId, commandFingerprint: agentToolCommandFingerprint(command))
    }
    if eventType == "item.completed" {
      return .completed(toolCallId: toolCallId)
    }
    if eventType == "item.updated", case let .string(status)? = item["status"],
       ["completed", "failed", "error"].contains(status) {
      return .completed(toolCallId: toolCallId)
    }
    return .heartbeat(eventType: eventType)
  }
}

// MARK: - Monitor

/// Terminal tool-child stall monitor for one codex invocation (module 5).
/// Correlates `command_execution` tool calls to descendant processes, keeps
/// tool-child liveness separate from backend-event recency, and — under the
/// `recover` policy — performs the bounded host-completion-first cleanup.
/// Deterministic under test: the clock, prober, discoverer, signaler, and
/// poll driver are all injectable, and `tick(now:)` advances one evaluation.
public final class CodexToolChildRecoveryMonitor: LocalAgentToolChildMonitoring, @unchecked Sendable {
  private let state: MonitorState

  public init(
    policy: AgentToolChildRecoveryPolicy,
    workflowExecutionId: String,
    stepExecutionId: String,
    attempt: Int,
    prober: any AgentProcessStateProbing = SystemAgentProcessStateProber(),
    discoverer: any AgentChildProcessDiscovering = SystemAgentChildProcessDiscoverer(),
    signaler: any AgentProcessSignaling = SystemAgentProcessSignaler(),
    pollIntervalMs: Int = 1_000,
    autoPoll: Bool = true
  ) {
    state = MonitorState(
      policy: policy,
      workflowExecutionId: workflowExecutionId,
      stepExecutionId: stepExecutionId,
      attempt: attempt,
      prober: prober,
      discoverer: discoverer,
      signaler: signaler,
      pollIntervalMs: pollIntervalMs,
      autoPoll: autoPoll
    )
  }

  public func start(emitBackendEvent: @escaping @Sendable (AdapterBackendEvent) -> Void) {
    let state = state
    Task { await state.start(emitBackendEvent: emitBackendEvent) }
  }

  public func processSpawned(_ processId: Int32) {
    let state = state
    Task { await state.processSpawned(processId) }
  }

  public func observeStdoutLine(_ line: String) {
    guard let event = CodexToolChildEventParser.parse(line: line) else {
      return
    }
    let state = state
    Task { await state.observe(event) }
  }

  public func stop() async {
    await state.stop()
  }

  /// Test hook: one deterministic evaluation pass at `now`.
  public func tick(now: Date) async {
    await state.tick(now: now)
  }

  /// Deterministic (awaited) variants of the fire-and-forget production
  /// entry points, for tests that need ordering guarantees.
  public func startAndAwait(emitBackendEvent: @escaping @Sendable (AdapterBackendEvent) -> Void) async {
    await state.start(emitBackendEvent: emitBackendEvent)
  }

  public func processSpawnedAndAwait(_ processId: Int32) async {
    await state.processSpawned(processId)
  }

  public func observeStdoutLineAndAwait(_ line: String) async {
    guard let event = CodexToolChildEventParser.parse(line: line) else {
      return
    }
    await state.observe(event)
  }

  public func recoveryEvents() async -> [AgentToolChildRecoveryEvent] {
    await state.sink.snapshot()
  }
}

/// Synchronous, thread-safe audit sink: tracker and coordinator emits land
/// here immediately (no actor hop), so deterministic tests observe every
/// event as soon as the emitting call returns. Incident/cleanup/resolution
/// events are additionally forwarded into the live backend event stream.
final class CodexToolChildRecoverySink: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [AgentToolChildRecoveryEvent] = []
  private var emitBackendEvent: (@Sendable (AdapterBackendEvent) -> Void)?

  func configure(emitBackendEvent: @escaping @Sendable (AdapterBackendEvent) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    self.emitBackendEvent = emitBackendEvent
  }

  func snapshot() -> [AgentToolChildRecoveryEvent] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }

  func record(_ event: AgentToolChildRecoveryEvent) {
    lock.lock()
    events.append(event)
    let emit = emitBackendEvent
    lock.unlock()
    guard let emit else {
      return
    }
    switch event {
    case let .incidentRecorded(incidentKey, diagnostic):
      emit(AdapterBackendEvent(
        provider: CliAgentBackend.codexAgent.rawValue,
        eventType: "tool_child_incident",
        channel: .lifecycle,
        contentSnapshot: "\(incidentKey): \(diagnostic)"
      ))
    case let .cleanupEscalated(incidentKey, signal):
      emit(AdapterBackendEvent(
        provider: CliAgentBackend.codexAgent.rawValue,
        eventType: "tool_child_cleanup",
        channel: .lifecycle,
        contentSnapshot: "\(incidentKey): escalated \(signal)"
      ))
    case let .resolved(incidentKey, outcome):
      emit(AdapterBackendEvent(
        provider: CliAgentBackend.codexAgent.rawValue,
        eventType: "tool_child_resolved",
        channel: .lifecycle,
        contentSnapshot: "\(incidentKey): \(outcome)"
      ))
    default:
      break
    }
  }
}

private actor MonitorState {
  let policy: AgentToolChildRecoveryPolicy
  let workflowExecutionId: String
  let stepExecutionId: String
  let attempt: Int
  let prober: any AgentProcessStateProbing
  let discoverer: any AgentChildProcessDiscovering
  let signaler: any AgentProcessSignaling
  let pollIntervalMs: Int
  let autoPoll: Bool

  let sink = CodexToolChildRecoverySink()
  private var tracker: AgentToolChildTracker?
  private var agentProcessId: Int32?
  private var boundChildren: Set<Int32> = []
  private var pollTask: Task<Void, Never>?
  private var stopped = false

  init(
    policy: AgentToolChildRecoveryPolicy,
    workflowExecutionId: String,
    stepExecutionId: String,
    attempt: Int,
    prober: any AgentProcessStateProbing,
    discoverer: any AgentChildProcessDiscovering,
    signaler: any AgentProcessSignaling,
    pollIntervalMs: Int,
    autoPoll: Bool
  ) {
    self.policy = policy
    self.workflowExecutionId = workflowExecutionId
    self.stepExecutionId = stepExecutionId
    self.attempt = attempt
    self.prober = prober
    self.discoverer = discoverer
    self.signaler = signaler
    self.pollIntervalMs = pollIntervalMs
    self.autoPoll = autoPoll
  }

  func start(emitBackendEvent: @escaping @Sendable (AdapterBackendEvent) -> Void) {
    guard policy.mode != .off, tracker == nil, !stopped else {
      return
    }
    sink.configure(emitBackendEvent: emitBackendEvent)
    tracker = AgentToolChildTracker { [sink] event in
      sink.record(event)
    }
    guard autoPoll else {
      return
    }
    pollTask = Task { [pollIntervalMs] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(max(100, pollIntervalMs)) * 1_000_000)
        if Task.isCancelled {
          return
        }
        await self.tick(now: Date())
      }
    }
  }

  func processSpawned(_ processId: Int32) {
    agentProcessId = processId
  }

  func observe(_ event: CodexToolChildEvent) async {
    guard let tracker, !stopped else {
      return
    }
    switch event {
    case let .started(toolCallId, commandFingerprint):
      await tracker.recordStarted(AgentToolProcessObservation(
        workflowExecutionId: workflowExecutionId,
        stepExecutionId: stepExecutionId,
        attempt: attempt,
        toolCallId: toolCallId,
        toolType: "command_execution",
        commandFingerprint: commandFingerprint,
        agentProcessId: agentProcessId,
        agentProcessGroupId: agentProcessId, // posix_spawn setpgroup(0): the agent leads its own group
        startedAt: Date()
      ))
      await bindNewChild(toolCallId: toolCallId)
    case let .completed(toolCallId):
      await tracker.recordCompleted(toolCallId: toolCallId, at: Date())
    case let .heartbeat(eventType):
      // Explicitly excluded from tool-call evidence; audit only, and only
      // while at least one call is unresolved (avoids unbounded noise).
      if let first = await tracker.unresolvedObservations().first {
        await tracker.recordIgnoredHeartbeat(toolCallId: first.toolCallId, eventType: eventType)
      }
    }
  }

  private func bindNewChild(toolCallId: String) async {
    guard let tracker, let agentProcessId else {
      return
    }
    let children = Set(discoverer.childProcessIds(of: agentProcessId))
    let unbound = children.subtracting(boundChildren)
    // Bind only when the new child is unambiguous; a wrong binding could
    // authorize cleanup against the wrong process.
    guard unbound.count == 1, let child = unbound.first else {
      return
    }
    boundChildren.insert(child)
    await tracker.bindChild(
      toolCallId: toolCallId,
      childProcessId: child,
      startIdentity: prober.probe(processId: child).startIdentity
    )
  }

  func tick(now: Date) async {
    guard let tracker, !stopped else {
      return
    }
    let unresolved = await tracker.unresolvedObservations()
    // Record terminal observations before classification so the grace
    // interval anchors at first terminal sighting.
    for observation in unresolved {
      guard observation.terminalObservedAt == nil, let child = observation.childProcessId else {
        continue
      }
      let probed = prober.probe(processId: child)
      if probed.state == .zombie {
        await tracker.recordTerminalObservation(toolCallId: observation.toolCallId, at: now, state: "zombie")
      }
    }
    let incidents = AgentTerminalToolChildClassifier.classify(
      observations: await tracker.unresolvedObservations(),
      prober: prober,
      policy: policy,
      now: now
    )
    for incident in incidents {
      guard await tracker.beginIncident(incident) else {
        continue
      }
      guard policy.mode == .recover else {
        continue
      }
      let coordinator = AgentToolChildCleanupCoordinator(
        prober: prober,
        signaler: signaler,
        // Riela's direct-child reap stays with the runner's single waitpid
        // owner: killing the group makes that wait return and the ordinary
        // completion path reaps. Nothing to do here.
        reapDirectChild: {},
        emit: { [sink] event in
          sink.record(event)
        }
      )
      _ = await coordinator.cleanUp(incident: incident, policy: policy, tracker: tracker)
    }
  }

  func stop() {
    stopped = true
    pollTask?.cancel()
    pollTask = nil
  }
}
