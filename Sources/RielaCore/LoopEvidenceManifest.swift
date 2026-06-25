import Foundation

public struct LoopEvidenceManifest: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var manifestId: String
  public var workflowId: String
  public var sessionId: String
  public var workflowSource: LoopWorkflowSource
  public var workflowDefinitionDigest: String?
  public var variablesDigest: String?
  public var worktree: LoopWorktreeSummary?
  public var policy: LoopPolicyEvidence
  public var recovery: LoopRecoveryLineage?
  public var steps: [LoopStepEvidence]
  public var gates: [LoopGateResult]
  public var artifacts: [LoopArtifactRef]
  public var changedFiles: [LoopChangedFile]
  public var commands: [LoopCommandEvidence]
  public var verification: [LoopVerificationEvidence]
  public var implementationPlans: [LoopImplementationPlanRef]
  public var residualRisks: [LoopResidualRisk]
  public var redaction: LoopRedactionSummary
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    schemaVersion: Int,
    manifestId: String,
    workflowId: String,
    sessionId: String,
    workflowSource: LoopWorkflowSource,
    workflowDefinitionDigest: String? = nil,
    variablesDigest: String? = nil,
    worktree: LoopWorktreeSummary? = nil,
    policy: LoopPolicyEvidence,
    recovery: LoopRecoveryLineage? = nil,
    steps: [LoopStepEvidence] = [],
    gates: [LoopGateResult] = [],
    artifacts: [LoopArtifactRef] = [],
    changedFiles: [LoopChangedFile] = [],
    commands: [LoopCommandEvidence] = [],
    verification: [LoopVerificationEvidence] = [],
    implementationPlans: [LoopImplementationPlanRef] = [],
    residualRisks: [LoopResidualRisk] = [],
    redaction: LoopRedactionSummary,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.schemaVersion = schemaVersion
    self.manifestId = manifestId
    self.workflowId = workflowId
    self.sessionId = sessionId
    self.workflowSource = workflowSource
    self.workflowDefinitionDigest = workflowDefinitionDigest
    self.variablesDigest = variablesDigest
    self.worktree = worktree
    self.policy = policy
    self.recovery = recovery
    self.steps = steps
    self.gates = gates
    self.artifacts = artifacts
    self.changedFiles = changedFiles
    self.commands = commands
    self.verification = verification
    self.implementationPlans = implementationPlans
    self.residualRisks = residualRisks
    self.redaction = redaction
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct LoopEvidenceSummary: Codable, Equatable, Sendable {
  public var manifestId: String
  public var schemaVersion: Int
  public var workflowId: String
  public var sessionId: String
  public var gateCount: Int
  public var acceptedGateCount: Int
  public var rejectedGateCount: Int
  public var needsWorkGateCount: Int
  public var skippedGateCount: Int
  public var blockingFindingCount: Int
  public var stepCount: Int
  public var artifactCount: Int
  public var changedFileCount: Int
  public var commandCount: Int
  public var verificationCount: Int
  public var implementationPlanCount: Int
  public var residualRiskCount: Int
  public var redactionStatus: String
  public var updatedAt: Date

  public init(
    manifestId: String,
    schemaVersion: Int,
    workflowId: String,
    sessionId: String,
    gateCount: Int,
    acceptedGateCount: Int,
    rejectedGateCount: Int,
    needsWorkGateCount: Int,
    skippedGateCount: Int,
    blockingFindingCount: Int,
    stepCount: Int,
    artifactCount: Int,
    changedFileCount: Int,
    commandCount: Int,
    verificationCount: Int,
    implementationPlanCount: Int,
    residualRiskCount: Int,
    redactionStatus: String,
    updatedAt: Date
  ) {
    self.manifestId = manifestId
    self.schemaVersion = schemaVersion
    self.workflowId = workflowId
    self.sessionId = sessionId
    self.gateCount = gateCount
    self.acceptedGateCount = acceptedGateCount
    self.rejectedGateCount = rejectedGateCount
    self.needsWorkGateCount = needsWorkGateCount
    self.skippedGateCount = skippedGateCount
    self.blockingFindingCount = blockingFindingCount
    self.stepCount = stepCount
    self.artifactCount = artifactCount
    self.changedFileCount = changedFileCount
    self.commandCount = commandCount
    self.verificationCount = verificationCount
    self.implementationPlanCount = implementationPlanCount
    self.residualRiskCount = residualRiskCount
    self.redactionStatus = redactionStatus
    self.updatedAt = updatedAt
  }

  public init(manifest: LoopEvidenceManifest) {
    self.init(
      manifestId: manifest.manifestId,
      schemaVersion: manifest.schemaVersion,
      workflowId: manifest.workflowId,
      sessionId: manifest.sessionId,
      gateCount: manifest.gates.count,
      acceptedGateCount: manifest.gates.filter { $0.decision == .accepted }.count,
      rejectedGateCount: manifest.gates.filter { $0.decision == .rejected }.count,
      needsWorkGateCount: manifest.gates.filter { $0.decision == .needsWork }.count,
      skippedGateCount: manifest.gates.filter { $0.decision == .skipped }.count,
      blockingFindingCount: manifest.gates.reduce(0) { $0 + $1.blockingFindings.count },
      stepCount: manifest.steps.count,
      artifactCount: manifest.artifacts.count,
      changedFileCount: manifest.changedFiles.count,
      commandCount: manifest.commands.count,
      verificationCount: manifest.verification.count,
      implementationPlanCount: manifest.implementationPlans.count,
      residualRiskCount: manifest.residualRisks.count,
      redactionStatus: manifest.redaction.status,
      updatedAt: manifest.updatedAt
    )
  }
}

public struct LoopWorkflowSource: Codable, Equatable, Sendable {
  public var scope: String
  public var kind: String
  public var workflowDirectory: String?
  public var packageName: String?
  public var packageVersion: String?
  public var packageDirectory: String?
  public var mutable: Bool

  public init(
    scope: String,
    kind: String,
    workflowDirectory: String? = nil,
    packageName: String? = nil,
    packageVersion: String? = nil,
    packageDirectory: String? = nil,
    mutable: Bool
  ) {
    self.scope = scope
    self.kind = kind
    self.workflowDirectory = workflowDirectory
    self.packageName = packageName
    self.packageVersion = packageVersion
    self.packageDirectory = packageDirectory
    self.mutable = mutable
  }
}

public struct LoopWorktreeSummary: Codable, Equatable, Sendable {
  public var branch: String?
  public var baseCommit: String?
  public var headCommit: String?
  public var dirtySummary: String?
  public var hadUnrelatedDirtyFiles: Bool

  public init(
    branch: String? = nil,
    baseCommit: String? = nil,
    headCommit: String? = nil,
    dirtySummary: String? = nil,
    hadUnrelatedDirtyFiles: Bool = false
  ) {
    self.branch = branch
    self.baseCommit = baseCommit
    self.headCommit = headCommit
    self.dirtySummary = dirtySummary
    self.hadUnrelatedDirtyFiles = hadUnrelatedDirtyFiles
  }
}

public struct LoopPolicyEvidence: Codable, Equatable, Sendable {
  public var declared: LoopPolicyDeclaration?
  public var effective: LoopPolicyDeclaration?
  public var decisions: [LoopPolicyDecision]
  public var denials: [LoopPolicyDecision]

  public init(
    declared: LoopPolicyDeclaration? = nil,
    effective: LoopPolicyDeclaration? = nil,
    decisions: [LoopPolicyDecision] = [],
    denials: [LoopPolicyDecision] = []
  ) {
    self.declared = declared
    self.effective = effective
    self.decisions = decisions
    self.denials = denials
  }
}

public struct LoopPolicyDecision: Codable, Equatable, Sendable {
  public var id: String
  public var policy: String
  public var decision: String
  public var reason: String?
  public var evidenceRefs: [String]

  public init(id: String, policy: String, decision: String, reason: String? = nil, evidenceRefs: [String] = []) {
    self.id = id
    self.policy = policy
    self.decision = decision
    self.reason = reason
    self.evidenceRefs = evidenceRefs
  }
}

public struct LoopStepEvidence: Codable, Equatable, Sendable {
  public var stepId: String
  public var nodeId: String
  public var stepExecutionId: String
  public var backend: String?
  public var model: String?
  public var status: String
  public var artifactRefs: [String]
  public var acceptedOutputSummary: String?
  public var evidenceTags: [String]

  public init(
    stepId: String,
    nodeId: String,
    stepExecutionId: String,
    backend: String? = nil,
    model: String? = nil,
    status: String,
    artifactRefs: [String] = [],
    acceptedOutputSummary: String? = nil,
    evidenceTags: [String] = []
  ) {
    self.stepId = stepId
    self.nodeId = nodeId
    self.stepExecutionId = stepExecutionId
    self.backend = backend
    self.model = model
    self.status = status
    self.artifactRefs = artifactRefs
    self.acceptedOutputSummary = acceptedOutputSummary
    self.evidenceTags = evidenceTags
  }
}

public struct LoopArtifactRef: Codable, Equatable, Sendable {
  public var id: String
  public var path: String
  public var kind: String
  public var digest: String?
  public var producerStepExecutionId: String?
  public var redactionStatus: String
  public var retentionClass: String?

  public init(
    id: String,
    path: String,
    kind: String,
    digest: String? = nil,
    producerStepExecutionId: String? = nil,
    redactionStatus: String,
    retentionClass: String? = nil
  ) {
    self.id = id
    self.path = path
    self.kind = kind
    self.digest = digest
    self.producerStepExecutionId = producerStepExecutionId
    self.redactionStatus = redactionStatus
    self.retentionClass = retentionClass
  }
}

public struct LoopChangedFile: Codable, Equatable, Sendable {
  public var path: String
  public var changeKind: String
  public var producerStepExecutionId: String?
  public var digest: String?
  public var withinAllowedMutationRoots: Bool?

  public init(
    path: String,
    changeKind: String,
    producerStepExecutionId: String? = nil,
    digest: String? = nil,
    withinAllowedMutationRoots: Bool? = nil
  ) {
    self.path = path
    self.changeKind = changeKind
    self.producerStepExecutionId = producerStepExecutionId
    self.digest = digest
    self.withinAllowedMutationRoots = withinAllowedMutationRoots
  }
}

public struct LoopCommandEvidence: Codable, Equatable, Sendable {
  public var id: String
  public var argvSummary: String
  public var argvRedactionStatus: String
  public var workingDirectoryPolicyStatus: String?
  public var exitCode: Int?
  public var durationMs: Int?
  public var stdoutStoragePolicy: String?
  public var stderrStoragePolicy: String?
  public var evidenceRefs: [String]

  public init(
    id: String,
    argvSummary: String,
    argvRedactionStatus: String,
    workingDirectoryPolicyStatus: String? = nil,
    exitCode: Int? = nil,
    durationMs: Int? = nil,
    stdoutStoragePolicy: String? = nil,
    stderrStoragePolicy: String? = nil,
    evidenceRefs: [String] = []
  ) {
    self.id = id
    self.argvSummary = argvSummary
    self.argvRedactionStatus = argvRedactionStatus
    self.workingDirectoryPolicyStatus = workingDirectoryPolicyStatus
    self.exitCode = exitCode
    self.durationMs = durationMs
    self.stdoutStoragePolicy = stdoutStoragePolicy
    self.stderrStoragePolicy = stderrStoragePolicy
    self.evidenceRefs = evidenceRefs
  }
}

public struct LoopVerificationEvidence: Codable, Equatable, Sendable {
  public var id: String
  public var commandRef: String?
  public var evidenceRefs: [String]
  public var outcome: String
  public var diagnosticSummary: String?

  public init(
    id: String,
    commandRef: String? = nil,
    evidenceRefs: [String] = [],
    outcome: String,
    diagnosticSummary: String? = nil
  ) {
    self.id = id
    self.commandRef = commandRef
    self.evidenceRefs = evidenceRefs
    self.outcome = outcome
    self.diagnosticSummary = diagnosticSummary
  }
}

public struct LoopImplementationPlanRef: Codable, Equatable, Sendable {
  public var path: String
  public var status: String
  public var linkedSessionId: String?
  public var stale: Bool
  public var completionChecks: [String]
  public var verificationRefs: [String]

  public init(
    path: String,
    status: String,
    linkedSessionId: String? = nil,
    stale: Bool = false,
    completionChecks: [String] = [],
    verificationRefs: [String] = []
  ) {
    self.path = path
    self.status = status
    self.linkedSessionId = linkedSessionId
    self.stale = stale
    self.completionChecks = completionChecks
    self.verificationRefs = verificationRefs
  }
}

public struct LoopResidualRisk: Codable, Equatable, Sendable {
  public var severity: String
  public var message: String
  public var evidenceRefs: [String]
  public var owner: String?
  public var accepted: Bool

  public init(
    severity: String,
    message: String,
    evidenceRefs: [String] = [],
    owner: String? = nil,
    accepted: Bool = false
  ) {
    self.severity = severity
    self.message = message
    self.evidenceRefs = evidenceRefs
    self.owner = owner
    self.accepted = accepted
  }
}

public struct LoopRedactionSummary: Codable, Equatable, Sendable {
  public var policyName: String
  public var status: String
  public var redactedFieldCount: Int
  public var unredactedExceptions: [String]
  public var warnings: [String]

  public init(
    policyName: String,
    status: String,
    redactedFieldCount: Int = 0,
    unredactedExceptions: [String] = [],
    warnings: [String] = []
  ) {
    self.policyName = policyName
    self.status = status
    self.redactedFieldCount = redactedFieldCount
    self.unredactedExceptions = unredactedExceptions
    self.warnings = warnings
  }
}
