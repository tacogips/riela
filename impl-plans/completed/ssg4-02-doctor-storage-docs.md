# ssg4-02-doctor-storage-docs: `riela doctor storage` reporting and storage/retention docs

**Status**: Completed (2026-10-30; accepted by the session-566 test-integrity, adversarial and integration reviews; progress `impl-plans/progress/ssg4-02-doctor-storage-docs.md`)
**planId**: ssg4-02-doctor-storage-docs
**dependsOn**: ssg4-01-release-cascade-benchmark (wave 2). The docs describe
the final reduced-by-default behavior and the release rules that ssg4-01
proves.
**Design**: `design-docs/specs/design-session-storage-efficiency-and-default-gc.md`
§3 (representation to document), §4 (defaults), §5 (automatic maintenance),
§6 (doctor, including `session.payloadFragments` and the JSON shape), §7
(docs), §8 (upgrade notes), §10 (gc and compact behavior), §11 (isolation),
§13 row `ssg4-02` and its "Docs content" bullet
**Supersedes**: `impl-plans/completed/ssg3-02-doctor-storage-docs.md` and
`impl-plans/completed/ssg2-08-doctor-docs.md` (neither was implemented)
**Progress log**: `impl-plans/progress/ssg4-02-doctor-storage-docs.md` (new)
**Evidence root**: `tmp/ssg4/ssg4-02-doctor-storage-docs/` (gitignored)

**Build outputs**: SwiftPM/Xcode build products and caches under .build/, .swiftpm/ and the temporary HOME, and evidence logs under tmp/ssg4/<planId>/, are authorized untracked outputs of every plan's verification commands; artifactRoots stays [] and these writes are never an implementation blocker.

**writePaths**:
- `Sources/RielaCLI/StorageDoctorCommand.swift`
- `Tests/RielaCLITests/StorageDoctorCommandTests.swift`
- `docs/storage-doctor-and-compact.md`
- `docs/terminal-retention.md`
- `README.md`
- `impl-plans/progress/ssg4-02-doctor-storage-docs.md`

**sharedPaths**: none

`README.md` may be edited only inside the "## Runtime Data Retention"
section (line ~777).

## Intent and context

`riela doctor storage` must tell an operator four things:

- how many bytes can still be reclaimed;
- what the reduced payload representation costs (fragment and ref
  statistics);
- how to recover an `auto_vacuum=NONE` store;
- which legacy rows automatic maintenance parked.

It must stay strictly read-only. The user docs must describe everything the
branch changed. Write from the shipped code, and read these files first so
every number and name matches:

- `Sources/RielaCore/RuntimePayloadFragmentEncoder.swift`: `minimumFragmentBytes`
  1024, `referenceKey` `$rielaPayloadRef`, `markerKey` `_rielaPayloadRefs`,
  and the default `writesReducedExecutionPayloadsByDefault = true`.
- `Sources/RielaCore/RielaRetentionConfiguration.swift`: `RielaRetentionPolicy.builtInDefault`,
  `effectivePolicy(for:)`, `RielaRetentionPolicySource`.
- `Sources/RielaCLI/StorageMaintenanceConversion.swift`: budgets, retry
  share, and the parking warning text at ~line 227.
- `Sources/RielaCLI/StorageMaintenanceCursor.swift`: `fileName`
  `storage-maintenance.json`, the `Queue` fields, and
  `read(stateDirectory:) -> Self?`.
- `Sources/RielaCLI/RunEndStorageMaintenance.swift`: page caps and profiles.
- `Sources/RielaCLI/AutomaticRetentionHook.swift`: hosts and the scheduled
  pass.
- `Sources/RielaCore/RielaDataGarbageCollector.swift`: the read-only removal
  rule and `warnings`.
- `Sources/RielaCLI/StorageCompactCommand.swift`: the `workRemaining` rule.
- `Sources/RielaCLI/GarbageCollectionCommand.swift`: help text and defaults.

Current doctor code, in `Sources/RielaCLI/StorageDoctorCommand.swift`:

- `StorageDoctorFile.reclaimable: [String: Int64]` (line 58) is built at
  ~line 189 with `freePagesBytes`, `compactEstimateBytes` and
  `pruneEstimateBytes`. `compactEstimate` already includes the free pages.
- `StorageDoctorSession` is at ~line 24.
- `retentionReport(path:)` (~line 279) is **broken today, and this plan
  fixes it**. It takes the database path's parent directory as the session
  store root. A `session` database lives at
  `<store>/runtime-records/runtime-message-log.sqlite`
  (`CLIWorkflowSessionStore.defaultDatabasePath` → `canonicalRuntimeStoreRoot`,
  `CLIWorkflowSessionStore.swift:853-856`), so that parent is
  `<store>/runtime-records`, not the store root. The function also calls
  `RielaRetentionService` with `scope: .project` and no `projectDirectory`,
  and `RetentionTargetResolver.resolve` then returns no target
  (`RetentionTargets.swift:26-30`). The report is therefore always `nil`, and
  `pruneEstimateBytes` is always 0, even under the built-in defaults.
- `paths(_:)` (~line 89) already knows the real session store root of each
  database: it loops over `sessionRoots` (the explicit `--session-store`, or
  `CLIWorkflowSessionStore.resolveRootDirectory(... workingDirectory: working)`
  for project/user scope). It then appends `(path, kind)` for the `session`
  database and, when present, the `definitions` database
  (`SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root)`).
  `run(_:)` passes `workingDirectory: parsed.workingDir ?? cwd` to `inspect`.
- Automatic maintenance writes the cursor to the `stateDirectory` of the
  target that `RetentionTargetResolver.resolve` returns for the real store
  root and the project directory (`AutomaticRetentionHook.swift:94-96` →
  `RunEndStorageMaintenance.swift:12-18`). That is `<store>/retention` for an
  explicit store and `<…/.riela>/retention` for a user or project store
  (`RetentionTargets.swift:20-44`).
- The text renderer is `text(_:)` at ~line 329 (the `reclaimable:` line is
  ~line 343).

Helpers to reuse:

- Free space: the `RetentionSQLiteReclaimer().freeSpace` closure
  (`Sources/RielaCLI/RetentionSQLiteReclaimer.swift:39`); see its use at
  `StorageCompactCommand.swift:181`.
- State directory: `RetentionTargetResolver.resolve(scope:homeDirectory:projectDirectory:explicitSessionStore:environment:)`
  (`Sources/RielaCLI/RetentionTargets.swift:15`).

## Non-goals

- Doctor writes nothing. No cursor creation, no `RetentionTargetLock`, no
  migration, no directory creation, no `PRAGMA` that writes.
- No new CLI flags. No change to compact, gc, maintenance, retention or
  payload code. No GraphQL, SDL or catalog change.
- Docs: only the three files in writePaths. Keep README hunks inside the
  Runtime Data Retention section, because another workflow edits `main`. No
  design-doc edits; the supersession notes already exist. No changelog or
  version bump.
- No commit, stash, checkout, reset or restore.

## File-level changes

### 1. `Sources/RielaCLI/StorageDoctorCommand.swift`

**Session store root and target lookup. Do this first; every new session
field depends on it.**

- `paths(_:)` returns the session store root with each database, for example
  `[(path: String, kind: String, sessionRoot: String?)]`. `sessionRoot` is the
  `sessionRoots` loop variable for both the `session` and the `definitions`
  database, and `nil` for memory, cache and KV. `inspect` takes
  `sessionRoot: String?` in addition to its current `workingDirectory`.
  Never derive a store root from a database path again; remove the
  `deletingLastPathComponent()` root derivation from `retentionReport`.
- **Single target lookup** (a private helper used by both the maintenance
  lookup and `retentionReport`):
  - Call `RetentionTargetResolver.resolve` with `scope: .all`,
    `homeDirectory: URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory())`,
    `projectDirectory: URL(fileURLWithPath: workingDirectory)`,
    `explicitSessionStore: sessionRoot` and
    `environment: CLIRuntimeEnvironment.mergedProcessEnvironment()`.
  - Pick the target whose standardized `sessionStoreRoot` equals the
    standardized `sessionRoot`. Standardize with
    `URL(fileURLWithPath:).standardizedFileURL.path`, and also resolve
    symlinks, because macOS `/var` is a symlink to `/private/var`. If no
    target matches, return `nil`.
  - Passing `projectDirectory` matters: without it, a project store
    `<project>/.riela/sessions` resolves as an `explicit` target whose state
    directory is the wrong `<project>/.riela/sessions/retention`. With it,
    the resolver de-duplicates and returns the `project` target, whose state
    directory is `<project>/.riela/retention`, the same one maintenance uses.
- **`retentionReport` fix.** Build the `RielaRetentionRequest` from the same
  inputs: `trigger: .manual`, the same home, `projectDirectory: working`,
  `explicitSessionStore: sessionRoot`, the same environment, and
  `dryRun: true`. Choose `scope` from the matched target's kind: `.user` →
  `.user`, `.project` → `.project`, `.explicit` → `.all`. This avoids
  dry-running unrelated targets where possible. From
  `report.targets`, select the entry whose `root` equals the matched
  `target.root` (compare standardized paths). It is `nil` when no target
  matched. `pruneEstimateBytes` then reflects the effective policy, including
  the built-in defaults.
  - `dryRun: true` is read-only. `RielaRetentionService.run` takes no lock
    and writes no stamp when `dryRun` is true (`RielaRetentionService.swift:183-198,216-221`).
    `TerminalRetentionExecutor` opens the database `.strictReadOnly` in dry
    run (`TerminalRetentionExecutor.swift:90,304`). Keep `dryRun: true`.
    Never pass `.automatic`.

Pin these shapes. They are a JSON contract, and existing key names must not
change.

- `private struct StorageDoctorReclaimable: Codable` with fields:
  - `freePagesBytes: Int64`, `compactEstimateBytes: Int64`,
    `pruneEstimateBytes: Int64` (same names and values as today);
  - `remainingBytes: Int64`, equal to `compactEstimateBytes + pruneEstimateBytes`;
  - `remainingBytesIsUpperBound: Bool`, always `true`;
  - `recovery: StorageDoctorRecovery?`.
  `StorageDoctorFile.reclaimable` changes to this type.
- `private struct StorageDoctorRecovery: Codable` with fields:
  - `requiredFreeBytes: Int64`, equal to `2 * (fileBytes + walBytes) + 268_435_456`;
  - `availableFreeBytes: Int64?`, from `freeSpace` on the database directory;
  - `steps: String`.
  It is present only for `session` or `definitions` databases whose
  `autoVacuum == "none"`. Memory, cache and KV databases never get it.
  `steps` is a fixed English sentence: freed pages are reused but the file
  cannot shrink; stop writers and run `riela storage compact --apply` (or
  `riela gc`) once free space is at least `requiredFreeBytes`; otherwise
  follow the `VACUUM INTO` sequence in `docs/storage-doctor-and-compact.md`.
- `StorageDoctorSession` gains two fields:
  - `maintenance: StorageDoctorMaintenance?` with `parkedCount: Int` (sum of
    `parked.count + parkedOverflow` over all queues), `parkedExamples:
    [StorageDoctorParkedRow]` (`queue`, `key`, `error`; the first 5 in queue
    order snapshots, cliRecords, nested), `busyCount: Int`, `failedCount: Int`,
    `queuesComplete: Bool` (every queue `complete`), and `hint: String?`
    (`"run riela storage compact --apply"` when `parkedCount > 0`).
    The cursor is found through the **single target lookup** described below.
    Call `StorageMaintenanceCursor.read(stateDirectory: target.stateDirectory)`
    on that target. If there is no matched target, or the file is missing or
    invalid, the result is `nil`.
  - `payloadFragments: StorageDoctorPayloadFragments?` with `fragmentRows`,
    `fragmentBytes`, `reducedPayloadRows`, `refRows`, `danglingRefRows`,
    `unreferencedPayloadRows` and `unreferencedPayloadBytes` (all `Int64`),
    defined exactly as in design §6. It is `nil` when
    `workflow_runtime_payload_refs` does not exist (use `db.tableExists`).
    Join on `(root_session_id, digest)` in every query.
    `unreferencedPayloadBytes` is not added to `remainingBytes`.
- Text output, added to the existing per-file block; keep the `reclaimable:`
  prefix:
  - `  reclaimable: remaining <n> bytes (upper bound; free pages <n>, compact <n>, prune <n>)`
  - `  recovery: auto_vacuum=NONE; need <required> free bytes, available <available|unknown>; <steps>` when present
  - `  fragments: <fragmentRows> rows (<fragmentBytes> bytes), refs <refRows>, dangling refs <n>, unreferenced payloads <n> (<bytes> bytes)` when present
  - `  maintenance: parked <n>, busy <n>, failed <n>, complete <true|false>` plus `; run riela storage compact --apply` when parked > 0, only when the cursor exists

Imitate the existing private report helpers (`memoryReport`, `sessionReport`,
and `value(db, sql)`) for style and error handling.

### 2. `Tests/RielaCLITests/StorageDoctorCommandTests.swift`

Use `Tests/RielaCLITests/RielaCLIIsolatedEnvironment.swift` (temporary HOME
and project directory, `CLIRuntimeEnvironment.$captured`), as the existing
tests in this file do. Use temporary stores only. Add:

- incremental session store with `--output json` → `remainingBytes ==
  compactEstimateBytes + pruneEstimateBytes`, `remainingBytesIsUpperBound ==
  true`, and no `recovery`. The three old keys are present.
- `auto_vacuum=NONE` session store → `recovery.requiredFreeBytes == 2*(db+wal)+268435456`;
  `steps` contains `riela storage compact --apply` and `VACUUM INTO`.
- a store written with reduced payloads (default form; for example, save one
  execution with a 2048-byte `inputSnapshot` string through
  `SQLiteWorkflowRuntimePersistenceStore`) → `payloadFragments.fragmentRows
  >= 1`, `refRows >= 1`, `danglingRefRows == 0`, and
  `unreferencedPayloadRows == 0`. A store with an SQL-inserted dangling refs
  row → `danglingRefRows == 1`.
- **explicit store, pinned path.** Explicit store `S` (a temporary directory
  with a saved session; run with `--session-store S --output json`). The
  fixture cursor is written by the test at exactly
  `S/retention/storage-maintenance.json`, with 2 parked rows in `snapshots`
  and `parkedOverflow: 1`. Expect `parkedCount == 3`, examples holding the 2
  keys, and `hint` set. The cursor's bytes and modification date are
  unchanged after the command. Do not compute the fixture path through the
  production lookup helper; hard-code it from `S`.
- **project store, pinned path.** A store at `<isolation project>/.riela/sessions`,
  with the cursor fixture at exactly
  `<isolation project>/.riela/retention/storage-maintenance.json`, run with
  `--working-dir <isolation project>` and no `--session-store` → the
  `maintenance` report is present with the fixture's counts. A cursor placed
  only at the wrong `<project>/.riela/sessions/retention/storage-maintenance.json`
  must not be found.
- **default-policy prune.** No retention config at all, under isolated HOME
  and project, with a terminal (`completed`) root family whose `updatedAt` is
  more than 30 days before now, saved into `S`. Expect
  `pruneEstimateBytes > 0` and
  `remainingBytes == compactEstimateBytes + pruneEstimateBytes`. The family
  still exists afterward, because doctor is a dry run.
- **no cursor.** No cursor → `maintenance` is absent or null, and neither
  `S/retention` nor `<project>/.riela/retention` is created by the command.
- The existing read-only tests (`testDoctorStorageReadsDatabaseWithoutChangingBytesOrModificationDate`,
  `testDoctorReadOnlyReconciliationLeavesTreeAndLocksUntouched`) must keep
  passing unchanged now that the retention dry run really runs.
- text output contains `reclaimable: remaining`, and `fragments:` for the
  reduced store.

### 3. `docs/storage-doctor-and-compact.md`

Cover each item in design §13 "Docs content":

- **Payload representation:** subtrees of at least 1024 bytes are stored once
  per root as sha256 content-addressed fragments (`$rielaPayloadRef`,
  `_rielaPayloadRefs`), and this is the default for new writes. Every older
  format stays readable. Reads fail closed on a missing or corrupt fragment.
  The schema is generation 12, and older binaries refuse the store. There is
  no compression. Fragments are released when no longer referenced.
- **Automatic maintenance:** replaces the last paragraph's "4,096 / does not
  change retention" text. Cover hosts, terminal-only lock-skipping
  conversion, outcome classes with parking, the cursor file, budgets and
  retry share, the 4,096/65,536 page caps, no full `VACUUM`, and the opt-outs.
- **Doctor fields:** the new fields and the NONE recovery path. Keep the
  existing `VACUUM INTO` sequence.
- **`storage compact`:** the prune step uses the effective policy, including
  the defaults. Document the `workRemaining` definition (design §10.2).

### 4. `docs/terminal-retention.md` and the README Runtime Data Retention section

- Built-in defaults: results 30 days, messages follow results, logs 30 days,
  no byte cap. Only fully terminal, unprotected families are deleted.
- Per-category fill; opt-outs (`{"keepForever": true}`, `"automatic": false`,
  `RIELA_RETENTION_AUTOMATIC=0`); precedence (env > project > user); flags
  override; `riela gc --dry-run` shows `policySource`.
- The upgrade behavior change.
- The generated sweep runs only for a configured or flag-provided
  `results.maxAgeDays`. Read-only expired snapshot directories inside the
  store are made owner-writable and removed. An unremovable path is a
  warning, not a failure.
- Remove the README sentence "Retention for results, workflow messages and
  logs is off when no `retention` ..." (`README.md:779`).

## Pitfalls

- `JSONEncoder` drops `nil` optionals. That is fine for `recovery` and
  `maintenance`, but a test asserting `maintenance` is null must check that
  the key is absent or null, not a specific literal.
- Doctor must never call any helper that creates directories, such as the
  state-directory ensure helpers in retention, or `RetentionTargetLock`.
- The session database's parent directory is `runtime-records`, not the
  store root. Always use the `sessionRoot` carried from `paths(_:)`, together
  with `projectDirectory` set to the working directory. A self-consistent
  test that computes the cursor path through the production helper would hide
  this bug, so the tests pin absolute paths.
- If the default-policy prune test shows the dry run writing to the database
  (the read-only tests fail), stop and record it as blocked. Do not switch
  to a non-dry-run path.
- Do not de-duplicate `remainingBytes`; it is an upper bound by design.
- Every documented number must match the code. Record any design-vs-code
  mismatch in the progress log instead of guessing.
- Before editing a file, record its sha256 in
  `tmp/ssg4/ssg4-02-doctor-storage-docs/pre.sha256`. Read it fresh before
  every edit. Record `post.sha256` at the end.

## Acceptance criteria (mechanically checkable)

- `grep -nE "StorageDoctorReclaimable|StorageDoctorRecovery|StorageDoctorMaintenance|StorageDoctorPayloadFragments|remainingBytes" Sources/RielaCLI/StorageDoctorCommand.swift` → matches for each.
- `grep -n "deletingLastPathComponent" Sources/RielaCLI/StorageDoctorCommand.swift`
  shows no use in `retentionReport`. `retentionReport` and the maintenance
  lookup both pass `projectDirectory` and the `sessionRoot` from `paths(_:)`.
- These tests exist and pass: the cursor pinned at
  `S/retention/storage-maintenance.json` (explicit store), the cursor pinned
  at `<project>/.riela/retention/storage-maintenance.json` (project store via
  `--working-dir`), and default-policy `pruneEstimateBytes > 0`.
- `grep -n "is off when no" README.md` → no match.
- `built-in default` appears in README.md, docs/storage-doctor-and-compact.md and docs/terminal-retention.md.
- docs/storage-doctor-and-compact.md contains `storage-maintenance.json`,
  `parked`, `remainingBytes`, `payloadFragments`, `_rielaPayloadRefs`,
  `workRemaining` and `auto_vacuum`. docs/terminal-retention.md contains
  `keepForever` and `30 days`.
- Every test log ends with `exit=0` and 0 failures, including the
  isolation-proof run.

## Verification (each must exit 0)

```
mkdir -p tmp/ssg4/ssg4-02-doctor-storage-docs
test "$(mise which swift)" = /Users/taco/.local/share/mise/installs/swift/6.3.3/bin/swift
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -c 'set -o pipefail; /Users/taco/.local/share/mise/installs/swift/6.3.3/bin/swift build 2>&1 | tee tmp/ssg4/ssg4-02-doctor-storage-docs/build.log; s=$?; echo "exit=$s" >> tmp/ssg4/ssg4-02-doctor-storage-docs/build.log; exit $s'
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -c 'set -o pipefail; /Users/taco/.local/share/mise/installs/swift/6.3.3/bin/swift test --filter "Retention|GarbageCollection|StorageCompact|StorageDoctor|RunEndStorageMaintenance|AutomaticRetention|EventLiveServe|RuntimePayload|SchemaMigration|SQLiteRuntimeExecutionRows" 2>&1 | tee tmp/ssg4/ssg4-02-doctor-storage-docs/test.log; s=$?; echo "exit=$s" >> tmp/ssg4/ssg4-02-doctor-storage-docs/test.log; exit $s'
H="$(mktemp -d)" && mkdir -p "$H/.riela" && printf '%s' '{"retention":{"automatic":false,"results":{"keepForever":true},"messages":{"keepForever":true},"logs":{"keepForever":true}}}' > "$H/.riela/config.json" && HOME="$H" RIELA_RETENTION_AUTOMATIC=0 arch -arm64 /bin/zsh -c 'set -o pipefail; /Users/taco/.local/share/mise/installs/swift/6.3.3/bin/swift test --filter "Retention|GarbageCollection|StorageCompact|StorageDoctor|RunEndStorageMaintenance|AutomaticRetention|EventLiveServe|RuntimePayload|SchemaMigration|SQLiteRuntimeExecutionRows" 2>&1 | tee tmp/ssg4/ssg4-02-doctor-storage-docs/isolation-proof.log; s=$?; echo "exit=$s" >> tmp/ssg4/ssg4-02-doctor-storage-docs/isolation-proof.log; exit $s'
arch -arm64 /bin/zsh -lc 'set -o pipefail; swiftlint lint --strict Sources/RielaCLI/StorageDoctorCommand.swift Tests/RielaCLITests/StorageDoctorCommandTests.swift 2>&1 | tee tmp/ssg4/ssg4-02-doctor-storage-docs/lint.log; s=$?; echo "exit=$s" >> tmp/ssg4/ssg4-02-doctor-storage-docs/lint.log; exit $s'
/bin/zsh -c '! grep -n "is off when no" README.md'
/bin/zsh -c 'for f in README.md docs/storage-doctor-and-compact.md docs/terminal-retention.md; do grep -q "built-in default" "$f" || exit 1; done'
/bin/zsh -c 'for t in storage-maintenance.json parked remainingBytes payloadFragments _rielaPayloadRefs workRemaining auto_vacuum; do grep -q -F "$t" docs/storage-doctor-and-compact.md || exit 1; done; grep -q keepForever docs/terminal-retention.md && grep -q "30 days" docs/terminal-retention.md'
```

Evidence each command must establish:

- build.log, test.log, isolation-proof.log and lint.log end with `exit=0`.
- test.log and isolation-proof.log show the same final `Executed N tests,
  with 0 failures` count.
- The three doc checks exit 0.
- Save `git diff -U0 -- README.md` to
  `tmp/ssg4/ssg4-02-doctor-storage-docs/readme.diff`. Every hunk must sit
  between `## Runtime Data Retention` and the next `## ` heading.

## Progress log

Write `impl-plans/progress/ssg4-02-doctor-storage-docs.md` with:

- status;
- pre and post sha256;
- a sample doctor JSON from a temporary store showing `remainingBytes`,
  `recovery`, `payloadFragments` and `maintenance`;
- each command with its exit code and log path;
- the doc numbers cross-checked against the code (file:line);
- any reconciliation item.
