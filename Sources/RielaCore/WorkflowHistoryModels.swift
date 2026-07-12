import Foundation

public enum WorkflowHistorySourceScope: String, Codable, Equatable, Sendable {
  case project
  case user
  case direct
}

public enum WorkflowHistorySourceKind: String, Codable, Equatable, Sendable {
  case authoredWorkflow = "authored-workflow"
  case installedPackage = "installed-package"
}

public enum WorkflowArtifactKind: String, Codable, Equatable, Sendable {
  case workflowDefinition = "workflow-definition"
  case node
  case prompt
  case nestedWorkflow = "nested-workflow"
  case mockScenario = "mock-scenario"
  case expectedResults = "expected-results"
  case packageMetadata = "package-metadata"
  case sharedNode = "shared-node"
  case ownedArtifact = "owned-artifact"
}

public enum WorkflowFileOperationKind: String, Codable, Equatable, Sendable {
  case create
  case update
  case delete
  case executableBit = "executable-bit"
}

public enum WorkflowChangeReviewDecision: String, Codable, Equatable, Sendable {
  case accepted
  case rejected
  case needsWork = "needs-work"
}

public enum WorkflowHistoryOutcome: String, Codable, Equatable, Sendable {
  case proposed
  case finalized
  case rejected
  case applied
  case restored
  case failed
  case recovered
}

public struct WorkflowBundleIdentity: Codable, Equatable, Sendable {
  public var workflowId: String
  public var sourceScope: WorkflowHistorySourceScope
  public var sourceKind: WorkflowHistorySourceKind
  public var workflowDirectory: String
  public var ownershipRoot: String
  public var packageDirectory: String?
  public var packageName: String?
  public var packageVersion: String?
  public var workflowContractVersion: String?
  public var sourceMutable: Bool

  public init(
    workflowId: String,
    sourceScope: WorkflowHistorySourceScope,
    sourceKind: WorkflowHistorySourceKind,
    workflowDirectory: String,
    ownershipRoot: String,
    packageDirectory: String? = nil,
    packageName: String? = nil,
    packageVersion: String? = nil,
    workflowContractVersion: String? = nil,
    sourceMutable: Bool
  ) {
    self.workflowId = workflowId
    self.sourceScope = sourceScope
    self.sourceKind = sourceKind
    self.workflowDirectory = workflowDirectory
    self.ownershipRoot = ownershipRoot
    self.packageDirectory = packageDirectory
    self.packageName = packageName
    self.packageVersion = packageVersion
    self.workflowContractVersion = workflowContractVersion
    self.sourceMutable = sourceMutable
  }
}

public struct WorkflowFileState: Codable, Equatable, Sendable {
  public var contentDigest: String
  public var byteCount: Int
  public var artifactKind: WorkflowArtifactKind
  public var executable: Bool

  public init(contentDigest: String, byteCount: Int, artifactKind: WorkflowArtifactKind, executable: Bool) {
    self.contentDigest = contentDigest
    self.byteCount = byteCount
    self.artifactKind = artifactKind
    self.executable = executable
  }
}

public struct WorkflowFileOperation: Codable, Equatable, Sendable {
  public var relativePath: String
  public var kind: WorkflowFileOperationKind
  public var before: WorkflowFileState?
  public var after: WorkflowFileState?

  public init(
    relativePath: String,
    kind: WorkflowFileOperationKind,
    before: WorkflowFileState?,
    after: WorkflowFileState?
  ) {
    self.relativePath = relativePath
    self.kind = kind
    self.before = before
    self.after = after
  }
}

public struct WorkflowChangeProposal: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var proposalId: String
  public var sourceSessionId: String
  public var sourceStepId: String?
  public var target: WorkflowBundleIdentity
  public var beforeBundleDigest: String
  public var operations: [WorkflowFileOperation]
  public var expectedAfterBundleDigest: String
  public var rationale: String
  public var validation: [LoopVerificationEvidence]
  public var rejectedAlternatives: [String]
  public var createdAt: Date
  public var proposalDigest: String

  public init(
    schemaVersion: Int = 1,
    proposalId: String,
    sourceSessionId: String,
    sourceStepId: String? = nil,
    target: WorkflowBundleIdentity,
    beforeBundleDigest: String,
    operations: [WorkflowFileOperation],
    expectedAfterBundleDigest: String,
    rationale: String,
    validation: [LoopVerificationEvidence] = [],
    rejectedAlternatives: [String] = [],
    createdAt: Date,
    proposalDigest: String
  ) {
    self.schemaVersion = schemaVersion
    self.proposalId = proposalId
    self.sourceSessionId = sourceSessionId
    self.sourceStepId = sourceStepId
    self.target = target
    self.beforeBundleDigest = beforeBundleDigest
    self.operations = operations
    self.expectedAfterBundleDigest = expectedAfterBundleDigest
    self.rationale = rationale
    self.validation = validation
    self.rejectedAlternatives = rejectedAlternatives
    self.createdAt = createdAt
    self.proposalDigest = proposalDigest
  }
}

public struct WorkflowChangeSetReviewEvidence: Codable, Equatable, Sendable {
  public var gateId: String
  public var gateResultId: String
  public var decision: WorkflowChangeReviewDecision
  public var reviewedProposalId: String
  public var reviewedProposalDigest: String
  public var reviewedBeforeBundleDigest: String
  public var reviewerStepId: String
  public var reviewerStepExecutionId: String
  public var reviewedAt: Date
  public var evidenceReferences: [String]

  public init(
    gateId: String,
    gateResultId: String,
    decision: WorkflowChangeReviewDecision,
    reviewedProposalId: String,
    reviewedProposalDigest: String,
    reviewedBeforeBundleDigest: String,
    reviewerStepId: String,
    reviewerStepExecutionId: String,
    reviewedAt: Date,
    evidenceReferences: [String] = []
  ) {
    self.gateId = gateId
    self.gateResultId = gateResultId
    self.decision = decision
    self.reviewedProposalId = reviewedProposalId
    self.reviewedProposalDigest = reviewedProposalDigest
    self.reviewedBeforeBundleDigest = reviewedBeforeBundleDigest
    self.reviewerStepId = reviewerStepId
    self.reviewerStepExecutionId = reviewerStepExecutionId
    self.reviewedAt = reviewedAt
    self.evidenceReferences = evidenceReferences
  }
}

public struct WorkflowChangeSet: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var changeSetId: String
  public var proposal: WorkflowChangeProposal
  public var review: WorkflowChangeSetReviewEvidence
  public var finalizedAt: Date
  public var finalizedDigest: String

  public init(
    schemaVersion: Int = 1,
    changeSetId: String,
    proposal: WorkflowChangeProposal,
    review: WorkflowChangeSetReviewEvidence,
    finalizedAt: Date,
    finalizedDigest: String
  ) {
    self.schemaVersion = schemaVersion
    self.changeSetId = changeSetId
    self.proposal = proposal
    self.review = review
    self.finalizedAt = finalizedAt
    self.finalizedDigest = finalizedDigest
  }
}

public struct WorkflowBundleSnapshotFile: Codable, Equatable, Sendable {
  public var relativePath: String
  public var contentDigest: String
  public var byteCount: Int
  public var artifactKind: WorkflowArtifactKind
  public var executable: Bool

  public init(
    relativePath: String,
    contentDigest: String,
    byteCount: Int,
    artifactKind: WorkflowArtifactKind,
    executable: Bool
  ) {
    self.relativePath = relativePath
    self.contentDigest = contentDigest
    self.byteCount = byteCount
    self.artifactKind = artifactKind
    self.executable = executable
  }
}

public struct WorkflowBundleSnapshotManifest: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var snapshotId: String
  public var target: WorkflowBundleIdentity
  public var createdBySessionId: String?
  public var createdBeforeChangeSetId: String?
  public var createdBeforeRestoreId: String?
  public var createdAt: Date
  public var bundleDigest: String
  public var files: [WorkflowBundleSnapshotFile]
  public var retentionClass: String
  public var redactionStatus: String
  public var integrityAlgorithm: String
  public var complete: Bool

  public init(
    schemaVersion: Int = 1,
    snapshotId: String,
    target: WorkflowBundleIdentity,
    createdBySessionId: String? = nil,
    createdBeforeChangeSetId: String? = nil,
    createdBeforeRestoreId: String? = nil,
    createdAt: Date,
    bundleDigest: String,
    files: [WorkflowBundleSnapshotFile],
    retentionClass: String = "standard",
    redactionStatus: String = "not-required",
    integrityAlgorithm: String = "sha256",
    complete: Bool = true
  ) {
    self.schemaVersion = schemaVersion
    self.snapshotId = snapshotId
    self.target = target
    self.createdBySessionId = createdBySessionId
    self.createdBeforeChangeSetId = createdBeforeChangeSetId
    self.createdBeforeRestoreId = createdBeforeRestoreId
    self.createdAt = createdAt
    self.bundleDigest = bundleDigest
    self.files = files
    self.retentionClass = retentionClass
    self.redactionStatus = redactionStatus
    self.integrityAlgorithm = integrityAlgorithm
    self.complete = complete
  }
}

public struct WorkflowRestoreRecord: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var restoreId: String
  public var target: WorkflowBundleIdentity
  public var sourceSnapshotId: String
  public var preRestoreSnapshotId: String
  public var requestedBundleDigest: String
  public var beforeBundleDigest: String
  public var resultBundleDigest: String?
  public var approved: Bool
  public var dirtyConflictPolicy: String
  public var observedDirtyConflicts: [String]
  public var restoredFiles: [String]
  public var skippedFiles: [String]
  public var validation: [LoopVerificationEvidence]
  public var transactionId: String
  public var startedAt: Date
  public var completedAt: Date?
  public var outcome: WorkflowHistoryOutcome
  public var diagnostics: [String]

  public init(
    schemaVersion: Int = 1,
    restoreId: String,
    target: WorkflowBundleIdentity,
    sourceSnapshotId: String,
    preRestoreSnapshotId: String,
    requestedBundleDigest: String,
    beforeBundleDigest: String,
    resultBundleDigest: String? = nil,
    approved: Bool,
    dirtyConflictPolicy: String,
    observedDirtyConflicts: [String] = [],
    restoredFiles: [String] = [],
    skippedFiles: [String] = [],
    validation: [LoopVerificationEvidence] = [],
    transactionId: String,
    startedAt: Date,
    completedAt: Date? = nil,
    outcome: WorkflowHistoryOutcome,
    diagnostics: [String] = []
  ) {
    self.schemaVersion = schemaVersion
    self.restoreId = restoreId
    self.target = target
    self.sourceSnapshotId = sourceSnapshotId
    self.preRestoreSnapshotId = preRestoreSnapshotId
    self.requestedBundleDigest = requestedBundleDigest
    self.beforeBundleDigest = beforeBundleDigest
    self.resultBundleDigest = resultBundleDigest
    self.approved = approved
    self.dirtyConflictPolicy = dirtyConflictPolicy
    self.observedDirtyConflicts = observedDirtyConflicts
    self.restoredFiles = restoredFiles
    self.skippedFiles = skippedFiles
    self.validation = validation
    self.transactionId = transactionId
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.outcome = outcome
    self.diagnostics = diagnostics
  }
}

public struct LoopWorkflowMutationEvidence: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var mode: String
  public var changeSetId: String?
  public var snapshotId: String?
  public var restoreId: String?
  public var transactionId: String?
  public var target: WorkflowBundleIdentity
  public var beforeBundleDigest: String?
  public var afterBundleDigest: String?
  public var review: WorkflowChangeSetReviewEvidence?
  public var validation: [LoopVerificationEvidence]
  public var applied: Bool
  public var restored: Bool
  public var outcome: WorkflowHistoryOutcome
  public var diagnostics: [String]

  public init(
    schemaVersion: Int = 1,
    mode: String,
    changeSetId: String? = nil,
    snapshotId: String? = nil,
    restoreId: String? = nil,
    transactionId: String? = nil,
    target: WorkflowBundleIdentity,
    beforeBundleDigest: String? = nil,
    afterBundleDigest: String? = nil,
    review: WorkflowChangeSetReviewEvidence? = nil,
    validation: [LoopVerificationEvidence] = [],
    applied: Bool,
    restored: Bool,
    outcome: WorkflowHistoryOutcome,
    diagnostics: [String] = []
  ) {
    self.schemaVersion = schemaVersion
    self.mode = mode
    self.changeSetId = changeSetId
    self.snapshotId = snapshotId
    self.restoreId = restoreId
    self.transactionId = transactionId
    self.target = target
    self.beforeBundleDigest = beforeBundleDigest
    self.afterBundleDigest = afterBundleDigest
    self.review = review
    self.validation = validation
    self.applied = applied
    self.restored = restored
    self.outcome = outcome
    self.diagnostics = diagnostics
  }
}
