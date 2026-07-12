import Foundation

public struct WorkflowLoopMetadata: Codable, Equatable, Sendable {
  public var kind: String?
  public var required: Bool
  public var description: String?
  public var evidence: LoopEvidenceRequirements?
  public var policies: LoopPolicyDeclaration?
  public var convergence: LoopConvergenceDeclaration?
  public var budget: LoopBudgetDeclaration?
  public var concurrency: LoopConcurrencyDeclaration?
  public var notifications: LoopNotificationDeclaration?
  public var gates: [LoopGateDeclaration]
  public var recovery: LoopRecoveryDeclaration?
  public var implementationPlan: LoopImplementationPlanRequirement?
  public var selfEvolution: WorkflowSelfEvolutionDeclaration?

  private enum CodingKeys: String, CodingKey {
    case kind
    case required
    case description
    case evidence
    case policies
    case convergence
    case budget
    case concurrency
    case notifications
    case gates
    case recovery
    case implementationPlan
    case selfEvolution
  }

  public init(
    kind: String? = nil,
    required: Bool = false,
    description: String? = nil,
    evidence: LoopEvidenceRequirements? = nil,
    policies: LoopPolicyDeclaration? = nil,
    convergence: LoopConvergenceDeclaration? = nil,
    budget: LoopBudgetDeclaration? = nil,
    concurrency: LoopConcurrencyDeclaration? = nil,
    notifications: LoopNotificationDeclaration? = nil,
    gates: [LoopGateDeclaration] = [],
    recovery: LoopRecoveryDeclaration? = nil,
    implementationPlan: LoopImplementationPlanRequirement? = nil,
    selfEvolution: WorkflowSelfEvolutionDeclaration? = nil
  ) {
    self.kind = kind
    self.required = required
    self.description = description
    self.evidence = evidence
    self.policies = policies
    self.convergence = convergence
    self.budget = budget
    self.concurrency = concurrency
    self.notifications = notifications
    self.gates = gates
    self.recovery = recovery
    self.implementationPlan = implementationPlan
    self.selfEvolution = selfEvolution
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.kind = try container.decodeIfPresent(String.self, forKey: .kind)
    self.required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
    self.description = try container.decodeIfPresent(String.self, forKey: .description)
    self.evidence = try container.decodeIfPresent(LoopEvidenceRequirements.self, forKey: .evidence)
    self.policies = try container.decodeIfPresent(LoopPolicyDeclaration.self, forKey: .policies)
    self.convergence = try container.decodeIfPresent(LoopConvergenceDeclaration.self, forKey: .convergence)
    self.budget = try container.decodeIfPresent(LoopBudgetDeclaration.self, forKey: .budget)
    self.concurrency = try container.decodeIfPresent(LoopConcurrencyDeclaration.self, forKey: .concurrency)
    self.notifications = try container.decodeIfPresent(LoopNotificationDeclaration.self, forKey: .notifications)
    self.gates = try container.decodeIfPresent([LoopGateDeclaration].self, forKey: .gates) ?? []
    self.recovery = try container.decodeIfPresent(LoopRecoveryDeclaration.self, forKey: .recovery)
    self.implementationPlan = try container.decodeIfPresent(LoopImplementationPlanRequirement.self, forKey: .implementationPlan)
    self.selfEvolution = try container.decodeIfPresent(WorkflowSelfEvolutionDeclaration.self, forKey: .selfEvolution)
  }
}

/// Authored same-loop concurrency guard (design S11). The MVP validates
/// `maxActive == 1` — the lease table's primary key is the workflow id.
public struct LoopConcurrencyDeclaration: Codable, Equatable, Sendable {
  public var maxActive: Int
  /// "fail" (default) refuses to start; "skip" exits successfully without
  /// creating a session (cron/webhook triggers where an in-flight run is
  /// normal). Kept as a validated string so unknown authored values surface
  /// as validation diagnostics rather than hard decode failures.
  public var onBusy: String

  private enum CodingKeys: String, CodingKey {
    case maxActive
    case onBusy
  }

  public init(maxActive: Int = 1, onBusy: String = "fail") {
    self.maxActive = maxActive
    self.onBusy = onBusy
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.maxActive = try container.decodeIfPresent(Int.self, forKey: .maxActive) ?? 1
    self.onBusy = try container.decodeIfPresent(String.self, forKey: .onBusy) ?? "fail"
  }
}

public enum WorkflowSelfEvolutionDefaultMode: String, Codable, Equatable, Sendable {
  case propose
}

public enum WorkflowSelfEvolutionSnapshotPolicy: String, Codable, Equatable, Sendable {
  case bundleBeforeApply = "bundle-before-apply"
}

public enum WorkflowImmutablePackageMutationPolicy: String, Codable, Equatable, Sendable {
  case deny
}

public enum WorkflowSelfEvolutionVerification: String, Codable, Equatable, Sendable {
  case workflowValidate = "workflow validate"
  case mockScenario = "mock-scenario"
}

public struct WorkflowSelfEvolutionDeclaration: Codable, Equatable, Sendable {
  public var allowed: Bool
  public var defaultMode: WorkflowSelfEvolutionDefaultMode
  public var requiresReviewGate: Bool
  public var snapshotPolicy: WorkflowSelfEvolutionSnapshotPolicy
  public var historyRoot: String
  public var immutablePackageMutation: WorkflowImmutablePackageMutationPolicy
  public var requiredVerification: [WorkflowSelfEvolutionVerification]

  public init(
    allowed: Bool = false,
    defaultMode: WorkflowSelfEvolutionDefaultMode = .propose,
    requiresReviewGate: Bool = true,
    snapshotPolicy: WorkflowSelfEvolutionSnapshotPolicy = .bundleBeforeApply,
    historyRoot: String = ".riela/workflow-history",
    immutablePackageMutation: WorkflowImmutablePackageMutationPolicy = .deny,
    requiredVerification: [WorkflowSelfEvolutionVerification] = [.workflowValidate]
  ) {
    self.allowed = allowed
    self.defaultMode = defaultMode
    self.requiresReviewGate = requiresReviewGate
    self.snapshotPolicy = snapshotPolicy
    self.historyRoot = historyRoot
    self.immutablePackageMutation = immutablePackageMutation
    self.requiredVerification = requiredVerification
  }
}

public struct LoopConvergenceDeclaration: Codable, Equatable, Sendable {
  public var maxGateVisits: Int?
  public var maxRepeatedFindingRounds: Int?
  public var onStall: LoopConvergenceStallAction

  private enum CodingKeys: String, CodingKey {
    case maxGateVisits
    case maxRepeatedFindingRounds
    case onStall
  }

  public init(
    maxGateVisits: Int? = nil,
    maxRepeatedFindingRounds: Int? = nil,
    onStall: LoopConvergenceStallAction = .fail
  ) {
    self.maxGateVisits = maxGateVisits
    self.maxRepeatedFindingRounds = maxRepeatedFindingRounds
    self.onStall = onStall
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.maxGateVisits = try container.decodeIfPresent(Int.self, forKey: .maxGateVisits)
    self.maxRepeatedFindingRounds = try container.decodeIfPresent(Int.self, forKey: .maxRepeatedFindingRounds)
    self.onStall = try container.decodeIfPresent(LoopConvergenceStallAction.self, forKey: .onStall) ?? .fail
  }
}

public struct LoopBudgetDeclaration: Codable, Equatable, Sendable {
  public var maxTotalTokens: Int?
  public var maxWallClockMs: Int?
  public var maxSessionAttempts: Int?
  /// "fail" | "warn". Kept as a validated string so an unknown authored value is
  /// reported as a validation diagnostic rather than a hard decode failure.
  public var onExceeded: String

  private enum CodingKeys: String, CodingKey {
    case maxTotalTokens
    case maxWallClockMs
    case maxSessionAttempts
    case onExceeded
  }

  public init(
    maxTotalTokens: Int? = nil,
    maxWallClockMs: Int? = nil,
    maxSessionAttempts: Int? = nil,
    onExceeded: String = "fail"
  ) {
    self.maxTotalTokens = maxTotalTokens
    self.maxWallClockMs = maxWallClockMs
    self.maxSessionAttempts = maxSessionAttempts
    self.onExceeded = onExceeded
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.maxTotalTokens = try container.decodeIfPresent(Int.self, forKey: .maxTotalTokens)
    self.maxWallClockMs = try container.decodeIfPresent(Int.self, forKey: .maxWallClockMs)
    self.maxSessionAttempts = try container.decodeIfPresent(Int.self, forKey: .maxSessionAttempts)
    self.onExceeded = try container.decodeIfPresent(String.self, forKey: .onExceeded) ?? "fail"
  }
}

public struct WorkflowStepLoopMetadata: Codable, Equatable, Sendable {
  public var role: String?
  public var gateId: String?
  public var evidenceTags: [String]
  public var recordsChangedFiles: Bool?
  public var recordsVerification: Bool?

  private enum CodingKeys: String, CodingKey {
    case role
    case gateId
    case evidenceTags
    case recordsChangedFiles
    case recordsVerification
  }

  public init(
    role: String? = nil,
    gateId: String? = nil,
    evidenceTags: [String] = [],
    recordsChangedFiles: Bool? = nil,
    recordsVerification: Bool? = nil
  ) {
    self.role = role
    self.gateId = gateId
    self.evidenceTags = evidenceTags
    self.recordsChangedFiles = recordsChangedFiles
    self.recordsVerification = recordsVerification
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.role = try container.decodeIfPresent(String.self, forKey: .role)
    self.gateId = try container.decodeIfPresent(String.self, forKey: .gateId)
    self.evidenceTags = try container.decodeIfPresent([String].self, forKey: .evidenceTags) ?? []
    self.recordsChangedFiles = try container.decodeIfPresent(Bool.self, forKey: .recordsChangedFiles)
    self.recordsVerification = try container.decodeIfPresent(Bool.self, forKey: .recordsVerification)
  }
}

public struct LoopEvidenceRequirements: Codable, Equatable, Sendable {
  public var required: Bool
  public var artifactRootPolicy: String?
  public var requiredSections: [String]

  private enum CodingKeys: String, CodingKey {
    case required
    case artifactRootPolicy
    case requiredSections
  }

  public init(required: Bool = false, artifactRootPolicy: String? = nil, requiredSections: [String] = []) {
    self.required = required
    self.artifactRootPolicy = artifactRootPolicy
    self.requiredSections = requiredSections
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
    self.artifactRootPolicy = try container.decodeIfPresent(String.self, forKey: .artifactRootPolicy)
    self.requiredSections = try container.decodeIfPresent([String].self, forKey: .requiredSections) ?? []
  }
}

public struct LoopPolicyDeclaration: Codable, Equatable, Sendable {
  public var mutation: LoopMutationPolicyDeclaration?
  public var process: LoopProcessPolicyDeclaration?
  public var network: LoopNetworkPolicyDeclaration?
  public var redaction: LoopRedactionPolicyDeclaration?

  public init(
    mutation: LoopMutationPolicyDeclaration? = nil,
    process: LoopProcessPolicyDeclaration? = nil,
    network: LoopNetworkPolicyDeclaration? = nil,
    redaction: LoopRedactionPolicyDeclaration? = nil
  ) {
    self.mutation = mutation
    self.process = process
    self.network = network
    self.redaction = redaction
  }
}

public struct LoopMutationPolicyDeclaration: Codable, Equatable, Sendable {
  public var allowedWriteRoots: [String]
  public var scratchRoot: String?
  public var commit: String?
  public var push: String?

  private enum CodingKeys: String, CodingKey {
    case allowedWriteRoots
    case scratchRoot
    case commit
    case push
  }

  public init(allowedWriteRoots: [String] = [], scratchRoot: String? = nil, commit: String? = nil, push: String? = nil) {
    self.allowedWriteRoots = allowedWriteRoots
    self.scratchRoot = scratchRoot
    self.commit = commit
    self.push = push
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.allowedWriteRoots = try container.decodeIfPresent([String].self, forKey: .allowedWriteRoots) ?? []
    self.scratchRoot = try container.decodeIfPresent(String.self, forKey: .scratchRoot)
    self.commit = try container.decodeIfPresent(String.self, forKey: .commit)
    self.push = try container.decodeIfPresent(String.self, forKey: .push)
  }
}

public struct LoopProcessPolicyDeclaration: Codable, Equatable, Sendable {
  public var nestedRiela: String?
  public var nestedCodex: String?
  public var allowedBackends: [String]
  public var requiredWorkerModel: String?

  private enum CodingKeys: String, CodingKey {
    case nestedRiela
    case nestedCodex
    case allowedBackends
    case requiredWorkerModel
  }

  public init(
    nestedRiela: String? = nil,
    nestedCodex: String? = nil,
    allowedBackends: [String] = [],
    requiredWorkerModel: String? = nil
  ) {
    self.nestedRiela = nestedRiela
    self.nestedCodex = nestedCodex
    self.allowedBackends = allowedBackends
    self.requiredWorkerModel = requiredWorkerModel
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.nestedRiela = try container.decodeIfPresent(String.self, forKey: .nestedRiela)
    self.nestedCodex = try container.decodeIfPresent(String.self, forKey: .nestedCodex)
    self.allowedBackends = try container.decodeIfPresent([String].self, forKey: .allowedBackends) ?? []
    self.requiredWorkerModel = try container.decodeIfPresent(String.self, forKey: .requiredWorkerModel)
  }
}

public struct LoopNetworkPolicyDeclaration: Codable, Equatable, Sendable {
  public var mode: String?

  public init(mode: String? = nil) {
    self.mode = mode
  }
}

public struct LoopRedactionPolicyDeclaration: Codable, Equatable, Sendable {
  public var secretPolicy: String?
  public var storeRawStdout: Bool?
  public var storeRawStderr: Bool?

  public init(secretPolicy: String? = nil, storeRawStdout: Bool? = nil, storeRawStderr: Bool? = nil) {
    self.secretPolicy = secretPolicy
    self.storeRawStdout = storeRawStdout
    self.storeRawStderr = storeRawStderr
  }
}

public struct LoopGateDeclaration: Codable, Equatable, Sendable {
  public var id: String
  public var stepId: String
  public var required: Bool
  public var acceptWhen: LoopGateAcceptancePolicy

  private enum CodingKeys: String, CodingKey {
    case id
    case stepId
    case required
    case acceptWhen
  }

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

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.stepId = try container.decode(String.self, forKey: .stepId)
    self.required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
    self.acceptWhen = try container.decodeIfPresent(LoopGateAcceptancePolicy.self, forKey: .acceptWhen)
      ?? LoopGateAcceptancePolicy()
  }
}

public struct LoopGateAcceptancePolicy: Codable, Equatable, Sendable {
  public var decision: LoopGateDecision?
  public var maxHighFindings: Int?
  public var maxMediumFindings: Int?

  public init(decision: LoopGateDecision? = nil, maxHighFindings: Int? = nil, maxMediumFindings: Int? = nil) {
    self.decision = decision
    self.maxHighFindings = maxHighFindings
    self.maxMediumFindings = maxMediumFindings
  }
}

public struct LoopRecoveryDeclaration: Codable, Equatable, Sendable {
  public var resume: String?
  public var rerun: String?
  public var retry: String?

  public init(resume: String? = nil, rerun: String? = nil, retry: String? = nil) {
    self.resume = resume
    self.rerun = rerun
    self.retry = retry
  }
}

public struct LoopImplementationPlanRequirement: Codable, Equatable, Sendable {
  public var required: Bool
  public var pathPattern: String?

  private enum CodingKeys: String, CodingKey {
    case required
    case pathPattern
  }

  public init(required: Bool = false, pathPattern: String? = nil) {
    self.required = required
    self.pathPattern = pathPattern
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
    self.pathPattern = try container.decodeIfPresent(String.self, forKey: .pathPattern)
  }
}
