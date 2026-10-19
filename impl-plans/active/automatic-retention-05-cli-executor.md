# ar-05-cli-executor: policy-mode terminal retention executor (RielaCLI)

```json
{
  "planId": "ar-05-cli-executor",
  "planPath": "impl-plans/active/automatic-retention-05-cli-executor.md",
  "dependsOn": ["ar-01-core-config", "ar-02-core-planners", "ar-03-cli-reclaimer", "ar-04-cli-lock-admission"],
  "wave": 2,
  "writePaths": [
    "Sources/RielaCLI/TerminalRetentionExecutor.swift",
    "Sources/RielaCLI/TerminalRetentionMetadata.swift",
    "Sources/RielaCLI/TerminalRetentionSecondary.swift",
    "Sources/RielaCLI/TerminalRetentionPaths.swift",
    "Sources/RielaCLI/SessionRetentionTombstones.swift",
    "Sources/RielaCLI/SessionPruneCommand.swift",
    "Tests/RielaCLITests/TerminalRetentionTests.swift",
    "Tests/RielaCLITests/TerminalRetentionPolicyTests.swift",
    "impl-plans/progress/ar-05-cli-executor.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Design §3 (optional roots and `pendingRootsMismatch`), §4.1–§4.3 (results and
messages categories), §4.5 (orphan locks, via ar-04), §5.2 (bounds) and §5.3
(the reclaimer, via ar-03).

Today `TerminalRetentionExecutor.run`
(`Sources/RielaCLI/TerminalRetentionExecutor.swift:22`) works like this:

- it supports only explicit workflows and all three roots;
- it deletes messages together with results (`TerminalRetentionSecondary.deleteMessages`
  inside the transaction);
- it runs a full `VACUUM` (`TerminalRetentionSecondary.reclaim`);
- it throws `pendingRootsMismatch` for the whole run.

This plan adds a policy entry point and keeps `session prune` behavior and flags
unchanged.

Every existing safety rule stays as it is:

- sorted non-blocking member locks;
- in-transaction re-plan plus member-equality recheck;
- tombstones committed before secondary cleanup;
- `secure_delete`;
- no inference of terminal state from process absence;
- the user-memory exclusions.

Follow the shared worker protocol in `impl-plans/active/automatic-retention.md`.

## Non-goals

- No config loading, target resolution, throttle, lock/stamp, logs, CLI flags or
  triggers. Those belong to ar-06, ar-07 and ar-08.
- No artifact-root use in policy mode. Artifact roots stay `session prune` only.
- No GraphQL.

## File-level changes

### `TerminalRetentionPaths.swift`

- Change `artifactRoot` and `memoryRoot` to `String?`, with the init
  `init(sessionRoot: String, artifactRoot: String?, memoryRoot: String?)`.
- Distinctness, nesting, `/` and home checks apply only among the roots that are
  present.
- `artifactSnapshot(_:)` throws `unsafePath` when `artifactRoot` is nil. Callers
  must check for nil first.
- `memoryDatabases()` returns `[]` when `memoryRoot` is nil.

`session prune` still passes all three roots, so its behavior is unchanged.

### `TerminalRetentionMetadata.swift`

- Stop adding `workflow_messages` bytes into `payloadBytes`. Put them into
  `messageBytes`, a new field from ar-02.
- Do the same in `TerminalRetentionSecondary.decorate` for the artifact-root
  message log.
- Skip artifact scanning when `artifactRoot` is nil, and memory scanning when
  `memoryRoot` is nil.

### `SessionRetentionTombstones.swift`

- Add `ensureMessageRetentionTombstones(_ db:)` with the DDL pinned in ar-04.
- Extend `ensureSessionRetentionTriggers` with
  `retention_message_guard_<table>_<insert|update>` triggers on
  `workflow_messages` and `workflow_message_payload_index`:
  `WHEN EXISTS(SELECT 1 FROM session_message_retention_tombstones WHERE session_id=NEW.workflow_execution_id)`,
  raising `RAISE(ABORT,'workflow messages expired under retention')`. Create
  them only when the message tombstone table exists.

### `TerminalRetentionSecondary.swift`

- Replace `reclaim(_:)` with
  `RetentionSQLiteReclaimer().reclaim(databasePath:mode:)` (ar-03). Thread a
  `RetentionReclamationMode` through `clean(...)`. `session prune` uses
  `.manual`.
- Collect the `RetentionReclamationResult` values instead of throwing. Delete
  the `reclamationBusy` throw path and the `checkpoint` helper.
- `clean` reclaims each touched memory DB once.

### `TerminalRetentionExecutor.swift`

**`run(...)` (session prune).** Keep the signature and keep
`TerminalRetentionReport`'s existing fields. Append
`var reclamation: [RetentionReclamationResult]` to the report; the JSON output
gains only this field. Internally it calls the shared core with:

- `scope: .workflows(...)`;
- results policy `maxAge = hours*3600, maxBytes`;
- `messages: .followResults`;
- `mode: .manual`;
- `familyLimit: .max`.

`pendingRootsMismatch` becomes a per-family protection here as well; it no
longer aborts the run.

**New policy entry point.** Pinned contract consumed by ar-07:

```swift
struct TerminalRetentionCategoryPolicy: Equatable, Sendable { var maxAge: TimeInterval?; var maxBytes: Int64? }
enum TerminalRetentionMessageMode: Equatable, Sendable {
  case followResults                                 // messages notConfigured: delete rows with pruned results
  case keepForever                                   // never delete message rows
  case independent(TerminalRetentionCategoryPolicy)  // keep rows on results pruning; run messages pass
}
struct TerminalRetentionPolicyReport: Equatable, Sendable {
  var results: RetentionCategoryReport; var messages: RetentionCategoryReport
  var orphanLocks: SessionExecutionLockRegistry.OrphanLockRemovalResult?   // filled by finalize
  var reclamation: [RetentionReclamationResult]                            // filled by finalize
}
func runPolicy(paths: TerminalRetentionPaths, keepWorkflowIds: Set<String>,
               results: TerminalRetentionCategoryPolicy?,          // nil = results inactive (keepForever or notConfigured)
               resultsState: RielaRetentionCategoryState, messages: TerminalRetentionMessageMode,
               messagesState: RielaRetentionCategoryState,
               dryRun: Bool, familyLimit: Int = 500) throws -> TerminalRetentionPolicyReport
func finalize(paths: TerminalRetentionPaths, report: inout TerminalRetentionPolicyReport,
              mode: RetentionReclamationMode, dryRun: Bool, orphanLockLimit: Int = 2000)
```

`runPolicy` steps:

1. Open the store DB. A missing DB returns inactive and zero reports. A foreign
   DB throws `foreignDatabase`. A dry run opens strictReadOnly and writes
   nothing: no tombstone tables and no triggers.
2. Run pending-cleanup recovery as today. Use
   `locks.acquire(sessionId:, allowRetired: true)`. A root mismatch (tombstone
   roots compared with `paths.artifactRoot ?? ""` and `paths.memoryRoot ?? ""`)
   marks that family protected `pendingRootsMismatch` and continues; it does not
   throw.
3. **Results.** Run only when `results != nil`. Plan with
   `.allExcept(keepWorkflowIds)` and `bytes: .results`. The per-family flow is
   today's flow with these changes:
   - lock with `acquire(sessionId:, allowMessagesRetired: true)`;
   - `SessionExecutionLockError.messagesRetired` must never become
     `executionLocked`, though it cannot occur with this option;
   - delete message rows (`deleteMessages`) only when messages are
     `.followResults`;
   - with `.keepForever` or `.independent`, leave the `workflow_messages` and
     `workflow_message_payload_index` rows in place;
   - tombstone rows store `artifact_root = paths.artifactRoot ?? ""` and
     `memory_root = paths.memoryRoot ?? ""`.
4. **Messages-only.** Run only when messages are `.independent(policy)`.
   - **Candidate families.** Plan with `.allExcept([])` and `bytes: .messages`,
     then take `plan.eligible` (ar-02) as the family candidates, not
     `plan.selected`. The planner's `selected` is computed over family bytes
     only and cannot see orphan bytes. `eligible` already excludes protected
     families and families with `messageBytes == 0`.
   - **Orphan sets.** When `workflow_messages` has a `created_at` column and the
     `session_retention_tombstones` table exists, query
     `SELECT workflow_execution_id, max(created_at), sum(length(CAST(payload_json AS BLOB))+length(CAST(artifact_refs_json AS BLOB)))`
     for ids present in `session_retention_tombstones`.
   - **Selection.** Merge `plan.eligible` families and orphan sets into one list
     ordered by `(age date, id)`. A family's age date is its `updatedAt`; an
     orphan set's is its newest `created_at`. Select by `maxAge` OR cap
     pressure, where the cap total is the families' message bytes
     (`beforeBytes` for `.messages`) plus orphan bytes. Stop at `familyLimit`,
     which counts both kinds. Report `workLimitReached`.
   - **Family candidates.** Lock members with
     `acquire(sessionId:, allowMessagesRetired: false)`, so a family already
     retired is skipped as protected `messagesAlreadyRetired`. Inside
     `db.transaction`, re-plan and check member equality as the results path
     does, except that the family must still be in `currentPlan.eligible` (same
     ids, equal member metadata), not in `currentPlan.selected`. Then call `ensureMessageRetentionTombstones` and the triggers. Then
     delete the message rows for every member and insert one tombstone row per
     member with that member's message bytes.
   - **Orphan sets.** Lock with `acquire(sessionId:, allowRetired: true)`.
     Inside the transaction, re-check that the results tombstone exists, then
     delete the rows.
   - Report `orphanSessionCount`.
5. **`followResults` accounting.** The `messages` report has state
   `notConfigured`, but `removedCount` and `removedBytes` reflect the message
   rows deleted together with results. Compute them from the families' `messageBytes`.
   Bytes are never under-reported.
6. **Category reports.** Fill `RetentionCategoryReport` for each category:
   - `selected*` comes from the plan, `removed*` from what actually committed;
   - in a dry run, `removed*` is 0;
   - `protected` holds reason counts, `protectedFamilies` the first 50 by rootId;
   - `capAchieved` is nil when there is no cap;
   - `pendingCleanupCount` as today.

   An inactive category uses `RetentionCategoryReport.inactive(state)`.

`finalize` steps:

- In a dry run it only counts orphan lock candidates.
- Otherwise it calls `SessionExecutionLockRegistry(sessionStoreRoot:).removeOrphanLocks(limit:dryRun:sessionExists:)`
  (ar-04). `sessionExists` queries `cli_workflow_sessions` and
  `workflow_runtime_snapshots` by id. A row in `session_retention_tombstones`
  counts as absent.
- Then it reclaims the store DB and appends the result. Memory DB results come
  from `clean`.

### `SessionPruneCommand.swift`

Keep the flags unchanged. Pass the non-optional roots through. Its JSON gains
only `reclamation`.

## Patterns to imitate

- The current `TerminalRetentionExecutor.run`: lock ordering, `defer` release,
  `db.transaction` recheck, and the `changedDuringAdmission` and
  `executionLocked` mapping.
- `finishPending` and `cleanup`.
- The `TerminalRetentionTests` fixture style.

## Pitfalls

- Never delete message rows in the results transaction unless messages are
  `.followResults`. This is the `messages.keepForever` acceptance test.
- Never use `allowRetired: true` on the results main path. That would delete a
  family that is already tombstoned twice and bypass identity reservation.
- Never count a `messagesRetired` error as `executionLocked`. The design review
  found that this would block results pruning forever.
- Message tombstone rows remain after the family's results are pruned. Do not
  delete them.
- In a dry run, never call `ensureTombstones`,
  `ensureMessageRetentionTombstones`, `ensureSessionRetentionTriggers` or the
  reclaimer, and never write lock files.
- The cap totals for results exclude message bytes; the reports carry message
  bytes separately.
- The messages-only in-transaction recheck must test membership in
  `currentPlan.eligible`, never `currentPlan.selected.contains`. `selected` is
  family-bytes-only, so a family chosen because of orphan cap pressure would be
  reported `changedDuringAdmission` on every pass and the messages cap would
  never be achieved. The results path recheck stays on `selected`.
- Real-run timestamps versus the injected clock: the protocol's fake clock is
  `Date(timeIntervalSince1970: 1_800_000_000)`, but sessions created by a real
  mock `workflow run` carry the real wall-clock `updated_at`. Never combine the
  two. Set `updated_at` explicitly for EVERY session in BOTH
  `workflow_runtime_snapshots` and `cli_workflow_sessions` (ISO8601 with
  fractional seconds, as the store writes it), relative to the injected clock,
  because metadata takes `max(updated_at)` across both tables and backdating one
  table leaves the family too young. Do the same for orphan
  `workflow_messages.created_at`. Alternatively derive the injected clock from
  the real time captured after the runs.
- The existing `TerminalRetentionTests` fixtures create a minimal
  `workflow_messages` table without `created_at`. The orphan query must check
  the columns with `db.tableColumnNames` and skip orphan handling when the column
  is missing.

## Tests

`TerminalRetentionTests`: all existing tests stay green. Update initializer calls
only where needed, and add:

- pending tombstone recorded with a different memory root -> the family is
  protected `pendingRootsMismatch` and other families are still pruned (no throw)
- `session prune` JSON contains a `reclamation` array whose actions are not
  `failed`

`TerminalRetentionPolicyTests` (new). Use the real store schema: create it by
running one mock workflow (pattern `WorkflowCommandScenarioTests.swift:58`), or
insert rows into the tables that `CLIWorkflowSessionStore` creates. Then
backdate `updated_at` (in both `workflow_runtime_snapshots` and
`cli_workflow_sessions`, for every session) and `created_at`, relative to the
injected clock, e.g. old session `now - 3 days`, kept session `now - 1 hour`. See
the real-run timestamp pitfall above.

- policy results maxAge 1d with messages `.followResults` -> old completed family
  removed, its message rows gone, and messages `removedBytes > 0` with state
  `notConfigured`
- messages `.keepForever` with results maxAge 1d -> results removed but every
  `workflow_messages` row kept; `riela session status` on the id reports it
  expired (results tombstone)
- results inactive with messages `.independent(maxAge 1d)` -> message rows
  deleted and the snapshot row kept; a message tombstone row exists; inserting a
  message row for that id fails with `workflow messages expired under retention`
- messages-retired family, then a results pass -> results pruned and not
  reported `executionLocked`; message tombstone rows still present
- a second messages pass -> the retired family is not selected and
  `workLimitReached` stays false with `familyLimit: 1` and one newer eligible
  family (the newer one is selected)
- orphan messages (results pruned with messages independent), then a messages
  pass with maxAge 1d -> orphan rows deleted and `orphanSessionCount == 1`
- messages cap with orphan bytes plus family bytes over the cap but family bytes
  alone under it -> the oldest family is still removed (not
  `changedDuringAdmission`) and the cap is achieved
- `keepWorkflowIds: ["news"]` -> that family protected `keptWorkflow`
- running, suspended, created, unresolved-lineage and execution-locked families
  with cap `maxBytes: 1` -> all protected, `capAchieved == false`, rows intact
- dry run -> rows and files unchanged, no `session_message_retention_tombstones`
  table created, no lock files created, and `selectedCount > 0`
- `familyLimit: 1` with three eligible families -> one removed and
  `workLimitReached` true
- `finalize` -> an orphan lock file for an absent id is removed, a lock for a
  present session is kept, and the reclamation result for the store DB is
  present

## Verification

1. ```
   arch -arm64 /bin/zsh -lc 'swift test --filter "TerminalRetentionTests|TerminalRetentionPolicyTests" > tmp/automatic-retention/ar-05-cli-executor/test.log 2>&1'
   ```
   Must show exitStatus 0, testsRun ≥ (pre-existing TerminalRetentionTests count
   + 14) and failureCount 0.
2. ```
   arch -arm64 /bin/zsh -lc 'swift test --filter "SessionExecutionLockTests|RetentionReclamationTests|TerminalRetentionPlanTests" > tmp/automatic-retention/ar-05-cli-executor/deps.log 2>&1'
   ```
   Must exit 0, proving the dependencies are still green.
3. ```
   arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet --no-cache Sources/RielaCLI/TerminalRetentionExecutor.swift Sources/RielaCLI/TerminalRetentionMetadata.swift Sources/RielaCLI/TerminalRetentionSecondary.swift Sources/RielaCLI/TerminalRetentionPaths.swift Sources/RielaCLI/SessionRetentionTombstones.swift Sources/RielaCLI/SessionPruneCommand.swift Tests/RielaCLITests/TerminalRetentionTests.swift Tests/RielaCLITests/TerminalRetentionPolicyTests.swift > tmp/automatic-retention/ar-05-cli-executor/swiftlint.log 2>&1'
   ```
   Must exit 0.

## Done criteria

- `grep -n "VACUUM\|wal_checkpoint(TRUNCATE)" Sources/RielaCLI/TerminalRetentionSecondary.swift Sources/RielaCLI/TerminalRetentionExecutor.swift`
  prints nothing.
- `grep -n "func runPolicy(" Sources/RielaCLI/TerminalRetentionExecutor.swift` matches.
- `grep -n "allowMessagesRetired: true" Sources/RielaCLI/TerminalRetentionExecutor.swift`
  matches.
- The progress records exist with integer fields.
