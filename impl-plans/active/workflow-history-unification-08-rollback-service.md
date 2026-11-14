# whu-08-rollback-service: regression evaluation, proposals, store-mode and bundle-mode apply, recovery, post-run hook, Q7 regression test

```json
{
  "planId": "whu-08-rollback-service",
  "planPath": "impl-plans/active/workflow-history-unification-08-rollback-service.md",
  "dependsOn": [],
  "wave": 4,
  "writePaths": [
    "Sources/RielaCLI",
    "Tests/RielaCLITests/LoopRegressionRollbackTests.swift",
    "Tests/RielaCLITests/WorkflowHistoryBoundedStorageTests.swift",
    "Sources/RielaCore/LoopEngineeringModels.swift",
    "Sources/RielaCore/LoopRegressionVerdict.swift",
    "Sources/RielaCore/WorkflowDefinitionHistorySchema.swift",
    "Sources/RielaCore/WorkflowDefinitionStore+FileChanges.swift",
    "Sources/RielaCore/WorkflowDefinitionStore+Retention.swift",
    "Sources/RielaCore/WorkflowDefinitionStore.swift",
    "Sources/RielaCore/WorkflowLoopValidation.swift",
    "Sources/RielaCore/WorkflowRollbackProposalStore.swift",
    "Sources/RielaWorkflowRegistry",
    "Tests/RielaCLITests/WorkflowCoordinatorDefinitionSyncTests.swift",
    "Tests/RielaCLITests/WorkflowMutableRegistryTests.swift",
    "Tests/RielaCLITests/WorkflowRegistryDefinitionSyncTests.swift",
    "Tests/RielaCoreTests/WorkflowDefinitionFileChangeStoreTests.swift",
    "Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift",
    "Tests/RielaCoreTests/WorkflowRollbackProposalStoreTests.swift",
    "impl-plans/progress/whu-08-rollback-service.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Design §5.1-§5.7 (C), D3-002, and QA Q2/Q4/Q5/Q6/Q7. A regression verdict
on an improvement version produces a bounded, idempotent proposal to roll
back to the version's parent. Policies are manual, approval-required and
automatic. Apply happens in one of two modes:

- **store mode:** one atomic transaction;
- **bundle mode:** a snapshot file restore under the claim protocol.

This plan exposes a service API. whu-10 builds the CLI and GraphQL
surfaces on it. Follow the execution protocol in the index plan.

Code to reuse:

- **Pair resolution.** `LoopCommandRunner().resolveBaselinePair(workflowId:parsed:)`
  (`LoopBaselineCommands.swift:296`, internal, same module) with
  `LoopCommandRunner.ParsedBaselineOptions(sessionId:scope:workingDirectory:sessionStore:)`.
  Do not copy it. `LoopBaselineCommands.swift` stays unchanged, and
  `loop regress` output and exit codes stay unchanged.
- **Verdict.** `LoopRegressionClassifier.verdict(base:target:requiredGateIds:)`.
- **Session load.** `CLIWorkflowSessionResolution.loadPersistedSession(sessionId:sessionStore:scope:workingDirectory:)`;
  `session.definitionSource` (`RuntimeSession.swift:434`).
- **whu-01.** `WorkflowRollbackProposalStore` (insert, claim, transition,
  list); `WorkflowDefinitionStore.latestVersion(workflowName:documentDigest:)`
  and `audit(forVersionId:)`; `WorkflowDefinitionWrite.rollbackProposalId`
  (commit sets the proposal `applied` atomically); the head guard.
- **whu-05.** `WorkflowDefinitionStoreRoots`, `WorkflowDefinitionChangeRecorder.storeRoot`,
  and the `WorkflowDefinitionService` internal helpers.
- **whu-06.** `WorkflowMutableRegistry.recoverWorkflow(workflowId:)`.
- **whu-07.** `WorkflowSnapshotService.restore(…, attribution:,
  beforePublication:)` and
  `WorkflowDirectoryTransactionCoordinator.replayDefinitionSyncIntents(target:historyRoot:recorder:)`.
- **Post-run hook site.** `dispatchLoopNotificationsAfterTerminalPersistence`
  (`WorkflowRunCommand+LoopOperations.swift:61-86`), called at
  `WorkflowRunCommand.swift:1001`. It is best effort, records diagnostics
  and never changes the outcome.

## Non-goals

- No CLI subcommands or GraphQL providers; whu-10 owns those.
- No catalog or help text.
- No change to `loop regress` or `loop baseline`.
- No automatic trigger for one-time runs (Q4, Q7).

## Pinned API (consumed by whu-10)

```swift
public enum WorkflowRegressionRollbackOutcome: String, Codable, Sendable { case noBaseline, noTargetEvidence, noRegression, targetVersionUnknown, notEligible, proposed, existing }
public struct WorkflowRegressionRollbackCheckResult: Codable, Equatable, Sendable {
  public var outcome: WorkflowRegressionRollbackOutcome; public var eligibilityCode: String?   // headMoved|notImprovementVersion|sameVersionAsBaseline|noParent
  public var regressions: [WorkflowRollbackRegressionEntry]; public var proposal: WorkflowRollbackProposal?; public var diagnostics: [String] }
public struct WorkflowRegressionRollbackError: Error, Equatable, CustomStringConvertible {
  public var code: String   // rollback_proposal_not_found | rollback_proposal_not_pending | rollback_superseded | rollback_in_progress |
                            // rollback_snapshot_unavailable | reason_required | definition_rollback_in_progress | definition_sync_failed | definition_version_not_retained
  public var message: String }
public struct WorkflowRegressionRollbackService: Sendable {
  public init(workingDirectory: String, sessionStore: String?, scope: WorkflowScope = .auto,
              environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment(),
              snapshotService: WorkflowSnapshotService = WorkflowSnapshotService(),
              mutableRegistry: WorkflowMutableRegistry = WorkflowMutableRegistry())
  public func check(workflowName: String, targetSessionId: String?, actor: WorkflowDefinitionActor) throws -> WorkflowRegressionRollbackCheckResult
  public func list(workflowName: String, status: WorkflowRollbackProposalStatus?, limit: Int) throws -> [WorkflowRollbackProposal]
  public func approve(workflowName: String, proposalId: String, reason: String?, actor: WorkflowDefinitionActor) throws -> WorkflowRollbackProposal
  public func reject(workflowName: String, proposalId: String, reason: String, actor: WorkflowDefinitionActor) throws -> WorkflowRollbackProposal
}
// WorkflowDefinitionService+Rollback.swift
// func rollback(workflowName:, toVersionId:, expectedHeadVersionId:, proposalId:, reason:, evidence:, actor:) throws -> (WorkflowDefinitionVersion, WorkflowDefinitionAuditRecord)
//   store-mode: writes the target's document as operation .rollback with rollbackProposalId + expectedCurrentVersionId, NO fileTransaction evidence.
```

## Behavior (design §5.3-§5.5)

**`check`.**

1. Resolve the pair; outcomes `noBaseline` / `noTargetEvidence`.
2. Compute the verdict. No regression → `noRegression`.
3. Resolve versions:
   - store pin → `definitionSource.versionId` in `definitionSource.storeRoot`;
   - file pin → `latestVersion(workflowName, documentDigest)` in
     `WorkflowDefinitionChangeRecorder.storeRoot(workflowName,
     sourceScope)`;
   - target not found → `targetVersionUnknown`.
4. Eligibility, in this order (the first failing code wins):
   1. `vT` is the head (`headMoved`).
   2. `vT` is an improvement version: operation `selfImprove`, or
      `update | updatePrompt` with actor `improvementNode`
      (`notImprovementVersion`).
   3. The baseline version differs from `vT` (`sameVersionAsBaseline`).
   4. A parent exists (`noParent`).
5. Mode: `selfImprove` → `bundle`, with `bundleSnapshotId` from `vT`'s
   audit `bundleSnapshotBefore` evidence. Otherwise `store`.
6. Policy: decode the **parent** version's document and use
   `runtime.workflow.loop?.regressionRollback?.policy ?? .manual`. If `vT`
   is `selfImprove` and its audit has `overwrittenChanges`, force `manual`
   and add diagnostic `divergedParent`.
7. `insertIfAbsent`, with status `recorded` (manual) or `pending`; outcome
   `proposed` or `existing`.
8. A new `automatic` proposal → `approve` with actor `system`, id
   `regression-rollback@<targetSessionId>`.

**`approve`.**

- Require a `pending` proposal. `recorded` → `rollback_proposal_not_pending`;
  `applying` → run recovery (below) first.
- Reason: `regression rollback of <vT> to <parent>: <kinds> (baseline <B>,
  target <T>)`, followed by `; approved: <reason>` when one is given.
- Evidence: `rollbackProposal:<id>`, `session:<B>`, `session:<T>`.
- **Store mode.** Head ≠ `vT` → `transition(→superseded)` and
  `rollback_superseded`. Otherwise call
  `WorkflowDefinitionService.rollback(…expectedHeadVersionId: vT,
  proposalId:)`; the proposal becomes `applied` in the same transaction.
  `staleHead` → `superseded`.
- **Bundle mode.**
  - Build the snapshot target **by name and scope**:
    `WorkflowSnapshotTargetRequest(workflowName, scope: WorkflowScope(rawValue:
    head.sourceScope) ?? .auto, workflowDefinitionDir: nil,
    workingDirectory)`. That way a mutable-registry workflow resolves with
    `provenance == .mutable`, and `WorkflowSnapshotService` takes the
    registry-locked path.
    - Never resolve by `.direct` directory: that would bypass the registry
      lock and write the registry directory directly.
    - Before restoring, require that the resolved bundle's directory
      (symlinks resolved) equals `head.sourceDirectory`. If it does not,
      the proposal fails with `rollback_snapshot_unavailable` and
      diagnostic `sourceMismatch`, and nothing changes.
  - Call `snapshotService.restore(snapshotId: bundleSnapshotId, approved:
    true, …)` with attribution `{operation: .rollback, reason, evidence,
    expectedHeadVersionId: vT, rollbackProposalId}` and `beforePublication:
    { tx in try proposals.claim(proposalId, expectedHeadVersionId: vT,
    claimTransactionId: tx) }`.
  - A claim failure maps to `rollback_superseded` /
    `rollback_proposal_not_pending` / `rollback_in_progress`. Files are
    untouched because the hook runs before publication.
  - A restore error thrown before publication: run recovery, then
    transition the proposal from `applying` (same claim id) to `failed`
    (codes `rollback_snapshot_unavailable`, `restore_dirty_conflicts`,
    `invalid_definition`) or to `pending` (any other error).
  - A result with `definitionSyncError` → return `definition_sync_failed`.
    The proposal stays `applying` until replay completes it.
  - Finally re-read the proposal. If `appliedVersionId`'s digest ≠ the
    parent digest, append diagnostic `rollbackDigestMismatch`, keeping the
    status `applied`.

**Recovery** (`recoverClaims(workflowName)`) runs at the start of `check`
and `approve`. For an `applying` proposal:

1. Run file-level recovery:
   - mutable workflow → `mutableRegistry.recoverWorkflow`;
   - otherwise → `replayDefinitionSyncIntents`.

   These complete the sync (the proposal becomes `applied` atomically) or
   discard it (the claim is released).
2. If it is still `applying` with the same `claim_transaction_id`, nothing
   committed (a crash between claim and intent/record) → CAS `applying →
   pending` on `(status, claim_transaction_id)`.

**`reject`.** The reason must be non-empty after trim (`reason_required`).
CAS `pending → rejected`. Applying → `rollback_in_progress`. It writes no
definition row.

**Post-run hook.** Add
`evaluateRegressionRollbackAfterTerminalPersistence(finalResult:loopEvidence:bundle:options:storeRoot:)`
next to the notification dispatcher, and call it right after it in
`WorkflowRunCommand.swift`. It runs only when **all** of these hold:

- `options.executionMode` is `.service`;
- `finalResult.session.definitionSource?.kind == .store`;
- `bundle.workflow.loop?.regressionRollback != nil`;
- the session is completed;
- `loopEvidence != nil`;
- a baseline exists.

It calls `check(targetSessionId: session id, actor system)`. Every error
becomes a session diagnostic, like notifications. It never changes the
outcome or exit code.

## Pitfalls

- Read the policy from the **parent** document, never from `vT` or the run
  bundle.
- Never let a rollback CAS fall back to the current head. Never treat
  overwritten changes as permission.
- One-time runs must not open definition tables. Check the conditions
  before constructing any store (Q7).
- Bundle mode for a mutable workflow: `beforePublication` runs inside the
  registry lock, which whu-07 guarantees. Do not take a second registry
  lock.

## Tests

`LoopRegressionRollbackTests`. Build fixtures like
`Tests/RielaCLITests/LoopBaselineCommandTests.swift`: sessions with loop
evidence and baselines, in temp stores.

- An improvement-node `update` version regressing (required gate
  downgrade), with `approval-required` on the parent → `proposed` /
  `pending`, mode `store`.
  - Approve → head = new `rollback` version whose digest equals the
    parent, with audit reason, evidence and actor;
    `last_file_version_id` unchanged.
  - Reject → `rejected`, no new definition row.
- Parent `manual` → `recorded`; approve → `rollback_proposal_not_pending`.
- Parent `automatic` → `applied` with actor `system`.
- `automatic` only on the regressed version → treated as `manual`.
- A second check → `existing`, no second head move.
- A regression measured on the rollback version → `notEligible` /
  `notImprovementVersion`.
- Head moved before approve → `superseded`.
- **First use** (D3-001). A mutable registry/user-scope workflow with no head, its first
  self-improvement regresses, the baseline (B) declares `approval-required`
  → a proposal with `rollbackToVersionId == B`, mode `bundle`. Approve
  restores the files to the before-snapshot, and the head digest equals
  B's digest.
- A file-origin target resolves by digest.
- **Mutable-registry `selfImprove` regression.** Approve restores through
  the registry lock: exactly one `rollback` version with
  `fileTransaction` evidence and no `registryWrite` row. A source-directory
  mismatch → `failed` / `rollback_snapshot_unavailable`, with nothing
  changed.
- **Bundle-mode interleavings** (hook seams):
  - a store-only update after the claim → `definition_rollback_in_progress`,
    head still `vT`;
  - reject before the claim → claim fails, files untouched;
  - reject during `applying` → `rollback_in_progress`;
  - two concurrent approvals (two tasks) → exactly one `rollback` version
    and one restore;
  - a crash after the claim but before publication → recovery gives
    `pending`, files unchanged;
  - a crash after publication but before the sync → recovery replays and
    gives `applied`;
  - dirty conflict → `failed`, head and files unchanged;
  - no deadlock: concurrent registry update + approve complete within a
    timeout.
- **Post-run hook.** A service run of a declaring workflow → the proposal
  is created and the run outcome is unchanged. A failing evaluation → a
  diagnostic only.

`WorkflowHistoryBoundedStorageTests` (Q7, binding). The following each
leave `definition_heads`, `definition_versions`, `definition_change_audit`
and `definition_rollback_proposals` at **0 rows** in the run's store, even
when the workflow declares `loop.regressionRollback` and a baseline exists:

- in-process `riela workflow run <named workflow> --mock-scenario`;
- the temporary-workflow forms that design §8/§9 call "`--workflow-json`".
  At `28ce6a28` the CLI has no such flag: temporary workflows are the
  positional run target, handled by
  `WorkflowRunCommand.loadTemporaryWorkflowIfPresent`
  (`WorkflowRunCommand.swift:717`) and `isTemporaryWorkflowRunTarget`
  (`RielaArgumentParser+WorkflowAndMemory.swift:249`). Exercise both
  forms:
  - `riela workflow run '<inline JSON object>'`;
  - `riela workflow run <tmp>/temp-workflow.json`.

  Record this naming in the progress log. Do not add a flag;
- `riela loop start <workflow>`.

Imitate the zero-row assertions in `WorkflowDefinitionServiceResolutionTests`.

## Verification (logs under `tmp/workflow-history-unification/whu-08/`)

- `arch -arm64 /bin/zsh -lc 'swift build' > tmp/workflow-history-unification/whu-08/build.log 2>&1; echo exit=$?`
  → `exit=0`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "LoopRegressionRollbackTests|WorkflowHistoryBoundedStorageTests|LoopBaselineCommandTests|LoopRegressionVerdictTests|LoopNotificationDispatcherTests|WorkflowDefinitionServiceResolutionTests"' > tmp/workflow-history-unification/whu-08/tests.log 2>&1; echo exit=$?`
  → `exit=0`. `LoopBaselineCommandTests` passing proves `loop regress` is
  unchanged.
- `swiftlint lint --quiet` on owned Swift files → exit 0.

## Done criteria

- [ ] The pinned service API exists, and every test above passes.
- [ ] The Q7 zero-row regression test exists and passes.
- [ ] No change to `LoopBaselineCommands.swift`, verified with
      `git diff --stat`.

## Operator standing directive (2026-11-02)

When an acceptance criterion needs an API-shape or naming choice that is additive and can be made inside this plan's writePaths/sharedPaths, choose the minimal additive option, record the decision in the progress file, and continue. Block only when the work truly needs a path outside this plan or contradicts the design.

## Operator decision (2026-11-02, resume #14)

Project-scope and direct workflow sources stay immutable for self-improve apply and `workflow restore` (whu-07 decision). The first-use and bundle-rollback coverage uses a mutable registry/user-scope workflow. whu-08 must not change `WorkflowSelfImproveVersioning.swift` to admit project/direct sources. whu-07 and whu-09 are accepted in b523407f. Also consider the two low findings from the whu-06 integration review: `MutableGeneratedWorkflowTaskRegistrar` registers with no recorder, and activation runs during recorder-less recovery. Fix them if they fall inside this plan's paths, otherwise record them as residual risks.

## Operator amendment (2026-11-02, resume #15)

whu-08 may edit all of `Sources/RielaWorkflowRegistry`, `Sources/RielaCLI/WorkflowDefinitionSyncIntentStore.swift`, `Sources/RielaCLI/ProductionNodeAdapter+WorkflowTaskAddon.swift` and their focused tests (sharedPaths). Make `releaseRollbackClaim` and `replayPending` use compare-and-swap transitions in `WorkflowRollbackProposalStore` that check both the status and the claim transaction id, and add an interleaving test proving that an older transaction's retry never releases a newer applying claim. Give `MutableGeneratedWorkflowTaskRegistrar` the production recorder. Implement the whole plan in this fresh dispatch.

## Operator amendment (2026-11-02, resume #16)

Every path in `writePaths` may be edited by this plan, including the former sharedPaths that have now been moved there. Start with the compare-and-swap in `Sources/RielaCore/WorkflowRollbackProposalStore.swift` that checks status and claim transaction id (transition, `releaseRollbackClaim`, `replayPending`) and the older-transaction interleaving test in `Tests/RielaCoreTests/WorkflowRollbackProposalStoreTests.swift`. Then implement the whole plan.

## Operator amendment (2026-11-02, resume #17): ordered kickoff

Follow the ordered checklist in `impl-plans/progress/whu-08-rollback-service.md`, which whu-08 owns. Every dispatch must change at least step 1 (the compare-and-swap on status plus claim transaction id, with its interleaving test). If the whole plan does not fit, return the partial changes with implementationIncomplete. An empty result is not acceptable. The only remaining plans are whu-08, whu-10 and whu-11; ignore older checkpoint-amendment inputs about wave 1.

## Operator amendment (2026-11-02, resume #18)

The partial whu-08 work in the tree is kept and continues from where it stopped. Remaining items:
1. bundle-mode apply with the applying claim, and crash recovery in approve/check, registry and coordinator recovery, and import;
2. automatic bundle evaluation and bundle approval;
3. the best-effort post-run hook for store-pinned service runs;
4. `WorkflowHistoryBoundedStorageTests` for Q7;
5. full policy coverage, plus the CAS interleaving test.

Report remaining work with implementationIncomplete together with changed files and plan updates. Do not list your own unfinished work as a high finding.

## Operator amendment (2026-11-02, resume #19)

Continue from the preserved tree. Remaining items:
1. generic restore error cleanup and digest diagnostics;
2. applying-claim crash recovery (approve/check, registry and coordinator recovery, import) with interruption tests;
3. the CAS interleaving test;
4. `WorkflowHistoryBoundedStorageTests` (Q7);
5. direct post-run hook tests;
6. full policy coverage.

Set implementationIncomplete=false only when all of them pass the plan gates.

## Operator amendment (2026-11-02, resume #20)

whu-08 owns the whole `Sources/RielaCLI` directory. Keep `WorkflowResolutionError.invalidWorkflow` typed through `WorkflowDirectoryTransaction.swift` (do not wrap it in CLIUsageError), so that the rollback service moves the proposal to failed with `invalid_definition`. Then make `testBundleApprovalFailsInvalidDefinitionAfterClaim` and the expanded focused filter pass, and finish the remaining items and gates.
