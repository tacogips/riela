# whu-07-coordinator-sync: coordinator callbacks, durable sync intents and replay, self-improve and `workflow restore` attribution

```json
{
  "planId": "whu-07-coordinator-sync",
  "planPath": "impl-plans/active/workflow-history-unification-07-coordinator-sync.md",
  "dependsOn": [],
  "wave": 3,
  "writePaths": [
    "Sources/RielaCLI/WorkflowDirectoryTransaction.swift",
    "Sources/RielaCLI/WorkflowDefinitionSyncIntentStore.swift",
    "Sources/RielaCLI/WorkflowSelfImproveVersioning.swift",
    "Sources/RielaCLI/WorkflowSnapshotService.swift",
    "Sources/RielaCLI/WorkflowDefinitionCommand.swift",
    "Tests/RielaCLITests/WorkflowCoordinatorDefinitionSyncTests.swift",
    "Tests/RielaCLITests/WorkflowSelfImproveVersioningTests.swift",
    "Tests/RielaCLITests/WorkflowVersionCommandsTests.swift",
    "Sources/RielaCLI/ParityCommands.swift",
    "impl-plans/progress/whu-07-coordinator-sync.md"
  ],
  "sharedPaths": [
    "Sources/RielaCLI/WorkflowVersionCommands.swift",
    "Sources/RielaCLI/WorkflowVersionContentDiff.swift",
    "Sources/RielaCore/WorkflowHistoryModels.swift",
    "Sources/RielaWorkflowRegistry"
  ]
}
```

The two existing test files are writable only for isolation fixes and new
cases. Existing assertions must not be weakened.

## Intent and context

Design §3.1 and §3.4 (Coordinator: durable sync intent), §3.3 (baseline),
D3-003 and D3-001. Changes committed through
`WorkflowDirectoryTransactionCoordinator` for non-registry
(project/direct) workflows each get exactly one sync. Those changes are
self-improve apply and `workflow restore`. The committed document and
attribution are made durable before publication and replayed before any
later mutation, so no committed change or its attribution is lost. Mutable
workflows go through the registry's attributed access overload (whu-06)
instead. Follow the execution protocol in the index plan.

Current code:

- `WorkflowDirectoryTransactionCoordinator.commit`:
  `WorkflowDirectoryTransaction.swift:229-420`.
  - Preflight acquires the target lock and refuses a nonterminal
    transaction (`:779-800`).
  - Phases: `committing` (`:335`) → live moved → `published` (`:358`) →
    post-commit digest check (`:361-365`) → `postCommitPublication`
    (`:367`) → operation and transaction audits (`:377-388`) → `committed`
    (`:389`) → cleanup.
  - `recover(historyRoot:target:…)`: `:447`.
- Self-improve apply: `WorkflowSelfImproveVersioning.swift:249-345`, plus
  the mutable branch in `execute` at `:100-115`.
- `WorkflowSnapshotService.restore` from whu-02. It moves the logic of the
  former `WorkflowVersionCommands.swift:225-338`.
- whu-05: `WorkflowDefinitionChangeRecording`, `WorkflowDefinitionChangeRecorder`,
  `WorkflowDefinitionSyncIntent`, `WorkflowDefinitionChangeAttribution`.
- whu-06: `withWorkflowMutationAccess(workflowId:expectedDigest:attribution:…)`.
- `riela workflow definition import`: the `.import` case in
  `WorkflowDefinitionCommand.swift`.

## Non-goals

- No registry internals; whu-06 owns them.
- No rollback evaluation; whu-08 only calls the `beforePublication` hook
  defined here.
- No GraphQL; whu-09 does that.
- No new CLI flags beyond those whu-02 added.

## Pinned API

```swift
// WorkflowDirectoryTransaction.swift
struct WorkflowDirectoryDefinitionSync {                     // internal to RielaCLI
  var recorder: any WorkflowDefinitionChangeRecording
  var workflowName: String
  var sourceScope: WorkflowScope
  var attribution: WorkflowDefinitionChangeAttribution
  var bundleSnapshotBefore: String?
  var bundleSnapshotAfter: String?
  var beforePublication: ((_ transactionId: String) throws -> Void)?   // rollback claim hook (whu-08)
}
// commit(..., definitionSync: WorkflowDirectoryDefinitionSync? = nil, ...)  — must be nil when physicalOwnershipRoot != nil (precondition failure otherwise)
// WorkflowDirectoryTransactionResult += definitionSyncOutcome: WorkflowDefinitionSyncOutcome?, definitionSyncError: String?
// WorkflowDefinitionSyncIntentStore.swift
struct WorkflowDefinitionSyncIntentStore { init(historyRoot: URL)
  func write(_ intent: WorkflowDefinitionSyncIntent) throws          // <historyRoot>/definition-sync/<tx>.json, atomic temp+rename+fsync
  func pending() throws -> [WorkflowDefinitionSyncIntent]
  func delete(transactionId: String) throws
  func replayPending(recorder: any WorkflowDefinitionChangeRecording, isCommitted: (WorkflowDefinitionSyncIntent) throws -> Bool) throws -> [WorkflowDefinitionSyncOutcome] }
// WorkflowDirectoryTransactionCoordinator.replayDefinitionSyncIntents(target:historyRoot:recorder:) throws   // takes the target lock
// WorkflowSnapshotService.restore(_:snapshotId:approved:reason:actor:attribution: WorkflowDefinitionChangeAttribution? = nil,
//                                 beforePublication: ((String) throws -> Void)? = nil, recorder: (any WorkflowDefinitionChangeRecording)? = default)
// WorkflowSelfImproveCommandResult += definitionVersionId: String?, definitionAuditId: String?, definitionSyncError: String?,
//                                     definitionWarnings: [String]?   (all nil-omitted)
// Warning text (WHU-R5-03, QA Q1 write-and-warn): "definition_overwritten_changes: <auditId>,<auditId>" whenever the sync
// outcome is .versionWritten with non-empty overwrittenAuditIds. Source: the coordinator result's definitionSyncOutcome
// (non-mutable path) or the whu-06 attributed access overload's returned outcome (mutable path).
// WorkflowRestoreCommandResult.definitionWarnings (pinned by whu-02) is filled the same way by WorkflowSnapshotService.restore.
```

## File-level changes

1. **Locked pre-publication step in `commit`.** It runs when
   `definitionSync != nil`, under the target lock, after `mutateStaging`
   has produced the staging tree and before `record.phase = .committing`.
   Check that `mutateStaging` runs before `:335`; if not, place the step
   right after `mutateStaging` within the lock. In order:
   1. `replayPending`. A failure throws
      `WorkflowRegistryError(.definitionSyncPending)` and nothing changes.
      By construction at most one intent can be pending per target, because
      every later commit replays first. Still process the list in
      transaction-audit order.
   2. `captureBaselineIfAbsent` (live directory, `bundleSnapshotBefore`).
   3. `beforePublication?(transactionId)`.
   4. `prepareIntent(stagingDirectory: staging, liveDirectory: live, …,
      expectedAfterBundleDigest)`, then write it to the intent store.
2. **After the post-commit digest check (`:361-365`).** Still locked and
   before the audits:
   - call `recorder.sync(intent)`. On success, delete the intent.
   - On failure, store the error text in the result and keep the intent.
     Never throw into the coordinator's rollback path, because the files
     are committed.
   - The coordinator then completes its normal audits and cleanup.
3. **`recover(...)`.** After its own recovery, when a recorder is
   supplied, call `replayPending`. `isCommitted(intent)` returns true when
   a transaction audit for `intent.transactionId` with outcome
   `applied|restored` exists (via `auditStore`), or when the live bundle
   digest equals `intent.expectedAfterBundleDigest`. Otherwise:
   - delete the intent without writing;
   - when `attribution.rollbackProposalId != nil`, release the claim:
     `WorkflowRollbackProposalStore.transition(from: [.applying], to:
     .pending)`, ignoring not-pending.
4. **`replayPending` per intent.**
   - Not committed → discard, as above.
   - The full whu-01 predicate `isChangeComplete(op, tx, documentDigest:
     intent.documentDigest)`, which is (a)∨(b), is true → delete the
     intent without syncing.
   - Otherwise call `recorder.sync(intent)`, which pre-checks (a) only (see
     whu-05), then delete the intent. A crash after the database commit
     therefore never duplicates rows. A baseline row (`baselineTransaction`)
     never satisfies either branch, so it never deletes a pending intent.
5. **`WorkflowSelfImproveVersioning.swift`.**
   - Build the attribution before mutation:
     - operation `selfImprove`, actor `cli` / OS user;
     - reason `self-improve change set <changeSetId>: <proposal
       rationale>`; load the change set early through
       `WorkflowChangeSetStore(root: historyRoot).loadChangeSet` using
       `WorkflowHistoryIdentityResolver.identity(for: bundle)`;
     - evidence `review:<changeSetId>` and `session:<proposal
       sourceSessionId>`.
   - **Non-mutable:** pass `definitionSync` with `bundleSnapshotBefore =
     snapshot.snapshotId`.
   - **Mutable:** call the whu-06 attributed access overload and pass
     `definitionSync: nil` to the coordinator.
   - Fill the new result fields. A sync error makes the CLI exit non-zero
     with `definition_sync_failed` in the report, while the files stay
     committed.
6. **`WorkflowSnapshotService.restore`.**
   - Attribution defaults to `snapshotRestore`, with reason `reason ??
     "restore bundle snapshot <id>"`, the given actor,
     `bundleSnapshotBefore = preRestore.snapshotId` and
     `bundleSnapshotAfter = source snapshotId`. An explicit `attribution`
     (whu-08 rollback) overrides operation, reason, evidence,
     `expectedHeadVersionId` and `rollbackProposalId`.
   - **Mutable:** the access overload with the attribution;
     `beforePublication` runs as the first statement inside the access
     body, under the registry lock and before staging publication.
   - **Non-mutable:** `definitionSync.beforePublication`.
   - Fill `definitionVersionId` and `definitionAuditId`.
   - Dry run (`approved == false`) never syncs, captures a baseline or
     calls the hook.
7. **`WorkflowDefinitionCommand.swift` `.import`.** Before the existing
   import logic, resolve the file bundle's identity and history root, then
   call `replayDefinitionSyncIntents` (the documented recovery command).

## Pitfalls

- Never re-read files to build the synced document. Always use the
  intent's `documentJSON` (D3-003).
- Never sync twice for a mutable workflow. The coordinator gets
  `definitionSync: nil` whenever `physicalOwnershipRoot != nil`.
- A sync failure must not trigger coordinator rollback or leave the
  transaction nonterminal.
- One-time runs never reach this code (Q7). Do not add a sync to
  `loop promote` or any run path.

## Tests (`WorkflowCoordinatorDefinitionSyncTests`; input → expected)

- **First use.** Self-improve on a project workflow with no head → B
  (`import`, `baselineTransaction`), then I (`selfImprove`, parent B,
  `review`, `session`, `bundleSnapshotBefore`, `fileTransaction`). The
  head digest equals the committed files.
- **Failure injection, sync fails after publication** (stub recorder
  throws on the first sync) → `definitionSyncError` set, files committed,
  intent present. The next restore (F2) on the same target first replays
  F1 with its original attribution exactly once, then records F2 with
  `parent = F1`.
- **Failure injection, crash after the database commit, before intent
  deletion** (hook) → replay deletes the intent and writes no duplicate
  row.
- **Failure injection, interruption before `published`** → recovery
  discards the intent, zero rows are written, and an `applying` claim with
  this transaction id returns to `pending`.
- **Replay failure** (store unavailable) → the next commit throws
  `definition_sync_pending`, and files and history are unchanged.
- **Import replays first.** `riela workflow definition import` with a
  pending intent → the intent is replayed before the import outcome.
- **Restore dry run** → zero definition rows and no intent file.
- **Restore with `--yes --reason r`** → `snapshotRestore` with reason `r`
  and before/after snapshot evidence.
- **Mutable self-improve** → exactly one `selfImprove` row and no
  `registryWrite` row.
- **Overwrite warning (WHU-R5-03).** A store-only `definition update` U,
  then `workflow self-improve --yes` (project workflow) → the result's
  `definitionWarnings` contains U's audit id, and text output prints the
  warning line. The same holds for a mutable workflow, and for `workflow
  restore <id> --yes` after a store-only update (`WorkflowRestoreCommandResult.definitionWarnings`).
  Without store-only changes the JSON has no `definitionWarnings` key, and
  the whu-02 golden JSON test stays green.

## Verification (logs under `tmp/workflow-history-unification/whu-07/`)

- `arch -arm64 /bin/zsh -lc 'swift build' > tmp/workflow-history-unification/whu-07/build.log 2>&1; echo exit=$?`
  → `exit=0`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowCoordinatorDefinitionSyncTests|WorkflowSelfImproveVersioningTests|WorkflowVersionCommandsTests|WorkflowVersionContentDiffTests|WorkflowDefinitionCommandTests|WorkflowSharedNodeVersioningTests"' > tmp/workflow-history-unification/whu-07/tests.log 2>&1; echo exit=$?`
  → `exit=0`.
- `swiftlint lint --quiet` on owned Swift files → exit 0.

## Done criteria

- [ ] An intent is written before publication, synced from its document,
      and deleted only after completion. Replay runs in all three places.
- [ ] All tests above pass, and the existing self-improve and version
      suites stay green.

## Operator decision (2026-11-02)

whu-07 owns `Sources/RielaCLI/ParityCommands.swift` for self-improve result fields, sync-failure exit handling and warning rendering, and runs after whu-06 so it can use whu-06's attributed `withWorkflowMutationAccess` overload.

## Operator standing directive (2026-11-02)

When an acceptance criterion needs an API-shape or naming choice that is additive and can be made inside this plan's writePaths/sharedPaths, choose the minimal additive option, record the decision in the progress file, and continue. Block only when the work truly needs a path outside this plan or contradicts the design.

## Operator amendment (2026-11-02, resume #11)

whu-06 is accepted (473c4b56). whu-07 may edit all of `Sources/RielaWorkflowRegistry` (sharedPaths). Add a registry pre-publication hook (`beforePublication`) that carries the real `replaceLocked` transaction id for rollback-claim recovery. Finish the coordinator failure-injection and replay tests (`WorkflowCoordinatorDefinitionSyncTests`), restore-warning rendering, and verification in this dispatch. This is a fresh dispatch: earlier progress entries do not count toward any continuation limit.

## Operator decision (2026-11-02, resume #13): project/direct sources

Option 1. Project-scope and direct (`--workflow-definition-dir`) workflow sources stay immutable for self-improve apply and `workflow restore`. Keep the existing rejection in `WorkflowHistoryIdentity.swift` and `WorkflowDirectoryTransaction.swift`, and keep the rejection assertions in `WorkflowSelfImproveVersioningTests` and `WorkflowVersionCommandsTests`. Drop the project/direct first-use and overwrite-warning acceptance items. Those behaviors apply to mutable (registry/user-scope) sources only. Import-replay coverage stays in scope and must be verified. This is a fresh dispatch: earlier progress entries do not count toward any continuation limit.
