# ssg2-04-legacy-conversion: bounded, lock-gated, terminal-only legacy conversion

**planId**: ssg2-04-legacy-conversion
**dependsOn**: none (wave W1)
**Design**: `design-docs/specs/design-session-storage-efficiency-and-default-gc.md`
§5.3 Step 1 (queues, eligibility, outcome classes, busy list, failed map and
parked list, budgets and retry share, cursor), §9 (`RunEndStorageMaintenanceTests`
conversion cases), §12 row (d); QA Q6, Q7
**Shared rules**: `impl-plans/active/ssg2-session-storage-gc.md` → "Shared execution rules"
**Progress log**: `impl-plans/progress/ssg2-04-legacy-conversion.md` (new; do not read or continue `sgc-03`)
**Evidence root**: `tmp/ssg2/ssg2-04-legacy-conversion/`
**writePaths**: `Sources/RielaCLI/StorageMaintenanceConversion.swift` (new), `Sources/RielaCLI/StorageMaintenanceCursor.swift` (existing, untracked; preserve), `Tests/RielaCLITests/RunEndStorageMaintenanceConversionTests.swift` (new), `impl-plans/progress/ssg2-04-legacy-conversion.md`
**sharedPaths**: none

## Intent and context

Legacy rows (inline `workflow_runtime_snapshots.session_json`, full
`cli_workflow_sessions.record_json` copies, embedded nested child snapshots)
are converted today only by a manual `riela storage compact --apply`. This
plan builds the conversion step that automatic maintenance will call: a
bounded, resumable pass that only converts terminal sessions whose execution
locks are free, with a persistent cursor. Host wiring (taking
`automatic.lock`, calling this from the hook and schedulers, vacuum) is
ssg2-05.

Existing code to reuse or imitate:

- Converters (idempotent; return `false` when the row is not legacy or gone):
  `SQLiteWorkflowRuntimePersistenceStore.convertLegacySession(sessionId:)`
  (`+SessionFamily.swift:456`),
  `CLIWorkflowSessionStore.convertLegacyRecord(sessionId:)`
  (`CLIWorkflowSessionStore.swift:562`; caller holds the session lock),
  `SQLiteWorkflowRuntimePersistenceStore.convertLegacyNestedInvocation(invocationKey:)`
  (`+SessionFamily.swift:486`).
- Legacy predicates (copy them into your keyset SQL):
  `legacyInlineSessionIds` (`+SessionFamily.swift:443`):
  `json_type(session_json,'$.executions')='array' AND json_type(session_json,'$._rielaExecutionStorage') IS NULL`;
  `legacyFullRecordIds` (`CLIWorkflowSessionStore.swift:546`):
  `json_extract(record_json,'$.sessionStorage') IS NOT 'canonical'`;
  `legacyEmbeddedNestedInvocationKeys` (`+SessionFamily.swift:476`):
  `json_type(reservation_json,'$.childSnapshotStorage') IS NULL`.
- Lock loop: `Sources/RielaCLI/StorageCompactCommand.swift:convertSessionStores`
  (`SessionExecutionLockRegistry(sessionStoreRoot:)`,
  `acquire(sessionId:allowMessagesRetired: true)`, `release(sessionId:)`;
  runtime root via `canonicalRuntimeStoreRoot(sessionStoreRoot:)`).
- Lock errors: `SessionExecutionLockError` (`Sources/RielaCLI/SessionExecutionLock.swift:10-15`).
- Cursor: `Sources/RielaCLI/StorageMaintenanceCursor.swift` (already in the
  tree, untracked; preserve): `read(stateDirectory:)` returns `nil` when
  missing or invalid; `write(stateDirectory:)` writes a temp file and renames
  it.
- Status columns: `workflow_runtime_snapshots.session_status`,
  `cli_workflow_sessions.status`; nested parent/child ids as used by
  `Sources/RielaCLI/TerminalRetentionIndexes.swift`.

## Non-goals

- No edits to `RunEndStorageMaintenance.swift`, `AutomaticRetentionHook.swift`,
  RielaApp, `StorageCompactCommand.swift` or any `Sources/RielaCore` file.
- No vacuum and no `automatic.lock` handling (ssg2-05). The caller holds the
  lock; tests take it with `RetentionTargetLock.tryAcquire(stateDirectory:)`.
- No doctor output (ssg2-08).

## Contract (pinned; ssg2-05 and ssg2-08 depend on it)

New file `Sources/RielaCLI/StorageMaintenanceConversion.swift`:

```swift
struct StorageMaintenanceBudget: Equatable, Sendable { let conversions: Int; let rowsExamined: Int; let wallSeconds: TimeInterval }
enum StorageMaintenanceProfile: Sendable {
  case runEnd, scheduled
  var total: StorageMaintenanceBudget      // runEnd 16/256/2 s, scheduled 64/1024/10 s
  var retryShare: StorageMaintenanceBudget // runEnd 8/128/1 s,  scheduled 32/512/5 s
  var vacuumPageCap: Int                   // runEnd 4096, scheduled 65536 (used by ssg2-05)
}
struct StorageMaintenancePassStats: Equatable, Sendable {
  var retryConversions = 0, retryRowsExamined = 0, forwardRowsExamined = 0, converted = 0, parked = 0, skippedBusy = 0
}
enum StorageMaintenanceConversion {
  /// Caller must hold RetentionTargetLock for `stateDirectory`. Never throws; returns stderr warning lines.
  static func run(sessionStoreRoot: String, stateDirectory: String, profile: StorageMaintenanceProfile,
                  now: @escaping () -> Date = Date.init,
                  observe: ((StorageMaintenancePassStats) -> Void)? = nil) -> [String]
}
```

`StorageMaintenanceCursor` keeps its current shape (queue keys `snapshots`,
`cliRecords`, `nested`).

## Behavior (design §5.3 Step 1; follow the design tables exactly)

- **Fast path.** If the cursor exists and every queue is `complete` with empty
  `busy` and `failed`, return immediately without opening a database. Parked
  rows do not keep the pass active.
- **Order.** Queues `snapshots`, `cliRecords`, `nested`. Retry phase first
  (busy keys, then failed keys) capped by `retryShare`; then the forward phase
  with the rest of `total` plus whatever retries left unused. Check budgets
  between items. Each queue that is not `complete` examines at least one
  forward row per pass, even if retries overran the wall-time share.
- **Forward scan.** Keyset on the primary key, read-only selection:
  `SELECT <pk>, <status>, (<legacy predicate>) AS legacy FROM <table> WHERE <pk> > ? ORDER BY <pk> LIMIT ?`
  (no `OFFSET`, no `rowid`). Reaching the end sets `complete = true`; if
  `rescanNeeded` is set at that moment, reset to `after = nil`,
  `complete = false`, `rescanNeeded = false`. `after` always moves past every
  examined row. Rows with `legacy = 0` need no action. Rows in `parked` are
  skipped without an attempt.
- **Eligibility.** Terminal = `completed|failed|cancelled`. Snapshots: the
  snapshot status. CLI records: the snapshot status with the same id when it
  exists, else the CLI status. Nested: the parent is terminal and the child is
  terminal or absent. A non-terminal row is `nonTerminal`: skipped
  permanently (never in `busy`/`failed`).
- **Locks.** Acquire every involved session (nested: parent and child when
  present) with `acquire(sessionId:allowMessagesRetired: true)`, never
  blocking. `retiredSession` → `retired` (skip permanently, never in
  `busy`/`failed`/`parked`). `alreadyRunning`/`unavailable` → `busy`: append
  if `busy.count < 256`, else set `rescanNeeded = true`. `invalidSessionId` →
  park immediately. Release every acquired lock right after the item, on every
  path.
- **Conversion** under the locks: `true` → converted; `false` or row gone →
  notLegacy/gone. Either removes the key from `busy` and `failed`. A thrown
  error → `failed[key] += 1`; on the 3rd failure, or when `failed` already has
  256 keys, move the key to `parked` (cap 256, then `parkedOverflow += 1`)
  and emit exactly one warning:
  `riela retention warning: legacy <queue> row <key> parked after <n> failed conversions: <error>; run riela storage compact --apply`
  (error truncated to 512 UTF-8 bytes).
- **Cursor.** Write it once at the end of the pass, even when a budget ran out
  mid-queue. A missing or invalid cursor restarts every queue from the start.
- **Errors** become `riela retention warning:` lines. Never throw; never write
  stdout.

## Pitfalls

- Never take a lock blockingly, never break or delete a held lock.
- Never convert a non-terminal row ("never rewrite resumable sessions").
- Never `load` a row just to learn whether it is legacy; the predicate is in
  the selection query.
- The retry share is a hard cap; the forward cursor must still advance by at
  least one row per incomplete queue per pass.
- Inject the clock; tests must not sleep.

## Tests

New `Tests/RielaCLITests/RunEndStorageMaintenanceConversionTests.swift`
(class `RunEndStorageMaintenanceConversionTests`). Real stores in temporary
roots (`makeRielaCLITestTemporaryDirectory`); call
`StorageMaintenanceConversion.run` directly with explicit roots (no process
environment, no `HOME`). Fixtures: legacy inline snapshot (as in
`SQLiteRuntimeExecutionRowsTests.testLegacyInlineSessionLoadsAndConvertsOnFirstSave`),
legacy CLI copy (as in `CLIWorkflowSessionEnvelopeTests.insertLegacy`),
embedded nested row (as in the nested conversion tests in
`StorageCompactCommandTests`).

- mixed store, 40 terminal legacy rows of all three kinds, repeated `.runEnd`
  passes → each pass converts ≤ 16; eventually `legacyInlineSessionIds`,
  `legacyFullRecordIds` and `legacyEmbeddedNestedInvocationKeys` are empty,
  every queue is `complete`, and the next pass reports zero rows examined
  (fast path);
- terminal session whose lock the test holds → in `busy`, still legacy; after
  release, the next pass converts it and `busy` is empty;
- running and suspended legacy sessions → never converted, never in
  `busy`/`failed`; cursor moves past them;
- deterministically failing row placed before convertible rows (legacy inline
  `session_json` the decoder rejects) → attempted exactly 3 times across
  passes, then parked with exactly one warning line, never attempted again;
  later rows still convert;
- retired row (results tombstone in `session_retention_tombstones`, as
  `TerminalRetentionTests` creates it) → skipped; absent from
  `busy`/`failed`/`parked`; cursor advances;
- retry share: 256 busy rows held by test locks plus failing rows plus forward
  rows → observed `retryConversions ≤ 8` and `retryRowsExamined ≤ 128` per
  pass; forward `after` advances every pass; a 257th busy row sets
  `rescanNeeded`, and after its lock is released a later rescan converts it;
- injected clock that jumps past the retry wall-time share during retries →
  forward phase still examines ≥ 1 row;
- corrupt cursor file (`{`) → pass restarts and converts remaining rows;
  stopping after k passes and resuming converts the rest exactly once;
- `.scheduled` profile → ≤ 64 conversions per pass.

## Acceptance criteria

- `rg -n "enum StorageMaintenanceConversion|enum StorageMaintenanceProfile" Sources/RielaCLI` → both present.
- `rg -n "allowMessagesRetired: true" Sources/RielaCLI/StorageMaintenanceConversion.swift` → present.
- All tests above pass; progress log records per-pass conversion counts and
  the parked-row warning text from the mixed-store and parking tests.

## Verification (each must exit 0)

```
mkdir -p tmp/ssg2/ssg2-04-legacy-conversion
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -lc 'set -o pipefail; swift build 2>&1 | tee tmp/ssg2/ssg2-04-legacy-conversion/build.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-04-legacy-conversion/build.log; exit $s'
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test --filter "RunEndStorageMaintenanceConversion" 2>&1 | tee tmp/ssg2/ssg2-04-legacy-conversion/test.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-04-legacy-conversion/test.log; exit $s'
arch -arm64 /bin/zsh -lc 'set -o pipefail; swiftlint lint --strict Sources/RielaCLI/StorageMaintenanceConversion.swift Sources/RielaCLI/StorageMaintenanceCursor.swift Tests/RielaCLITests/RunEndStorageMaintenanceConversionTests.swift 2>&1 | tee tmp/ssg2/ssg2-04-legacy-conversion/lint.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-04-legacy-conversion/lint.log; exit $s'
```

Evidence: logs end with `exit=0`; `test.log` shows
`RunEndStorageMaintenanceConversionTests` executed with 0 failures. (The
existing `RunEndStorageMaintenanceTests` class is owned and fixed by ssg2-05;
this filter does not select it.)

## Progress log

Record in `impl-plans/progress/ssg2-04-legacy-conversion.md`: pre/post sha256
(including `StorageMaintenanceCursor.swift`), commands with exit codes and
log paths, per-pass counts, parked-row evidence, and reconciliation items.
