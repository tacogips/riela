# ssg2-08-doctor-docs: doctor storage reporting + documentation (final plan)

**Archived 2026-10-30 (session 564)**: superseded by
`impl-plans/active/ssg3-02-doctor-storage-docs.md`; never implemented.

**planId**: ssg2-08-doctor-docs
**dependsOn**: ssg2-03-fragment-release-benchmark, ssg2-05-maintenance-host-wiring, ssg2-07-gc-readonly-workremaining (wave W4; all other plans transitively)
**Design**: `design-docs/specs/design-session-storage-efficiency-and-default-gc.md`
§6 (doctor), §7 (docs), §8 (rollout notes to document), §9
(`StorageDoctorCommandTests`), §10 (gc and compact behavior to document), §12
row (h); QA Q1-Q9
**Shared rules**: `impl-plans/active/ssg2-session-storage-gc.md` → "Shared execution rules"
**Progress log**: `impl-plans/progress/ssg2-08-doctor-docs.md` (new; do not read or continue `sgc-04`/`sgc-05`)
**Evidence root**: `tmp/ssg2/ssg2-08-doctor-docs/`
**writePaths**: `Sources/RielaCLI/StorageDoctorCommand.swift`, `Tests/RielaCLITests/StorageDoctorCommandTests.swift`, `docs/storage-doctor-and-compact.md`, `docs/terminal-retention.md`, `README.md` (Runtime Data Retention section only), `impl-plans/progress/ssg2-08-doctor-docs.md`
**sharedPaths**: none

## Intent and context

`riela doctor storage` must report the remaining reclaimable bytes, the
recovery path for `auto_vacuum=NONE` stores, and legacy rows that automatic
maintenance parked, while staying strictly read-only. The docs must describe
the payload representation, the built-in defaults, automatic maintenance, the
gc and compact fixes, and the overrides. Write from the shipped code; read
these first so every number and name matches:

- `Sources/RielaCore/RuntimePayloadFragmentEncoder.swift` (1024-byte
  threshold, `$rielaPayloadRef`, `_rielaPayloadRefs`);
- `Sources/RielaCore/RielaRetentionConfiguration.swift` (`builtInDefault`);
- `Sources/RielaCLI/StorageMaintenanceConversion.swift` (budgets, retry share,
  parking warning text) and `Sources/RielaCLI/StorageMaintenanceCursor.swift`;
- `Sources/RielaCLI/RunEndStorageMaintenance.swift` (page caps);
- `Sources/RielaCore/RielaDataGarbageCollector.swift` and
  `Sources/RielaCLI/StorageCompactCommand.swift` (§10 behavior);
- `Sources/RielaCLI/GarbageCollectionCommand.swift` (help text).

Doctor code: `Sources/RielaCLI/StorageDoctorCommand.swift` (`reclaimable` is
`[String: Int64]` with `freePagesBytes`, `compactEstimateBytes`,
`pruneEstimateBytes`; `compactEstimate` already includes free pages at
~line 180; text renderer ~line 342). Free space:
`RetentionSQLiteReclaimer().freeSpace` (`Sources/RielaCLI/RetentionSQLiteReclaimer.swift:39`).
State directory: `RetentionTargetResolver.resolve` (`Sources/RielaCLI/RetentionTargets.swift`).

## Non-goals

- Doctor writes nothing: no cursor creation, no lock, no migration, no
  directory creation. No new CLI flags. No change to compact, gc or
  maintenance.
- Docs: only `docs/storage-doctor-and-compact.md`, `docs/terminal-retention.md`
  and the README "Runtime Data Retention" section (line ~777). Another
  workflow edits `main`; keep README hunks inside that section.
- No design-doc edits (supersession notes already exist in
  `design-automatic-retention.md`, `design-efficient-history-and-storage.md`
  and the QA files). No version or changelog bump.

## File-level changes

### 1. `Sources/RielaCLI/StorageDoctorCommand.swift`

- `reclaimable` becomes a Codable struct `StorageDoctorReclaimable` with the
  three existing keys unchanged, plus `remainingBytes = compactEstimateBytes + pruneEstimateBytes`,
  `remainingBytesIsUpperBound = true`, and `recovery: StorageDoctorRecovery?`.
- `StorageDoctorRecovery` only for session or definitions databases with
  `autoVacuum == "none"`: `requiredFreeBytes = 2 * (dbBytes + walBytes) + 268_435_456`,
  `availableFreeBytes: Int64?` (read-only `statfs` via `freeSpace`), and a
  fixed English `steps` string: freed pages are reused but the file cannot
  shrink; stop writers and run `riela storage compact --apply` (or
  `riela gc`) once when free space is at least `requiredFreeBytes`; otherwise
  follow the `VACUUM INTO` sequence in `docs/storage-doctor-and-compact.md`.
- `session.maintenance: StorageDoctorMaintenance?` for session databases:
  `parkedCount` (sum of `parked.count + parkedOverflow` over queues),
  `parkedExamples` (first 5 `{queue, key, error}` in queue order snapshots,
  cliRecords, nested), `busyCount`, `failedCount`, `queuesComplete`, and
  `hint = "run riela storage compact --apply"` when `parkedCount > 0`.
  Find the target whose standardized `sessionStoreRoot` equals this
  database's session root, then `StorageMaintenanceCursor.read(stateDirectory:)`.
  Missing or invalid cursor → `nil`.
- Text output: `remaining reclaimable (upper bound): <n> bytes`; for NONE
  stores the recovery line with required and available bytes; when parked rows
  exist, `parked legacy rows: <n> (run riela storage compact --apply)`.

### 2. `docs/storage-doctor-and-compact.md`

- New "Payload representation" section: `inputSnapshot` subtrees ≥ 1024
  bytes stored once per root session as sha256 content-addressed fragments;
  every older form stays readable; missing or corrupt fragments fail closed;
  schema generation 12 (older binaries refuse the store); no compression.
- Replace the last paragraph ("4,096 / does not change retention") with
  "Automatic maintenance": hosts (`workflow run`, `session
  resume/rerun/continue`, `events serve`, `serve`, RielaApp); terminal-only,
  lock-free conversion; outcome classes incl. busy retry, parking after 3
  failures with the warning text, retired skip; the `storage-maintenance.json`
  cursor under the retention state directory; budgets and retry share per
  profile; incremental vacuum caps 4096 / 65536 pages; never a full VACUUM;
  opt-out with `"automatic": false` or `RIELA_RETENTION_AUTOMATIC=0`.
- Doctor fields (`reclaimable.remainingBytes`, `remainingBytesIsUpperBound`,
  `recovery`, `session.maintenance`) and the NONE recovery path.
- `storage compact`: the prune step uses the effective policy including
  defaults; the `workRemaining` definition from design §10.2.

### 3. `docs/terminal-retention.md` and README "Runtime Data Retention"

- Built-in defaults (results 30 days, messages with results, logs 30 days, no
  byte cap); only fully terminal unprotected families are deleted.
- Per-category fill; opt-outs `{"keepForever": true}`, `"automatic": false`,
  `RIELA_RETENTION_AUTOMATIC=0`; flags override; `riela gc --dry-run` shows
  `policySource`.
- Upgrade behavior change (stores without config start pruning data older
  than 30 days).
- Generated sweep runs only with a configured or flag `results.maxAgeDays`;
  read-only expired snapshot directories inside the store are made writable
  and removed; an unremovable path is a warning, not a failure.
- Remove the README statement that retention is off when no `retention`
  policy is configured.

## Pitfalls

- `StorageMaintenanceCursor.read` must not create anything; do not call
  `RetentionTargetLock` or any directory-ensuring helper from doctor.
- No `recovery` for memory, cache or KV databases.
- `remainingBytes` is an upper bound by design; do not de-duplicate.
- Existing doctor tests that read `reclaimable` keys keep passing with the
  same JSON key names.
- Every documented number must match the code; record any design-vs-code
  mismatch in the progress log instead of guessing.

## Tests (`Tests/RielaCLITests/StorageDoctorCommandTests.swift`, isolated via `RielaCLIIsolatedEnvironment`)

- incremental session store → `remainingBytes == compactEstimateBytes + pruneEstimateBytes`,
  `remainingBytesIsUpperBound == true`, no `recovery`;
- NONE session store → `recovery.requiredFreeBytes == 2*(db+wal)+268435456`;
  `steps` mentions `riela storage compact --apply` and `VACUUM INTO`;
- fixture cursor with 2 parked rows and 1 overflow → `parkedCount == 3`,
  examples hold the first parked keys, hint set; cursor bytes and mtime
  unchanged after the command;
- no cursor → `maintenance` null and no `retention/` directory created;
- no retention config plus an old terminal family → `pruneEstimateBytes > 0`.

## Acceptance criteria

- `rg -n "remainingBytes|StorageDoctorRecovery|StorageDoctorMaintenance" Sources/RielaCLI/StorageDoctorCommand.swift` → matches.
- `grep -n "is off when no" README.md` → no match (today it matches `README.md:779`).
- `rg -n "built-in default" README.md docs/storage-doctor-and-compact.md docs/terminal-retention.md` → matches in all three files.
- `rg -n "storage-maintenance.json|parked|remainingBytes|_rielaPayloadRefs|workRemaining" docs/storage-doctor-and-compact.md` → each term present.

## Verification (each must exit 0)

```
mkdir -p tmp/ssg2/ssg2-08-doctor-docs
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -lc 'set -o pipefail; swift build 2>&1 | tee tmp/ssg2/ssg2-08-doctor-docs/build.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-08-doctor-docs/build.log; exit $s'
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test --filter "StorageDoctor" 2>&1 | tee tmp/ssg2/ssg2-08-doctor-docs/test.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-08-doctor-docs/test.log; exit $s'
arch -arm64 /bin/zsh -lc 'set -o pipefail; swiftlint lint --strict Sources/RielaCLI/StorageDoctorCommand.swift Tests/RielaCLITests/StorageDoctorCommandTests.swift 2>&1 | tee tmp/ssg2/ssg2-08-doctor-docs/lint.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-08-doctor-docs/lint.log; exit $s'
/bin/zsh -c '! grep -n "is off when no" README.md'
/bin/zsh -c 'for f in README.md docs/storage-doctor-and-compact.md docs/terminal-retention.md; do grep -q "built-in default" "$f" || exit 1; done'
/bin/zsh -c 'for t in storage-maintenance.json parked remainingBytes _rielaPayloadRefs workRemaining; do grep -q -F "$t" docs/storage-doctor-and-compact.md || exit 1; done'
```

Evidence: Swift logs end with `exit=0`; the three doc checks exit 0. Save
`git diff -U0 -- README.md` output in the progress log to show hunks stay in
the Runtime Data Retention section.

## Progress log

Record in `impl-plans/progress/ssg2-08-doctor-docs.md`: pre/post sha256,
sample doctor JSON from a temporary store (showing `remainingBytes`,
`recovery`, `maintenance`), commands with exit codes and log paths, doc
numbers cross-checked against code, and reconciliation items.
