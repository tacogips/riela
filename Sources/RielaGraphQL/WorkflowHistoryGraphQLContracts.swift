public struct GraphQLWorkflowBundleSnapshotSummary: Codable, Equatable, Sendable {
  public var snapshotId: String
  public var parentSnapshotId: String?
  public var createdAt: String
  public var bundleDigest: String
  public var createdBySessionId: String?
  public var createdBeforeChangeSetId: String?
  public var createdBeforeRestoreId: String?
  public var mutationReferences: [String]
  public var restoreReferences: [String]

  public init(
    snapshotId: String,
    parentSnapshotId: String? = nil,
    createdAt: String,
    bundleDigest: String,
    createdBySessionId: String? = nil,
    createdBeforeChangeSetId: String? = nil,
    createdBeforeRestoreId: String? = nil,
    mutationReferences: [String],
    restoreReferences: [String]
  ) {
    self.snapshotId = snapshotId
    self.parentSnapshotId = parentSnapshotId
    self.createdAt = createdAt
    self.bundleDigest = bundleDigest
    self.createdBySessionId = createdBySessionId
    self.createdBeforeChangeSetId = createdBeforeChangeSetId
    self.createdBeforeRestoreId = createdBeforeRestoreId
    self.mutationReferences = mutationReferences
    self.restoreReferences = restoreReferences
  }
}

public struct GraphQLWorkflowVersionsPayload: Codable, Equatable, Sendable {
  public var workflowId: String
  public var snapshots: [GraphQLWorkflowBundleSnapshotSummary]
  public var nextBeforeSnapshotId: String?

  public init(
    workflowId: String,
    snapshots: [GraphQLWorkflowBundleSnapshotSummary],
    nextBeforeSnapshotId: String? = nil
  ) {
    self.workflowId = workflowId
    self.snapshots = snapshots
    self.nextBeforeSnapshotId = nextBeforeSnapshotId
  }
}

public struct GraphQLWorkflowVersionContentDiff: Codable, Equatable, Sendable {
  public var unified: String?
  public var binary: Bool
  public var tooLarge: Bool
  public var limitBytes: Int?

  public init(
    unified: String? = nil,
    binary: Bool,
    tooLarge: Bool,
    limitBytes: Int? = nil
  ) {
    self.unified = unified
    self.binary = binary
    self.tooLarge = tooLarge
    self.limitBytes = limitBytes
  }
}

public struct GraphQLWorkflowVersionDifference: Codable, Equatable, Sendable {
  public var relativePath: String
  public var kind: String
  public var content: GraphQLWorkflowVersionContentDiff?

  public init(
    relativePath: String,
    kind: String,
    content: GraphQLWorkflowVersionContentDiff? = nil
  ) {
    self.relativePath = relativePath
    self.kind = kind
    self.content = content
  }
}

public struct GraphQLWorkflowVersionDiffPayload: Codable, Equatable, Sendable {
  public var workflowId: String
  public var from: String
  public var to: String
  public var differences: [GraphQLWorkflowVersionDifference]

  public init(
    workflowId: String,
    from: String,
    to: String,
    differences: [GraphQLWorkflowVersionDifference]
  ) {
    self.workflowId = workflowId
    self.from = from
    self.to = to
    self.differences = differences
  }
}

public struct RestoreWorkflowVersionInput: Codable, Equatable, Sendable {
  public var workflowName: String
  public var scope: String?
  public var snapshotId: String
  public var apply: Bool?
  public var reason: String?
  public var actorKind: String?
  public var actorId: String?

  public init(
    workflowName: String,
    scope: String? = nil,
    snapshotId: String,
    apply: Bool? = nil,
    reason: String? = nil,
    actorKind: String? = nil,
    actorId: String? = nil
  ) {
    self.workflowName = workflowName
    self.scope = scope
    self.snapshotId = snapshotId
    self.apply = apply
    self.reason = reason
    self.actorKind = actorKind
    self.actorId = actorId
  }
}

public struct GraphQLRestoreWorkflowVersionPayload: Codable, Equatable, Sendable {
  public var workflowId: String
  public var sourceSnapshotId: String
  public var dryRun: Bool
  public var restored: Bool
  public var beforeBundleDigest: String
  public var requestedBundleDigest: String
  public var preRestoreSnapshotId: String?
  public var restoredFiles: [String]
  public var dirtyConflicts: [String]
  public var definitionVersionId: String?
  public var definitionAuditId: String?
  public var definitionWarnings: [String]?

  public init(
    workflowId: String,
    sourceSnapshotId: String,
    dryRun: Bool,
    restored: Bool,
    beforeBundleDigest: String,
    requestedBundleDigest: String,
    preRestoreSnapshotId: String? = nil,
    restoredFiles: [String],
    dirtyConflicts: [String],
    definitionVersionId: String? = nil,
    definitionAuditId: String? = nil,
    definitionWarnings: [String]? = nil
  ) {
    self.workflowId = workflowId
    self.sourceSnapshotId = sourceSnapshotId
    self.dryRun = dryRun
    self.restored = restored
    self.beforeBundleDigest = beforeBundleDigest
    self.requestedBundleDigest = requestedBundleDigest
    self.preRestoreSnapshotId = preRestoreSnapshotId
    self.restoredFiles = restoredFiles
    self.dirtyConflicts = dirtyConflicts
    self.definitionVersionId = definitionVersionId
    self.definitionAuditId = definitionAuditId
    self.definitionWarnings = definitionWarnings
  }
}

public struct GraphQLWorkflowRollbackRegression: Codable, Equatable, Sendable {
  public var kind: String
  public var gateId: String?
  public var detail: String

  public init(
    kind: String,
    gateId: String? = nil,
    detail: String
  ) {
    self.kind = kind
    self.gateId = gateId
    self.detail = detail
  }
}

public struct GraphQLWorkflowRollbackProposal: Codable, Equatable, Sendable {
  public var proposalId: String
  public var workflowName: String
  public var regressedVersionId: String
  public var rollbackToVersionId: String
  public var mode: String
  public var bundleSnapshotId: String?
  public var baselineSessionId: String
  public var targetSessionId: String
  public var regressions: [GraphQLWorkflowRollbackRegression]
  public var policy: String
  public var status: String
  public var decidedActor: GraphQLWorkflowDefinitionActor?
  public var decisionReason: String?
  public var appliedVersionId: String?
  public var appliedAuditId: String?
  public var failureCode: String?
  public var diagnostics: [String]
  public var createdAt: String
  public var updatedAt: String

  public init(
    proposalId: String,
    workflowName: String,
    regressedVersionId: String,
    rollbackToVersionId: String,
    mode: String,
    bundleSnapshotId: String? = nil,
    baselineSessionId: String,
    targetSessionId: String,
    regressions: [GraphQLWorkflowRollbackRegression],
    policy: String,
    status: String,
    decidedActor: GraphQLWorkflowDefinitionActor? = nil,
    decisionReason: String? = nil,
    appliedVersionId: String? = nil,
    appliedAuditId: String? = nil,
    failureCode: String? = nil,
    diagnostics: [String],
    createdAt: String,
    updatedAt: String
  ) {
    self.proposalId = proposalId
    self.workflowName = workflowName
    self.regressedVersionId = regressedVersionId
    self.rollbackToVersionId = rollbackToVersionId
    self.mode = mode
    self.bundleSnapshotId = bundleSnapshotId
    self.baselineSessionId = baselineSessionId
    self.targetSessionId = targetSessionId
    self.regressions = regressions
    self.policy = policy
    self.status = status
    self.decidedActor = decidedActor
    self.decisionReason = decisionReason
    self.appliedVersionId = appliedVersionId
    self.appliedAuditId = appliedAuditId
    self.failureCode = failureCode
    self.diagnostics = diagnostics
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct CheckWorkflowRegressionRollbackInput: Codable, Equatable, Sendable {
  public var workflowName: String
  public var storeScope: String?
  public var targetSessionId: String?

  public init(
    workflowName: String,
    storeScope: String? = nil,
    targetSessionId: String? = nil
  ) {
    self.workflowName = workflowName
    self.storeScope = storeScope
    self.targetSessionId = targetSessionId
  }
}

// The public DTO name is pinned by the GraphQL contract.
// swiftlint:disable:next type_name
public struct GraphQLCheckWorkflowRegressionRollbackPayload: Codable, Equatable, Sendable {
  public var outcome: String
  public var eligibilityCode: String?
  public var regressions: [GraphQLWorkflowRollbackRegression]
  public var proposal: GraphQLWorkflowRollbackProposal?
  public var diagnostics: [String]

  public init(
    outcome: String,
    eligibilityCode: String? = nil,
    regressions: [GraphQLWorkflowRollbackRegression],
    proposal: GraphQLWorkflowRollbackProposal? = nil,
    diagnostics: [String]
  ) {
    self.outcome = outcome
    self.eligibilityCode = eligibilityCode
    self.regressions = regressions
    self.proposal = proposal
    self.diagnostics = diagnostics
  }
}

public struct ApproveWorkflowRollbackProposalInput: Codable, Equatable, Sendable {
  public var workflowName: String
  public var storeScope: String?
  public var proposalId: String
  public var reason: String?
  public var actorKind: String?
  public var actorId: String?

  public init(
    workflowName: String,
    storeScope: String? = nil,
    proposalId: String,
    reason: String? = nil,
    actorKind: String? = nil,
    actorId: String? = nil
  ) {
    self.workflowName = workflowName
    self.storeScope = storeScope
    self.proposalId = proposalId
    self.reason = reason
    self.actorKind = actorKind
    self.actorId = actorId
  }
}

public struct RejectWorkflowRollbackProposalInput: Codable, Equatable, Sendable {
  public var workflowName: String
  public var storeScope: String?
  public var proposalId: String
  public var reason: String
  public var actorKind: String?
  public var actorId: String?

  public init(
    workflowName: String,
    storeScope: String? = nil,
    proposalId: String,
    reason: String,
    actorKind: String? = nil,
    actorId: String? = nil
  ) {
    self.workflowName = workflowName
    self.storeScope = storeScope
    self.proposalId = proposalId
    self.reason = reason
    self.actorKind = actorKind
    self.actorId = actorId
  }
}

public enum WorkflowHistoryGraphQLErrorCode {
  public static let rollbackProposalNotFound = "ROLLBACK_PROPOSAL_NOT_FOUND"
  public static let rollbackProposalNotPending = "ROLLBACK_PROPOSAL_NOT_PENDING"
  public static let rollbackSuperseded = "ROLLBACK_SUPERSEDED"
  public static let rollbackInProgress = "ROLLBACK_IN_PROGRESS"
  public static let rollbackFailed = "ROLLBACK_FAILED"
  public static let definitionRollbackInProgress = "DEFINITION_ROLLBACK_IN_PROGRESS"
  public static let definitionSyncPending = "DEFINITION_SYNC_PENDING"
  public static let definitionSyncFailed = "DEFINITION_SYNC_FAILED"
  public static let workflowVersionNotFound = "WORKFLOW_VERSION_NOT_FOUND"
  public static let workflowRestoreDirtyConflicts = "WORKFLOW_RESTORE_DIRTY_CONFLICTS"
  public static let workflowImmutable = "WORKFLOW_IMMUTABLE"
}
