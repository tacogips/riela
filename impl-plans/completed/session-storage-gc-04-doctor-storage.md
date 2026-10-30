# sgc-04-doctor-storage: remaining reclaimable bytes, NONE recovery path, parked-row visibility

**Status**: Ready
**planId**: sgc-04-doctor-storage
**dependsOn**: sgc-02-default-retention, sgc-03-automatic-maintenance (wave W3)
**Design Reference**: design-docs/specs/design-session-storage-efficiency-and-default-gc.md §6 and §9 (StorageDoctorCommandTests)
**Progress log**: impl-plans/progress/sgc-04-doctor-storage.md
**Evidence root**: tmp/session-storage-gc/sgc-04-doctor-storage/

## Intent and context

`riela doctor storage` must report:

- how many bytes remain reclaimable;
- for `auto_vacuum=NONE` stores, how to recover the space;
- which legacy rows automatic maintenance parked (sgc-03).

The command must stay strictly read-only.

Existing code: `Sources/RielaCLI/StorageDoctorCommand.swift`.

- The per-file report is built in the function ending around lines 175-191.
  `reclaimable` is currently `[String: Int64]` with `freePagesBytes`,
  `compactEstimateBytes` and `pruneEstimateBytes`.
- `compactEstimate` already includes the free pages (line 180).
- `retentionReport(path:)` is a dry-run retention report. With sgc-02 it
  reflects the default policy.
- The session details come from `sessionReport(...)`.
- Text output: the renderer near line 342.
- Free space: `RetentionSQLiteReclaimer().freeSpace` (`Sources/RielaCLI/RetentionSQLiteReclaimer.swift:39`).
- Targets and state directories: `RetentionTargetResolver.resolve` (`Sources/RielaCLI/RetentionTargets.swift`).
- Cursor: `StorageMaintenanceCursor.read(stateDirectory:)` from sgc-03
  (`Sources/RielaCLI/StorageMaintenanceCursor.swift`).

## Non-goals

- No writes of any kind: no cursor creation, no lock files, no migrations, no
  state directory creation.
- No new CLI flags.
- No change to compact or gc.
- Docs belong to sgc-05.

## File-level changes (`Sources/RielaCLI/StorageDoctorCommand.swift` only)

- **`reclaimable` type.** Replace the `[String: Int64]` with a Codable struct
  `StorageDoctorReclaimable`:
  - `freePagesBytes`, `compactEstimateBytes`, `pruneEstimateBytes` (as today);
  - `remainingBytes = compactEstimateBytes + pruneEstimateBytes`;
  - `remainingBytesIsUpperBound: Bool = true`;
  - `recovery: StorageDoctorRecovery?`.

  Keep the JSON key names identical for the existing three fields. The JSON
  encoder already uses sorted keys.
- **`StorageDoctorRecovery`.** It is present only when the database is a
  session or definitions database and `autoVacuum == "none"`. Fields:
  - `requiredFreeBytes = 2 * (fileBytes + walBytes) + 268_435_456`;
  - `availableFreeBytes: Int64?` from `freeSpace(directory of the DB)`;
  - `steps`, a fixed English string: freed pages are reused but the file
    cannot shrink; stop writers and run `riela storage compact --apply` (or
    `riela gc`) once when free space is at least `requiredFreeBytes`;
    otherwise follow the `VACUUM INTO` sequence in
    docs/storage-doctor-and-compact.md.

  It is absent for `incremental`.
- **`session.maintenance`.** Add `StorageDoctorMaintenance?` to the session
  details: `parkedCount`, `parkedExamples` (first 5 `{queue, key, error}` in
  queue order snapshots, cliRecords, nested), `busyCount`, `failedCount`,
  `queuesComplete`, and `hint`, which is
  `"run riela storage compact --apply"` when `parkedCount > 0`, otherwise
  `nil`.
  - `parkedCount = parked.count + parkedOverflow`, summed over the queues.
  - Find the state directory by resolving retention targets with the doctor's
    scope, working directory and session-store options. Pick the target whose
    `sessionStoreRoot` standardizes to this database's session root, then read
    `StorageMaintenanceCursor.read(stateDirectory:)`.
  - A missing or invalid cursor gives `maintenance: nil`.
- **Text output.** Add one line per file:
  - `remaining reclaimable (upper bound): <n> bytes`;
  - for NONE stores, the recovery line with the required and available bytes;
  - when parked rows exist, `parked legacy rows: <n> (run riela storage compact --apply)`.

## Pitfalls

- **Read-only.** `StorageMaintenanceCursor.read` must never create files or
  directories. Do not call `RetentionTargetLock`. Do not call anything that
  ensures a directory exists. The doctor contract forbids any write.
- **Recovery scope.** Do not compute `recovery` for memory, cache or KV
  databases.
- **Upper bound.** `remainingBytes` is a deliberately simple upper bound (the
  design accepts the possible double count). Do not try to de-duplicate it.
- **Default policy.** `pruneEstimateBytes` now includes families selected by
  the sgc-02 default policy. Update the existing tests that expected 0 with no
  config.

## Tests (`Tests/RielaCLITests/StorageDoctorCommandTests.swift`)

- An incremental session store → `reclaimable.remainingBytes ==
  compactEstimateBytes + pruneEstimateBytes`,
  `remainingBytesIsUpperBound == true`, and no `recovery`.
- A `NONE` session store → `recovery.requiredFreeBytes == 2*(db+wal)+268435456`,
  and `steps` mentions `riela storage compact --apply` and `VACUUM INTO`.
  Inject a free-space value if the command exposes one. Otherwise assert only
  that `availableFreeBytes` is non-nil or nil-safe.
- A fixture cursor file in the target state directory with 2 parked rows and
  1 overflow → `session.maintenance.parkedCount == 3`, the examples hold the
  first parked keys, and the hint is set. The cursor file bytes and mtime are
  unchanged after the command.
- No cursor file → `maintenance` is null, and no `retention/` directory is
  created.
- No retention config plus an old terminal family → `pruneEstimateBytes > 0`
  (the default policy).
- Existing assertions on the `reclaimable` keys keep passing, with their
  access adapted to the struct.

## Acceptance criteria

- `rg -n "remainingBytes|StorageDoctorRecovery|StorageDoctorMaintenance" Sources/RielaCLI/StorageDoctorCommand.swift`
  matches the new fields.
- The tests pass. The read-only assertions (the cursor file is unchanged and
  no state directory is created) pass.

## Verification (every log must end with `exit=0`)

Build cache: writes to `.build/` and `.swiftpm/` by these commands are
authorized and untracked. They are not part of `writePaths`, `sharedPaths` or
`artifactRoots`, and `artifactRoots` is intentionally empty. See the index
`impl-plans/active/session-storage-gc.md`, Shared execution rules, "Build
cache". Never block on them.

```
mkdir -p tmp/session-storage-gc/sgc-04-doctor-storage
arch -arm64 /bin/zsh -lc 'set -o pipefail; swift build 2>&1 | tee tmp/session-storage-gc/sgc-04-doctor-storage/build.log; echo "exit=$?" >> tmp/session-storage-gc/sgc-04-doctor-storage/build.log'
arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test --filter "StorageDoctor|StorageHelpBackstop" 2>&1 | tee tmp/session-storage-gc/sgc-04-doctor-storage/test.log; echo "exit=$?" >> tmp/session-storage-gc/sgc-04-doctor-storage/test.log'
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict Sources/RielaCLI/StorageDoctorCommand.swift Tests/RielaCLITests/StorageDoctorCommandTests.swift 2>&1 | tee tmp/session-storage-gc/sgc-04-doctor-storage/lint.log'
```

What each command must show:

- `build.log`: `exit=0`.
- `test.log`: `exit=0` and 0 failures.
- `lint.log`: no new violations.

## Progress-log expectations

Record in `impl-plans/progress/sgc-04-doctor-storage.md`: hashes, commands
with exit codes and log paths, sample JSON output (from a temp store) showing
`remainingBytes`, `recovery` and `maintenance`, and any reconciliation items.
