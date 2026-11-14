# Automatic config-driven retention

Status: design accepted for implementation on `feat/automatic-retention`.
Issue: workflowInput `automatic-config-driven-retention` ("Automatic,
config-driven retention for Riela session results, messages and logs"). There is
no GitHub issue number.

Baseline: `design-docs/specs/scoped-terminal-retention.md` (shipped in 0.2.16).
This design reuses its eligibility, locking, recheck, tombstone and secondary
cleanup rules. It adds a policy, automatic triggers, per-category pruning, a
reclamation strategy that does not need a full VACUUM, orphan-lock removal and a
manual front door. It replaces `gc.retentionDays` / `RIELA_GC_RETENTION_DAYS`.
There is no alias for the old keys.

## 1. Problem

On the operator machine `~/.riela` is 7.8G. The runtime DB
`sessions/runtime-records/runtime-message-log.sqlite` is 6.0G with
`auto_vacuum=0`. A second store, `sessions-telescreen`, holds 1.2G. `logs/` holds
534M of captured `--output jsonl` streams, and there are about 1300 lock files
in `execution-locks`. Today:

- `riela gc` removes only workflow-history snapshots, event receipts and
  terminal-task handover files/refs.
- `riela session prune` is safe, but it needs explicit roots and workflow ids,
  never runs automatically, and reclaims space with a full `VACUUM`. A full
  VACUUM needs about the DB size in free disk.

## 2. Configuration

### 2.1 Shape

`~/.riela/config.json`:

```json
{
  "retention": {
    "automatic": true,
    "minIntervalMinutes": 60,
    "results":  { "keepForever": false, "maxAgeDays": 30, "maxTotalBytes": "5GB", "keepWorkflowIds": ["release-audit"] },
    "messages": { "keepForever": false, "maxAgeDays": 30, "maxTotalBytes": "1GiB" },
    "logs":     { "keepForever": false, "maxAgeDays": 14, "maxTotalBytes": "1GB" }
  }
}
```

The documented example "keep results and messages forever, cap logs at 14 days
/ 1GB":

```json
{
  "retention": {
    "results":  { "keepForever": true },
    "messages": { "keepForever": true },
    "logs":     { "maxAgeDays": 14, "maxTotalBytes": "1GB" }
  }
}
```

### 2.2 Validation

Validation fails closed. Any error means no deletion in that pass.

| Field | Rule |
|---|---|
| `retention` | Optional object. If it is absent, nothing is deleted by any automatic pass. Unknown keys inside `retention` or inside a category are errors, so a typo cannot silently disable a limit. |
| `automatic` | Bool. Default `true` when `retention` is present. |
| `minIntervalMinutes` | Integer 1...10080. Default 60. |
| `<category>.keepForever` | Bool. Default false. If it is true, setting `maxAgeDays` or `maxTotalBytes` in the same category is an error. |
| `<category>.maxAgeDays` | Integer 1...36500. |
| `<category>.maxTotalBytes` | An integer from 1 to 2^50, or a string `^[0-9]+ ?(B\|KB\|MB\|GB\|TB\|KiB\|MiB\|GiB\|TiB)$` (units are case-insensitive). KB/MB/GB/TB are 1000-based; KiB/MiB/GiB/TiB are 1024-based. Decimals are rejected. |
| `results.keepWorkflowIds` | An array of non-empty strings, each at most 512 UTF-8 bytes. |

Each category is in one of three states:

- `keepForever`: untouchable by automatic passes and by manual `riela gc`. A CLI
  override flag for that category is a usage error.
- `active`: at least one limit is set.
- `notConfigured`: the object is absent or empty, so nothing is deleted.

One exception applies to messages. When `messages` is `notConfigured`, the
message rows of a family whose results are pruned are deleted in the same
transaction, which is today's behavior (§4.3).

Removed keys are errors with the exact text `gc.retentionDays was removed;
configure "retention" (see riela gc --help)`. This error fires when
`config.json` has a top-level `gc` key, or when `RIELA_GC_RETENTION_DAYS` is set
and not empty. Other unknown top-level keys in `config.json` are ignored, so
other features may own keys there.

### 2.3 Sources and precedence

Highest precedence first:

1. `RIELA_RETENTION`: inline JSON for the `retention` object. It replaces both
   files for every target.
2. Project `<project>/.riela/config.json` `retention`: when present, it replaces
   the user policy as a whole object, but only for the project target (§3).
3. User `~/.riela/config.json` `retention`.

`RIELA_RETENTION_AUTOMATIC` (`true|false|1|0`) overrides only `automatic`, after
the steps above. Any other value is a config error.

`riela gc` flags (§6) override single limits for that invocation only.

How the CLI and the app react to a config error:

- Automatic passes write one stderr warning and delete nothing.
- `riela gc` exits with the usage exit code (2).
- RielaApp logs a warning.

Config parsing and validation live in RielaCore as `RielaRetentionConfiguration`,
which replaces `RielaGarbageCollectionConfiguration`.

## 3. Targets

A *target* is one riela root that retention manages. Each target has its own
state directory, which holds the lock and the stamp.

| Target | Session store | Memory root (journal cleanup) | Logs root | State dir | Policy |
|---|---|---|---|---|---|
| user | `$HOME/.riela/sessions` | `$HOME/.riela/memory` | `$HOME/.riela/logs` | `$HOME/.riela/retention/` | user (or env) |
| project | `<project>/.riela/sessions` | `<project>/.riela/memory` | `<project>/.riela/logs` | `<project>/.riela/retention/` | project override, else user (or env) |
| explicit | the `--session-store` value, or `RIELA_SESSION_STORE` | `RIELA_MEMORY_ROOT` if set, else none | none | `<store>/retention/` | user (or env) |

Target rules:

- **Home.** `$HOME` comes from `CLIRuntimeEnvironment.homeDirectory`.
  `RIELA_WORKFLOW_HOME` does not move session storage, so it is not used here.
- **Project directory.** The project is the command's `--working-dir` /
  `--working-directory`, or the current working directory. RielaApp uses
  `launchOptions.projectRoot` and skips the project target when that is unset.
- **Deduplication.** Targets are deduplicated by standardized path. A project
  root equal to the user root is skipped. An explicit store equal to the
  user or project store merges into that target.
- **Missing roots.** A target whose root does not exist is skipped without
  creating directories. A target with no session DB and no logs directory
  creates no state directory.
- **Artifact root.** Automatic passes and `riela gc` never take an artifact root,
  because artifact roots are explicit per-run output directories owned by the
  user. Artifact-root cleanup stays in `riela session prune` (§7).
- **Optional roots.** `TerminalRetentionPaths` gains optional artifact and memory
  roots. An absent root is stored as `""` in the tombstone `artifact_root` /
  `memory_root` columns.
- **Root mismatch.** Pending tombstone cleanup recorded under different roots
  marks that family protected with `pendingRootsMismatch`. It no longer aborts
  the whole pass.
- **Unsafe paths.** Existing symlink and traversal checks still apply. A target
  whose path has a symlink component is skipped with warning `unsafePath`.
- **Unpaired journals.** Journals written to a memory root that is not paired
  with the store are left in place, never deleted.

## 4. Categories and eligibility

### 4.1 Common family rules

These rules are unchanged from the baseline. The unit is the full lineage
family, built by `TerminalRetentionPlan`. A family is eligible only if:

- every member is `completed` or `failed`;
- status projections agree;
- the lineage resolves;
- timestamps are known and not in the future;
- no member has a protection.

Existing protections are `unsettledNestedInvocation`, `loopBaseline`,
`concurrencyLease`, `externalRuntimeOwnership`, `conflictingLineage`,
`unmanagedSessionArtifacts` and the `journal*` protections. `created`,
`running`, `suspended` and any unknown status are protected. Terminal state is
never inferred from a missing process. The session that just finished is judged
by the same rules.

Execution:

1. Acquire kernel execution locks for every member, in sorted order and without
   blocking. A busy lock gives `executionLocked`.
2. Re-plan inside the runtime SQLite transaction. A family that changed gives
   `changedDuringAdmission`.
3. Commit tombstones before secondary cleanup.

Age is the family's newest `updatedAt`. Caps select the oldest eligible families
first (ties by `rootId`) until the projected total is at or under the cap.
Protected bytes still count toward the total. When the cap cannot be reached,
the report sets `capAchieved: false` and lists the protected reasons.

`TerminalRetentionPlan` changes:

- It takes a scope. `.workflows(Set)` keeps today's `session prune` semantics,
  including `rootOutsideScope`. `.allExcept(Set)` is the policy mode: a family
  where any member's `workflowId` is in the set is protected with `keptWorkflow`.
- It takes an optional age (`TimeInterval`) and an optional cap. At least one is
  required.
- It takes a byte selector, `results` or `messages`.
- `TerminalRetentionSession` carries `payloadBytes` (results) and `messageBytes`
  separately. `TerminalRetentionMetadata` and `TerminalRetentionSecondary.decorate`
  stop adding `workflow_messages` bytes into `payloadBytes`.

### 4.2 Results

Results cover these parts of terminal families in the target store:

- `workflow_runtime_snapshots`, `cli_workflow_sessions` and `loop_baselines`
  rows;
- `workflow_nested_invocations` rows whose whole family is selected;
- automatic `riela-node-manager` inbox/outbox journals in the paired memory root.

The tombstone semantics are unchanged.

The legacy generated-data sweep keeps running in `RielaDataGarbageCollector`, now
driven by `results.maxAgeDays` as its cutoff. It covers workflow-history
snapshots, `events/receipts` and terminal Work Runtime handover files and refs.
It runs only when results are `active` with `maxAgeDays`. `keepForever` skips it,
and the byte cap does not apply to it.

### 4.3 Messages

Messages are the `workflow_messages` and `workflow_message_payload_index` rows in
the target's runtime DB. The messages category is independent of results.

**Messages-only pruning.** This happens when results are kept or not yet
eligible. The family must pass the same eligibility, lock and recheck rules as
results, with age from family `updatedAt` and a cap over message bytes. Inside
the transaction:

- the family's message rows are deleted;
- one row per member is written to the new table
  `session_message_retention_tombstones(session_id PK, workflow_id, pruned_at,
  message_bytes)`. The rows hold no payload.

New guards for messages-only pruning:

- Triggers abort `INSERT` and `UPDATE` on `workflow_messages` and
  `workflow_message_payload_index` for any session in that table, in the same way
  as `ensureSessionRetentionTriggers`.
- `SessionExecutionLockRegistry.acquire` (unless `allowRetired`) throws a new
  `messagesRetired` error for such sessions, so resume and continue fail closed.
  This covers both commands: `session continue` delegates to
  `SessionResumeCommand` (`ScopedParityCommands.swift`), and that command admits
  the session through `makeSessionExecutionAdmission(registry:)`
  (`SessionCommands.swift:741,798`). `SessionRerunCommand` admits only its new
  session (`SessionCommands.swift:470,520`), which is why it needs the separate
  source check below.
- The rerun source load in `CLIWorkflowSessionResolution` rejects a source whose
  messages are retired, with the error `workflow messages expired under
  retention`.

Two rules keep messages-only pruning from blocking or starving the other passes:

- **Results pruning tolerates a messages-only retirement.** `acquire` gets a
  second option, `allowMessagesRetired: true`. It skips only the `messagesRetired`
  check. The results-tombstone `retiredSession` check stays on, so a session with a
  results tombstone is still rejected. Only the retention executor uses it, in
  both the results main loop and pending-cleanup recovery. `messagesRetired` is
  never mapped to the `executionLocked` protection. A family whose messages are
  already retired stays eligible for results pruning under the normal rules. When
  its results are pruned, its message tombstone rows remain, because they hold no
  payload. Resume, continue and rerun do not pass the option and still fail closed.
- **Messages-only selection skips families already retired.** A session already in
  `session_message_retention_tombstones` (equivalently, a family with zero
  remaining message bytes) is not selected again. Such families do not count
  toward the per-pass bound in §5.2, so they cannot keep `workLimitReached` true or
  starve newer families.

**Orphan messages.** These are message rows of sessions that already have a
results tombstone because messages were kept when results were pruned. They are
terminal by tombstone. They are eligible by their newest `created_at`, and by the
cap. The pass locks them with `allowRetired: true`, re-checks that the tombstone
exists inside the transaction, and deletes the rows.

**Results pruning removes a family's message rows only when** the messages
category is `notConfigured`. If messages are `keepForever` or `active`, results
pruning leaves the message rows for the messages category to judge. The existing
results-tombstone triggers already stop rows from being re-created.

### 4.4 Logs

Managed files are only regular files directly inside a target's logs root
(`<riela-root>/logs`, user and project). Riela itself writes no other log files.
The only content is operator-captured jsonl. Rules:

- Use `lstat`. Symlinks, directories, hidden names (leading `.`) and other
  non-regular entries are skipped and counted as protected. Nothing is followed
  or recursed into.
- Files modified within the last 24 hours (a fixed constant) are protected as
  `withinGraceWindow`, because an active writer may hold them open.
- Age rule: mtime is older than `now - maxAgeDays`. Cap rule: the total
  `st_size` of the managed files must be at or under `maxTotalBytes`. Files are
  deleted oldest mtime first, ties by name.
- Just before each unlink, `lstat` again. If the device, inode, size or mtime
  changed, or the file is no longer regular, skip it with `changedDuringAdmission`.
- When grace-protected bytes keep the total over the cap, the report sets
  `capAchieved: false`.

### 4.5 Orphan execution locks

After the results and messages steps, the pass checks
`<store>/runtime-records/execution-locks/*.lock`. A lock file is a candidate only
when its session id matches the existing id regex and is absent from both
`cli_workflow_sessions` and `workflow_runtime_snapshots`. Tombstoned ids count as
absent. For each candidate:

1. `open` without `O_CREAT`, then `flock(LOCK_EX|LOCK_NB)`. If the lock is busy,
   skip the file.
2. Under the lock, re-query the DB to confirm the session is still absent.
3. `unlink`, then close.

`SessionExecutionLock.init` is hardened to make the unlink safe. After `flock`
succeeds, it compares `fstat(fd)` (device and inode) with `stat(path)`. If they
differ, or the path is gone, it closes and retries the open, up to 8 times, and
then fails with `unavailable`. A live reservation holds its lock, so it is never
removed. A process that opened the old inode just before the unlink re-opens the
new path.

## 5. Automatic enforcement

### 5.1 Single flight and throttle

Each target's state directory holds:

- `automatic.lock`, an flock that is always taken non-blocking.
- `last-run.json`, with `{lastAttemptAt, lastCompletedAt, lastStatus}`. It is
  written by writing a temp file and renaming it, while holding the lock.

An automatic pass runs these steps for each target:

1. Read the stamp. If `lastAttemptAt` is within `minIntervalMinutes` and not in
   the future, the status is `skippedThrottled`.
2. Try the lock. If it is busy, the status is `skippedBusy`.
3. Re-read the stamp under the lock, in case another process just finished.
4. Write `lastAttemptAt`.
5. Run the pass.
6. Write `lastCompletedAt` and the status.

A stamp in the future counts as stale. Manual `riela gc` ignores the throttle,
still takes the lock (busy gives target status `busy`), and updates the stamp
unless it is a dry run. Dry runs take no lock and write nothing.

### 5.2 Per-pass order and bounds

Steps run in this order for each target:

1. results;
2. messages (family-based, then orphans);
3. logs;
4. generated sweep;
5. orphan locks;
6. reclamation (§5.3), once per touched DB.

The legacy pending-cleanup recovery runs first, as it does today.

Work per pass is bounded by internal constants, not config:

| Bound | Value |
|---|---|
| Families per category per target | 500 |
| Log unlinks | 1000 |
| Orphan-lock unlinks | 2000 |
| Incremental-vacuum pages per DB (automatic) | 65536 |

When a bound is hit, the report sets `workLimitReached: true`. Later passes
continue the work.

### 5.3 Reclamation without a full VACUUM

`TerminalRetentionSecondary.reclaim` currently runs `VACUUM` with
`wal_checkpoint(TRUNCATE)` and throws `reclamationBusy`. One reclaimer replaces
it for the runtime DB, the artifact message DB (session prune only) and memory
DBs. The reclaimer:

1. Reads `auto_vacuum`, `page_size`, `page_count` and `freelist_count`.
2. Sets `PRAGMA journal_size_limit=67108864` on its own connection.
3. When `auto_vacuum=INCREMENTAL`, runs `PRAGMA incremental_vacuum(N)` (N = 65536
   in automatic mode, all free pages in manual mode), then
   `PRAGMA wal_checkpoint(PASSIVE)`. A PASSIVE checkpoint never waits on or
   truncates another connection's WAL. An incomplete checkpoint gives
   `checkpointPending`, not an error.
4. When `auto_vacuum=NONE`, conversion means `PRAGMA auto_vacuum=INCREMENTAL;
   VACUUM`. It is allowed only when the free space on the volume is at least 2 ×
   (DB + WAL bytes) + 256 MiB. Automatic mode also requires the DB file to be at
   most 64 MiB. Otherwise the result is `deferredInsufficientSpace` or
   `deferredAutomaticSizeLimit`. Manual `riela gc` and `session prune` convert
   when space allows, so a large store converts once, on an operator-run `riela gc`.
5. A `SQLITE_BUSY` gives `busy` and is a warning, not a failure.
6. Never runs a full `VACUUM` on an already-converted DB.

Until conversion, freed pages are reused by SQLite, so the file stops growing.
The free-space provider and the size threshold can be injected in tests.

`reclaimedBytes` is reported honestly. It is the measured `stat` change in DB +
WAL file size. `reusableFreeBytes` is `freelist_count × page_size` after the
pass. The report also includes the action taken.

## 6. Triggers and manual surface

### 6.1 Triggers

| Trigger | Seam | Behavior |
|---|---|---|
| `workflow run`, `session resume`, `session rerun`, `session continue` | `RielaCLIMain.run` (`Sources/RielaCLI/EntryPoint.swift`) after the command result is written to stdout/stderr and before `exit` | Skipped when: the exit code is usage (2), the arguments contain `--help`/`-h`, the run task was cancelled by a signal, the policy is absent or has `automatic=false`, or there is a config error (one warning line). Targets are user, project and explicit, taken from leniently scanned `--working-dir`/`--working-directory` and `--session-store`. Nothing is written to stdout. Warnings go to stderr as lines prefixed `riela retention warning:`. The process exits with the command's own exit code in every case. |
| `riela events serve` | `EventLiveServe` loop | A `RielaRetentionScheduler` starts with the serve and stops when it ends. It runs non-overlapping automatic passes on a utility task and never blocks event dispatch. |
| `riela serve` | `ServeHTTPCommand` around its long sleep | The same scheduler, cancelled on SIGINT or SIGTERM. |
| RielaApp | `EntryPoint+GarbageCollection.swift` (renamed to retention) | Replaces `startGarbageCollection`. Runs one automatic pass at launch, then the scheduler. Uses `appHomeDirectory` and `launchOptions.projectRoot`, and the roots are injected in tests. |

The scheduler wakes every 5 minutes (injectable). On each wake it re-reads the
config, and the durable stamp decides whether to act. With no config, a wake
does nothing.

The shared entry point is `RielaRetentionService` in `Sources/RielaCLI` (public
for RielaApp). It takes this request:

```
{ trigger: automatic|manual, homeDirectory, projectDirectory?, explicitSessionStore?,
  environment, scope, overrides, dryRun }
```

It accepts an injected clock and an injected free-space provider, and it returns
`RielaRetentionReport`.

### 6.2 `riela gc`

`riela gc` is the manual front door for the same policy:

```
riela gc [--scope user|project|all] [--working-dir <dir>] [--session-store <path>] [--dry-run]
         [--results-max-age-days N] [--results-max-total-bytes SIZE]
         [--messages-max-age-days N] [--messages-max-total-bytes SIZE]
         [--logs-max-age-days N] [--logs-max-total-bytes SIZE]
         [--output text|json]
```

- `all` means user + project, plus explicit when `--session-store` or
  `RIELA_SESSION_STORE` is given.
- Flags may activate a `notConfigured` category for this invocation. Explicit
  flags count as configuration.
- A flag for a `keepForever` category is a usage error.
- With no config and no flags, the command reports every category as
  `notConfigured` and deletes nothing.
- `--retention-days` is removed, and ArgumentParser rejects it as unknown.

Exit codes:

| Code | When |
|---|---|
| 0 | Every target `completed` or `skipped`. This includes unmet caps. |
| 1 | Any target `failed` or `busy`. |
| 2 | Usage or config error. |

The JSON report (`--output json`) has this shape. In a dry run the `selected*`
fields say what would be removed, and the `removed*` fields are 0.

```
{ dryRun, trigger, targets: [ {
    kind: user|project|explicit, root, status: completed|skippedThrottled|skippedBusy|busy|skippedUnsafePath|failed,
    results:  { state, policy, selectedCount, removedCount, selectedBytes, removedBytes,
                beforeBytes, remainingBytes, capAchieved, protected: {reason: count},
                protectedFamilies: [{rootId, reason}] (first 50), pendingCleanupCount, workLimitReached },
    messages: { same fields, plus orphanSessionCount },
    logs:     { state, policy, selectedCount, removedCount, selectedBytes, removedBytes,
                beforeBytes, remainingBytes, capAchieved, protected: {reason: count}, workLimitReached },
    generated: { removedEntryCount, removedBytes },
    orphanLocks: { selectedCount, removedCount, skippedBusy },
    reclamation: [ { database, autoVacuum, action, fileBytesBefore, fileBytesAfter, reclaimedBytes, reusableFreeBytes } ],
    warnings: [string] } ] }
```

The text output prints one block per target, with one line per category
(removed or would-remove count and bytes, cap status, the top protected reasons)
and the reclamation lines.

### 6.3 Control surface

The `gc.sweep` row in `SurfaceCatalog+RowsCLI.swift` already uses
`localToolDefaults` (GraphQL `localProcess` exclusion). The parity gates
therefore need no GraphQL, SDL or web exposure. No DTO or catalog change is
made.

## 7. `riela session prune`

`session prune` stays as the explicit low-level command. It keeps its flags and
`.workflows(Set)` semantics, its explicit artifact root, and its JSON report.
Internally it uses the shared planner, the split byte accounting and the new
reclaimer in manual mode. Its report additionally carries the `reclamation`
entry.

## 8. Safety invariants

These are tested and cannot be negotiated:

1. No config means no deletion, by any automatic path.
2. `keepForever` categories are untouched by automatic and manual runs, even when
   another category is pruned.
3. Only families that are fully terminal and unprotected are deleted, after a lock
   and an in-transaction recheck. Byte-cap pressure never overrides a protection.
4. Retention never deletes user-authored memory, persona, checkpoints, export
   receipts, workflow definitions, packages, registries, kaiba data or artifact
   roots.
5. Retention failures never change a command's exit code or stdout. The jsonl
   stream gains no records.
6. Dry runs write nothing: no tombstone tables, no stamp, no lock files.
7. Log deletion touches only regular files directly in a logs root that are
   outside the grace window, and never follows a symlink.

## 9. Docs

- **README.** Replace the "Runtime Data Garbage Collection" section
  (README.md:540-574) with the retention policy, the keep-forever example, the
  precedence and env overrides, and `riela gc` usage.
- **Terminal-retention doc.** Update `docs/terminal-retention.md`: it is now the
  low-level command, and the full-VACUUM wording around line 64 is replaced by
  the reclaimer behavior (§5.3).
- **CLI help.** Update `rielaCLIHelpText` and `riela gc --help`.
- **Skill.** Add a short "Disk retention" section to
  `Resources/skills/riela-workflow-run/SKILL.md`.
- **Out of scope.** The `riela-troubleshooting` skill lives in the riela-packages
  registry, outside this repository, so it is not updated here.

## 10. Verification

All tests use realpath-resolved temp roots (macOS `/var` is a symlink, which
`TerminalRetentionPaths` rejects), fake clocks and injected free space. They
never touch the real `~/.riela`.

- RielaCoreTests `RielaRetentionConfigurationTests`: shape, defaults, size
  parsing, range errors, the `keepForever` + limit conflict, unknown-key errors,
  removed-key errors (`gc`, `RIELA_GC_RETENTION_DAYS`), precedence (env > project
  > user) and `RIELA_RETENTION_AUTOMATIC`.
- RielaCoreTests `TerminalRetentionPlanTests`: `.allExcept` with
  `keepWorkflowIds`, an age-only plan, a cap-only plan, the messages byte
  selector, and protected families under cap pressure.
- RielaCoreTests log planner tests: age, cap ordering, grace, symlink and
  non-regular protection.
- RielaCLITests `AutomaticRetentionTests`:
  - a mock-scenario `workflow run` against a temp HOME prunes an old terminal
    family, and the exit code and stdout are unchanged;
  - a failing pass only warns;
  - throttle stamp;
  - busy lock skip;
  - no config means no deletion;
  - each `keepForever` category kept while another category is pruned;
  - messages-only pruning and the rerun/resume `messagesRetired` rejection;
  - results pruning of a family whose messages were already retired succeeds
    (not `executionLocked`), while a results-tombstoned session still fails
    closed;
  - a second messages pass does not re-select already-retired families, and the
    bound is not consumed by them;
  - orphan message pruning;
  - running, suspended, created, locked and ambiguous families protected under
    cap pressure.
- RielaCLITests `RetentionReclamationTests`: after pruning, an incremental DB
  physically shrinks with no VACUUM executed; a `NONE` DB above the automatic
  threshold is deferred; manual conversion happens with enough free space and is
  deferred without it.
- RielaCLITests `SessionExecutionLockTests`: orphan-lock removal, a busy lock
  kept, and an inode-mismatch retry.
- RielaCLITests `GarbageCollectionCommandTests` and `CommandParsingTests`: flags,
  the `keepForever` override error, the dry-run JSON report writing nothing, exit
  codes, and help text.
- RielaCLITests `TerminalRetentionTests`: session prune regression with the
  optional roots and the `pendingRootsMismatch` protection.
- RielaAppSupportTests: RielaApp retention start uses the injected home only.

Gate commands:

```
arch -arm64 /bin/zsh -lc 'swift build && swift test --filter "Retention|GarbageCollection|SessionPrune|SessionExecutionLock|CommandParsing"'
```

The gate also includes `swiftlint` on touched files.
