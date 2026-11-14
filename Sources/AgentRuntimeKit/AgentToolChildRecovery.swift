import Foundation
#if canImport(Glibc)
import Glibc
#endif

// MARK: - Policy (design: codex-unified-exec-stall-followup module 5)

/// Recovery policy for terminal-but-unreaped agent tool children.
/// - `off` (default): no correlation-based detection or cleanup.
/// - `observe`: detect and record incidents/diagnostics; never signal.
/// - `recover`: detect, request host-side completion, then perform bounded
///   ownership-validated process-group cleanup.
public enum AgentToolChildRecoveryMode: String, Codable, CaseIterable, Sendable {
  case off
  case observe
  case recover
}

public struct AgentToolChildRecoveryPolicy: Codable, Equatable, Sendable {
  public var mode: AgentToolChildRecoveryMode
  /// How long a correlated terminal child may miss its host completion before
  /// it classifies as an incident.
  public var terminalObservationGraceMs: Int
  /// Grace between process-group SIGTERM and SIGKILL during cleanup.
  public var cleanupGraceMs: Int
  /// Whether a same-attempt continuation is permitted after cleanup. Even
  /// when true, continuation additionally requires an acknowledged terminal
  /// tool result and an intact stream; the fail-closed default routes
  /// confirmed incidents to supervised retry/rerun instead.
  public var allowSameAttemptContinuation: Bool

  private enum CodingKeys: String, CodingKey {
    case mode
    case terminalObservationGraceMs
    case cleanupGraceMs
    case allowSameAttemptContinuation
  }

  public init(
    mode: AgentToolChildRecoveryMode = .off,
    terminalObservationGraceMs: Int = 30_000,
    cleanupGraceMs: Int = 5_000,
    allowSameAttemptContinuation: Bool = false
  ) {
    self.mode = mode
    self.terminalObservationGraceMs = terminalObservationGraceMs
    self.cleanupGraceMs = cleanupGraceMs
    self.allowSameAttemptContinuation = allowSameAttemptContinuation
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.mode = try container.decodeIfPresent(AgentToolChildRecoveryMode.self, forKey: .mode) ?? .off
    self.terminalObservationGraceMs = try container.decodeIfPresent(Int.self, forKey: .terminalObservationGraceMs) ?? 30_000
    self.cleanupGraceMs = try container.decodeIfPresent(Int.self, forKey: .cleanupGraceMs) ?? 5_000
    self.allowSameAttemptContinuation = try container.decodeIfPresent(Bool.self, forKey: .allowSameAttemptContinuation) ?? false
  }
}

// MARK: - Correlation record

/// Per-attempt correlation between a started agent tool call and the child
/// process identity it spawned. A PID alone is never sufficient (reuse); the
/// process-start identity and parent linkage bind the observation to the
/// exact child.
public struct AgentToolProcessObservation: Codable, Equatable, Sendable {
  public var workflowExecutionId: String
  public var stepExecutionId: String
  public var attempt: Int
  public var toolCallId: String
  public var toolType: String
  /// Redacted identity of the command (stable hash), never the command text.
  public var commandFingerprint: String
  /// Riela's direct agent child (the tool host, e.g. the codex CLI).
  public var agentProcessId: Int32?
  public var agentProcessGroupId: Int32?
  /// The descendant executing the tool call, when observable.
  public var childProcessId: Int32?
  /// Platform process-start identity for `childProcessId` (start timestamp
  /// or equivalent), guarding against PID reuse.
  public var childProcessStartIdentity: String?
  public var startedAt: Date
  /// Set when the host published the terminal tool result.
  public var completedAt: Date?
  /// Set when process observation saw the child in a terminal (zombie or
  /// exited) state without a host completion.
  public var terminalObservedAt: Date?

  public init(
    workflowExecutionId: String,
    stepExecutionId: String,
    attempt: Int,
    toolCallId: String,
    toolType: String,
    commandFingerprint: String,
    agentProcessId: Int32? = nil,
    agentProcessGroupId: Int32? = nil,
    childProcessId: Int32? = nil,
    childProcessStartIdentity: String? = nil,
    startedAt: Date,
    completedAt: Date? = nil,
    terminalObservedAt: Date? = nil
  ) {
    self.workflowExecutionId = workflowExecutionId
    self.stepExecutionId = stepExecutionId
    self.attempt = attempt
    self.toolCallId = toolCallId
    self.toolType = toolType
    self.commandFingerprint = commandFingerprint
    self.agentProcessId = agentProcessId
    self.agentProcessGroupId = agentProcessGroupId
    self.childProcessId = childProcessId
    self.childProcessStartIdentity = childProcessStartIdentity
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.terminalObservedAt = terminalObservedAt
  }

  /// Incident/remediation idempotency key: one incident per attempt+tool call.
  public var incidentKey: String {
    "\(workflowExecutionId)/\(stepExecutionId)/attempt-\(attempt)/\(toolCallId)"
  }
}

// MARK: - Process probing

public enum AgentProbedProcessState: Equatable, Sendable {
  case running
  /// Exited but unreaped (defunct) — the decisive terminal evidence.
  case zombie
  /// No such process (already reaped or never existed).
  case missing
}

public struct AgentProbedProcess: Equatable, Sendable {
  public var state: AgentProbedProcessState
  public var parentProcessId: Int32?
  /// Platform process-start identity; nil when unavailable.
  public var startIdentity: String?

  public init(state: AgentProbedProcessState, parentProcessId: Int32? = nil, startIdentity: String? = nil) {
    self.state = state
    self.parentProcessId = parentProcessId
    self.startIdentity = startIdentity
  }
}

/// Read-only process observation. Injectable so classification and cleanup
/// are deterministic under test.
public protocol AgentProcessStateProbing: Sendable {
  func probe(processId: Int32) -> AgentProbedProcess
}

/// Signals a process group (or single process). Injectable for tests; the
/// real implementation never signals anything the coordinator has not
/// ownership-revalidated.
public protocol AgentProcessSignaling: Sendable {
  func signalGroup(_ groupId: Int32, signal: Int32) -> Bool
  func signalProcess(_ processId: Int32, signal: Int32) -> Bool
}

public struct SystemAgentProcessSignaler: AgentProcessSignaling {
  public init() {}

  public func signalGroup(_ groupId: Int32, signal: Int32) -> Bool {
    kill(-groupId, signal) == 0
  }

  public func signalProcess(_ processId: Int32, signal: Int32) -> Bool {
    kill(processId, signal) == 0
  }
}

// MARK: - Classification

/// A confirmed terminal-child stall incident: a started tool call whose
/// correlated child is terminal, whose owning host is still alive, and whose
/// completion has been missing past the grace interval.
public struct AgentToolChildIncident: Equatable, Sendable {
  public var observation: AgentToolProcessObservation
  public var childState: AgentProbedProcessState
  public var detectedAt: Date
  public var diagnostic: String

  public init(
    observation: AgentToolProcessObservation,
    childState: AgentProbedProcessState,
    detectedAt: Date,
    diagnostic: String
  ) {
    self.observation = observation
    self.childState = childState
    self.detectedAt = detectedAt
    self.diagnostic = diagnostic
  }
}

/// Pure terminal-child stall classifier (module 5). Distinct from ordinary
/// LLM silence: it requires (1) an unresolved started tool call, (2) a
/// correlated terminal/zombie child (or a child that vanished after a
/// terminal observation), (3) a live owning tool host, and (4) a bounded
/// missing-completion interval. Generic wait/status heartbeats never enter
/// this evaluation.
public enum AgentTerminalToolChildClassifier {
  public static func classify(
    observations: [AgentToolProcessObservation],
    prober: any AgentProcessStateProbing,
    policy: AgentToolChildRecoveryPolicy,
    now: Date
  ) -> [AgentToolChildIncident] {
    guard policy.mode != .off else {
      return []
    }
    var incidents: [AgentToolChildIncident] = []
    for observation in observations where observation.completedAt == nil {
      guard let childProcessId = observation.childProcessId else {
        continue
      }
      // Owning host must be alive: a dead host is an ordinary process exit,
      // handled by the managed-process completion path, not a stall.
      if let agentProcessId = observation.agentProcessId {
        guard prober.probe(processId: agentProcessId).state == .running else {
          continue
        }
      }
      let child = prober.probe(processId: childProcessId)
      switch child.state {
      case .running:
        continue
      case .zombie, .missing:
        // Ownership correlation: a probed parent that is not our agent
        // process, or a start identity mismatch, means PID reuse or an
        // uncorrelated process — never classify it.
        if let recordedIdentity = observation.childProcessStartIdentity,
           let probedIdentity = child.startIdentity,
           recordedIdentity != probedIdentity {
          continue
        }
        if child.state == .zombie,
           let parent = child.parentProcessId,
           let agent = observation.agentProcessId,
           parent != agent {
          continue
        }
        // A missing child is terminal evidence only after a prior terminal
        // observation (otherwise we cannot distinguish reaped-and-completed
        // from never-started).
        if child.state == .missing, observation.terminalObservedAt == nil {
          continue
        }
        let terminalSince = observation.terminalObservedAt ?? observation.startedAt
        let missingForMs = Int(now.timeIntervalSince(terminalSince) * 1_000)
        guard missingForMs >= policy.terminalObservationGraceMs else {
          continue
        }
        incidents.append(AgentToolChildIncident(
          observation: observation,
          childState: child.state,
          detectedAt: now,
          diagnostic: "tool call \(observation.toolCallId) (fingerprint \(observation.commandFingerprint)) has a "
            + "\(child.state == .zombie ? "zombie" : "vanished terminal") child pid \(childProcessId) with no host "
            + "completion for \(missingForMs)ms while the tool host is alive"
        ))
      }
    }
    return incidents
  }
}

// MARK: - Tracker (correlation + CAS incident state)

/// Diagnostic/audit event stream for the recovery pipeline. All payloads are
/// redacted by construction: ids, fingerprints, pids, and outcomes only.
public enum AgentToolChildRecoveryEvent: Equatable, Sendable {
  case correlated(toolCallId: String, childProcessId: Int32?)
  case terminalObserved(toolCallId: String, state: String)
  case heartbeatIgnored(toolCallId: String, eventType: String)
  case incidentRecorded(incidentKey: String, diagnostic: String)
  case duplicateSuppressed(incidentKey: String)
  case cleanupRequestedHostCompletion(incidentKey: String)
  case cleanupEscalated(incidentKey: String, signal: String)
  case cleanupReapedDirectChild(incidentKey: String)
  case ownershipRefused(incidentKey: String, reason: String)
  case policyRefused(incidentKey: String, reason: String)
  case continuationRefused(incidentKey: String, reason: String)
  case retryRouted(incidentKey: String)
  case cancelled(incidentKey: String)
  case resolved(incidentKey: String, outcome: String)
}

/// Durable-in-session correlation and incident state. Compare-and-set
/// semantics on the incident key make cleanup, continuation, and retry
/// idempotent: duplicate polls, cancellation races, resume, or supervisor
/// replay observe `duplicateSuppressed` instead of repeating a signal
/// sequence, incident, or remediation.
public actor AgentToolChildTracker {
  public enum IncidentPhase: String, Sendable {
    case recorded
    case cleaningUp
    case resolved
    case cancelled
  }

  private var observations: [String: AgentToolProcessObservation] = [:]
  private var incidentPhases: [String: IncidentPhase] = [:]
  private let emit: @Sendable (AgentToolChildRecoveryEvent) -> Void

  public init(emit: @escaping @Sendable (AgentToolChildRecoveryEvent) -> Void = { _ in }) {
    self.emit = emit
  }

  public func recordStarted(_ observation: AgentToolProcessObservation) {
    guard observations[observation.toolCallId] == nil else {
      return
    }
    observations[observation.toolCallId] = observation
    emit(.correlated(toolCallId: observation.toolCallId, childProcessId: observation.childProcessId))
  }

  /// Binds or refreshes the child-process identity for a started call.
  public func bindChild(
    toolCallId: String,
    childProcessId: Int32,
    startIdentity: String?
  ) {
    guard var observation = observations[toolCallId] else {
      return
    }
    observation.childProcessId = childProcessId
    observation.childProcessStartIdentity = startIdentity
    observations[toolCallId] = observation
    emit(.correlated(toolCallId: toolCallId, childProcessId: childProcessId))
  }

  public func recordTerminalObservation(toolCallId: String, at date: Date, state: String) {
    guard var observation = observations[toolCallId], observation.terminalObservedAt == nil else {
      return
    }
    observation.terminalObservedAt = date
    observations[toolCallId] = observation
    emit(.terminalObserved(toolCallId: toolCallId, state: state))
  }

  /// Closes the call on the matching terminal tool observation from the host.
  public func recordCompleted(toolCallId: String, at date: Date) {
    guard var observation = observations[toolCallId], observation.completedAt == nil else {
      return
    }
    observation.completedAt = date
    observations[toolCallId] = observation
  }

  /// Generic wait/status lifecycle events are explicitly ignored for the
  /// tool-call evaluation; recorded only as audit evidence.
  public func recordIgnoredHeartbeat(toolCallId: String, eventType: String) {
    emit(.heartbeatIgnored(toolCallId: toolCallId, eventType: eventType))
  }

  public func unresolvedObservations() -> [AgentToolProcessObservation] {
    observations.values.filter { $0.completedAt == nil }.sorted { $0.startedAt < $1.startedAt }
  }

  public func observation(toolCallId: String) -> AgentToolProcessObservation? {
    observations[toolCallId]
  }

  /// CAS transition into `recorded`. Returns false (and emits
  /// `duplicateSuppressed`) when the incident already exists in any phase.
  public func beginIncident(_ incident: AgentToolChildIncident) -> Bool {
    let key = incident.observation.incidentKey
    guard incidentPhases[key] == nil else {
      emit(.duplicateSuppressed(incidentKey: key))
      return false
    }
    incidentPhases[key] = .recorded
    emit(.incidentRecorded(incidentKey: key, diagnostic: incident.diagnostic))
    return true
  }

  /// CAS transition `recorded -> cleaningUp`; false on any other phase.
  public func beginCleanup(incidentKey: String) -> Bool {
    guard incidentPhases[incidentKey] == .recorded else {
      emit(.duplicateSuppressed(incidentKey: incidentKey))
      return false
    }
    incidentPhases[incidentKey] = .cleaningUp
    return true
  }

  public func resolveIncident(incidentKey: String, outcome: String) {
    guard let phase = incidentPhases[incidentKey], phase == .recorded || phase == .cleaningUp else {
      return
    }
    incidentPhases[incidentKey] = .resolved
    emit(.resolved(incidentKey: incidentKey, outcome: outcome))
  }

  /// Cancellation wins all races: any non-terminal phase transitions to
  /// `cancelled` and later transitions are suppressed.
  public func cancelIncident(incidentKey: String) {
    guard let phase = incidentPhases[incidentKey], phase != .resolved else {
      return
    }
    if phase != .cancelled {
      incidentPhases[incidentKey] = .cancelled
      emit(.cancelled(incidentKey: incidentKey))
    }
  }

  public func incidentPhase(incidentKey: String) -> IncidentPhase? {
    incidentPhases[incidentKey]
  }
}

// MARK: - Cleanup coordination

public enum AgentToolChildCleanupOutcome: Equatable, Sendable {
  case hostCompleted
  case escalatedAndReaped
  case ownershipRefused(reason: String)
  case policyRefused(reason: String)
  case cancelled
}

/// Requests that the owning tool host finish/reap the exact tool call. The
/// codex CLI exposes no such control surface today, so the default
/// implementation waits out the grace period and reports whether the host
/// published the completion in the meantime.
public protocol AgentToolHostCompletionRequesting: Sendable {
  func requestCompletion(toolCallId: String, graceMs: Int) async -> Bool
}

public struct NoOpAgentToolHostCompletionRequester: AgentToolHostCompletionRequesting {
  public init() {}

  public func requestCompletion(toolCallId: String, graceMs: Int) async -> Bool {
    let clamped = max(0, min(graceMs, 60_000))
    try? await Task.sleep(nanoseconds: UInt64(clamped) * 1_000_000)
    return false
  }
}

/// Bounded, ownership-validated cleanup (module 5): host-side completion
/// first; then re-validate ownership and process-group TERM → grace → KILL;
/// finally reap Riela's direct agent child through the injected completion
/// owner. Never signals an uncorrelated or PID-reused process.
public struct AgentToolChildCleanupCoordinator: Sendable {
  public var prober: any AgentProcessStateProbing
  public var signaler: any AgentProcessSignaling
  public var hostCompletion: any AgentToolHostCompletionRequesting
  /// The single completion owner for Riela's direct agent child (the
  /// managed-process wait/reap path). Injected so cleanup never waits on a
  /// process it does not own.
  public var reapDirectChild: @Sendable () async -> Void
  public var emit: @Sendable (AgentToolChildRecoveryEvent) -> Void

  public init(
    prober: any AgentProcessStateProbing,
    signaler: any AgentProcessSignaling,
    hostCompletion: any AgentToolHostCompletionRequesting = NoOpAgentToolHostCompletionRequester(),
    reapDirectChild: @escaping @Sendable () async -> Void,
    emit: @escaping @Sendable (AgentToolChildRecoveryEvent) -> Void = { _ in }
  ) {
    self.prober = prober
    self.signaler = signaler
    self.hostCompletion = hostCompletion
    self.reapDirectChild = reapDirectChild
    self.emit = emit
  }

  public func cleanUp(
    incident: AgentToolChildIncident,
    policy: AgentToolChildRecoveryPolicy,
    tracker: AgentToolChildTracker
  ) async -> AgentToolChildCleanupOutcome {
    let key = incident.observation.incidentKey
    guard policy.mode == .recover else {
      emit(.policyRefused(incidentKey: key, reason: "policy mode is \(policy.mode.rawValue); cleanup requires recover"))
      return .policyRefused(reason: "mode \(policy.mode.rawValue)")
    }
    guard await tracker.beginCleanup(incidentKey: key) else {
      return .policyRefused(reason: "incident not in recorded phase")
    }
    if Task.isCancelled {
      await tracker.cancelIncident(incidentKey: key)
      return .cancelled
    }

    // 1. Ask the owning host to finish/reap the exact tool call first.
    emit(.cleanupRequestedHostCompletion(incidentKey: key))
    if await hostCompletion.requestCompletion(
      toolCallId: incident.observation.toolCallId,
      graceMs: policy.terminalObservationGraceMs
    ) {
      await tracker.resolveIncident(incidentKey: key, outcome: "host-completed")
      return .hostCompleted
    }
    if let completedAt = await tracker.observation(toolCallId: incident.observation.toolCallId)?.completedAt,
       completedAt > incident.observation.startedAt {
      await tracker.resolveIncident(incidentKey: key, outcome: "host-completed")
      return .hostCompleted
    }
    if Task.isCancelled {
      await tracker.cancelIncident(incidentKey: key)
      return .cancelled
    }

    // 2. Ownership revalidation immediately before signaling: the agent
    // process (our direct child) must still be alive and, when the group id
    // is recorded, the group must belong to it.
    guard let agentProcessId = incident.observation.agentProcessId,
          let groupId = incident.observation.agentProcessGroupId else {
      let reason = "no recorded agent process/group identity; refusing to signal"
      emit(.ownershipRefused(incidentKey: key, reason: reason))
      await tracker.resolveIncident(incidentKey: key, outcome: "ownership-refused")
      return .ownershipRefused(reason: reason)
    }
    let agentState = prober.probe(processId: agentProcessId)
    guard agentState.state == .running else {
      let reason = "agent process \(agentProcessId) is no longer running; ordinary completion path owns it"
      emit(.ownershipRefused(incidentKey: key, reason: reason))
      await tracker.resolveIncident(incidentKey: key, outcome: "ownership-refused")
      return .ownershipRefused(reason: reason)
    }

    // 3. Bounded process-group TERM -> grace -> KILL.
    emit(.cleanupEscalated(incidentKey: key, signal: "SIGTERM"))
    _ = signaler.signalGroup(groupId, signal: SIGTERM)
    let clampedGrace = max(0, min(policy.cleanupGraceMs, 60_000))
    try? await Task.sleep(nanoseconds: UInt64(clampedGrace) * 1_000_000)
    if Task.isCancelled {
      await tracker.cancelIncident(incidentKey: key)
      return .cancelled
    }
    if prober.probe(processId: agentProcessId).state == .running {
      emit(.cleanupEscalated(incidentKey: key, signal: "SIGKILL"))
      _ = signaler.signalGroup(groupId, signal: SIGKILL)
    }

    // 4. Reap Riela's direct child through the single completion owner.
    await reapDirectChild()
    emit(.cleanupReapedDirectChild(incidentKey: key))
    await tracker.resolveIncident(incidentKey: key, outcome: "escalated-and-reaped")
    return .escalatedAndReaped
  }
}

// MARK: - Recovery decision

public enum AgentToolChildRecoveryDecision: Equatable, Sendable {
  /// Continue the same attempt (requires acknowledged terminal result +
  /// intact stream + policy opt-in).
  case continueSameAttempt
  /// Route through supervised (auto-improve) targeted retry/rerun budgets.
  case superviseRetry
  /// No retry: mutation safety cannot be proven.
  case refuse(reason: String)
}

/// Fail-closed continuation decision (module 5): same-attempt continuation
/// only with an acknowledged terminal tool result, an intact stream, and the
/// policy opt-in; supervised retry only when mutation safety is provable.
public enum AgentToolChildRecoveryDecider {
  public static func decide(
    policy: AgentToolChildRecoveryPolicy,
    hostAcknowledgedTerminalResult: Bool,
    streamIntact: Bool,
    mutationSafetyProven: Bool
  ) -> AgentToolChildRecoveryDecision {
    if policy.allowSameAttemptContinuation, hostAcknowledgedTerminalResult, streamIntact {
      return .continueSameAttempt
    }
    guard mutationSafetyProven else {
      return .refuse(reason: "mutation safety cannot be proven; refusing retry")
    }
    return .superviseRetry
  }
}

// MARK: - Command fingerprinting

/// Stable redacted identity for a tool command: djb2-based hex digest of the
/// command text. Diagnostics and audit events carry only this fingerprint,
/// never the command itself.
public func agentToolCommandFingerprint(_ command: String) -> String {
  var hash: UInt64 = 5_381
  for byte in command.utf8 {
    hash = (hash &* 33) &+ UInt64(byte)
  }
  return String(format: "%016llx", hash)
}
