# whu-01-store-core: definition store contracts, proposal table (generation 13), head guard, completion predicate, proposal retention, loop policy field

```json
{
  "planId": "whu-01-store-core",
  "planPath": "impl-plans/active/workflow-history-unification-01-store-core.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "Sources/RielaCore/WorkflowDefinitionStore.swift",
    "Sources/RielaCore/WorkflowDefinitionStore+Retention.swift",
    "Sources/RielaCore/WorkflowDefinitionStore+FileChanges.swift",
    "Sources/RielaCore/WorkflowRollbackProposalStore.swift",
    "Sources/RielaCore/WorkflowDefinitionHistorySchema.swift",
    "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift",
    "Sources/RielaCore/LoopEngineeringModels.swift",
    "Sources/RielaCore/WorkflowLoopValidation.swift",
    "Sources/RielaCLI/RielaRetentionService.swift",
    "Sources/RielaCore/WorkflowRegistryModels.swift",
    "Tests/RielaCoreTests/WorkflowDefinitionFileChangeStoreTests.swift",
    "Tests/RielaCoreTests/WorkflowRollbackProposalStoreTests.swift",
    "Tests/RielaCoreTests/SQLiteRuntimeSchemaMigrationTests.swift",
    "Tests/RielaCoreTests/WorkflowLoopValidationTests.swift",
    "Tests/RielaCLITests/RielaRetentionServiceTests.swift",
    "Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift",
    "impl-plans/progress/whu-01-store-core.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Design §3.1 (new values), §3.3 (completion predicate, audit-only collapse),
§5.1 (policy field), §5.4 (proposal table, transitions), §5.5 (head guard,
atomic rollback write), §5.6 and QA Q7 (proposal pruning). Every later plan
builds on the API pinned below. Follow the execution protocol in
`impl-plans/active/workflow-history-unification.md`.

Current code to imitate:

- `WorkflowDefinitionStore.swift:5-36` holds the operation, actor and
  evidence enums, and `:276` holds `WorkflowDefinitionWrite`.
- `commit` (around `:495-620`) runs one transaction: head read →
  `expectedCurrentVersionId` CAS (`staleHead`) → engine write → version,
  audit and head rows → `deleteDroppedVersionsAndOrphanAudit`.
- `WorkflowDefinitionHistorySchema.swift`:
  - `create(in:)` at `:73`;
  - `withGuardedDelete` at `:189`;
  - `deleteDroppedVersionsAndOrphanAudit` at `:195`, the single deletion
    path used by commit, prune, purge, migration and
    `RielaRetentionService` (gc / automatic retention);
  - `protectedHistoryVersions` at `:216`.
- `WorkflowDefinitionStore+Retention.swift:234-284`
  (`insertRetentionAudit`) is the audit-only row shape: `version_id =
  previous_version_id = head`, `diff_json` `[]`, `approval_state
  'applied'`.
- Schema generation 12 is set at
  `SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift:124`, with
  the migration list at `:136-154`.
- `WorkflowLoopMetadata` is defined at `LoopEngineeringModels.swift:3-40`
  (explicit `CodingKeys`). Validation is in `WorkflowLoopValidation.swift`;
  the `selfEvolution` block at `:142-160` and the raw notifications block at
  `:198` are the pattern.

## Non-goals

- No registry, coordinator, CLI command, GraphQL or web changes.
- No sync logic. whu-05 owns it; this plan only provides store primitives.
- Do not bump the RielaMemory schema and do not edit `Packages/RielaMemory`.
- Do not change `createGeneration10DefinitionSchema` or the generation-11
  migration bodies.

## Pinned API (consumed by whu-05/06/07/08/10)

```swift
// WorkflowDefinitionOperation += registryWrite, registryDelete, snapshotRestore, selfImprove, rollback
// WorkflowDefinitionActorKind += system
// WorkflowDefinitionEvidenceKind += fileTransaction, baselineTransaction, bundleSnapshotBefore, bundleSnapshotAfter, rollbackProposal
//   WorkflowDefinitionEvidenceRef.parse(_:) (user-supplied tokens) keeps accepting ONLY session|stepExecution|review;
//   Codable decode of stored rows accepts all kinds.
// WorkflowDefinitionWrite += rollbackProposalId: String? = nil   (init parameter defaulted; existing call sites unchanged)
// WorkflowDefinitionStoreError.Code += rollbackInProgress = "definition_rollback_in_progress",
//                                      rollbackProposalNotPending = "rollback_proposal_not_pending"
public enum WorkflowRegressionRollbackPolicy: String, Codable, Sendable { case manual; case approvalRequired = "approval-required"; case automatic }
public struct WorkflowRegressionRollbackDeclaration: Codable, Equatable, Sendable { public var policy: WorkflowRegressionRollbackPolicy }
// WorkflowLoopMetadata += regressionRollback: WorkflowRegressionRollbackDeclaration?  (CodingKey "regressionRollback")

// WorkflowDefinitionStore+FileChanges.swift
public enum WorkflowDefinitionAuditOnlyOutcome: Equatable, Sendable { case recorded(WorkflowDefinitionAuditRecord); case collapsed(auditId: String); case noHead }
extension WorkflowDefinitionStore {
  public func isChangeComplete(workflowName: String, operation: WorkflowDefinitionOperation,
                               transactionId: String, documentDigest: String?) throws -> Bool
  public func recordAuditOnlyChange(workflowName: String, operation: WorkflowDefinitionOperation, reason: String,
                                    evidence: [WorkflowDefinitionEvidenceRef], actor: WorkflowDefinitionActor) throws -> WorkflowDefinitionAuditOnlyOutcome
  public func latestVersion(workflowName: String, documentDigest: String) throws -> WorkflowDefinitionVersion?
  public func audit(forVersionId versionId: String) throws -> WorkflowDefinitionAuditRecord?   // the audit row whose version_id = versionId and previous != versionId
}

// WorkflowRollbackProposalStore.swift
public enum WorkflowRollbackProposalStatus: String, Codable, Sendable { case recorded, pending, applying, applied, rejected, superseded, failed; public var isTerminal: Bool }
public enum WorkflowRollbackMode: String, Codable, Sendable { case store, bundle }
public struct WorkflowRollbackRegressionEntry: Codable, Equatable, Sendable { public var kind: String; public var gateId: String?; public var detail: String }
public struct WorkflowRollbackProposal: Codable, Equatable, Sendable {
  proposalId, workflowName, regressedVersionId, rollbackToVersionId: String; mode: WorkflowRollbackMode; bundleSnapshotId: String?
  baselineSessionId, targetSessionId: String; regressions: [WorkflowRollbackRegressionEntry]; policy: WorkflowRegressionRollbackPolicy
  status: WorkflowRollbackProposalStatus; claimTransactionId: String?; claimedAt: Date?
  createdActor: WorkflowDefinitionActor; decidedActor: WorkflowDefinitionActor?; decisionReason: String?
  appliedVersionId, appliedAuditId, failureCode: String?; diagnostics: [String]; createdAt, updatedAt: Date
}
public struct WorkflowRollbackProposalDraft: Sendable { /* the creation fields; status is .recorded or .pending */ }
public struct WorkflowRollbackProposalStore: Sendable {
  public init(rootDirectory: String, now: @escaping @Sendable () -> Date = Date.init)
  public func insertIfAbsent(_ draft: WorkflowRollbackProposalDraft) throws -> (proposal: WorkflowRollbackProposal, created: Bool)
  public func proposal(id: String) throws -> WorkflowRollbackProposal?
  public func list(workflowName: String, status: WorkflowRollbackProposalStatus?, limit: Int) throws -> [WorkflowRollbackProposal]   // newest first, limit 1...500
  public func transition(proposalId: String, from: Set<WorkflowRollbackProposalStatus>, to: WorkflowRollbackProposalStatus,
                         decidedActor: WorkflowDefinitionActor?, decisionReason: String?, failureCode: String?, diagnostics: [String]) throws -> WorkflowRollbackProposal
  public func claim(proposalId: String, expectedHeadVersionId: String, claimTransactionId: String) throws -> WorkflowRollbackProposal
}
```

- Policy storage. The SQL column stores the Swift case names
  (`manual|approvalRequired|automatic`); JSON uses the raw values.
- `claim` runs one `BEGIN IMMEDIATE`. It requires status `pending` and
  `definition_heads.current_version_id == expectedHeadVersionId`.
  - Head mismatch: it sets `superseded` and throws
    `WorkflowDefinitionStoreError(.staleHead)`.
  - Status not `pending`: it throws `rollbackProposalNotPending`.
  - Otherwise it sets `applying`, `claim_transaction_id` and `claimed_at`.

## File-level changes

1. **`WorkflowDefinitionStore.swift`.** Add the enum cases, the write field
   and the error codes above.
   - In `commit` and in the head-move function (`moveHead` / undo / redo),
     inside the existing transaction and before any write, add the
     **head guard**: if a row with `status = 'applying'` exists for this
     workflow, throw `rollbackInProgress`, unless
     `write.rollbackProposalId` equals that row's `proposal_id`. Guard the
     query with `tableExists("definition_rollback_proposals")`.
   - When `write.rollbackProposalId != nil`, in the same transaction after
     the version and audit insert:

     ```
     UPDATE definition_rollback_proposals
     SET status='applied', applied_version_id=?, applied_audit_id=?, updated_at=?
     WHERE proposal_id=? AND status IN ('pending','applying')
     ```

     If 0 rows change, throw `rollbackProposalNotPending`. The whole commit
     then rolls back.
   - **`last_file_version_id` rule** (design §3.3: file-derived writes move
     it). Find where `commit` currently decides to move it (the
     `seed | import | forceUpdate` set). Extend that set to
     `registryWrite | snapshotRestore | selfImprove`, plus `rollback` only
     when the write's evidence contains a `fileTransaction` ref (bundle
     mode). A store-mode `rollback`, `update`, `updatePrompt`, `restore`,
     `undo` and `redo` never move it. Expose the rule as
     `public static func isFileDerived(_ write: WorkflowDefinitionWrite) -> Bool`
     on `WorkflowDefinitionStore`, which whu-05 reuses.
2. **`WorkflowDefinitionStore+FileChanges.swift` (new).** Implement the
   four functions.
   - `isChangeComplete` is design §3.3:
     - (a) an audit row exists with `workflow_name`, `operation = op` and
       `EXISTS(SELECT 1 FROM json_each(evidence_refs_json) WHERE
       json_extract(value,'$.kind')='fileTransaction' AND
       json_extract(value,'$.id')=?)`;
     - (b) `op != .rollback`, `documentDigest != nil` and the current
       head's `documentDigest == documentDigest`.
   - `recordAuditOnlyChange`:
     - no head → `.noHead`;
     - an audit-only row (`version_id = previous_version_id`) with the
       same `operation` already exists for the current head `version_id` →
       `.collapsed`;
     - otherwise insert using the `insertRetentionAudit` shape, with
       evidence as given and `diff_json = '[]'`.
   - `reason` must be non-empty after trimming (`reasonRequired`).
3. **`WorkflowRollbackProposalStore.swift` (new).** Holds the models and
   the store above. Open the database the way `WorkflowDefinitionStore`
   does (`openDatabase`).
4. **`WorkflowDefinitionHistorySchema.swift`.**
   - **`migrateToGeneration13(in:)`** creates
     `definition_rollback_proposals` with the exact DDL in design §5.4,
     including the `applying` status and the `claim_transaction_id` /
     `claimed_at` columns. It also creates the indexes
     `definition_rollback_proposals_workflow_status(workflow_name, status, created_at)`
     and the partial unique index
     `definition_rollback_proposals_one_applying ON (workflow_name) WHERE status='applying'`.
     All statements use `IF NOT EXISTS`.
   - **`create(in:)`** calls the same DDL at its end.
   - **`protectedHistoryVersions`** also unions the `history_version` of
     `regressed_version_id` and `rollback_to_version_id` for proposals
     with status `pending` or `applying`, guarded by `tableExists`.
   - **`deleteDroppedVersionsAndOrphanAudit`**, after the audit delete and
     inside the same guarded block, deletes
     `definition_rollback_proposals` rows for the workflow where status is
     in (`recorded`, `rejected`, `applied`, `superseded`, `failed`) and
     neither version id is in `definition_versions`. Guard it with
     `tableExists`: the generation-11 migration calls this function before
     the table exists. Return or accumulate `proposalsDropped`.
5. **`SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift`.**
   Set `schemaGeneration = 13` and update the doc comment ("Generation 13
   adds rollback proposals"). Append
   `SQLiteSchemaMigration(fromGeneration: 12) { try WorkflowDefinitionHistorySchema.migrateToGeneration13(in: $0) }`.
6. **`WorkflowDefinitionStore+Retention.swift` and
   `Sources/RielaCLI/RielaRetentionService.swift`.** The prune and purge
   result types and `RielaRetentionDefinitionReport` gain
   `proposalsDropped: Int`, decoded with a default of 0 where those types
   decode persisted JSON.
   - `RielaRetentionService.pruneDefinitions`
     (`RielaRetentionService.swift:346-370`) **must accumulate**
     `report.proposalsDropped += result.proposalsDropped` next to the other
     counters. This is the gc / automatic-retention path required by Q7
     (WHU-R5-04).
   - In dry run (`request.dryRun`), the prune result reports the
     proposals that would be dropped without deleting them, mirroring how
     `removedVersionIds` behaves in dry run.
5b. **`Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift`** (checkpoint
   amendment, integration finding WHU-INT-01). The assertions at `:36` and
   `:61` compare `PRAGMA user_version` with the literal `"11"`, which was
   already stale at baseline generation 12. Replace both literals with
   `"\(SQLiteWorkflowRuntimePersistenceStore.schemaGeneration)"`, the
   pattern at `WorkflowDefinitionRetentionTests.swift:425`. Do not delete or
   weaken the assertions, and make no other change to this file.
   - **Resume.** Resume from the preserved partial whu-01 edits, using the
     current file hashes as the pre-edit baseline. Do not revert them.
   - **Remaining scope** from the first dispatch:
     - `WorkflowRollbackProposalStore.swift`;
     - `WorkflowRollbackProposalStoreTests.swift`;
     - the 12→13 migration test in `SQLiteRuntimeSchemaMigrationTests`;
     - the rejected-proposal commit test.
6b. **`WorkflowRegistryModels.swift`.** `WorkflowRegistryErrorCode` gains
   `definitionSyncFailed = "definition_sync_failed"`,
   `definitionSyncPending = "definition_sync_pending"` and
   `definitionBaselineFailed = "definition_baseline_failed"`. Follow the
   raw-value style of the existing cases. whu-06 and whu-07 throw them.
7. **`LoopEngineeringModels.swift` and `WorkflowLoopValidation.swift`.**
   Add the field and `CodingKey`, and the typed and raw validation:
   - `workflow.loop.regressionRollback` must be an object;
   - `.policy` is required and must be one of `manual`,
     `approval-required` or `automatic`;
   - otherwise emit an error diagnostic with that path.

## Pitfalls

- The head guard must not block the claimed rollback write itself. It must
  also run inside the commit transaction, not before it, or a race opens.
- Proposal pruning must be in the shared deletion function so that
  per-commit retention, `prune`, `purge-history` and `riela gc` all prune
  (Q7). Never delete `pending` or `applying` rows.
- Do not add delete triggers to the proposal table.
- `transition` is a CAS: `UPDATE … WHERE proposal_id=? AND status IN
  (from)`. Zero rows → `rollbackProposalNotPending`.
- `recorded` can never transition.
- Keep `parse(_:)` closed to the three user kinds. Runtime code constructs
  `WorkflowDefinitionEvidenceRef(kind:id:)` directly.

## Tests (`input → expected`)

`WorkflowDefinitionFileChangeStoreTests`:

- An audit with `operation=selfImprove` and `fileTransaction:T` →
  `isChangeComplete(selfImprove, T, d)` is true. The same transaction id
  queried with `registryWrite` → false.
- A baseline `import` row with `baselineTransaction:T` and a head digest
  different from `d` → false (the D3-001 negative case).
- Head digest == `d`, op `selfImprove`, no audit → true (predicate (b)).
  The same situation with op `rollback` → false.
- `recordAuditOnlyChange` called twice for the same head and op →
  `.recorded`, then `.collapsed`. A different op → `.recorded`. No head →
  `.noHead`.
- An `applying` proposal P exists:
  - a `commit` with no `rollbackProposalId` → `definition_rollback_in_progress`
    and no rows written;
  - a commit with `rollbackProposalId = P` and the matching expected head →
    succeeds, and P becomes `applied` with ids;
  - undo → `definition_rollback_in_progress`.
- A commit with `rollbackProposalId` of a `rejected` proposal → throws, and
  the head is unchanged.
- A `selfImprove` commit → `last_file_version_id` equals the new version.
  A `rollback` commit without `fileTransaction` evidence →
  `last_file_version_id` unchanged. A `rollback` commit with
  `fileTransaction` evidence → moved.

`WorkflowRollbackProposalStoreTests`:

- `insertIfAbsent` twice for the same (workflow, regressed) → the second
  call returns `created=false` and the same id.
- `claim`:
  - head == expected and status pending → `applying`;
  - head moved → `superseded` and `staleHead`;
  - status `rejected` → not pending.
- A second `applying` row for the same workflow is rejected by the unique
  index.
- `transition` CAS failure → `rollback_proposal_not_pending`.
- Retention with window 2: a terminal proposal whose two versions are
  dropped is deleted (`proposalsDropped == 1`). A `pending` proposal
  survives, and its versions are still present.
- `prune` and `purgeHistory` also delete terminal orphaned proposals.

`RielaRetentionServiceTests`. Add a case to the existing file, imitating
its existing definition-retention cases (Q7 gc path, WHU-R5-04).

Setup: a temp store with workflow W and enough versions that versions
v1/v2 fall outside `keepVersions`. It holds:

- a `rejected` proposal referencing v1→v2;
- a `pending` proposal referencing two other old versions v3→v4.

Running the retention service (gc / automatic trigger) with definitions
configured gives:

- the rejected row deleted, and
  `report.definitions.proposalsDropped == 1`;
- the pending row still present, with v3 and v4 still retained (pinned).

The same run with `dryRun: true` gives `proposalsDropped == 1` and both
rows still present.

`SQLiteRuntimeSchemaMigrationTests`:

- A generation-12 database with definition rows opens at 13 with the
  proposal table, and all existing rows are intact.
- A fresh database has the table.

`WorkflowLoopValidationTests`:

- `{"regressionRollback":{"policy":"approval-required"}}` → valid and
  decodes to `.approvalRequired`.
- `"policy":"auto"` → an error at `workflow.loop.regressionRollback.policy`.
- A missing `policy` → an error.

## Verification (logs under `tmp/workflow-history-unification/whu-01/`)

- `arch -arm64 /bin/zsh -lc 'swift build' > tmp/workflow-history-unification/whu-01/build.log 2>&1; echo exit=$?`
  → `exit=0`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowDefinitionFileChangeStoreTests|WorkflowRollbackProposalStoreTests|SQLiteRuntimeSchemaMigrationTests|WorkflowLoopValidationTests|WorkflowLoopMetadataCodableTests|LoopEngineeringModelsTests|WorkflowDefinitionStoreTests|WorkflowDefinitionRetentionTests|WorkflowDefinitionSessionPinTests|RielaRetentionServiceTests"' > tmp/workflow-history-unification/whu-01/tests.log 2>&1; echo exit=$?`
  → `exit=0`. The log shows `Executed N tests, with 0 failures` and the
  new test classes appear in the log.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet <each owned .swift file>'`
  → exit 0.

## Done criteria

- [ ] All pinned symbols exist with the exact names and shapes above. The
      progress log lists `rg -n` lines for each.
- [ ] `schemaGeneration == 13`, with a migration from 12.
- [ ] The tests above pass, and the build and swiftlint exit 0.
- [ ] The progress log records hashes, commands, exit codes and log paths.
