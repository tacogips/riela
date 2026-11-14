# whu-01-store-core progress

Workflow mode: issue-resolution. Issue reference: workflowInput.requestedOutcome (opus-terra-design-and-implement-review-loop-session-631, comm-012347). The dependency-free plan aligns with the accepted design. WHU-INT-01's write-path amendment is present in the committed plan and dispatch manifest.

Implemented generation 13 proposal schema, proposal store and claim/CAS transitions, head guard and atomic proposal completion, file-change completion and audit primitives, rollback policy metadata and validation, registry error codes, and proposal retention including dry-run and GC accounting. Replaced both stale schema assertions with the runtime generation constant. Added migration, actual rejected-proposal rollback, proposal store, and prune/purge coverage. Preserved partial work from the previous dispatch and sibling work.

## Completion criteria

- [x] Pinned symbols and behavior implemented; symbol inventory: `tmp/workflow-history-unification/whu-01-store-core/symbols.txt`.
- [x] Generation 13 migration and fresh schema tested.
- [x] Focused tests, build, and strict changed-file SwiftLint pass.
- [x] Source hashes and NUL-delimited Swift paths: `tmp/workflow-history-unification/whu-01-store-core/source-hashes.txt` and `changed-swift.nul`.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift build'`: exit 0; `tmp/workflow-history-unification/whu-01-store-core/build-final.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowDefinitionFileChangeStoreTests|WorkflowRollbackProposalStoreTests|SQLiteRuntimeSchemaMigrationTests|WorkflowLoopValidationTests|WorkflowLoopMetadataCodableTests|LoopEngineeringModelsTests|WorkflowDefinitionStoreTests|WorkflowDefinitionRetentionTests|WorkflowDefinitionSessionPinTests|RielaRetentionServiceTests"'`: exit 0, 103 tests, 0 failures; `tmp/workflow-history-unification/whu-01-store-core/tests.log`.
- `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/workflow-history-unification/whu-01-store-core/changed-swift.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi'`: exit 0; `tmp/workflow-history-unification/whu-01-store-core/lint-final.log`.
- `git diff --check` on tracked assigned paths: exit 0; `tmp/workflow-history-unification/whu-01-store-core/diff-check.log`.

Earlier build attempt failed on an incorrect SQLite binding type, fixed before final gates; `build-attempt1.log`. A subsequent build waiting on a sibling SwiftPM process was interrupted; `build-attempt2.log`. The first lint attempt identified scoped issues fixed before final lint; `lint-attempt1.log`. Formal integrity, adversarial and integration reviews, review-dependent documentation, staging, commit and push belong to later steps.

## Pinned symbol inventory (`rg -n`)

```text
Sources/RielaCLI/RielaRetentionService.swift:71:  public var proposalsDropped: Int
Sources/RielaCLI/RielaRetentionService.swift:74:    case keepVersions, workflowCount, removedVersionCount, removedAuditCount, removedBlobCount, removedBlobBytes, proposalsDropped
Sources/RielaCLI/RielaRetentionService.swift:78:       removedBlobCount: Int, removedBlobBytes: Int64, proposalsDropped: Int) {
Sources/RielaCLI/RielaRetentionService.swift:85:    self.proposalsDropped = proposalsDropped
Sources/RielaCLI/RielaRetentionService.swift:96:    proposalsDropped = try values.decodeIfPresent(Int.self, forKey: .proposalsDropped) ?? 0
Sources/RielaCLI/RielaRetentionService.swift:380:      removedAuditCount: 0, removedBlobCount: 0, removedBlobBytes: 0, proposalsDropped: 0)
Sources/RielaCLI/RielaRetentionService.swift:396:      report.proposalsDropped += result.proposalsDropped
Sources/RielaCore/WorkflowDefinitionStore+Retention.swift:33:  public var proposalsDropped: Int
Sources/RielaCore/WorkflowDefinitionStore+Retention.swift:38:    case removedAuditCount, removedBlobCount, removedBlobBytes, proposalsDropped, audit
Sources/RielaCore/WorkflowDefinitionStore+Retention.swift:43:       removedAuditCount: Int, removedBlobCount: Int, removedBlobBytes: Int64, proposalsDropped: Int,
Sources/RielaCore/WorkflowDefinitionStore+Retention.swift:55:    self.proposalsDropped = proposalsDropped
Sources/RielaCore/WorkflowDefinitionStore+Retention.swift:71:    proposalsDropped = try values.decodeIfPresent(Int.self, forKey: .proposalsDropped) ?? 0
Sources/RielaCore/WorkflowDefinitionStore+Retention.swift:173:      let proposalsDropped = try WorkflowDefinitionHistorySchema.deleteDroppedVersionsAndOrphanAudit(
Sources/RielaCore/WorkflowDefinitionStore+Retention.swift:188:        proposalsDropped: proposalsDropped, audit: nil
Sources/RielaCore/WorkflowDefinitionStore.swift:298:  public var rollbackProposalId: String?
Sources/RielaCore/WorkflowDefinitionStore.swift:318:    rollbackProposalId: String? = nil
Sources/RielaCore/WorkflowDefinitionStore.swift:337:    self.rollbackProposalId = rollbackProposalId
Sources/RielaCore/WorkflowDefinitionStore.swift:510:      try guardRollback(workflowName: write.workflowName, proposalId: write.rollbackProposalId, in: transaction)
Sources/RielaCore/WorkflowDefinitionStore.swift:583:      if let proposalId = write.rollbackProposalId {
Sources/RielaCore/WorkflowDefinitionStore.swift:592:      let fileOperation = Self.isFileDerived(write)
Sources/RielaCore/WorkflowDefinitionStore.swift:712:      try guardRollback(workflowName: workflowName, proposalId: nil, in: transaction)
Sources/RielaCore/WorkflowDefinitionStore.swift:778:  public static func isFileDerived(_ write: WorkflowDefinitionWrite) -> Bool {
Sources/RielaCore/WorkflowDefinitionStore.swift:785:  func guardRollback(workflowName: String, proposalId: String?, in database: SQLiteDatabase) throws {
Sources/RielaCore/WorkflowDefinitionStore+FileChanges.swift:11:  public func isChangeComplete(workflowName: String, operation: WorkflowDefinitionOperation,
Sources/RielaCore/WorkflowDefinitionStore+FileChanges.swift:28:  public func recordAuditOnlyChange(workflowName: String, operation: WorkflowDefinitionOperation, reason: String,
Sources/RielaCore/WorkflowDefinitionStore+FileChanges.swift:67:  public func latestVersion(workflowName: String, documentDigest: String) throws -> WorkflowDefinitionVersion? {
Sources/RielaCore/WorkflowDefinitionStore+FileChanges.swift:74:  public func audit(forVersionId versionId: String) throws -> WorkflowDefinitionAuditRecord? {
Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift:125:  public static let schemaGeneration: Int64 = 13
Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift:130:  /// here for every future `schemaGeneration` bump that is allowed to migrate.
Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift:157:      try WorkflowDefinitionHistorySchema.migrateToGeneration13(in: database)
Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift:170:        currentGeneration: schemaGeneration,
Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift:182:        message: "session store schema (generation \(error.stampedGeneration)) has no migration path to generation \(schemaGeneration); delete the session store and rerun"
Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift:188:        message: "session store uses schema generation \(error.stampedGeneration); this build supports \(schemaGeneration)"
Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift:210:        db, currentGeneration: schemaGeneration, migrations: schemaMigrations
Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift:305:    let userVersion = Int(Self.schemaGeneration)
Sources/RielaCore/WorkflowRollbackProposalStore.swift:26:  public var policy: WorkflowRegressionRollbackPolicy
Sources/RielaCore/WorkflowRollbackProposalStore.swift:43:  public var policy: WorkflowRegressionRollbackPolicy
Sources/RielaCore/WorkflowRollbackProposalStore.swift:50:              policy: WorkflowRegressionRollbackPolicy, status: WorkflowRollbackProposalStatus,
Sources/RielaCore/WorkflowRollbackProposalStore.swift:59:public struct WorkflowRollbackProposalStore: Sendable {
Sources/RielaCore/WorkflowRollbackProposalStore.swift:143:  private func policyColumn(_ policy: WorkflowRegressionRollbackPolicy) -> String {
Sources/RielaCore/WorkflowRollbackProposalStore.swift:153:          let policy = WorkflowRegressionRollbackPolicy(rawValue: row.string("policy") == "approvalRequired" ? "approval-required" : row.string("policy")),
Sources/RielaCore/WorkflowDefinitionHistorySchema.swift:84:    try migrateToGeneration13(in: db)
Sources/RielaCore/WorkflowDefinitionHistorySchema.swift:87:  static func migrateToGeneration13(in db: SQLiteDatabase) throws {
Sources/RielaCore/WorkflowDefinitionHistorySchema.swift:217:    var proposalsDropped = 0
Sources/RielaCore/WorkflowDefinitionHistorySchema.swift:230:        proposalsDropped = try db.executeAndReturnChangedRowCount("""
Sources/RielaCore/WorkflowDefinitionHistorySchema.swift:238:    return proposalsDropped
Sources/RielaCore/LoopEngineeringModels.swift:3:public enum WorkflowRegressionRollbackPolicy: String, Codable, Sendable {
Sources/RielaCore/LoopEngineeringModels.swift:9:public struct WorkflowRegressionRollbackDeclaration: Codable, Equatable, Sendable {
Sources/RielaCore/LoopEngineeringModels.swift:10:  public var policy: WorkflowRegressionRollbackPolicy
Sources/RielaCore/LoopEngineeringModels.swift:12:  public init(policy: WorkflowRegressionRollbackPolicy) {
Sources/RielaCore/LoopEngineeringModels.swift:30:  public var regressionRollback: WorkflowRegressionRollbackDeclaration?
Sources/RielaCore/LoopEngineeringModels.swift:64:    regressionRollback: WorkflowRegressionRollbackDeclaration? = nil
Sources/RielaCore/LoopEngineeringModels.swift:96:    self.regressionRollback = try container.decodeIfPresent(WorkflowRegressionRollbackDeclaration.self, forKey: .regressionRollback)
```
