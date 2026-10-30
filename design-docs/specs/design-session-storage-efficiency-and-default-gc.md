# Session store efficiency and default GC

Status: revised 2026-10-30 (replan rerun). The first revision was accepted at
step 3 (comm-010590) and partly implemented as `sgc-01..03`. This revision
keeps every accepted decision. It adds the three operational fixes (§10), the
test-isolation rule (§11) and the `ssg2-` implementation partition (§12), and
it corrects stale wording found against the uncommitted code (§4.1, §5.1).
Branch `feat/message-log-storage-gc`. Source: the inline workflowInput "Stop
the Riela session store from growing to many GiB". There is no GitHub issue.
The defaults this design assumes are listed in
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
- **Schema.** Runtime schema generation is 11 at HEAD
  (`+SchemaMigrations.swift:123`).

### 1.1 Uncommitted state on the branch (HEAD `493a5de6` + working tree)

This work is preserved and built on. It is not rewritten.

- **Default retention (sgc-02), implemented, not reviewed.**
  `RielaRetentionPolicy.builtInDefault`, `RielaRetentionPolicySource`
  (`configured|default|override`), `RielaRetentionConfiguration.effectivePolicy(for:)`
  and `automaticOverride` (`RielaRetentionConfiguration.swift`);
  `policySource` on `RetentionCategoryReport`; the service uses the effective
  policy and skips the generated sweep when `sources.results == .builtInDefault`
  (`RielaRetentionService.swift:151-170,292-293`); `riela gc` text and help
  (`GarbageCollectionCommand.swift:65-90`).
- **Fragments (sgc-01), schema only.** Generation 12, the
  `workflow_runtime_payload_refs` table and index, the 11→12 migration
  (`SQLiteRuntimeExecutionRowsSchema.swift`, `+SchemaMigrations.swift`), the
  retention delete of ref rows (`TerminalRetentionExecutor.swift:629-631`) and
  the tombstone guard triggers (`SessionRetentionTombstones.swift:35-44`).
  There is no encoder, writer, hydration, release, test or benchmark. The
  schema bump alone saves nothing and already makes older binaries reject the
  store.
- **Maintenance (sgc-03), partial.** `Sources/RielaCLI/StorageMaintenanceCursor.swift`
  (the §5.3 cursor model with read and atomic write) and `session
  resume|rerun|continue` target selection by `--scope`
  (`AutomaticRetentionHook.swift:130-133`). Maintenance is still gated on a
  `completed` retention target (`AutomaticRetentionHook.swift:96-101`), and
  the vacuum cap is still 128 pages (`RunEndStorageMaintenance.swift:7`).

### 1.2 Operational defects found on the real store

- **Test isolation.** Retention, gc, compact and maintenance tests call CLI
  runners and `AutomaticRetentionHook.runIfApplicable` without overriding the
  environment. `CLIRuntimeEnvironment.homeDirectory()` then reads the process
  `HOME`, so the developer's `~/.riela/config.json` and any ambient
  `RIELA_RETENTION*`/`RIELA_SESSION_STORE` value change the result. Example:
  `StorageCompactCommandTests.testNoRetentionPolicyReportsDefaultAndKeepsSessionDatabase`
  (`StorageCompactCommandTests.swift:477-494`). Only three call sites in that
  file override `HOME` (`:52`, `:68`, `:325`). `runIfApplicable` also uses
  the process working directory (`AutomaticRetentionHook.swift:88`), so tests
  resolve the repository checkout as the project target.
- **Read-only snapshot directories fail `riela gc`.**
  `RielaDataGarbageCollector.remove` calls `removeItem` once and records any
  error as a diagnostic (`RielaDataGarbageCollector.swift:511-531`). Expired
  `workflow-history/*/snapshots/registry-before-*` directories are written
  read-only (`dr-xr-xr-x`, files `r--r--r--`), so removal fails.
  `RielaRetentionService` then marks the whole target `failed` when any
  generated diagnostic exists (`RielaRetentionService.swift:300-303`).
- **`storage compact --apply` never reports done.** `workRemaining` is set by a
  failed retention pass (`StorageCompactCommand.swift:301`) and by any `live`
  or `skipped` abandoned-invocation verdict (`StorageCompactCommand.swift:265`).
  Neither is conversion or reclamation work that compact can finish, so the
  flag stays `true` forever with 0 converted and 0 reclaimed.

## 2. Scope

In scope:

- **Part A.** A reduced representation for new execution payloads (§3).
- **Part B.** Built-in default retention (§4), bounded automatic storage
  maintenance in every automatic host (§5), and doctor reporting (§6).
- **Part C.** The `riela gc` read-only snapshot fix and the `storage compact`
  `workRemaining` fix (§10).
- **Test isolation** for every retention, gc, compact and maintenance test
  (§11).

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
- **Release.** It is delivered in two parts (§12).
  - **Guard (`ssg2-01`).** `releasePayloadIfUnreferenced` and
    `releaseUnreferencedPayloads` also require `NOT EXISTS (SELECT 1 FROM
    workflow_runtime_payload_refs WHERE root_session_id = p.root_session_id
    AND digest = p.digest)`. Without it, the run-end release
    (`SQLiteWorkflowRuntimePersistenceStore.swift:747,873-874`, which also
    runs on the first save of an already-terminal root) deletes every fragment,
    because fragments are referenced by neither `workflow_runtime_executions`
    nor `workflow_nested_invocation_refs`. With only the guard in place,
    fragments can leak through stale refs rows, but a referenced fragment is
    never deleted.
  - **Cascade (`ssg2-03`).** The rest of reference-aware release:
    - When a payload row is deleted, its `workflow_runtime_payload_refs` rows
      where `parent_digest = d` are deleted in the same transaction, and each
      child digest returned is released by the same rule.
    - Fragments never carry their own `_rielaPayloadRefs` (step 4 flattens
      them), so release is one level deep.
    - This closes the leak that the guard alone allows.
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

Public read paths and the assembly point each one reaches. Every row was
checked against the SQL readers of `workflow_runtime_payloads` in
`Sources/RielaCore` and `Sources/RielaCLI`; no other reader parses
`inputSnapshot`.

| Public read path | Store entry | Expansion point |
|---|---|---|
| `session status`, `export`, `logs`, `progress`; `resume`, `rerun`, `continue` admission and rerun carry-over | `load(sessionId:)`, `load(sessionId:in:)`, `loadStrictReadOnly` → `snapshot(from:db:)` | `assembledSessionData` |
| session family, rollup, `loadAll` | `loadRollupSnapshots`, `loadRollupSnapshotPage`, `loadAll` → `snapshot(from:db:)` | `assembledSessionData` |
| GraphQL session views, web session detail | `loadWebSessionDetail` (`+WebSummaries.swift:191`) | `assembledSessionData` |
| web summaries, CLI list counts | SQL `json_extract` on `$.stepId`, `$.status`, `$.importedFrom` | none needed (top-level fields unchanged, §3.1 step 6) |
| nested invocation records and reservations (parent and child) | `nestedInvocationRecord(s)`, `decodedReservation`, `decodedNestedSnapshot` | `hydratedNestedSnapshot` |
| nested callee payload | `decodedReservation` (`calleeDigest`) | none needed (not an execution payload; never reduced) |

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

**Write switch.** The store has one internal property,
`writesReducedExecutionPayloads`. When it is `false`, the writers above
store full generation-11 payloads exactly as today. Its default stays `false`
until the full reference-aware release (§3.2 "Release", guard and cascade) is
in place, and then becomes `true` (§12, `ssg2-03`). Production therefore never
writes fragments that could leak before the cascade exists. Tests set it to
`true` before `ssg2-03` to exercise the reduced form, and to `false` to build
generation-11 fixtures for the parity tests. It is not a user setting, not an
environment variable and not configuration.

Test safety before `ssg2-03` comes from the §3.2 guard, which ships in
`ssg2-01`, not from the switch. Tests that save terminal root sessions in the
reduced form, including the `ssg2-02` parity tests, rely on that guard: the
run-end release keeps every referenced fragment.

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
  the target uses `builtInDefault`. `policy(for:)` keeps returning the raw
  configured policy (`nil` when absent), and every caller that applies
  retention uses `effectivePolicy(for:)`, which never fails to return a policy
  and carries per-category `sources`. (This corrects the earlier wording
  "`policy(for:)` never returns `nil`"; the implemented split is kept.)
- **`RIELA_RETENTION_AUTOMATIC`** applies to the effective policy even when no
  `retention` object exists (`automaticOverride`).
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

### 4.6 Review of the existing implementation (§1.1)

The uncommitted sgc-02 code is reviewed against §4.1-§4.5 and repaired in
place, not rewritten. The review checks these rules, and each one needs a
test in the gate filter:

1. No config at all: every category reports its default, `policySource:
   default`, and `results`/`logs` are `active` with `maxAgeDays: 30`.
2. Per-category fill: a `retention` object with only `messages` configured
   still gets defaulted `results` and `logs`. `keepWorkflowIds` survives the
   fill.
3. `keepForever` on a category and `automatic: false` (config, or
   `RIELA_RETENTION_AUTOMATIC=0` with no config) are honored. The automatic
   trigger skips the target; manual `riela gc` still applies the effective
   policy.
4. A `riela gc` flag sets that category's `policySource` to `override`.
5. The generated sweep does not run when `results` comes from the default,
   and does run for a configured or flag-provided `results.maxAgeDays`.
6. `riela gc --dry-run` writes no tombstone, no `last-run.json` and no
   deletion.
7. The §4.2 protections hold under the default policy: running, suspended,
   created, locked and tree-member families are kept; a 29-day terminal
   family is kept; a 31-day one is removed.

A defect is any rule that fails. It is fixed in the plan that owns the
review (§12, `ssg2-06`).

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
- **Explicit store equal to a scoped store.** `RetentionTargetResolver`
  de-duplicates an explicit store whose root equals the user or project store,
  so no target of kind `explicit` exists in that case and today's
  `targets.first(where: { $0.kind == .explicit })` returns `nil`. With an
  explicit store, selection instead picks the target whose `sessionStoreRoot`
  equals the resolved explicit root, whatever its kind.
- **Working directory.** `runIfApplicable` takes the current directory as a
  parameter (default: the process working directory), so tests can pass a
  temporary project directory (§11).
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
bound. This removes the 128-page cap (`RunEndStorageMaintenance.swift:7`)
that kept the file from shrinking. The caps stay finite so that one pass
cannot hold the write lock for an unbounded time; a store with more free
pages shrinks over consecutive passes. The 128-page minimum free-list
threshold is unchanged. Maintenance never runs a full `VACUUM` and never converts an
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
  - the new doctor fields and the recovery path;
  - the `workRemaining` definition (§10.2).
- **README retention section and `docs/terminal-retention.md`:** the built-in
  defaults, per-category fill, opt-outs (`keepForever`, `automatic: false`,
  `RIELA_RETENTION_AUTOMATIC=0`), the upgrade behavior change, and the
  generated-sweep handling of read-only snapshot directories and unremovable
  paths (§10.1).
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
- **Superseded plans.** `impl-plans/active/session-storage-gc.md`,
  `session-storage-gc-01..05-*.md` and `session-storage-gc-dispatch.json` are
  moved to `impl-plans/completed/` with a short "superseded by ssg2" note, and
  `impl-plans/README.md` is updated to match. The `impl-plans/progress/sgc-0*.md`
  logs stay as history. No `ssg2-` plan reads or continues them (§12).
- **Concurrent edits on `main`.** Another workflow edits `main`. This change
  never merges or rebases `main` and stays inside the files named in §12.

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
    the same executions. The test prints both numbers and the ratio.
  - **Terminal save keeps fragments (`ssg2-01`).** With the switch set to
    `true`, saving a `completed` root session whose `inputSnapshot` has a
    subtree of at least 1 KiB triggers the run-end release. This covers both
    a status transition and a first save that is already terminal. The number
    of fragment rows (digests listed in `workflow_runtime_payload_refs`) and
    their bytes are unchanged afterwards. The test checks this through SQL,
    because expansion arrives in `ssg2-02`.
  - **Round-trip.** `load` returns a `WorkflowSession` equal to the input.
  - **Fail closed.** A missing or corrupted fragment throws.
  - **Release (`ssg2-03`).** Release and truncation leave no orphan fragment
    or ref row.
  - **Nested.** Nested refs hydrate equal and share fragments with the child's
    rows.
  - **Migration.** Generation 11 → 12 migration is DDL-only.
- **`RuntimePayloadReadParityTests`** (new; the class name must contain
  `RuntimePayload` so the gate filter selects it; it lives in RielaCLITests,
  or in the GraphQL test target for the GraphQL case). The same session,
  including a nested invocation, is written three ways: reduced, generation-11
  full payloads (`writesReducedExecutionPayloads = false`), and a legacy inline
  fixture. These outputs are byte-identical across the three:
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
  defaults; plus the §10.2 cases.
- **`GarbageCollectionCommandTests` / `RielaRetentionServiceTests`:** the §10.1
  cases.
- **Isolation:** the §11 rule applies to every test above.

Gate commands. Every command exits 0 when the change is complete. Each
`ssg2-` plan lists only the subset its own changes make pass (§12).

```
HOME=$(mktemp -d) arch -arm64 /bin/zsh -lc 'swift build'
HOME=$(mktemp -d) arch -arm64 /bin/zsh -lc "swift test --filter 'Retention|GarbageCollection|StorageCompact|StorageDoctor|RunEndStorageMaintenance|SessionStore|AutomaticRetention|EventLiveServe|RuntimePayload|SchemaMigration'"
H=$(mktemp -d) && mkdir -p "$H/.riela" && printf '%s' '{"retention":{"automatic":false,"results":{"keepForever":true},"messages":{"keepForever":true},"logs":{"keepForever":true}}}' > "$H/.riela/config.json" && HOME="$H" RIELA_RETENTION_AUTOMATIC=0 arch -arm64 /bin/zsh -lc "swift test --filter 'Retention|GarbageCollection|StorageCompact|StorageDoctor|RunEndStorageMaintenance|SessionStore|AutomaticRetention|EventLiveServe|RuntimePayload|SchemaMigration'"
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict <touched swift files>'
```

The third command is the isolation proof (§11): the same suites must pass
with a `HOME` whose config, and an ambient environment variable, would
disable every default the tests rely on.

A Linux build check (`swift build` in `swift:6.3.3-noble`, matching
`linux-amd64-build.yml`) is run if one is available. It is not a gate command,
because the environment may not provide it. The change adds no linkage, so the
risk is only source portability.

## 10. Part C: `riela gc` and `storage compact` fixes

### 10.1 Read-only expired paths in the generated sweep

Scope: `RielaDataGarbageCollector.remove` for the generated sweep
(workflow-history snapshot children, event receipts, handover files). Handover
git refs are unchanged. Dry runs never change permissions.

1. Try `removeItem` as today.
2. If it fails, and only when all of these hold, restore permissions and retry
   once:
   - the entry is not a symbolic link;
   - the resolved path of the entry's parent lies inside the resolved
     collection root (`<home>/.riela` or `<project>/.riela`) of the current
     scope;
   - the entry is owned by the effective uid.
3. **Permission restoration.** Walk the entry tree without following symbolic
   links (each node is checked with `lstat` semantics; a symbolic link is
   never descended and its target is never changed). For the entry and every
   descendant that is a directory owned by the effective uid, add owner
   `rwx` (`u+rwx`) when it is missing. Files are not changed, because unlinking
   needs write permission only on the directory. Nodes owned by another uid
   are left unchanged. The entry's parent (for example `snapshots/`) is never
   changed.
4. **Unremovable path.** If the retry still fails, or step 2 does not apply,
   the path and error go to a new non-fatal list, `RielaGarbageCollectionReport.warnings`.
   `diagnostics` stays for collector-level errors (for example an invalid
   retention day count).
5. **Report.** `RielaRetentionService` appends generated `warnings` to the
   target's `warnings` without changing `status`. Only `diagnostics` still set
   `status = "failed"`. The target and the store are therefore `completed`
   when the only problem is an unremovable path, `riela gc` exits 0, and the
   automatic hook prints nothing for it (it only prints `failed` targets).

Acceptance tests (temporary HOME and stores only):

- an expired `snapshots/registry-before-x` directory with mode `0555`
  containing `0444` files and a `0555` subdirectory is removed by
  `riela gc --results-max-age-days 1`, and the target reports `completed`;
- a symbolic link inside that entry, pointing at a read-only directory outside
  the collection root, is removed as a link; the outside directory keeps its
  mode and contents;
- an expired entry whose parent `snapshots/` directory is made `0555` by the
  test is reported once in `warnings`, the target is `completed`, the exit
  code is 0, and other expired entries in other `snapshots/` directories are
  still removed (the test restores the mode in teardown);
- `--dry-run` changes no mode.

### 10.2 `storage compact` `workRemaining`

`workRemaining` is `true` if and only if conversion or reclamation work is
still pending after the run:

| Sets `workRemaining` | Does not set it |
|---|---|
| a conversion loop stopped at `--max-batch` | retention target status `failed` or `busy` |
| a legacy row was skipped because its lock was held, or its conversion threw | abandoned-invocation verdicts (`live`, `recent`, `skipped`, `abandoned`) |
| memory history conversion reports `remaining > 0` or throws | retention or generated-sweep warnings |
| definition-pin backfill throws | |
| the dry-run estimate finds convertible rows | |
| reclaimer `checkpointPending`, `deferredInsufficientSpace`, `deferredLiveSessions`, `busy`, `failed`, or `incrementalVacuum` with `reusableFreeBytes > 0` | |

A failed or busy retention pass still adds the warning
`retention pass reported failure: <first target warning>` (or
`retention target busy`), and abandoned-invocation verdicts stay in
`reconciled`. Exit codes are unchanged.

Acceptance tests:

- a store whose only issue is a retention warning (the §10.1 unremovable
  path) reports `workRemaining: false` on `--apply`, with the warning listed;
- a second `--apply` on a fully converted, reclaimed store reports
  `workRemaining: false`, 0 converted and 0 reclaimed;
- a live nested invocation does not set `workRemaining`;
- a lock-held legacy session still sets `workRemaining: true`.

## 11. Test isolation

Every test that runs a CLI runner (`riela gc`, `storage compact`, `doctor
storage`, `events serve`), `AutomaticRetentionHook`, the scheduler pass,
`RunEndStorageMaintenance`, `RielaRetentionService` or
`RielaRetentionConfiguration.load` follows these rules:

- **Environment.** CLI code runs inside
  `CLIRuntimeEnvironment.$captured.withValue(env)`. `env` is a complete
  environment: `HOME` is a temporary directory, `PATH` and `TMPDIR` are copied
  from the process, and only the `RIELA_*` keys the test sets itself are
  present. `$captured` replaces the process environment, so an ambient
  `HOME`, `RIELA_RETENTION`, `RIELA_RETENTION_AUTOMATIC`, `RIELA_SESSION_STORE`
  or `RIELA_WORKFLOW_HOME` cannot leak in. `$overrides` alone is not enough,
  because it only adds keys.
- **Direct calls.** A `RielaRetentionRequest` or a
  `RielaRetentionConfiguration.load` call gets the temporary home, a temporary
  project directory and an explicit environment dictionary. It never gets
  `ProcessInfo.processInfo.environment`.
- **Project directory.** Every test passes a temporary project directory
  (`--working-dir`, the `currentDirectory` parameter of `runIfApplicable`
  (§5.1), or an explicit `--session-store`). No test resolves the repository
  checkout as its project target.
- **Subprocesses.** A test that launches a `riela` process passes the same
  complete environment to it instead of inheriting the test process
  environment.
- **Paths.** Temporary roots are realpath-resolved
  (`URL.resolvingSymlinksInPath`), because macOS `/var` is a symlink.
- **Helper.** One test-support file in `Tests/RielaCLITests` provides the
  temporary home, project directory and captured environment, so every suite
  uses the same rule.
- **Proof.** The third gate command (§9) runs the suites with a conflicting
  `HOME` config and `RIELA_RETENTION_AUTOMATIC=0`. It must pass.

## 12. Implementation partition (`ssg2-` plans)

Each plan is small enough for one implementer in one execution: at most about
four production source files plus their tests. Plan ids are new, so no
`sgc-` progress log or continuation count applies.

| Plan | Scope (design §) | Production files (approx.) | dependsOn |
|---|---|---|---|
| `ssg2-01` (a) | encoder; writer into `workflow_runtime_payload_refs`; the refs `NOT EXISTS` guard on both `releasePayloadIfUnreferenced` and `releaseUnreferencedPayloads` (§3.2 "Release", Guard); write switch default `false`; keep and test the existing generation-12 DDL/migration; §9 "Terminal save keeps fragments" test (§3.1-3.3, §3.5) | new `RuntimePayloadFragmentEncoder.swift`; `+SessionFamily.swift` (`writeExecutionRows`, guard in both release statements); `+NestedInvocations.swift` (`persistNestedReferences`); `SQLiteWorkflowRuntimePersistenceStore.swift` (switch) | — |
| `ssg2-02` (b) | fail-closed sha256-verified expansion at both assembly points; read parity for every §3.4 path including nested, on terminal and non-terminal sessions, with the switch set to `true` in tests (§3.4) | `RuntimePayloadFragmentEncoder.swift` (expansion); `+SessionFamily.swift` (`assembledSessionData`); `+NestedInvocations.swift` (`hydratedNestedSnapshot`) | `ssg2-01` |
| `ssg2-03` (c) | cascade release (delete refs by `parent_digest`, release child digests) and truncation; orphan-free release and truncation tests; write switch default `true`; ≥5x benchmark (§3.2 "Release", Cascade; §3.6; §9 "Release" and benchmark) | `+SessionFamily.swift` (release functions); `SQLiteWorkflowRuntimePersistenceStore.swift` (switch default) | `ssg2-02` |
| `ssg2-04` (d) | bounded, lock-gated, terminal-only legacy conversion with the cursor, busy/failed/parked classes and budgets (§5.3 Step 1) | new `StorageMaintenanceConversion.swift`; `StorageMaintenanceCursor.swift` (existing); `RunEndStorageMaintenance.swift` (Step 1 call, profiles, injected clock) | — |
| `ssg2-05` (e) | host wiring: maintenance without the `completed` gate, explicit-store selection fix, shared scheduled pass for `events serve`/`serve`/RielaApp, vacuum caps 4,096/65,536 (§5.1, §5.2, §5.3 Step 2, §5.4) | `AutomaticRetentionHook.swift`; `RunEndStorageMaintenance.swift` (Step 2 caps); `Sources/RielaApp/EntryPoint+Retention.swift` | `ssg2-04`, `ssg2-06` |
| `ssg2-06` (f) | review and repair of the sgc-02 default retention (§4.6) plus test isolation (§11), including the `currentDirectory` parameter | `RielaRetentionConfiguration.swift`; `RielaRetentionService.swift`; `GarbageCollectionCommand.swift`; `AutomaticRetentionHook.swift` (parameter only); plus one new test-support file in `Tests/RielaCLITests` | — |
| `ssg2-07` (g) | read-only snapshot removal and `workRemaining` (§10) | `RielaDataGarbageCollector.swift`; `RielaRetentionService.swift` (generated warnings); `StorageCompactCommand.swift` | `ssg2-06` |
| `ssg2-08` (h) | `doctor storage` (§6) and docs (§7) | `StorageDoctorCommand.swift`; docs and design supersession notes | all other plans |

- `ssg2-01 → ssg2-02 → ssg2-03` are sequential. They share files, and the
  write-switch default only becomes `true` once release is fully
  reference-aware.
- Between `ssg2-01` and `ssg2-03`, the `ssg2-01` guard means fragments can
  only leak (stale refs rows), never be deleted while referenced. The
  `ssg2-02` terminal-session parity tests depend on that guard. Production is
  unaffected because the switch default stays `false` until `ssg2-03`.
- `ssg2-04` and `ssg2-06` can run in parallel with `ssg2-01`. Plans that share
  a file are ordered by `dependsOn`.
- `EventLiveServe.swift` and `ServeHTTPCommand.swift` are not edited; they
  already call `AutomaticRetentionHook.runAutomaticPass`, which `ssg2-05`
  extends.
- Each plan's verification commands are `swift build` with a temporary HOME,
  its own focused `swift test --filter` with a temporary HOME, and strict
  `swiftlint` on its touched files. All of them exit 0 once that plan's own
  changes are done. No plan lists a command that only a later plan can make
  pass. The full §9 gate, including the isolation proof, belongs to the final
  integration and to `ssg2-08`.
