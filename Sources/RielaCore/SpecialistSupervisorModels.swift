import Foundation

/// Durable, local state for the specialist-supervisor control plane.  This is
/// intentionally separate from a chat adapter: accepted chat input becomes a
/// request before any classifier, child runner, or provider is invoked.
public enum SpecialistTaskState: String, Codable, CaseIterable, Sendable {
  case queued
  case unclaimed
  case capacityWait = "capacity_wait"
  case running
  case recoveryRequired = "recovery_required"
  case needsClarification = "needs_clarification"
  case succeeded
  case failed
  case cancelRequested = "cancel_requested"
  case cancelled

  public var isTerminal: Bool {
    switch self {
    case .succeeded, .failed, .cancelled:
      true
    default:
      false
    }
  }
}

public enum SpecialistRequestRoute: String, Codable, Equatable, Sendable {
  case work
  case status
  case cancel
  case clarification
}

public struct SpecialistPrincipal: Codable, Equatable, Sendable {
  public var accountId: String
  public var actorId: String
  public var roomId: String
  public var threadId: String?

  public init(accountId: String, actorId: String, roomId: String, threadId: String? = nil) {
    self.accountId = accountId
    self.actorId = actorId
    self.roomId = roomId
    self.threadId = threadId
  }
}

public struct SpecialistRequest: Codable, Equatable, Sendable {
  public var requestId: String
  public var sourceEventId: String
  public var principal: SpecialistPrincipal
  public var route: SpecialistRequestRoute
  public var body: String
  public var receivedAt: Date

  public init(
    requestId: String,
    sourceEventId: String,
    principal: SpecialistPrincipal,
    route: SpecialistRequestRoute,
    body: String,
    receivedAt: Date = Date()
  ) {
    self.requestId = requestId
    self.sourceEventId = sourceEventId
    self.principal = principal
    self.route = route
    self.body = body
    self.receivedAt = receivedAt
  }
}
public struct SpecialistTask: Codable, Equatable, Sendable {
  public var taskId: String
  public var requestId: String
  public var principal: SpecialistPrincipal
  public var state: SpecialistTaskState
  public var ownerId: String?
  public var dispatchId: String?
  public var childSessionId: String?
  /// Provider task identity is written only after a verified gateway receipt;
  /// it is never accepted from chat or classifier output.
  public var trackerTaskId: String?
  /// The selected callable is pinned before dispatch.  It is deliberately an
  /// identifier rather than chat-provided executable data.
  public var selectedWorkflowId: String?
  /// A clarification reply creates a new, durable work-routing request while
  /// retaining this task as the single ownership/dispatch authority. This
  /// prevents a restarted service from treating a reply as a transient queue
  /// transition or allocating a second task.
  public var continuationRequestId: String?
  /// Factual child/tracker observations only. These are not model estimates:
  /// nil means unavailable and `progressUncertain` remains visible to status.
  public var childStepId: String?
  public var childObservedAt: Date?
  public var trackerObservedAt: Date?
  public var progressUncertain: Bool?
  public var version: Int
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    taskId: String,
    requestId: String,
    principal: SpecialistPrincipal,
    state: SpecialistTaskState = .queued,
    ownerId: String? = nil,
    dispatchId: String? = nil,
    childSessionId: String? = nil,
    trackerTaskId: String? = nil,
    selectedWorkflowId: String? = nil,
    continuationRequestId: String? = nil,
    childStepId: String? = nil,
    childObservedAt: Date? = nil,
    trackerObservedAt: Date? = nil,
    progressUncertain: Bool? = nil,
    version: Int = 0,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.taskId = taskId
    self.requestId = requestId
    self.principal = principal
    self.state = state
    self.ownerId = ownerId
    self.dispatchId = dispatchId
    self.childSessionId = childSessionId
    self.trackerTaskId = trackerTaskId
    self.selectedWorkflowId = selectedWorkflowId
    self.continuationRequestId = continuationRequestId
    self.childStepId = childStepId
    self.childObservedAt = childObservedAt
    self.trackerObservedAt = trackerObservedAt
    self.progressUncertain = progressUncertain
    self.version = version
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum SpecialistDispatchState: String, Codable, Equatable, Sendable {
  case prepared
  case running
  case terminal
  case delivered
  case recoveryRequired = "recovery_required"
}

/// Durable monitor fencing. The nonce is committed before the kernel starts a
/// monitor, and only its holder may cross into the ordinary workflow runner.
public enum SpecialistDispatchLaunchPhase: String, Codable, Equatable, Sendable {
  case preflighted
  case launchAuthorized = "launch_authorized"
  case monitorBound = "monitor_bound"
  case nodeStarted = "node_started"
}

/// The immutable, durable record consumed by an execution worker.  A child ID
/// is reserved before launch and is never regenerated during recovery.
public struct SpecialistDispatch: Codable, Equatable, Sendable {
  public var dispatchId: String
  public var taskId: String
  public var childSessionId: String
  public var workflowId: String?
  public var workflowOriginId: String?
  /// Complete executable-closure digest captured before reservation.  Workers
  /// must compare it with the selected registry card before launching.
  public var workflowRevision: String?
  public var entryStepId: String?
  public var inputJSON: String?
  public var state: SpecialistDispatchState
  public var resultHash: String?
  public var resultJSON: String?
  /// Durable evidence that a replacement service observed an already-running
  /// child and attached its monitor lane instead of attempting a second launch.
  public var attachmentGeneration: Int?
  public var lastAttachedAt: Date?
  /// The independent workflow-run monitor process. This is advisory liveness
  /// evidence only; the canonical runtime SQLite terminal snapshot remains the
  /// completion receipt after a supervisor process is killed.
  public var childProcessId: Int32?
  public var childReceiptPath: String?
  public var childMonitorStartedAt: Date?
  public var childReceiptObservedAt: Date?
  /// Authentication digest, never a signalling authority for the advisory PID.
  public var childControlTokenHash: String?
  public var childMonitorHeartbeatAt: Date?
  /// Nil is retained for compatibility with pre-fencing dispatch records.
  public var launchPhase: SpecialistDispatchLaunchPhase?

  public init(
    dispatchId: String,
    taskId: String,
    childSessionId: String,
    workflowId: String? = nil,
    workflowOriginId: String? = nil,
    workflowRevision: String? = nil,
    entryStepId: String? = nil,
    inputJSON: String? = nil,
    state: SpecialistDispatchState = .prepared,
    resultHash: String? = nil,
    resultJSON: String? = nil,
    attachmentGeneration: Int? = nil,
    lastAttachedAt: Date? = nil,
    childProcessId: Int32? = nil,
    childReceiptPath: String? = nil,
    childMonitorStartedAt: Date? = nil,
    childReceiptObservedAt: Date? = nil,
    childControlTokenHash: String? = nil,
    childMonitorHeartbeatAt: Date? = nil,
    launchPhase: SpecialistDispatchLaunchPhase? = nil
  ) {
    self.dispatchId = dispatchId
    self.taskId = taskId
    self.childSessionId = childSessionId
    self.workflowId = workflowId
    self.workflowOriginId = workflowOriginId
    self.workflowRevision = workflowRevision
    self.entryStepId = entryStepId
    self.inputJSON = inputJSON
    self.state = state
    self.resultHash = resultHash
    self.resultJSON = resultJSON
    self.attachmentGeneration = attachmentGeneration
    self.lastAttachedAt = lastAttachedAt
    self.childProcessId = childProcessId
    self.childReceiptPath = childReceiptPath
    self.childMonitorStartedAt = childMonitorStartedAt
    self.childReceiptObservedAt = childReceiptObservedAt
    self.childControlTokenHash = childControlTokenHash
    self.childMonitorHeartbeatAt = childMonitorHeartbeatAt
    self.launchPhase = launchPhase
  }
}

public struct SpecialistRoutingRecord: Codable, Equatable, Sendable {
  public var requestId: String
  public var settlement: SpecialistRoutingSettlement
  public var decisions: [SpecialistDecision]

  public init(requestId: String, settlement: SpecialistRoutingSettlement, decisions: [SpecialistDecision]) {
    self.requestId = requestId
    self.settlement = settlement
    self.decisions = decisions
  }
}

/// The authenticated classifier round is persisted separately from the task.
/// A request can therefore be recovered while model calls are outstanding
/// without allowing a late answer to alter an already sealed settlement.
public struct SpecialistClassificationRound: Codable, Equatable, Sendable {
  public var requestId: String
  public var configurationRevision: String
  public var catalogRevision: String
  public var deadline: Date
  public var decisions: [SpecialistDecision]
  public var sealed: Bool

  public init(
    requestId: String,
    configurationRevision: String,
    catalogRevision: String,
    deadline: Date,
    decisions: [SpecialistDecision] = [],
    sealed: Bool = false
  ) {
    self.requestId = requestId
    self.configurationRevision = configurationRevision
    self.catalogRevision = catalogRevision
    self.deadline = deadline
    self.decisions = decisions
    self.sealed = sealed
  }
}

/// Stable identity for a nested child publication.  These fields identify the
/// producing transition rather than a workflow name, so recovery never has to
/// resolve a mutable callee again.
public struct SpecialistNestedInvocation: Codable, Equatable, Sendable {
  public var rootDispatchId: String
  public var parentSessionId: String
  public var sourceExecutionId: String
  public var transitionOrdinal: Int
  public var branchId: String
  public var childSessionId: String
  public var resultHash: String?
  public var delivered: Bool

  public init(
    rootDispatchId: String, parentSessionId: String, sourceExecutionId: String,
    transitionOrdinal: Int, branchId: String, childSessionId: String,
    resultHash: String? = nil, delivered: Bool = false
  ) {
    self.rootDispatchId = rootDispatchId; self.parentSessionId = parentSessionId
    self.sourceExecutionId = sourceExecutionId; self.transitionOrdinal = transitionOrdinal
    self.branchId = branchId; self.childSessionId = childSessionId
    self.resultHash = resultHash; self.delivered = delivered
  }
}

public struct SpecialistServiceLease: Codable, Equatable, Sendable {
  public var workerId: String
  public var generation: Int
  public var acquiredAt: Date

  public init(workerId: String, generation: Int, acquiredAt: Date = Date()) {
    self.workerId = workerId
    self.generation = generation
    self.acquiredAt = acquiredAt
  }
}

public struct SpecialistOutboxEvent: Codable, Equatable, Sendable {
  public var eventId: String
  public var taskId: String?
  public var destination: String
  public var operation: String
  public var payload: String
  public var sequence: Int
  public var taskState: SpecialistTaskState?
  public var recipient: SpecialistPrincipal?

  public init(
    eventId: String,
    taskId: String? = nil,
    destination: String,
    operation: String,
    payload: String,
    sequence: Int,
    taskState: SpecialistTaskState? = nil,
    recipient: SpecialistPrincipal? = nil
  ) {
    self.eventId = eventId
    self.taskId = taskId
    self.destination = destination
    self.operation = operation
    self.payload = payload
    self.sequence = sequence
    self.taskState = taskState
    self.recipient = recipient
  }
}

/// A delivery attempt is deliberately distinct from task execution. A timeout
/// after handing a request to a provider is uncertain, not permission to send
/// a second copy.
public enum SpecialistDeliveryState: String, Codable, Equatable, Sendable {
  case pending
  case delivering
  case delivered
  case retryableFailure = "retryable_failure"
  case permanentFailure = "permanent_failure"
  case uncertain
}

/// Explicit operator-only recovery decisions. Neither case authorizes an
/// automatic replacement launch; any new work must arrive as a new request.
public enum SpecialistDispatchReconciliationOutcome: String, Codable, Equatable, Sendable {
  case confirmedNoEffect = "confirmed_no_effect"
  case terminalFailure = "terminal_failure"
}

public struct SpecialistDeliveryReceipt: Codable, Equatable, Sendable {
  public var eventId: String
  public var destination: String
  public var state: SpecialistDeliveryState
  public var attempt: Int
  public var generation: Int
  public var observedAt: Date
  public var remoteReceiptId: String?
  /// A retryable outcome is eligible only after this durable deadline.  An
  /// absent value means the event has never been attempted or is immediately
  /// eligible by an explicit operator reconciliation.
  public var nextAttemptAt: Date?

  public init(
    eventId: String,
    destination: String,
    state: SpecialistDeliveryState,
    attempt: Int,
    generation: Int,
    observedAt: Date = Date(),
    remoteReceiptId: String? = nil,
    nextAttemptAt: Date? = nil
  ) {
    self.eventId = eventId
    self.destination = destination
    self.state = state
    self.attempt = attempt
    self.generation = generation
    self.observedAt = observedAt
    self.remoteReceiptId = remoteReceiptId
    self.nextAttemptAt = nextAttemptAt
  }
}

public enum SpecialistSupervisorStoreError: Error, Equatable, Sendable {
  case invalidIdentifier(String)
  case requestConflict(String)
  case taskNotFound(String)
  case taskVersionConflict(String)
  case taskOwnerConflict(String)
  case capacityUnavailable(String)
  case invalidTransition(String)
  case schemaTooNew(Int64)
  case deliveryConflict(String)
  case encodingFailure
  case sqlite(String)
}
