# sgc-03-automatic-maintenance: bounded automatic legacy conversion and reclamation

**Status**: Ready
**planId**: sgc-03-automatic-maintenance
**dependsOn**: sgc-02-default-retention (wave W2; it uses `RielaRetentionConfiguration.effectivePolicy(for:)`)
**Design Reference**: design-docs/specs/design-session-storage-efficiency-and-default-gc.md §5 (5.1-5.4) and §9 (RunEndStorageMaintenanceTests, EventLiveServe, runEnd selection); QA Q4, Q6, Q7
**Progress log**: impl-plans/progress/sgc-03-automatic-maintenance.md
**Evidence root**: tmp/session-storage-gc/sgc-03-automatic-maintenance/

## Intent and context

Legacy rows dominate real stores:

- inline `workflow_runtime_snapshots.session_json` (1.9 GB);
- full `cli_workflow_sessions.record_json` copies (1.9 GB);
- embedded `workflow_nested_invocations` child snapshots (488 MB).

Only a manual `riela storage compact --apply` converts them. Today
`RunEndStorageMaintenance` only vacuums (128 pages), and only after a retention
pass that `completed`, which never happens without config
(`Sources/RielaCLI/AutomaticRetentionHook.swift:96-101`). Scheduler hosts
(`events serve`, `serve`) call `AutomaticRetentionHook.runAutomaticPass`,
which does retention only. RielaApp calls `RielaRetentionService().run`
directly (`Sources/RielaApp/EntryPoint+Retention.swift`).

This plan extends `RunEndStorageMaintenance` into the single automatic
maintenance pass, with two profiles:

- **Step 1**: bounded, resumable, terminal-only, lock-gated legacy conversion
  that reuses the existing converters.
- **Step 2**: bounded incremental vacuum.

Every automatic host runs it.

Existing code to reuse or imitate:

- Converters (public, idempotent; each returns `false` when the row is not
  legacy or is gone):
  - `SQLiteWorkflowRuntimePersistenceStore.convertLegacySession(sessionId:)`
    (`+SessionFamily.swift:456`);
  - `CLIWorkflowSessionStore.convertLegacyRecord(sessionId:)`
    (`CLIWorkflowSessionStore.swift:562`; the caller must hold the session
    lock);
  - `SQLiteWorkflowRuntimePersistenceStore.convertLegacyNestedInvocation(invocationKey:)`
    (`+SessionFamily.swift:486`).
- Legacy predicates, copied as SQL into your keyset queries:
  - `legacyInlineSessionIds`: `json_type(session_json,'$.executions')='array' AND json_type(session_json,'$._rielaExecutionStorage') IS NULL`;
  - `legacyFullRecordIds`: `json_extract(record_json,'$.sessionStorage') IS NOT 'canonical'`;
  - `legacyEmbeddedNestedInvocationKeys`: `json_type(reservation_json,'$.childSnapshotStorage') IS NULL`.
- Lock and conversion loop: `Sources/RielaCLI/StorageCompactCommand.swift:convertSessionStores`
  (lines 214-262) uses `SessionExecutionLockRegistry(sessionStoreRoot:)`,
  `acquire(sessionId:allowMessagesRetired: true)` and `release(sessionId:)`.
- Lock errors: `SessionExecutionLockError` in `Sources/RielaCLI/SessionExecutionLock.swift:10-15`.
- Single flight: `RetentionTargetLock.tryAcquire(stateDirectory:)`. Atomic
  JSON state: `RetentionRunStamp.write(stateDirectory:)`
  (`Sources/RielaCLI/RetentionTargetState.swift`). Targets:
  `RetentionTargetResolver.resolve` and `RetentionTarget`
  (`Sources/RielaCLI/RetentionTargets.swift`).
- Status columns:
  - `workflow_runtime_snapshots.session_status`;
  - `cli_workflow_sessions.status`;
  - nested parent and child: `TerminalRetentionIndexes.parent` and `.child`
    (`Sources/RielaCLI/TerminalRetentionIndexes.swift:11-12`).

## Non-goals

- No change to the converters or any `Sources/RielaCore` file. Selection SQL
  lives in RielaCLI and reads the database read-only.
- No full `VACUUM`, no conversion of `auto_vacuum=NONE` databases, and no
  unlinking of DB, WAL or SHM files.
- No change to `riela storage compact` behavior, to retention deletion rules,
  or to `EventLiveServe.swift` and `ServeHTTPCommand.swift`. They already call
  `runAutomaticPass`.
- No doctor output (sgc-04) and no docs (sgc-05).

## Contract (pinned; sgc-04 decodes the cursor)

New file `Sources/RielaCLI/StorageMaintenanceCursor.swift`:

```swift
struct StorageMaintenanceCursor: Codable, Equatable, Sendable {
  static let fileName = "storage-maintenance.json"; static let version = 1
  var version: Int
  var queues: [String: Queue]            // keys: "snapshots", "cliRecords", "nested"
  struct Queue: Codable, Equatable, Sendable {
    var after: String?; var complete: Bool; var rescanNeeded: Bool
    var busy: [String]                   // ≤ 256
    var failed: [String: Int]            // ≤ 256, attempts 1...2
    var parked: [Parked]                 // ≤ 256
    var parkedOverflow: Int
  }
  struct Parked: Codable, Equatable, Sendable { var key: String; var error: String }  // error ≤ 512 UTF-8 bytes
  static func read(stateDirectory: String) -> StorageMaintenanceCursor?   // nil when missing or invalid; never creates
  func write(stateDirectory: String) throws                               // temp file + rename, caller holds automatic.lock
}
```

New public entry point for scheduler hosts, in
`Sources/RielaCLI/AutomaticRetentionHook.swift`:

```swift
public enum RielaAutomaticStoragePass { public static func runScheduled(_ request: RielaRetentionRequest) -> [String] }
```

It returns stderr warning lines. `AutomaticRetentionHook.runAutomaticPass`
delegates to it.

## File-level changes

### 1. `Sources/RielaCLI/StorageMaintenanceCursor.swift` (new)

The contract above. `read` returns `nil` for an unknown version, a decode
error or a missing file. The write pattern copies `RetentionRunStamp.write`.

### 2. `Sources/RielaCLI/RunEndStorageMaintenance.swift`

- **Profiles.** Add `enum StorageMaintenanceProfile { case runEnd, scheduled }`
  with these budgets:

  | Profile | Total (conversions / rows examined / wall) | Retry share (max) | Vacuum page cap |
  |---|---|---|---|
  | `runEnd` | 16 / 256 / 2 s | 8 / 128 / 1 s | 4096 |
  | `scheduled` | 64 / 1024 / 10 s | 32 / 512 / 5 s | 65536 |

- **Entry point.** Replace `run(sessionStoreRoots:)` with
  `static func run(targets: [RetentionTarget], profile: StorageMaintenanceProfile, now: () -> Date = Date.init, observe: ((StorageMaintenancePassStats) -> Void)? = nil) -> [String]`.
  `StorageMaintenancePassStats` is an internal value type with
  `retryConversions`, `retryRowsExamined`, `forwardRowsExamined`, `converted`,
  `parked` and `skippedBusy`, reported once per target. It is a test seam
  only and must not be printed.
  For each target that has a `sessionStoreRoot`, an existing session DB and no
  `unsafeReason`:
  1. Take `RetentionTargetLock.tryAcquire(stateDirectory:)`. If it is busy,
     skip silently.
  2. Run Step 1.
  3. Run Step 2.
  4. Release the lock.
- **Step 1, conversion.** Process the queues in the order snapshots,
  cliRecords, nested.
  - **Retry phase first.** Re-attempt the `busy` keys, then the `failed`
    keys, while staying within the retry share.
  - **Forward phase.** Run a keyset scan on the primary key:
    `SELECT <pk>, <status cols>, (<legacy predicate>) AS legacy FROM <table> WHERE <pk> > ? ORDER BY <pk> LIMIT ?`.
    Use `after = null` for the first page.
    - Open the DB read-only for selection (`SQLiteDatabase.open(path:mode: .strictReadOnly, options: .readOnlyDefault)`).
    - Use the remaining budget, but always examine at least 1 row per pass for
      each incomplete queue.
    - Rows with `legacy = 0` are examined but need no action.
    - A short page with no rows left sets `complete = true`. If
      `rescanNeeded` is true at that point, reset to `after = nil`,
      `complete = false`, `rescanNeeded = false`.
  - **Outcome classes.** Apply them per design §5.3 (table):
    - **nonTerminal.** The status is not in `completed|failed|cancelled`. For
      a snapshot, the canonical `session_status` is used. For a CLI record,
      the status of the snapshot with the same id wins when that row exists,
      otherwise `cli_workflow_sessions.status`. For a nested row, the parent
      session status, and the child status when the child exists. Skip it
      permanently.
    - **Locks.** Acquire locks for all involved ids (nested rows: the parent,
      and the child when present) with `acquire(sessionId:allowMessagesRetired: true)`.
      - `retiredSession` → skip permanently. Never add it to `busy` or
        `failed`.
      - `alreadyRunning` or `unavailable` → append to `busy` if it has fewer
        than 256 entries, otherwise set `rescanNeeded = true`.
      - `invalidSessionId` → park immediately.
      - Release every acquired lock right after the item, including on
        error.
    - **Conversion** runs under the lock.
      - `true` → converted.
      - `false` → notLegacy or gone.
      - A thrown error → `failed[key] += 1`. On the 3rd failure, move the key
        to `parked` (cap 256, otherwise `parkedOverflow += 1`). If `failed`
        is already full, park the key directly.
      - Every time a row is parked, emit exactly one warning:
        `riela retention warning: legacy <queue> row <key> parked after <n> failed conversions: <error>; run riela storage compact --apply`.
    - Rows listed in `parked` are skipped without an attempt when the forward
      scan meets them.
    - A converted, notLegacy or gone row is removed from `busy` and `failed`.
  - **Cursor writes.** Persist the cursor after Step 1 even when the budget is
    exhausted mid-queue.
  - **No-work fast path.** If every queue is `complete` with empty `busy` and
    `failed`, Step 1 returns immediately without opening the DB.
- **Step 2, vacuum.** Keep the current body (open with
  `busyTimeoutMilliseconds: 0`, `waitForLocks: false`, `enableWAL: false`;
  only when `auto_vacuum == 2` and `freelist_count >= 128`; `SQLITE_BUSY` is
  skipped). Replace `maximumVacuumPages = 128` with the profile cap. Keep the
  PASSIVE checkpoint.
- **Errors** become `riela retention warning:` lines. Never throw out of
  `run`.

### 3. `Sources/RielaCLI/AutomaticRetentionHook.swift`

- **`runIfApplicable`.**
  1. Run the retention pass as today.
  2. Load the config with `RielaRetentionConfiguration.load(...)`. On a
     config error, add no extra warning; the retention pass already warned.
     Skip maintenance.
  3. If `effectivePolicy(for: selectedTarget.kind).policy.automatic` is true
     and a selected target exists, call
     `RunEndStorageMaintenance.run(targets: [selectedTarget], profile: .runEnd)`.

  Remove the `completedRoots` gating.
- **`selectedSessionStoreRoot`** (DR-2). For `session resume|rerun|continue`
  without an explicit store, read `--scope`. If it is `user`, pick the user
  target; any other or absent value picks the project target. An explicit
  store still wins, and the `workflow run` branch is unchanged.
- **`RielaAutomaticStoragePass.runScheduled(_:)`.**
  1. Run the retention pass (the existing `runAutomaticPassWithReport` logic).
  2. Resolve the targets with `RetentionTargetResolver.resolve(...)` from the
     request.
  3. For each target whose effective policy is automatic, run
     `RunEndStorageMaintenance.run(targets:profile: .scheduled)`.
  4. Return all warnings.

  Make `runAutomaticPass` return `RielaAutomaticStoragePass.runScheduled(request)`.

### 4. `Sources/RielaApp/EntryPoint+Retention.swift`

- In the scheduler closure, replace the direct `RielaRetentionService().run`
  call with `RielaAutomaticStoragePass.runScheduled(request)`. Write each
  returned warning to stderr with the existing `RielaApp retention warning:`
  prefix (strip the `riela retention warning: ` prefix first).
- Keep `runImmediately: true` and `rielaAppRetentionRequest` unchanged.

## Pitfalls

- **Lock rules.** Never take a lock with blocking, and never break or delete a
  held lock. Every `acquire` must use `allowMessagesRetired: true`, as compact
  does. `release` must run on every path.
- **Terminal-only.** Never convert a non-terminal row. That would violate the
  "never rewrite resumable sessions" rule. Manual compact keeps converting
  any lock-free row; do not change it.
- **Keyset reads.** Select the legacy predicate in the same query. Never
  `load` a row just to find out whether it is legacy. Never use `OFFSET` or
  `rowid`; use primary keys, which survive `VACUUM`.
- **Retry share.** The retry share is a hard cap. Check the budget between
  items. The forward phase must still examine at least one row even when the
  retry phase overran its wall-time share.
- **No-config path.** Maintenance must run with no retention config, because
  the default is `automatic: true`. The existing test
  `testAutomaticHookSkipsMaintenanceWithoutCompletedRetentionPass` asserts the
  opposite. Replace it with "maintenance runs without config and vacuums",
  and add "`RIELA_RETENTION_AUTOMATIC=0` skips maintenance".
- **Output.** Do not write to stdout. The exit code and stdout of the wrapped
  command must stay unchanged.
- **Cursor writes.** Only write the cursor while holding `automatic.lock`. A
  dry run does not exist on this path.

## Tests

`Tests/RielaCLITests/RunEndStorageMaintenanceTests.swift` (update the file).
Build fixtures with real stores in temp roots:

- **Legacy fixtures.**
  - A legacy inline snapshot: save normally, then rewrite `session_json` with
    the full session, as in
    `SQLiteRuntimeExecutionRowsTests.testLegacyInlineSessionLoadsAndConvertsOnFirstSave`.
  - A legacy CLI copy: as in `CLIWorkflowSessionEnvelopeTests.insertLegacy`.
  - An embedded nested row: copy the pattern from the existing nested
    conversion tests in `StorageCompactCommandTests`.
- **Cases** (`situation -> expected outcome`):
  - Mixed legacy store (all three kinds, 40 terminal rows), with repeated
    `.runEnd` passes and an injected clock → each pass converts at most 16
    rows. Eventually `legacyInlineSessionIds`, `legacyFullRecordIds` and
    `legacyEmbeddedNestedInvocationKeys` are empty, every queue is
    `complete`, and the next pass opens no DB (a no-work assertion through the
    cursor state).
  - A terminal session whose execution lock is held by the test
    (`SessionExecutionLockRegistry.acquire`) → that session is in `busy` and
    still legacy. After the test releases the lock, the next pass converts it
    and `busy` becomes empty.
  - A running or suspended legacy session → never converted, never in `busy`
    or `failed`, and the cursor moves past it.
  - A deterministically failing row before convertible rows (a legacy inline
    `session_json` with an invalid enum value, so decode throws) → three
    passes attempt it, then it is parked with exactly one warning line, it is
    never attempted on the 4th or later passes, and the convertible rows after
    it convert.
  - A retired row: a legacy row whose id has a `session_retention_tombstones`
    row (create the table with `ensureSessionRetentionTriggers`'s companion
    schema, as `TerminalRetentionTests` does) → skipped, absent from
    `busy`/`failed`/`parked`, and the cursor advances.
  - Retry share: 256 busy rows held by test locks plus failing rows, then
    forward-queue rows → each pass uses at most 8 conversions and 128 rows on
    retries (checked through counts recorded by an injected observer or by the
    cursor deltas). The forward `after` moves by at least 1 every pass. A
    257th busy row sets `rescanNeeded`, and after its lock is released a later
    rescan converts it.
  - A corrupt cursor file (`{`) → the pass restarts from the beginning and
    converts the remaining rows. Interrupting after k passes and resuming
    converts the remaining rows exactly once.
  - An incremental store with legacy rows → the file size (`stat`) is smaller
    after conversion plus vacuum than before.
  - A `NONE` store → no `VACUUM` (`auto_vacuum` stays 0, and the file is not
    rewritten).
  - No retention config → maintenance still runs.
    `RIELA_RETENTION_AUTOMATIC=0` → it does not run.
  - `automatic.lock` held by the test → the pass is skipped and nothing
    changes.
  - runEnd selection: `session resume <id>` without an explicit store →
    project target. With `--scope user` → user target. With
    `--session-store` → explicit target.

`Tests/RielaCLITests/EventLiveServeMaintenanceTests.swift` (new):

- A legacy row in a temp project store → one
  `RielaAutomaticStoragePass.runScheduled(request)` call (as the events
  serve and serve scheduler closures make it) converts the row and vacuums.
- A `RielaRetentionScheduler` with a 0.01 s interval and the same pass →
  after the first tick the row is converted, and `stop()` ends the loop.

## Acceptance criteria

- `rg -n "completedRoots" Sources/RielaCLI/AutomaticRetentionHook.swift` → no
  gating use.
- `rg -n "RielaAutomaticStoragePass.runScheduled" Sources` → used by
  `AutomaticRetentionHook.runAutomaticPass` and by `Sources/RielaApp/EntryPoint+Retention.swift`.
- `rg -n "maximumVacuumPages = 128" Sources` → no match.
- All listed tests pass. The progress log records per-pass conversion counts
  for the mixed-store test.

## Verification (every log must end with `exit=0`)

Build cache: writes to `.build/` and `.swiftpm/` by these commands are
authorized and untracked. They are not part of `writePaths`, `sharedPaths` or
`artifactRoots`, and `artifactRoots` is intentionally empty. See the index
`impl-plans/active/session-storage-gc.md`, Shared execution rules, "Build
cache". Never block on them.

```
mkdir -p tmp/session-storage-gc/sgc-03-automatic-maintenance
arch -arm64 /bin/zsh -lc 'set -o pipefail; swift build 2>&1 | tee tmp/session-storage-gc/sgc-03-automatic-maintenance/build.log; echo "exit=$?" >> tmp/session-storage-gc/sgc-03-automatic-maintenance/build.log'
arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test --filter "RunEndStorageMaintenance|EventLiveServeMaintenance|AutomaticRetention|RielaRetentionScheduler|RetentionTargetState|StorageCompact" 2>&1 | tee tmp/session-storage-gc/sgc-03-automatic-maintenance/test.log; echo "exit=$?" >> tmp/session-storage-gc/sgc-03-automatic-maintenance/test.log'
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict Sources/RielaCLI/StorageMaintenanceCursor.swift Sources/RielaCLI/RunEndStorageMaintenance.swift Sources/RielaCLI/AutomaticRetentionHook.swift Sources/RielaApp/EntryPoint+Retention.swift Tests/RielaCLITests/RunEndStorageMaintenanceTests.swift Tests/RielaCLITests/EventLiveServeMaintenanceTests.swift 2>&1 | tee tmp/session-storage-gc/sgc-03-automatic-maintenance/lint.log'
```

What each command must show:

- `build.log`: `exit=0`. It builds RielaApp on macOS too.
- `test.log`: `exit=0` and 0 failures.
- `lint.log`: no new violations.

## Progress-log expectations

Record in `impl-plans/progress/sgc-03-automatic-maintenance.md`:

- hashes before and after;
- each command with its exit code and log path;
- the per-pass conversion counts and the parked-row evidence;
- the replaced test and the reason;
- any reconciliation items.
