import Foundation
import RielaCore

// The domain model of design section 4. Every enum here is closed and decodes
// strictly: an unknown case is a decode error, never a tolerated fallback
// (design decision 12, no backward compatibility).

// MARK: - Intent

public enum WorkOrigin: String, Codable, CaseIterable, Sendable {
  case cli
  case chat
  case tracker
  case schedule
  case api
}

public enum IntentState: String, Codable, CaseIterable, Sendable {
  case open
  case fulfilled
  case abandoned
}

/// One natural-language acceptance statement, optionally tied to the gates
/// that judge it. The runtime never evaluates the statement itself; a director
/// does (design section 16).
public struct AcceptanceCriterion: Codable, Equatable, Sendable {
  public var id: String
  public var statement: String
  public var gateIds: [String]

  public init(id: String, statement: String, gateIds: [String] = []) {
    self.id = id
    self.statement = statement
    self.gateIds = gateIds
  }
}

/// Capability ceilings and allowed contexts. P0 carries them; P7 maps them to
/// Seatbelt and backend permission modes.
public struct IntentConstraints: Codable, Equatable, Sendable {
  public var capabilities: [String]
  public var allowedContexts: [String]

  public init(capabilities: [String] = [], allowedContexts: [String] = []) {
    self.capabilities = capabilities
    self.allowedContexts = allowedContexts
  }
}

public struct Intent: Codable, Equatable, Sendable {
  public var id: IntentID
  public var title: String
  public var instruction: String
  public var constraints: IntentConstraints
  public var acceptance: [AcceptanceCriterion]
  public var origin: WorkOrigin
  public var state: IntentState

  public init(
    id: IntentID,
    title: String,
    instruction: String,
    constraints: IntentConstraints = IntentConstraints(),
    acceptance: [AcceptanceCriterion] = [],
    origin: WorkOrigin,
    state: IntentState = .open
  ) {
    self.id = id
    self.title = title
    self.instruction = instruction
    self.constraints = constraints
    self.acceptance = acceptance
    self.origin = origin
    self.state = state
  }
}

// MARK: - Plan

/// A registered workflow the task's attempts execute.
public struct WorkflowReference: Codable, Equatable, Sendable {
  public var name: String
  public var scope: String?
  public var workflowDefinitionDir: String?

  public init(name: String, scope: String? = nil, workflowDefinitionDir: String? = nil) {
    self.name = name
    self.scope = scope
    self.workflowDefinitionDir = workflowDefinitionDir
  }
}

/// A workflow generated for this task (the monja pattern, design decision 5).
/// P0 stores the definition; P1 executes it.
public struct TemporaryWorkflowPlan: Codable, Equatable, Sendable {
  public var name: String
  public var definition: JSONObject

  public init(name: String, definition: JSONObject) {
    self.name = name
    self.definition = definition
  }
}

public enum TaskPlan: Codable, Equatable, Sendable {
  case workflow(WorkflowReference)
  case temporaryWorkflow(TemporaryWorkflowPlan)

  private enum CodingKeys: String, CodingKey {
    case kind
    case workflow
    case temporaryWorkflow
  }

  private enum Kind: String, Codable {
    case workflow
    case temporaryWorkflow
  }

  /// The workflow name a plan runs under, when the plan names a registered
  /// workflow. `work_tasks.workflow_id` is generated from this JSON path.
  public var workflowName: String? {
    switch self {
    case let .workflow(reference):
      return reference.name
    case .temporaryWorkflow:
      return nil
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .workflow:
      self = .workflow(try container.decode(WorkflowReference.self, forKey: .workflow))
    case .temporaryWorkflow:
      self = .temporaryWorkflow(try container.decode(TemporaryWorkflowPlan.self, forKey: .temporaryWorkflow))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .workflow(reference):
      try container.encode(Kind.workflow, forKey: .kind)
      try container.encode(reference, forKey: .workflow)
    case let .temporaryWorkflow(plan):
      try container.encode(Kind.temporaryWorkflow, forKey: .kind)
      try container.encode(plan, forKey: .temporaryWorkflow)
    }
  }
}

// MARK: - Completion contract

/// `LoopGateDeclaration` lifted from the workflow to the task. The acceptance
/// policy is the core type so a lifted gate and an authored gate stay one
/// shape.
public struct GateDeclaration: Codable, Equatable, Sendable {
  public var id: String
  public var stepId: String
  public var required: Bool
  public var acceptWhen: LoopGateAcceptancePolicy

  public init(
    id: String,
    stepId: String,
    required: Bool = false,
    acceptWhen: LoopGateAcceptancePolicy = LoopGateAcceptancePolicy()
  ) {
    self.id = id
    self.stepId = stepId
    self.required = required
    self.acceptWhen = acceptWhen
  }

  public init(_ declaration: LoopGateDeclaration) {
    self.init(
      id: declaration.id,
      stepId: declaration.stepId,
      required: declaration.required,
      acceptWhen: declaration.acceptWhen
    )
  }
}

/// Evidence that must be present and passing before a task can succeed.
public struct VerificationRequirement: Codable, Equatable, Sendable {
  public var name: String
  public var command: String?

  public init(name: String, command: String? = nil) {
    self.name = name
    self.command = command
  }
}

public struct CompletionContract: Codable, Equatable, Sendable {
  public var gates: [GateDeclaration]
  public var verification: [VerificationRequirement]
  public var acceptance: [AcceptanceCriterion]
  public var requiresHumanAccept: Bool

  public init(
    gates: [GateDeclaration] = [],
    verification: [VerificationRequirement] = [],
    acceptance: [AcceptanceCriterion] = [],
    requiresHumanAccept: Bool = false
  ) {
    self.gates = gates
    self.verification = verification
    self.acceptance = acceptance
    self.requiresHumanAccept = requiresHumanAccept
  }
}

// MARK: - Guard

public struct InactivityGuard: Codable, Equatable, Sendable {
  public var stallTimeoutMs: Int
  public var monitorIntervalMs: Int
  /// Backends whose heartbeat makes the timeout meaningful.
  public var heartbeatBackends: [String]

  public init(stallTimeoutMs: Int, monitorIntervalMs: Int, heartbeatBackends: [String] = []) {
    self.stallTimeoutMs = stallTimeoutMs
    self.monitorIntervalMs = monitorIntervalMs
    self.heartbeatBackends = heartbeatBackends
  }
}

public struct ConvergenceGuard: Codable, Equatable, Sendable {
  public var maxGateVisits: Int?
  public var maxRepeatedFindingRounds: Int?

  public init(maxGateVisits: Int? = nil, maxRepeatedFindingRounds: Int? = nil) {
    self.maxGateVisits = maxGateVisits
    self.maxRepeatedFindingRounds = maxRepeatedFindingRounds
  }
}

public struct BudgetGuard: Codable, Equatable, Sendable {
  public var maxAttempts: Int?
  public var maxTotalTokens: Int?
  public var maxWallClockMs: Int?
  public var maxProposals: Int?

  public init(
    maxAttempts: Int? = nil,
    maxTotalTokens: Int? = nil,
    maxWallClockMs: Int? = nil,
    maxProposals: Int? = nil
  ) {
    self.maxAttempts = maxAttempts
    self.maxTotalTokens = maxTotalTokens
    self.maxWallClockMs = maxWallClockMs
    self.maxProposals = maxProposals
  }
}

public enum ViolationAction: String, Codable, CaseIterable, Sendable {
  case fail
  case warn
  case askDirector
}

/// One guard, three detectors (design section 7). P0 stores the policy; P1
/// runs the detectors.
public struct GuardPolicy: Codable, Equatable, Sendable {
  public var inactivity: InactivityGuard?
  public var convergence: ConvergenceGuard?
  public var budget: BudgetGuard?
  public var onViolation: ViolationAction

  public init(
    inactivity: InactivityGuard? = nil,
    convergence: ConvergenceGuard? = nil,
    budget: BudgetGuard? = nil,
    onViolation: ViolationAction = .fail
  ) {
    self.inactivity = inactivity
    self.convergence = convergence
    self.budget = budget
    self.onViolation = onViolation
  }
}

// MARK: - Director

/// The default rerun/recover table of design section 6.
public struct DeterministicDirectorRules: Codable, Equatable, Sendable {
  public var rerunOnAdapterFailure: Bool
  public var rerunOnNodeTimeout: Bool
  public var rerunOnInactivity: Bool
  public var recoverOnGateRejection: Bool

  public init(
    rerunOnAdapterFailure: Bool = true,
    rerunOnNodeTimeout: Bool = true,
    rerunOnInactivity: Bool = true,
    recoverOnGateRejection: Bool = true
  ) {
    self.rerunOnAdapterFailure = rerunOnAdapterFailure
    self.rerunOnNodeTimeout = rerunOnNodeTimeout
    self.rerunOnInactivity = rerunOnInactivity
    self.recoverOnGateRejection = recoverOnGateRejection
  }
}

public struct EscalationPolicy: Codable, Equatable, Sendable {
  public var escalateOnGuardViolation: Bool
  public var escalateAfterFailedAttempts: Int?

  public init(escalateOnGuardViolation: Bool = true, escalateAfterFailedAttempts: Int? = nil) {
    self.escalateOnGuardViolation = escalateOnGuardViolation
    self.escalateAfterFailedAttempts = escalateAfterFailedAttempts
  }
}

public struct DirectorPolicy: Codable, Equatable, Sendable {
  public var deterministic: DeterministicDirectorRules
  /// Declared in P0 and unused until P1 runs agent directors.
  public var agentWorkflow: WorkflowReference?
  public var humanEscalation: EscalationPolicy

  public init(
    deterministic: DeterministicDirectorRules = DeterministicDirectorRules(),
    agentWorkflow: WorkflowReference? = nil,
    humanEscalation: EscalationPolicy = EscalationPolicy()
  ) {
    self.deterministic = deterministic
    self.agentWorkflow = agentWorkflow
    self.humanEscalation = humanEscalation
  }
}

// MARK: - Task

public enum TaskState: String, Codable, CaseIterable, Sendable {
  case draft
  case ready
  case scheduled
  /// Capacity, dependency, clarification, or human. The reason lives on the
  /// `wait` decision that put the task here.
  case waiting
  case running
  case verifying
  case needsDecision
  case succeeded
  case failed
  case cancelled
  case superseded

  /// States no decision moves out of.
  public var isTerminal: Bool {
    switch self {
    case .succeeded, .failed, .cancelled, .superseded:
      return true
    case .draft, .ready, .scheduled, .waiting, .running, .verifying, .needsDecision:
      return false
    }
  }
}

public enum TaskTrigger: Codable, Equatable, Sendable {
  case manual
  case schedule(cron: String, timezone: String?)
  case event(bindingId: String)
  case dependency

  private enum CodingKeys: String, CodingKey {
    case kind
    case cron
    case timezone
    case bindingId
  }

  private enum Kind: String, Codable {
    case manual
    case schedule
    case event
    case dependency
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .manual:
      self = .manual
    case .schedule:
      self = .schedule(
        cron: try container.decode(String.self, forKey: .cron),
        timezone: try container.decodeIfPresent(String.self, forKey: .timezone)
      )
    case .event:
      self = .event(bindingId: try container.decode(String.self, forKey: .bindingId))
    case .dependency:
      self = .dependency
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .manual:
      try container.encode(Kind.manual, forKey: .kind)
    case let .schedule(cron, timezone):
      try container.encode(Kind.schedule, forKey: .kind)
      try container.encode(cron, forKey: .cron)
      try container.encodeIfPresent(timezone, forKey: .timezone)
    case let .event(bindingId):
      try container.encode(Kind.event, forKey: .kind)
      try container.encode(bindingId, forKey: .bindingId)
    case .dependency:
      try container.encode(Kind.dependency, forKey: .kind)
    }
  }
}

/// Who owns the task and which capacity lane it consumes.
public struct OwnerAssignment: Codable, Equatable, Sendable {
  public var identity: String
  public var lane: String?

  public init(identity: String, lane: String? = nil) {
    self.identity = identity
    self.lane = lane
  }
}

/// The unit of work. Spelled `WorkTask` in Swift so it never shadows
/// `_Concurrency.Task` inside an async module (accepted delta D4); the JSON
/// shape is the design's `Task`.
public struct WorkTask: Codable, Equatable, Sendable {
  public var id: TaskID
  public var intentId: IntentID
  public var parentId: TaskID?
  public var dependsOn: [TaskID]
  public var title: String
  public var instruction: String
  public var plan: TaskPlan?
  public var context: ContextBinding?
  public var completion: CompletionContract
  /// Encoded under the design's `"guard"` key; `guard` is a Swift keyword.
  public var guardPolicy: GuardPolicy
  public var director: DirectorPolicy
  public var trigger: TaskTrigger
  public var owner: OwnerAssignment?
  public var state: TaskState
  /// Optimistic concurrency, as `SpecialistSupervisorStore` does today.
  public var version: Int

  private enum CodingKeys: String, CodingKey {
    case id
    case intentId
    case parentId
    case dependsOn
    case title
    case instruction
    case plan
    case context
    case completion
    case guardPolicy = "guard"
    case director
    case trigger
    case owner
    case state
    case version
  }

  public init(
    id: TaskID,
    intentId: IntentID,
    parentId: TaskID? = nil,
    dependsOn: [TaskID] = [],
    title: String,
    instruction: String,
    plan: TaskPlan? = nil,
    context: ContextBinding? = nil,
    completion: CompletionContract = CompletionContract(),
    guardPolicy: GuardPolicy = GuardPolicy(),
    director: DirectorPolicy = DirectorPolicy(),
    trigger: TaskTrigger = .manual,
    owner: OwnerAssignment? = nil,
    state: TaskState = .draft,
    version: Int = 1
  ) {
    self.id = id
    self.intentId = intentId
    self.parentId = parentId
    self.dependsOn = dependsOn
    self.title = title
    self.instruction = instruction
    self.plan = plan
    self.context = context
    self.completion = completion
    self.guardPolicy = guardPolicy
    self.director = director
    self.trigger = trigger
    self.owner = owner
    self.state = state
    self.version = version
  }
}

// MARK: - Attempt

public enum AttemptState: String, Codable, CaseIterable, Sendable {
  case prepared
  case running
  case terminal
  case reconciled
}

public enum AttemptLaunchPhase: String, Codable, CaseIterable, Sendable {
  case reserved
  case authorized
  case nodeStarted
  case fenced
  case terminal
}

/// Launch-fence state stored with the attempt. The opaque token is returned
/// only to the reserving caller; persistence contains its SHA-256 digest.
public struct AttemptLaunchMetadata: Codable, Equatable, Sendable {
  public var phase: AttemptLaunchPhase
  public var tokenDigest: String
  public var reservedAt: Date
  public var authorizedAt: Date?
  public var nodeStartedAt: Date?
  public var updatedAt: Date

  public init(
    phase: AttemptLaunchPhase,
    tokenDigest: String,
    reservedAt: Date,
    authorizedAt: Date? = nil,
    nodeStartedAt: Date? = nil,
    updatedAt: Date
  ) {
    self.phase = phase
    self.tokenDigest = tokenDigest
    self.reservedAt = reservedAt
    self.authorizedAt = authorizedAt
    self.nodeStartedAt = nodeStartedAt
    self.updatedAt = updatedAt
  }
}

public enum AttemptEntry: Codable, Equatable, Sendable {
  case start
  case resume
  case rerunFromStep(String?)
  case recoverFromGate(String)
  /// An agent director round, recorded as an attempt so its cost counts
  /// against the budget (design section 6).
  case director

  private enum CodingKeys: String, CodingKey {
    case kind
    case stepId
    case gateId
  }

  private enum Kind: String, Codable {
    case start
    case resume
    case rerunFromStep
    case recoverFromGate
    case director
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .start:
      self = .start
    case .resume:
      self = .resume
    case .rerunFromStep:
      self = .rerunFromStep(try container.decodeIfPresent(String.self, forKey: .stepId))
    case .recoverFromGate:
      self = .recoverFromGate(try container.decode(String.self, forKey: .gateId))
    case .director:
      self = .director
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .start:
      try container.encode(Kind.start, forKey: .kind)
    case .resume:
      try container.encode(Kind.resume, forKey: .kind)
    case let .rerunFromStep(stepId):
      try container.encode(Kind.rerunFromStep, forKey: .kind)
      try container.encodeIfPresent(stepId, forKey: .stepId)
    case let .recoverFromGate(gateId):
      try container.encode(Kind.recoverFromGate, forKey: .kind)
      try container.encode(gateId, forKey: .gateId)
    case .director:
      try container.encode(Kind.director, forKey: .kind)
    }
  }
}

/// What one workflow session produced for its task.
public struct AttemptOutcome: Codable, Equatable, Sendable {
  public var sessionStatus: WorkflowSessionStatus
  public var failureKind: WorkflowSessionFailureKind?
  public var gateResults: [LoopGateResult]
  public var costs: [LoopCostEvidence]

  public init(
    sessionStatus: WorkflowSessionStatus,
    failureKind: WorkflowSessionFailureKind? = nil,
    gateResults: [LoopGateResult] = [],
    costs: [LoopCostEvidence] = []
  ) {
    self.sessionStatus = sessionStatus
    self.failureKind = failureKind
    self.gateResults = gateResults
    self.costs = costs
  }

  /// The latest result per gate id, in gate-id order. A loop visits one gate
  /// many times; completion is judged against the last visit.
  public var latestGateResults: [LoopGateResult] {
    var latest: [String: LoopGateResult] = [:]
    for result in gateResults {
      latest[result.gateId] = result
    }
    return latest.values.sorted { $0.gateId < $1.gateId }
  }
}

/// One workflow session executed for a task.
public struct Attempt: Codable, Equatable, Sendable {
  public var id: AttemptID
  public var taskId: TaskID
  /// Bumps on replan or merge (the monja generation).
  public var generation: Int
  public var sessionId: String
  public var entry: AttemptEntry
  public var lineage: LoopRecoveryLineage?
  public var isolation: IsolationRef?
  public var state: AttemptState
  public var outcome: AttemptOutcome?
  public var launch: AttemptLaunchMetadata?

  public init(
    id: AttemptID,
    taskId: TaskID,
    generation: Int = 1,
    sessionId: String,
    entry: AttemptEntry = .start,
    lineage: LoopRecoveryLineage? = nil,
    isolation: IsolationRef? = nil,
    state: AttemptState = .prepared,
    outcome: AttemptOutcome? = nil,
    launch: AttemptLaunchMetadata? = nil
  ) {
    self.id = id
    self.taskId = taskId
    self.generation = generation
    self.sessionId = sessionId
    self.entry = entry
    self.lineage = lineage
    self.isolation = isolation
    self.state = state
    self.outcome = outcome
    self.launch = launch
  }
}
