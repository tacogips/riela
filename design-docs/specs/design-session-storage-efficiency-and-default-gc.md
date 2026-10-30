# Session store efficiency and default GC

Status: draft for step 3 review, 2026-10-30. Branch
`feat/message-log-storage-gc`. Source: the inline workflowInput "Stop the Riela
session store from growing to many GiB". There is no GitHub issue. The defaults
this design assumes are listed in
`design-docs/user-qa/qa-session-storage-default-gc.md`.

This design extends two baselines. It does not restart either one:

- `design-efficient-history-and-storage.md` (§5 session rows and payloads, §7
  reclamation, §8 doctor/compact). Its tables, envelope, nested refs, conversion
  functions and reclaimer are reused. This design adds §3 (reduced execution
  payloads). It also replaces the §5 "Run end" paragraph and the
  `qa-efficient-history-and-storage.md` Q1 decision with §5 below.
- `design-automatic-retention.md` (policy, planner, protections, locks,
  tombstones, scheduler). Its invariant 1 ("no config means no deletion", §2.2
  and §8.1) is replaced by §4 below. Every other rule, including the protections,
  the in-transaction recheck and `keepForever`, is unchanged.

## 1. Verified current state (HEAD `9ab7058e`)

- **Payloads.** `workflow_runtime_payloads(root_session_id, digest, bytes BLOB
  CHECK(json_valid(bytes, 8)), byte_count)` stores one row per distinct
  execution JSON, keyed by `sha256` of the sorted-keys `payloadJSON` text
  (`SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift:86-137,271-280`).
- **Readers.** Readers depend on `bytes` being JSONB:
  - session assembly is SQL `json(p.bytes)` (`+SessionFamily.swift:369-392`,
    used by `load` and `+WebSummaries.swift:191`);
  - web summaries run `json_extract(p.bytes, '$.stepId'|'$.status')`
    (`+WebSummaries.swift:251-256`);
  - list counts run `json_extract(p.bytes, '$.importedFrom')`
    (`CLIWorkflowSessionStore.swift:509-515`);
  - nested hydration runs `json(p.bytes)` and checks
    `sha256(text) == digest` (`+NestedInvocations.swift:636-700`).
- **Redundancy.** `inputSnapshot` (`RuntimeSession.swift:266`) re-embeds
  upstream accepted outputs on every iteration, so whole-execution digests
  almost never repeat (848 distinct out of 862). zlib's 32 KiB window cannot
  see repeats that far apart (gzip about 5.7x over the concatenation), but
  long-range matching can (zstd --long about 58x). The redundancy is
  repeated JSON subtrees.
- **zlib.** zlib already exists as `CZlib` in `Packages/RielaMemory`
  (`VersionedHistoryCodec`), and it builds on Linux CI.
- **Retention.** `RielaRetentionService.run` drops every target whose policy
  is `nil` on automatic triggers (`RielaRetentionService.swift:151-157`).
  `RielaRetentionConfiguration.policy(for:)` returns `nil` when no `retention`
  key exists, so nothing is deleted without config.
- **Run-end maintenance.** `AutomaticRetentionHook.runIfApplicable` calls
  `RunEndStorageMaintenance` only for a target whose retention pass reported
  `completed` (`AutomaticRetentionHook.swift:96-101`). Without config it
  therefore never vacuums. The vacuum is capped at 128 pages, even though
  efficient-history §5 documents 4,096.
- **Scheduler hosts.** `events serve` (`EventLiveServe.swift:1114-1137`) and
  `serve` (`ServeHTTPCommand.swift:108-123`) already run a
  `RielaRetentionScheduler` (5-minute wake) that calls
  `AutomaticRetentionHook.runAutomaticPass`. RielaApp runs the scheduler with
  `RielaRetentionService` directly (`Sources/RielaApp/EntryPoint+Retention.swift`).
  Each wake does retention only. No host converts legacy rows or vacuums.
- **Legacy conversion.** `convertLegacySession`, `convertLegacyRecord` and
  `convertLegacyNestedInvocation` exist and are resumable. Only
  `riela storage compact --apply` calls them
  (`StorageCompactCommand.swift:214-262`), and it selects rows with a
  `LIMIT 10000` scan of each table.
- **Schema.** Runtime schema generation is 11
  (`+SchemaMigrations.swift:123`).

## 2. Scope

In scope:

- **Part A.** A reduced representation for new execution payloads (§3).
- **Part B.** Built-in default retention (§4), bounded automatic storage
  maintenance in every automatic host (§5), and doctor reporting (§6).

Out of scope:

- payload compression (rejected, §3.7);
- rewriting existing canonical (generation-11) execution rows;
- new manual commands;
- GraphQL, SDL and catalog changes;
- RielaMemory, definitions and the KV, cache and memory stores;
- Package manifests, versions and releases.

## 3. Part A: reduced execution payloads

### 3.1 Encoding rule

Execution payloads are encoded by one function,
`RuntimePayloadFragmentEncoder.encode(execution)`, in
`Sources/RielaCore`. It is a pure, deterministic function of the execution
value.

1. Serialize the execution exactly as today (`payloadJSON`: `JSONEncoder`,
   `.sortedKeys`, `RuntimeSnapshotDates`).
2. Inside `inputSnapshot` only, walk the tree bottom-up. A candidate is an
   object, array or string value, including `inputSnapshot` itself. A
   candidate is hoisted when its serialized text, after its own children have
   been replaced, is at least `minimumFragmentBytes = 1024` UTF-8 bytes.
   Serialization uses the same encoder settings as step 1.
3. **Hoisting.** A hoisted value becomes a *fragment* row, and its place in
   the tree becomes the reference object `{"$rielaPayloadRef":"<sha256 hex of
   the fragment text>"}`.
4. **Marker.** If anything was hoisted, the execution payload gains the
   top-level key `"_rielaPayloadRefs"`. Its value is the sorted, de-duplicated
   array of every fragment digest the payload needs, transitively, so a single
   query can fetch all of them.
5. **Escape rule.** If `inputSnapshot` contains any object key
   `$rielaPayloadRef` anywhere, that execution is stored unreduced, exactly as
   today. No escaping syntax is introduced.
6. **Unchanged fields.** `stepId`, `status`, `importedFrom`, and every
   top-level field other than `inputSnapshot`, stay as they are. The SQL
   readers listed in §1 therefore keep working without any change.

### 3.2 Storage and references (generation 12, additive DDL only)

- **Fragment rows.** Fragments are ordinary `workflow_runtime_payloads` rows:
  JSONB, the same root scope, `INSERT OR IGNORE`, and `byte_count` set to the
  UTF-8 length of the stored text.
- **New table:**

  ```
  workflow_runtime_payload_refs(root_session_id TEXT NOT NULL, parent_digest TEXT NOT NULL,
                                digest TEXT NOT NULL,
                                PRIMARY KEY(root_session_id, parent_digest, digest)) WITHOUT ROWID
  INDEX (root_session_id, digest)
  ```

  It holds one row per (reduced payload, fragment digest in its
  `_rielaPayloadRefs`) pair. Rows are inserted with the parent payload, with
  `INSERT OR IGNORE`.
- **Migration.** `SQLiteRuntimeExecutionRowsSchema` creates the table and the
  index with `IF NOT EXISTS`. `schemaGeneration` becomes 12. No existing row
  is rewritten when the store is opened.
- **Release.**
  - `releasePayloadIfUnreferenced` and `releaseUnreferencedPayloads` also
    require that no `workflow_runtime_payload_refs` row has `digest = d`.
  - When a payload row is deleted, its `workflow_runtime_payload_refs` rows
    where `parent_digest = d` are deleted in the same transaction, and each
    child digest returned is released by the same rule.
  - Fragments never carry their own `_rielaPayloadRefs` (step 4 flattens
    them), so release is one level deep.
- **Retention.**
  - `TerminalRetentionExecutor` deletes `workflow_runtime_payload_refs WHERE
    root_session_id = ?` together with the root's payloads
    (`TerminalRetentionExecutor.swift:629-630`).
  - `ensureSessionRetentionTriggers` adds INSERT/UPDATE guard triggers on the
    new table (`SessionRetentionTombstones.swift:25-35`).
  - Byte accounting (`TerminalRetentionMetadata.swift:61-66`) already sums
    every payload row of a root. Fragments are included without any change.

### 3.3 Digest rules

- Every payload row's digest is `sha256` of exactly the canonical JSON text
  stored in that row. This is uncompressed text, so the rule is unchanged from
  today.
- A reduced execution's digest covers the digests of its fragments, because
  their references are part of its text. The whole execution is therefore
  verifiable as a Merkle tree.
- The same execution value always yields the same text and digest (§3.1 is
  pure), so content addressing and dedup within a root stay stable.
- A generation-11 full-text row and a generation-12 reduced row for the same
  execution have different digests. Both stay readable. Nothing compares
  execution digests across rows except release, which is per digest.

### 3.4 Reads (backward compatible)

Expansion happens in Swift at the only two assembly points:

- **`assembledSessionData`** (`+SessionFamily.swift:369`), which serves
  `load`, family hydration and web session views. After the existing SQL
  assembly, if any execution object carries `_rielaPayloadRefs`:
  1. Fetch `SELECT digest, json(bytes) FROM workflow_runtime_payloads WHERE
     root_session_id = ? AND digest IN (...)`, batched at 500 parameters,
     inside the same read transaction.
  2. Verify `sha256(text) == digest` for every fragment.
  3. Substitute the references recursively and remove `_rielaPayloadRefs`.
  4. Re-encode the session for the existing `WorkflowSession` decode.
  5. A missing or mismatched fragment throws
     `runtime payload fragment missing or corrupt: <digest>`. This fails
     closed and never returns a partial snapshot.
- **`hydratedNestedSnapshot`** (`+NestedInvocations.swift:670`) runs the
  same expansion on each execution payload after its existing digest check.

Every existing representation stays readable: legacy inline
`session_json.executions`, legacy CLI full copies, legacy embedded nested
JSON, generation-11 full execution payloads, and generation-12 reduced
payloads. They are told apart by the existing markers
(`_rielaExecutionStorage`, `sessionStorage`, `childSnapshotStorage`) plus the
new `_rielaPayloadRefs`.

Expansion yields the same `JSONValue` tree that the stored text would
otherwise have decoded to. Public outputs are produced from the decoded
`WorkflowSession`, so they are byte-identical. This covers session
status/export/logs/progress, GraphQL session views, resume and rerun, and the
rerun carry-over reads of `inputSnapshot` (`mergedVariables`,
`_rielaHistoryContract`).

### 3.5 Writers

These three paths use the encoder:

- `writeExecutionRows`, for every save, including fast-path appends and full
  rebuilds;
- `persistNestedReferences` for execution payloads, so a child's nested refs
  dedupe against the child's own execution rows;
- every legacy conversion, which already goes through `upsertSnapshot` and the
  nested encoders.

Existing generation-11 canonical rows are not rewritten in bulk. They change
to the reduced form on their session's next save, or they age out under §4.
The `PersistenceWriteSample.boundBytes` metric reports reduced bytes.

### 3.6 Expected effect

- In a loop whose iteration *k* re-embeds *k* upstream outputs of size *S*,
  generation-11 storage grows as O(*k*²·*S*).
- Reduced storage grows as O(*k*·*S*) plus about 200 bytes of reference
  overhead per hoisted value.
- The acceptance test (§9) requires a ratio of at least 5x.

### 3.7 Rejected: payload compression

zlib (`CZlib`) is portable, but compression is rejected for this change:

- The `CHECK(json_valid(bytes, 8))` constraint means compressed bytes need
  either a table rebuild of multi-GB stores or a parallel column.
- Every SQL reader in §1 would have to move to Swift decoding.
- Per-payload deflate cannot see the cross-payload repetition that dominates
  the measured data.

Fragment dedup removes the same redundancy that `zstd --long` exploits. It
needs no codec, no linkage and no `Package.swift` change.

## 4. Part B1: built-in default retention

### 4.1 Effective policy

`RielaRetentionConfiguration` resolves an effective policy for every target.
`RielaRetentionPolicy.builtInDefault` is:

| Field | Built-in default |
|---|---|
| `automatic` | `true` |
| `minIntervalMinutes` | 60 |
| `results` | `maxAgeDays: 30`, no byte cap |
| `messages` | follow results: a pruned family's message rows are deleted with it (today's `notConfigured` behavior) |
| `logs` | `maxAgeDays: 30`, no byte cap |
| `definitions` | unchanged (keep 10 versions) |

Resolution:

- **No `retention` object** in any source (`RIELA_RETENTION`, project, user):
  the target uses `builtInDefault`. `policy(for:)` never returns `nil`.
- **A `retention` object is present.** Each category that is absent, or is
  `{}`, or has only `keepWorkflowIds`, takes that category's built-in default.
  `keepWorkflowIds` is kept. A category with `keepForever` or explicit limits
  is used exactly as configured. Top-level fields default as before.
- **Overrides.** Precedence (env > project > user), validation, the removed-key
  errors and the `riela gc` flags are unchanged. Flags override the effective
  policy.
- **Opt-outs.** They are documented together:
  - `"<category>": {"keepForever": true}` keeps that category.
  - `"automatic": false` or `RIELA_RETENTION_AUTOMATIC=0` disables every
    automatic pass, including §5. Manual `riela gc` still applies the effective
    policy.

### 4.2 What stays protected

The planner, the protections, locking and the recheck are reused unchanged
(`design-automatic-retention.md` §4.1):

- Only families whose every member is `completed`, `failed` or `cancelled` are
  eligible.
- A held execution lock gives `executionLocked`.
- Every family protection still applies: `created`, `running`, `suspended`,
  unknown status, unsettled nested invocations, conflicting lineage, loop
  baselines and leases, and Work Runtime ownership.
- Families whose lineage cannot be resolved from scalar metadata are protected
  (`conflictingLineage`, an unresolved lineage), including partially migrated
  legacy rows.

### 4.3 Generated sweep is not defaulted

`RielaDataGarbageCollector` (workflow-history snapshots, event receipts,
handover files) still runs only when `results.maxAgeDays` comes from config or
a flag, not from the built-in default. Defaults therefore never delete
`riela workflow versions` restore points.

### 4.4 Report

- Each category report gains `policySource: configured|default|override`.
- `state` is `active` for defaulted results and logs. Messages that follow
  results report `notConfigured` with `policySource: default`.
- The text output prints, for example, `results: older than 30 days (built-in
  default)` instead of "no cap".
- `riela gc --dry-run` with no config shows these limits and the selection.
- The `storage compact` prune step uses the same effective policy.

### 4.5 Replaced invariant

`design-automatic-retention.md` §8.1 now reads: "With no config, only the
built-in default policy applies. It deletes only fully terminal, unprotected
families older than 30 days, with their messages, and regular files in a logs
root older than 30 days. `keepForever` and `automatic: false` turn it off."

Invariants 2-7 are unchanged.

## 5. Part B2: automatic storage maintenance

### 5.1 Entry points

`RunEndStorageMaintenance` is extended. No parallel mechanism is added. It
runs per target session store with a profile:

| Host | Call site | Profile |
|---|---|---|
| `workflow run`, `session resume/rerun/continue` | `AutomaticRetentionHook.runIfApplicable`, after the retention pass, for the selected target | `runEnd` |
| `events serve`, `serve`, RielaApp | the scheduler pass `AutomaticRetentionHook.runAutomaticPass`, after the retention pass, for every resolved target with a session store | `scheduled` |

- **runEnd target selection.** `AutomaticRetentionHook.selectedSessionStoreRoot`
  (`AutomaticRetentionHook.swift:126-150`) is extended. Today it returns a
  target only for an explicit store or for `workflow run`. For `session
  resume|rerun|continue` without an explicit store, it now picks the target by
  the command's `--scope`, mirroring `CLIWorkflowSessionStore.resolveRootDirectory`
  (`CLIWorkflowSessionStore.swift:93-117`): `user` selects the user target, and
  any other or absent value (`auto`, `project`, `direct`) selects the project
  target. An explicit store (`--session-store` or `RIELA_SESSION_STORE`) still
  wins. The `workflow run` selection is unchanged.
- **RielaApp.** Its scheduler closure switches from `RielaRetentionService().run`
  to the same scheduled pass. That pass is exposed as one public function in
  RielaCLI, so RielaApp and the CLI share it.
- **When it runs.** Maintenance runs when the target is resolved, its path is
  safe, and the effective `automatic` is true. It no longer depends on the
  retention target reporting `completed`.
- **When it is skipped.** A config error skips it with the existing single
  warning.
- **Output.** Warnings go to stderr with the `riela retention warning:`
  prefix. The exit code, stdout and the jsonl stream never change.

### 5.2 Single flight

Maintenance takes the target's existing `automatic.lock`
(`RetentionTargetLock.tryAcquire`) without blocking. When the lock is busy,
the pass is skipped silently. It is not throttled by `last-run.json`. Instead,
it is O(1) when there is no work (§5.3).

### 5.3 Steps

**Step 1: legacy conversion.** This step is bounded, resumable and runs only
for terminal sessions.

- **Queues.** There are three queues. Each walks a primary key with a keyset
  cursor, so each step costs O(batch) and survives VACUUM.

  | Queue | Key | Legacy predicate (existing) | Converter (existing) |
  |---|---|---|---|
  | snapshots | `workflow_runtime_snapshots.workflow_execution_id` | inline `executions` array without `_rielaExecutionStorage` | `convertLegacySession` |
  | cliRecords | `cli_workflow_sessions.session_id` | `sessionStorage` is not `canonical` | `convertLegacyRecord` |
  | nested | `workflow_nested_invocations.invocation_key` | `childSnapshotStorage` is absent | `convertLegacyNestedInvocation` |

- **Eligibility.** A row is converted only when all of these hold. They match
  the constraint "never rewrite resumable sessions":
  - its session is `completed`, `failed` or `cancelled`. The canonical
    snapshot status wins when present.
  - for nested rows, the parent is terminal and the child is terminal or
    absent.
  - every involved session's execution lock is acquired with
    `SessionExecutionLockRegistry.acquire(..., allowMessagesRetired: true)`,
    without blocking. These are the session itself, or the parent and child
    for nested rows.

  Locks are released right after the item.
- **Outcomes.** Every examined row ends in exactly one of these classes, and
  each class has an exit rule. The cursor `after` key always moves past the
  row, so no class can hold the cursor back.

  | Class | Trigger | Rule |
  |---|---|---|
  | converted | the converter returned `true` | done |
  | notLegacy / gone | the converter returned `false`, or the row was deleted | done; any busy/failed/parked entry for the row is removed |
  | nonTerminal | an involved session is not terminal | skipped permanently; it converts on its own next save, because any status change saves the session (existing "first save rewrites them" rule) |
  | retired | `acquire` throws `retiredSession` (a results tombstone; `messagesRetired` cannot occur because of `allowMessagesRetired: true`) | skipped permanently; retention owns the row; never retried |
  | busy | `acquire` throws `alreadyRunning` or `unavailable` | added to the queue's `busy` list (transient) |
  | failed | `acquire` throws `invalidSessionId`, or the converter throws | the attempt count in the queue's `failed` map goes up by 1. On the 3rd failed attempt, or immediately for `invalidSessionId`, the row moves to `parked` |

- **Busy list.** It holds at most 256 keys per queue. Every pass re-attempts
  busy rows within the retry share (below). A busy row leaves the list when
  it ends in any class other than busy. When the list is full, a newly busy
  row is not recorded. The cursor still moves past it, and the queue sets
  `rescanNeeded = true`. When the forward scan of a queue reaches its end with
  `rescanNeeded = true`, the queue resets to `after = null`,
  `complete = false`, `rescanNeeded = false`, so the next passes rescan the
  queue from the start. Rows already converted are cheap `notLegacy` hits on
  a rescan. A full busy list therefore never stops the cursor; it only
  schedules a later rescan.
- **Failed map and parked list.**
  - A failed row is re-attempted at most once per pass, within the retry
    share, until it converts, leaves the legacy set, or is parked. The map
    holds at most 256 keys. When it is full, a newly failing row is parked
    directly.
  - A parked row is never retried automatically, deleted or rewritten. It
    stays legacy, stays readable, and remains convertible by
    `riela storage compact --apply`.
  - `parked` holds at most 256 keys. Beyond that, only `parkedOverflow` is
    incremented.
  - During a rescan, forward-scan rows listed in `parked` are skipped without
    an attempt. Overflowed parked rows are attempted again only during a
    rescan, and a rescan happens only after busy-list overflow. Their extra
    attempts are therefore bounded by the number of rescans.
  - When a row is parked, the pass writes one stderr warning
    `riela retention warning: legacy <queue> row <key> parked after
    <n> failed conversions: <error>; run riela storage compact --apply`.
    `riela doctor storage` reports the parked rows (§6).
- **Budgets and retry share.** A pass has a total budget per profile. Busy
  and failed re-attempts run first, but they may use at most half of each
  budget dimension. The forward scan gets the rest, plus whatever the retries
  left unused. The budget is checked between items, so one huge row can
  overrun its share by at most one item. The clock is injected for tests.

  | Profile | Total conversions / rows examined / wall time | Retry share (max) |
  |---|---|---|
  | `runEnd` | 16 / 256 / 2 s | 8 / 128 / 1 s |
  | `scheduled` | 64 / 1024 / 10 s | 32 / 512 / 5 s |

  The forward scan is therefore always guaranteed at least half of every
  budget dimension. It also always examines at least one row per pass for
  each queue that is not `complete`, even when a retry overran the wall-time
  share. In every pass where a queue is not `complete`, its cursor
  moves forward by at least one row. A fixed set of failing or busy rows
  cannot stall conversion, and each deterministically failing row costs at
  most 3 attempts.
- **Cursor.** The cursor is `<target stateDir>/storage-maintenance.json`:

  ```
  { "version": 1,
    "queues": { "snapshots" | "cliRecords" | "nested": {
        "after": <key> | null, "complete": Bool, "rescanNeeded": Bool,
        "busy": [<key>],                  // ≤ 256
        "failed": { <key>: <attempts> },  // ≤ 256, attempts 1...2
        "parked": [{ "key": <key>, "error": <string ≤ 512 bytes> }],  // ≤ 256
        "parkedOverflow": Int } } }
  ```

  - It is written by writing a temp file and renaming it, while holding
    `automatic.lock`.
  - A missing or invalid file restarts every queue from the beginning. This is
    safe because conversion is idempotent. Failed counts and parked entries
    are lost in that case, so each failing row costs at most 3 more attempts.
  - No current writer produces legacy rows. When every queue is `complete`
    with empty `busy` and `failed`, Step 1 does nothing (O(1)). Parked rows do
    not keep Step 1 active.

**Step 2: bounded incremental vacuum.** This is the existing
`RunEndStorageMaintenance` body:

- the open uses `busyTimeoutMilliseconds: 0` and `waitForLocks: false`;
- it acts only when `auto_vacuum = INCREMENTAL` and `freelist_count ≥ 128`;
- it runs `incremental_vacuum(min(freelist, cap))`, then
  `wal_checkpoint(PASSIVE)`;
- `SQLITE_BUSY` is skipped.

The page cap becomes 4,096 for `runEnd`, which matches the efficient-history
§5 text, and 65,536 for `scheduled`, which matches the automatic reclaimer
bound. Maintenance never runs a full `VACUUM` and never converts an
`auto_vacuum = NONE` database. Those stay with `riela gc`, `session prune` and
`storage compact --apply`, under the existing free-space and live-session
checks. Live SQLite, WAL and SHM files are never unlinked.

### 5.4 Ordering inside one host pass

The order is:

1. retention (existing order, including its own reclaimer);
2. Step 1, conversion;
3. Step 2, vacuum.

Families old enough to be pruned are therefore deleted rather than converted,
and the pages freed by conversion are reclaimed in the same pass.

## 6. Part B3: `riela doctor storage`

The command stays read-only. For each session or definitions database:

- **`reclaimable.remainingBytes`** = `compactEstimateBytes` +
  `pruneEstimateBytes`. `compactEstimateBytes` already includes the free
  pages (`StorageDoctorCommand.swift:180`). The sum is an upper bound because
  prune and compact can count the same legacy row, and it is marked
  `remainingBytesIsUpperBound: true`. `pruneEstimateBytes` now reflects the
  effective policy (§4), including defaults.
- **`reclaimable.recovery`** is present when `autoVacuum` is `none`:
  - `requiredFreeBytes` = 2 × (DB + WAL) + 256 MiB;
  - `availableFreeBytes` (read-only `statfs`);
  - a fixed `steps` text: freed pages are reused but the file cannot shrink;
    stop writers and run `riela storage compact --apply` (or `riela gc`) once
    when free space ≥ `requiredFreeBytes`; otherwise use the documented
    `VACUUM INTO` sequence.

  The text output prints the same information as one line.
- **`session.maintenance`** (session databases only). Doctor reads the §5.3
  cursor file without taking a lock and without creating it. The file is found
  through the same `RetentionTargetResolver` state-directory mapping. The
  report has:
  - `{parkedCount (parked + parkedOverflow), parkedExamples: [{queue, key,
    error}] (first 5), busyCount, failedCount, queuesComplete: Bool}`;
  - the hint `run riela storage compact --apply` when `parkedCount > 0`.

  When the file is absent, `session.maintenance` is `null`.

## 7. Docs

- **`docs/storage-doctor-and-compact.md`:**
  - the reduced payload representation and its readability guarantees;
  - automatic maintenance (hosts, terminal-only and lock-skipping rules, the
    outcome classes including parked rows, cursor file, budgets and retry
    share, page caps);
  - the replacement of the last paragraph's "4,096 / does not change retention"
    text;
  - the new doctor fields and the recovery path.
- **README retention section and `docs/terminal-retention.md`:** the built-in
  defaults, per-category fill, opt-outs (`keepForever`, `automatic: false`,
  `RIELA_RETENTION_AUTOMATIC=0`), and the upgrade behavior change.
- **`riela gc --help` text** (`rielaCLIHelpText`): the defaults.
- **Baselines:** short supersession notes in `design-automatic-retention.md`
  §2.2/§8, `design-efficient-history-and-storage.md` §5 "Run end", and the
  two QA files.

## 8. Rollout constraints

- **Downgrade.** Generation 12 is additive. Older binaries reject the store
  through the existing newer-generation error. They could not expand
  references, so the rejection is required.
- **Behavior change on upgrade.** Stores with no `retention` config start
  losing terminal families older than 30 days, and log files older than
  30 days, on the first automatic pass. This is documented in README and the
  retention doc.
- **First-pass cost.** The first automatic pass after upgrade is bounded by
  the existing per-pass limits (500 families per category, 65,536 vacuum
  pages).
- **Manifests and releases.** No `Package.swift` change, no new dependency,
  no version bump, no release. Commits are local only (`gitPush=false`).
- **Merge conflicts.** Changes stay in the storage, retention and maintenance
  files and their docs. RielaApp changes only in `EntryPoint+Retention.swift`.
- **Efficient-history plans.** The `impl-plans/active/efficient-history.md`
  index still lists eh-06, eh-07 and eh-10 as pending, but their code is in
  the tree (commits `358dfc73`, `ba193f81`, `59ca48ee`). This change gets its
  own impl-plan and reuses those functions. It does not reopen the eh plans or
  re-implement CLI-envelope dedup.

## 9. Verification

All tests use realpath-resolved temp roots, injected clocks and free space,
and never touch `~/.riela` or a project store.

- **RielaCoreTests `RuntimePayloadFragmentTests`** (new):
  - **Determinism.** The same execution gives the same text and digests.
  - **Escape rule.** An execution containing `$rielaPayloadRef` is stored
    unreduced.
  - **Benchmark.** A synthetic loop session has at least 20 iterations, each
    re-embedding all prior upstream outputs of at least 4 KiB. Stored payload
    bytes are `SUM(length(bytes))` of the root's payload rows plus the key
    lengths of its `workflow_runtime_payload_refs` rows. They must be at most
    one fifth of the sum of the distinct generation-11 full payload texts for
    the same executions.
  - **Round-trip.** `load` returns a `WorkflowSession` equal to the input.
  - **Fail closed.** A missing or corrupted fragment throws.
  - **Release.** Release and truncation leave no orphan fragment or ref row.
  - **Nested.** Nested refs hydrate equal and share fragments with the child's
    rows.
  - **Migration.** Generation 11 → 12 migration is DDL-only.
- **RielaCLITests `SessionStore` / `CLIWorkflowSessionEnvelopeTests`.** The
  same session is written once through the reduced path and once as a legacy
  inline fixture. These outputs are byte-identical between the two:
  - `session status`, `export`, `logs` and `progress` in `--output json`;
  - the GraphQL session view;
  - `resume` and `rerun` admission inputs.
- **`RielaRetentionConfigurationTests`, `TerminalRetentionPolicyTests` and
  `AutomaticRetentionTests`:**
  - with no config, an automatic pass prunes a terminal family older than 30
    days and keeps a 29-day family and a running, suspended, created, locked
    or tree-member family;
  - per-category default fill;
  - `keepForever` and `automatic: false` honored;
  - the generated sweep does not run on defaults;
  - `policySource` is reported.
- **`GarbageCollectionCommandTests`:**
  - `riela gc --dry-run --output json` with no config reports `maxAgeDays: 30`
    and `policySource: default`, and writes nothing;
  - `riela gc` with no config removes the old terminal family.
- **`RunEndStorageMaintenanceTests`:**
  - a store with legacy inline snapshots, legacy CLI copies and embedded nested
    rows converts over repeated passes within the budgets;
  - a lock-held terminal session is skipped and goes to `busy`, then converts
    after release;
  - **parking.** A deterministically failing terminal legacy row is placed
    before convertible rows (for example, a `session_json` the current decoder
    rejects). It is attempted at most 3 times across passes, then parked with
    one stderr warning, and never attempted again. The convertible rows after
    it still convert. Doctor reports `parkedCount: 1`;
  - **retired rows.** A row whose session has a results tombstone (`acquire`
    throws `retiredSession`) is skipped permanently. It never enters `busy` or
    `failed`, and the cursor moves past it;
  - **retry share.** With 256 busy rows and failing rows that use up the retry
    share, every pass still moves the forward cursor by at least one row. The
    retry phase never exceeds half of the conversion and row budgets (an
    injected clock checks the wall-time share). With the busy list full, an
    extra busy row sets `rescanNeeded`, and a later rescan converts it after
    its lock is released;
  - non-terminal legacy rows are untouched;
  - the cursor resumes after a simulated interruption, and a corrupt cursor
    restarts;
  - an incremental store's file size decreases after the pass;
  - a `NONE` store gets no `VACUUM`;
  - the pass runs without retention config;
  - a busy `automatic.lock` skips the pass.
- **`EventLiveServeTests`.** The scheduler pass (injected short interval)
  converts a legacy row and vacuums.
- **`StorageDoctorCommandTests`:**
  - `remainingBytes` is reported;
  - `recovery` appears for a `NONE` store and is absent for an incremental
    one;
  - `session.maintenance` reports parked rows from a fixture cursor file
    without modifying it.
- **`AutomaticRetentionTests`, runEnd selection.** `session resume`,
  `rerun` and `continue` without an explicit store select the project target
  by default and the user target with `--scope user`.
- **`StorageCompactCommandTests`:** regression, with the prune step using
  defaults.

Gate commands:

```
arch -arm64 /bin/zsh -lc 'swift build'
arch -arm64 /bin/zsh -lc 'swift test --filter "Retention|GarbageCollection|StorageCompact|StorageDoctor|RunEndStorageMaintenance|SessionStore|AutomaticRetention|EventLiveServe|RuntimePayloadFragment|SQLiteRuntimeExecutionRows|RuntimePersistenceBoundedWrite|CLIWorkflowSessionEnvelope"'
arch -arm64 /bin/zsh -lc 'swiftlint lint <touched files>'
```

A Linux build check (`swift build` in `swift:6.3.3-noble`, matching
`linux-amd64-build.yml`) is required if one is available. The change adds no
linkage, so the risk is only source portability.
