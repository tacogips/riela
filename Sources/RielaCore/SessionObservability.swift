import Foundation

public enum SessionBackendActivityVerdict: String, Codable, Equatable, Sendable {
  case active
  case quiet
  case stalledSuspect = "stalled-suspect"
  case unknown
}

public enum SessionBackendActivityEvidenceKind: String, Codable, Equatable, Sendable {
  case backendEvent = "backend-event"
  case artifact
  case process
  case diagnostic
}

public struct SessionBackendActivityEvidence: Codable, Equatable, Sendable {
  public var kind: SessionBackendActivityEvidenceKind
  public var detail: String
  public var path: String?
  public var observedAt: Date?
  public var ageMs: Int?

  public init(
    kind: SessionBackendActivityEvidenceKind,
    detail: String,
    path: String? = nil,
    observedAt: Date? = nil,
    ageMs: Int? = nil
  ) {
    self.kind = kind
    self.detail = detail
    self.path = path
    self.observedAt = observedAt
    self.ageMs = ageMs
  }
}

public struct SessionBackendActivity: Codable, Equatable, Sendable {
  public var backend: NodeExecutionBackend?
  public var verdict: SessionBackendActivityVerdict
  public var evidence: [SessionBackendActivityEvidence]
  public var activeThresholdMs: Int
  public var stalledThresholdMs: Int
  public var lastActivityAt: Date?
  public var ageMs: Int?
  public var observedAt: Date

  public init(
    backend: NodeExecutionBackend?,
    verdict: SessionBackendActivityVerdict,
    evidence: [SessionBackendActivityEvidence],
    activeThresholdMs: Int,
    stalledThresholdMs: Int,
    lastActivityAt: Date?,
    ageMs: Int?,
    observedAt: Date
  ) {
    self.backend = backend
    self.verdict = verdict
    self.evidence = evidence
    self.activeThresholdMs = activeThresholdMs
    self.stalledThresholdMs = stalledThresholdMs
    self.lastActivityAt = lastActivityAt
    self.ageMs = ageMs
    self.observedAt = observedAt
  }

  public static func unknown(
    backend: NodeExecutionBackend?,
    observedAt: Date,
    activeThresholdMs: Int,
    stalledThresholdMs: Int,
    reason: String,
    evidence: [SessionBackendActivityEvidence] = []
  ) -> SessionBackendActivity {
    SessionBackendActivity(
      backend: backend,
      verdict: .unknown,
      evidence: evidence.isEmpty
        ? [SessionBackendActivityEvidence(kind: .diagnostic, detail: reason)]
        : evidence,
      activeThresholdMs: activeThresholdMs,
      stalledThresholdMs: stalledThresholdMs,
      lastActivityAt: nil,
      ageMs: nil,
      observedAt: observedAt
    )
  }
}

public struct SessionProgressDigest: Codable, Equatable, Sendable {
  public var observedAt: Date
  public var sessionId: String
  public var workflowId: String
  public var parentSessionId: String?
  public var rootSessionId: String
  public var status: WorkflowSessionStatus
  public var failureKind: WorkflowSessionFailureKind?
  public var previousStatus: WorkflowSessionStatus?
  public var currentStepId: String?
  public var currentStage: String?
  public var executionCount: Int
  public var effectiveStepBudget: Int?
  public var gateVisitCounts: [String: Int]
  public var lastBackendEventType: String?
  public var lastBackendEventAt: Date?
  public var lastBackendEventAgeMs: Int?
  public var activeBackend: NodeExecutionBackend?

  public init(
    observedAt: Date,
    sessionId: String,
    workflowId: String,
    parentSessionId: String?,
    rootSessionId: String,
    status: WorkflowSessionStatus,
    failureKind: WorkflowSessionFailureKind?,
    previousStatus: WorkflowSessionStatus?,
    currentStepId: String?,
    currentStage: String?,
    executionCount: Int,
    effectiveStepBudget: Int?,
    gateVisitCounts: [String: Int],
    lastBackendEventType: String?,
    lastBackendEventAt: Date?,
    lastBackendEventAgeMs: Int?,
    activeBackend: NodeExecutionBackend?
  ) {
    self.observedAt = observedAt
    self.sessionId = sessionId
    self.workflowId = workflowId
    self.parentSessionId = parentSessionId
    self.rootSessionId = rootSessionId
    self.status = status
    self.failureKind = failureKind
    self.previousStatus = previousStatus
    self.currentStepId = currentStepId
    self.currentStage = currentStage
    self.executionCount = executionCount
    self.effectiveStepBudget = effectiveStepBudget
    self.gateVisitCounts = gateVisitCounts
    self.lastBackendEventType = lastBackendEventType
    self.lastBackendEventAt = lastBackendEventAt
    self.lastBackendEventAgeMs = lastBackendEventAgeMs
    self.activeBackend = activeBackend
  }
}

public struct SessionRollupNode: Codable, Equatable, Sendable {
  public var digest: SessionProgressDigest
  public var children: [SessionRollupNode]

  public init(digest: SessionProgressDigest, children: [SessionRollupNode] = []) {
    self.digest = digest
    self.children = children
  }
}

public struct SessionObservabilityView: Codable, Equatable, Sendable {
  public var root: SessionRollupNode
  public var backendActivity: SessionBackendActivity?
  public var rollupTruncated: Bool?
  public var rollupSnapshotLimit: Int?

  public init(
    root: SessionRollupNode,
    backendActivity: SessionBackendActivity? = nil,
    rollupTruncated: Bool? = nil,
    rollupSnapshotLimit: Int? = nil
  ) {
    self.root = root
    self.backendActivity = backendActivity
    self.rollupTruncated = rollupTruncated
    self.rollupSnapshotLimit = rollupSnapshotLimit
  }
}

public struct SessionObservabilityObservation: Equatable, Sendable {
  public var snapshot: WorkflowRuntimePersistenceSnapshot
  public var view: SessionObservabilityView

  public init(
    snapshot: WorkflowRuntimePersistenceSnapshot,
    view: SessionObservabilityView
  ) {
    self.snapshot = snapshot
    self.view = view
  }
}

public struct SessionBackendActivityProbeInput: Sendable {
  public var session: WorkflowSession
  public var execution: WorkflowStepExecution
  public var backend: NodeExecutionBackend
  public var observedAt: Date
  public var activeThresholdMs: Int
  public var stalledThresholdMs: Int

  public init(
    session: WorkflowSession,
    execution: WorkflowStepExecution,
    backend: NodeExecutionBackend,
    observedAt: Date,
    activeThresholdMs: Int,
    stalledThresholdMs: Int
  ) {
    self.session = session
    self.execution = execution
    self.backend = backend
    self.observedAt = observedAt
    self.activeThresholdMs = activeThresholdMs
    self.stalledThresholdMs = stalledThresholdMs
  }
}

public protocol SessionBackendActivityProbing: Sendable {
  var backend: NodeExecutionBackend { get }
  func assess(_ input: SessionBackendActivityProbeInput) throws -> SessionBackendActivity
}

public struct SessionBackendActivityProbeRegistry: Sendable {
  private var probes: [NodeExecutionBackend: any SessionBackendActivityProbing]

  public init(_ probes: [any SessionBackendActivityProbing] = []) {
    self.probes = probes.reduce(into: [:]) { result, probe in
      result[probe.backend] = probe
    }
  }

  public var registeredBackends: Set<NodeExecutionBackend> {
    Set(probes.keys)
  }

  public func assess(_ input: SessionBackendActivityProbeInput) -> SessionBackendActivity {
    guard let probe = probes[input.backend] else {
      return .unknown(
        backend: input.backend,
        observedAt: input.observedAt,
        activeThresholdMs: input.activeThresholdMs,
        stalledThresholdMs: input.stalledThresholdMs,
        reason: "no backend activity probe is registered"
      )
    }
    do {
      return try probe.assess(input)
    } catch {
      return .unknown(
        backend: input.backend,
        observedAt: input.observedAt,
        activeThresholdMs: input.activeThresholdMs,
        stalledThresholdMs: input.stalledThresholdMs,
        reason: "backend activity probe failed"
      )
    }
  }
}

public enum SessionBackendActivityClassifier {
  public static func classify(
    input: SessionBackendActivityProbeInput,
    providerActivityAt: Date?,
    providerEvidence: [SessionBackendActivityEvidence],
    requiresProviderArtifactForStall: Bool,
    hasCorrelatedProviderArtifact: Bool
  ) -> SessionBackendActivity {
    var evidence = providerEvidence
    if let backendEventAt = input.execution.lastBackendEventAt {
      evidence.append(SessionBackendActivityEvidence(
        kind: .backendEvent,
        detail: "persisted backend event \(input.execution.lastBackendEventType ?? "unknown")",
        observedAt: backendEventAt,
        ageMs: ageMs(from: backendEventAt, to: input.observedAt)
      ))
    }
    let activityDates = [providerActivityAt, input.execution.lastBackendEventAt].compactMap { $0 }
    guard let lastActivityAt = activityDates.max() else {
      return .unknown(
        backend: input.backend,
        observedAt: input.observedAt,
        activeThresholdMs: input.activeThresholdMs,
        stalledThresholdMs: input.stalledThresholdMs,
        reason: "no uniquely correlated backend activity evidence is available",
        evidence: evidence
      )
    }
    let activityAgeMs = ageMs(from: lastActivityAt, to: input.observedAt)
    let verdict: SessionBackendActivityVerdict
    if input.execution.status != .running {
      verdict = .quiet
    } else if activityAgeMs <= input.activeThresholdMs {
      verdict = .active
    } else if activityAgeMs <= input.stalledThresholdMs {
      verdict = .quiet
    } else {
      let runtimeSignalAt = input.execution.lastBackendEventAt ?? input.execution.updatedAt
      let runtimeAgeMs = ageMs(from: runtimeSignalAt, to: input.observedAt)
      if runtimeAgeMs > input.stalledThresholdMs,
         !requiresProviderArtifactForStall || hasCorrelatedProviderArtifact {
        verdict = .stalledSuspect
      } else {
        verdict = .unknown
      }
    }
    return SessionBackendActivity(
      backend: input.backend,
      verdict: verdict,
      evidence: evidence,
      activeThresholdMs: input.activeThresholdMs,
      stalledThresholdMs: input.stalledThresholdMs,
      lastActivityAt: lastActivityAt,
      ageMs: activityAgeMs,
      observedAt: input.observedAt
    )
  }

  public static func ageMs(from date: Date, to observedAt: Date) -> Int {
    max(0, Int(observedAt.timeIntervalSince(date) * 1_000))
  }
}

public struct SessionObservabilityService: Sendable {
  public static let defaultActiveThresholdMs = 30_000
  public static let defaultStalledThresholdMs = 180_000

  private var loadSnapshot: @Sendable (String) throws -> WorkflowRuntimePersistenceSnapshot
  private var loadRollupSnapshotPage: @Sendable (String) throws -> SessionRollupSnapshotPage
  private var clock: any WorkflowRuntimeClock
  private var probes: SessionBackendActivityProbeRegistry
  public var activeThresholdMs: Int
  public var stalledThresholdMs: Int

  public init(
    loadSnapshot: @escaping @Sendable (String) throws -> WorkflowRuntimePersistenceSnapshot,
    loadRollupSnapshots: @escaping @Sendable (String) throws -> [WorkflowRuntimePersistenceSnapshot],
    clock: any WorkflowRuntimeClock = SystemWorkflowRuntimeClock(),
    probes: SessionBackendActivityProbeRegistry = SessionBackendActivityProbeRegistry(),
    activeThresholdMs: Int = Self.defaultActiveThresholdMs,
    stalledThresholdMs: Int = Self.defaultStalledThresholdMs
  ) {
    self.loadSnapshot = loadSnapshot
    self.loadRollupSnapshotPage = { sessionId in
      let snapshots = try loadRollupSnapshots(sessionId)
      return SessionRollupSnapshotPage(
        snapshots: snapshots,
        truncated: false,
        limit: snapshots.count
      )
    }
    self.clock = clock
    self.probes = probes
    self.activeThresholdMs = activeThresholdMs
    self.stalledThresholdMs = stalledThresholdMs
  }

  public init(
    loadSnapshot: @escaping @Sendable (String) throws -> WorkflowRuntimePersistenceSnapshot,
    loadRollupSnapshotPage: @escaping @Sendable (String) throws -> SessionRollupSnapshotPage,
    clock: any WorkflowRuntimeClock = SystemWorkflowRuntimeClock(),
    probes: SessionBackendActivityProbeRegistry = SessionBackendActivityProbeRegistry(),
    activeThresholdMs: Int = Self.defaultActiveThresholdMs,
    stalledThresholdMs: Int = Self.defaultStalledThresholdMs
  ) {
    self.loadSnapshot = loadSnapshot
    self.loadRollupSnapshotPage = loadRollupSnapshotPage
    self.clock = clock
    self.probes = probes
    self.activeThresholdMs = activeThresholdMs
    self.stalledThresholdMs = stalledThresholdMs
  }

  public init(
    store: SQLiteWorkflowRuntimePersistenceStore,
    clock: any WorkflowRuntimeClock = SystemWorkflowRuntimeClock(),
    probes: SessionBackendActivityProbeRegistry = SessionBackendActivityProbeRegistry(),
    activeThresholdMs: Int = Self.defaultActiveThresholdMs,
    stalledThresholdMs: Int = Self.defaultStalledThresholdMs
  ) {
    self.init(
      loadSnapshot: { try store.loadStrictReadOnly(sessionId: $0) },
      loadRollupSnapshotPage: { try store.loadRollupSnapshotPage(sessionId: $0) },
      clock: clock,
      probes: probes,
      activeThresholdMs: activeThresholdMs,
      stalledThresholdMs: stalledThresholdMs
    )
  }

  public func progress(
    sessionId: String,
    includeChildren: Bool = false,
    previousStatuses: [String: WorkflowSessionStatus] = [:]
  ) throws -> SessionObservabilityView {
    try progressObservation(
      sessionId: sessionId,
      includeChildren: includeChildren,
      previousStatuses: previousStatuses
    ).view
  }

  public func progressObservation(
    sessionId: String,
    includeChildren: Bool = false,
    previousStatuses: [String: WorkflowSessionStatus] = [:]
  ) throws -> SessionObservabilityObservation {
    let observedAt = clock.now()
    let page: SessionRollupSnapshotPage
    if includeChildren {
      page = try loadRollupSnapshotPage(sessionId)
    } else {
      page = SessionRollupSnapshotPage(
        snapshots: [try loadSnapshot(sessionId)],
        truncated: false,
        limit: 1
      )
    }
    let snapshots = page.snapshots
    guard let snapshot = snapshots.first(where: { $0.session.sessionId == sessionId }) else {
      throw WorkflowRuntimePersistenceStoreError.notFound("runtime snapshot not found: \(sessionId)")
    }
    let root = try rollup(
      requestedSessionId: sessionId,
      snapshots: snapshots,
      observedAt: observedAt,
      previousStatuses: previousStatuses,
      includeChildren: includeChildren
    )
    return SessionObservabilityObservation(
      snapshot: snapshot,
      view: SessionObservabilityView(
        root: root,
        rollupTruncated: includeChildren ? page.truncated : nil,
        rollupSnapshotLimit: includeChildren ? page.limit : nil
      )
    )
  }

  public func health(sessionId: String) throws -> SessionObservabilityView {
    try healthObservation(sessionId: sessionId).view
  }

  public func healthObservation(sessionId: String) throws -> SessionObservabilityObservation {
    let snapshot = try loadSnapshot(sessionId)
    let observedAt = clock.now()
    let root = SessionRollupNode(digest: digest(
      snapshot: snapshot,
      observedAt: observedAt,
      previousStatus: nil
    ))
    let execution: WorkflowStepExecution?
    if Self.isTerminal(snapshot.session) {
      execution = snapshot.session.executions.last { $0.backend != nil }
    } else {
      execution = snapshot.session.executions.last { $0.status == .running }
    }
    guard let execution, let backend = execution.backend else {
      return SessionObservabilityObservation(
        snapshot: snapshot,
        view: SessionObservabilityView(
          root: root,
          backendActivity: .unknown(
            backend: nil,
            observedAt: observedAt,
            activeThresholdMs: activeThresholdMs,
            stalledThresholdMs: stalledThresholdMs,
            reason: Self.isTerminal(snapshot.session)
              ? "the session has no backend execution to assess"
              : "the session has no active backend execution to assess"
          )
        )
      )
    }
    let input = SessionBackendActivityProbeInput(
      session: snapshot.session,
      execution: execution,
      backend: backend,
      observedAt: observedAt,
      activeThresholdMs: activeThresholdMs,
      stalledThresholdMs: stalledThresholdMs
    )
    return SessionObservabilityObservation(
      snapshot: snapshot,
      view: SessionObservabilityView(root: root, backendActivity: probes.assess(input))
    )
  }

  public func digest(
    snapshot: WorkflowRuntimePersistenceSnapshot,
    observedAt: Date,
    previousStatus: WorkflowSessionStatus?
  ) -> SessionProgressDigest {
    let session = snapshot.session
    let lastBackendExecution = session.executions
      .filter { $0.lastBackendEventAt != nil }
      .max { ($0.lastBackendEventAt ?? .distantPast) < ($1.lastBackendEventAt ?? .distantPast) }
    let activeExecution = session.executions.last { $0.status == .running }
    let gateVisitCounts: [String: Int]
    if let convergence = snapshot.loopEvidence?.convergence, !convergence.gateVisitCounts.isEmpty {
      gateVisitCounts = convergence.gateVisitCounts
    } else if let evidence = snapshot.loopEvidence {
      gateVisitCounts = Dictionary(grouping: evidence.gates, by: \.gateId).mapValues(\.count)
    } else {
      gateVisitCounts = [:]
    }
    let lastBackendEventAt = lastBackendExecution?.lastBackendEventAt
    return SessionProgressDigest(
      observedAt: observedAt,
      sessionId: session.sessionId,
      workflowId: session.workflowId,
      parentSessionId: session.parentSessionId,
      rootSessionId: session.rootSessionId ?? session.sessionId,
      status: session.status,
      failureKind: session.failureKind,
      previousStatus: previousStatus,
      currentStepId: session.currentStepId,
      currentStage: Self.stageDescription(for: session.currentStepId),
      executionCount: session.executions.count,
      effectiveStepBudget: session.stepBudgetDiagnostic?.stepBudget ?? session.effectiveStepBudget,
      gateVisitCounts: gateVisitCounts,
      lastBackendEventType: lastBackendExecution?.lastBackendEventType,
      lastBackendEventAt: lastBackendEventAt,
      lastBackendEventAgeMs: lastBackendEventAt.map {
        SessionBackendActivityClassifier.ageMs(from: $0, to: observedAt)
      },
      activeBackend: activeExecution?.backend
    )
  }

  public static func isTerminal(_ session: WorkflowSession) -> Bool {
    if session.failureKind == .cancelled {
      return true
    }
    return switch session.status {
    case .completed, .failed:
      true
    case .created, .running:
      false
    }
  }

  public static func isTerminal(_ node: SessionRollupNode) -> Bool {
    let rootTerminal: Bool
    if node.digest.failureKind == .cancelled {
      rootTerminal = true
    } else {
      switch node.digest.status {
      case .completed, .failed:
        rootTerminal = true
      case .created, .running:
        rootTerminal = false
      }
    }
    return rootTerminal && node.children.allSatisfy(isTerminal)
  }

  private func rollup(
    requestedSessionId: String,
    snapshots: [WorkflowRuntimePersistenceSnapshot],
    observedAt: Date,
    previousStatuses: [String: WorkflowSessionStatus],
    includeChildren: Bool
  ) throws -> SessionRollupNode {
    let byId = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.session.sessionId, $0) })
    guard byId[requestedSessionId] != nil else {
      throw WorkflowRuntimePersistenceStoreError.notFound("runtime snapshot not found: \(requestedSessionId)")
    }
    let childrenByParent = Dictionary(grouping: snapshots.filter { $0.session.parentSessionId != nil }) {
      $0.session.parentSessionId ?? ""
    }
    var visited: Set<String> = []
    func makeNode(_ sessionId: String) -> SessionRollupNode? {
      guard let snapshot = byId[sessionId], visited.insert(sessionId).inserted else {
        return nil
      }
      let children: [SessionRollupNode]
      if includeChildren {
        children = (childrenByParent[sessionId] ?? [])
          .sorted {
            if $0.session.createdAt == $1.session.createdAt {
              return $0.session.sessionId < $1.session.sessionId
            }
            return $0.session.createdAt < $1.session.createdAt
          }
          .compactMap { makeNode($0.session.sessionId) }
      } else {
        children = []
      }
      return SessionRollupNode(
        digest: digest(
          snapshot: snapshot,
          observedAt: observedAt,
          previousStatus: previousStatuses[sessionId]
        ),
        children: children
      )
    }
    guard let root = makeNode(requestedSessionId) else {
      throw WorkflowRuntimePersistenceStoreError.notFound("runtime snapshot not found: \(requestedSessionId)")
    }
    return root
  }

  private static func stageDescription(for stepId: String?) -> String? {
    guard let stepId else {
      return nil
    }
    let normalized = stepId.lowercased()
    if normalized.contains("ocr") {
      return "OCR in progress"
    }
    if normalized.contains("translate") || normalized.contains("translation") {
      return "Translation in progress"
    }
    if normalized.contains("ingest") || normalized.contains("note-create") || normalized.contains("create-note") {
      return "Note creation in progress"
    }
    return nil
  }
}
