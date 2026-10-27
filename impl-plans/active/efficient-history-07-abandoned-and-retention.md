# eh-07-abandoned-and-retention: abandoned nested invocations, retention over the new tables, bounded run-end vacuum

```json
{
  "planId": "eh-07-abandoned-and-retention",
  "planPath": "impl-plans/active/efficient-history-07-abandoned-and-retention.md",
  "dependsOn": ["eh-05-session-rows"],
  "wave": 3,
  "writePaths": [
    "Sources/RielaCLI/SessionReconcileCommand.swift",
    "Sources/RielaCLI/SessionAbandonedInvocationReconciler.swift",
    "Sources/RielaCLI/TerminalRetentionIndexes.swift",
    "Sources/RielaCLI/TerminalRetentionMetadata.swift",
    "Sources/RielaCLI/TerminalRetentionExecutor.swift",
    "Sources/RielaCLI/SessionRetentionTombstones.swift",
    "Sources/RielaCLI/AutomaticRetentionHook.swift",
    "Sources/RielaCLI/RunEndStorageMaintenance.swift",
    "Tests/RielaCLITests/SessionReconcileCommandTests.swift",
    "Tests/RielaCLITests/SessionAbandonedInvocationTests.swift",
    "Tests/RielaCLITests/TerminalRetentionTests.swift",
    "Tests/RielaCLITests/RetentionReclamationTests.swift",
    "Tests/RielaCLITests/RunEndStorageMaintenanceTests.swift",
    "impl-plans/progress/eh-07-abandoned-and-retention.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Design §5 ("Run end"), §6, §7 and QA Q1/Q7.

In production, 383 families were protected forever by
`unsettledNestedInvocation`, because cancelled or crashed runs never settle
their nested rows.

Current code:

- **Settled predicate.**
  `TerminalRetentionIndexes.settled = "(child_terminal_json IS NOT NULL AND
  parent_message_json IS NOT NULL AND recovery_reason IS NULL)"`
  (`TerminalRetentionIndexes.swift:16`). The validity check also requires
  that both sessions exist and that the parent link matches
  (`TerminalRetentionMetadata.swift:37-56`).
- **Reconcile.** `SessionReconcileCommand.swift` handles only `running`
  sessions: a free flock through `SessionExecutionLockRegistry.acquire`
  means orphaned, and `--apply` marks the session `cancelled` (`:65-188`).
- **Deletes.** `TerminalRetentionExecutor.swift:369-389, 578-585` deletes
  snapshots, CLI rows, baselines and nested rows by child.
- **Tombstone triggers.** `SessionRetentionTombstones.swift` guards inserts
  for retired IDs.
- **Run-end hook.** `AutomaticRetentionHook.runIfApplicable`
  (`AutomaticRetentionHook.swift:70-82`) runs only when a retention policy
  is configured.
- **eh-05 (accepted before this wave).** It created
  `workflow_runtime_executions` (FK cascade from snapshots),
  `workflow_runtime_payloads(root_session_id, digest)`,
  `workflow_nested_invocation_refs` and
  `workflow_nested_invocations.abandoned_at`.

## Non-goals

- No new deletion without config. Invariant 1 of
  `design-automatic-retention.md` stays: no config, no deletion. The
  run-end work is only a bounded `incremental_vacuum`.
- Never touch `suspended` sessions, and never touch rows whose locks are
  held.
- No change to `RetentionSQLiteReclaimer.swift`.

## Pinned contract (eh-10 depends on it)

```swift
struct SessionAbandonedInvocationReconciler {
  init(registry: SessionExecutionLockRegistry, now: @escaping () -> Date = Date.init)
  func run(sessionStoreRoot: String, abandonedAfter: TimeInterval, apply: Bool) throws -> [SessionNestedInvocationVerdict]
}
struct SessionNestedInvocationVerdict: Codable, Equatable { invocationKey: String; parentSessionId: String?; childSessionId: String?
  verdict: String /* abandoned|live|recent|skipped */; applied: Bool; reason: String? }
enum RunEndStorageMaintenance { static func run(sessionStoreRoots: [String]) -> [String] /* warnings */ }
```

New CLI flag: `riela session reconcile … [--abandoned-after-hours <h>]`
(default 24, range 1...8760). The output gains
`nestedInvocations: [SessionNestedInvocationVerdict]`.

## File-level changes

- **`SessionAbandonedInvocationReconciler.swift` (new).** A candidate row is
  unsettled by the predicate in `TerminalRetentionIndexes.settled` and has
  `abandoned_at IS NULL`. It is **abandoned** when all of these hold:
  - the parent snapshot status is `completed|failed|cancelled`;
  - the child is terminal, absent or `created`;
  - the row's `updated_at` and the parent's `updatedAt` are both older than
    `now - abandonedAfter`;
  - the parent and child locks are both acquired non-blocking.

  Steps:
  1. Lock the parent, then the child, sorted by ID to avoid deadlock.
  2. Inside `BEGIN IMMEDIATE`, re-check every condition.
  3. When `apply` is set:
     - set `abandoned_at = now` (ISO8601 with fractional seconds, like the
       store's `updated_at`);
     - for a `created` child, save it as `cancelled` with
       `failureReason = "reservation abandoned; reconciled by riela session reconcile"`,
       through the same CLI-record-plus-canonical save that reconcile uses.
  4. Release the locks.

  Verdicts: a held lock → `live`; too new → `recent`; a save or guard
  rejection → `skipped` with the reason.
- **`SessionReconcileCommand.swift`.**
  - Parse `--abandoned-after-hours`.
  - Run the existing running-session step first, then the reconciler with
    the same `apply`.
  - Add `nestedInvocations` to the JSON and text output. The exit code
    rules are unchanged.
- **`TerminalRetentionIndexes.swift`.**
  - `settled` becomes `(<existing>) OR abandoned_at IS NOT NULL`. Guard it
    with a `PRAGMA table_info` check so a pre-11 database still works.
  - Payload byte expressions add `SUM(byte_count)` from
    `workflow_runtime_payloads` per root.
- **`TerminalRetentionMetadata.swift`.**
  - An abandoned row with an absent child does not mark the family
    `unsettledNestedInvocation`.
  - Family `payloadBytes` include the payload bytes of that root, counted
    once per family, not per session.
- **`TerminalRetentionExecutor.swift`.**
  - When a whole family is deleted, also delete
    `workflow_runtime_payloads WHERE root_session_id = <family root>` and
    `workflow_nested_invocation_refs` for the deleted invocation keys.
  - Execution rows go by cascade. Verify `foreign_keys=ON` on the
    executor's connection, or delete them explicitly.
  - Apply the same changes in the pending-cleanup recovery path.
- **`SessionRetentionTombstones.swift`.** Insert guards for retired session
  IDs on `workflow_runtime_executions` (keyed by `workflow_execution_id`).
  Payload rows are keyed by root, and a retired root's family is fully
  retired, so guard them by root through
  `session_retention_tombstones.session_id = root_session_id`.
- **`RunEndStorageMaintenance.swift` (new).** For each runtime database path:
  - open it with the writable runtime options;
  - when `PRAGMA auto_vacuum = 2` and `freelist_count > 0`, run
    `PRAGMA incremental_vacuum(min(freelist_count, 4096))` and then
    `wal_checkpoint(PASSIVE)`;
  - catch every error and turn it into a warning line prefixed
    `riela retention warning:`.
- **`AutomaticRetentionHook.swift`.**
  - In `runIfApplicable`, after the `applies(...)` gate and independent of
    whether a policy exists, call `RunEndStorageMaintenance.run` for the
    explicit, project and user session stores that the existing `request(...)`
    resolves.
  - stdout and the exit code must stay unchanged (safety invariant 5).
  - Append its warnings to the returned list.

## Pitfalls

- `created` sessions waiting for a distributed worker: never cancel one
  whose lock is held or whose parent is non-terminal.
- Re-check inside the transaction, because a resumed parent might have
  just settled the row.
- **Dry run.** `apply == false` acquires and releases locks but writes
  nothing. No `abandoned_at`, no status change.
- **Deadlock.** Acquire locks in sorted-ID order.
- **Byte accounting.** Payload bytes are per family. Do not double count
  them per member session.

## Tests

`SessionAbandonedInvocationTests.swift`:

- A failed parent with a `running`-row nested invocation, an absent child,
  and an age of 25 hours → `--apply` sets `abandoned_at`, and a dry-run
  prune (`TerminalRetentionPlan`) then shows the family eligible: not
  protected by `unsettledNestedInvocation`.
- The same with an age of 1 hour → `recent`; nothing is written.
- The parent lock held by a test registry → `live`; the row is
  byte-identical.
- A `created` child under an abandoned row → becomes `cancelled` with the
  reason.
- A `suspended` child → the row is skipped and the child is untouched.
- A dry run → no writes; the database checksum is unchanged.

Existing and extended suites:

- `SessionReconcileCommandTests`: the existing cases still pass; the
  `nestedInvocations` JSON is present.
- `TerminalRetentionTests`: prune of a family with execution rows and
  payloads deletes all of them, `reclamation.reclaimedBytes > 0` on an
  INCREMENTAL store, and the file shrinks.
- `RetentionReclamationTests`: unchanged expectations, plus a check that a
  fresh store is INCREMENTAL.
- `RunEndStorageMaintenanceTests`: a fresh store with freed pages and no
  retention config → after the hook, `freelist_count` is lower, stdout is
  empty and the exit code is unchanged. A NONE store → no vacuum and no
  error.

## Verification

```
arch -arm64 /bin/zsh -lc 'swift test --filter "SessionAbandonedInvocationTests|SessionReconcileCommandTests|TerminalRetentionTests|TerminalRetentionPolicyTests|TerminalRetentionPlanTests|RetentionReclamationTests|RunEndStorageMaintenanceTests|AutomaticRetentionTests|SessionMessageRetentionAdmissionTests"' > tmp/efficient-history/eh-07-abandoned-and-retention/test.log 2>&1; echo $?
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache <owned Swift files>'
```

Expected: exit 0, with every suite executed.

## Done criteria

- [ ] `grep -n "abandoned_at IS NOT NULL" Sources/RielaCLI/TerminalRetentionIndexes.swift`
      matches.
- [ ] The pinned types exist, and the reconcile flag parses (covered by a
      test).
- [ ] The listed suites pass. The progress log is complete.
