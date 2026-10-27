# Efficient history and session storage: one shared versioned history, bounded retention, storage doctor and compact

Status: accepted 2026-10-27 (step3, comm-009607); amended 2026-10-27 for
the session-523 continuation (§13, implementation sequencing only; no
behavior change). Branch `feat/efficient-history`. The source is
the owner issue "One shared versioned history (diff, undo/redo, retention:
memory 2 / state 1 / workflow definitions 10) and efficient session storage
with storage doctor/compact". It has no GitHub number. Open decisions, each
with a recommended answer that this design already assumes, are in
`design-docs/user-qa/qa-efficient-history-and-storage.md`.

Baselines that this design extends. It does not restart them:

- `design-evolution-history.md`: the memory reverse-delta contract. Its
  directional, hash-verified, transactional rules stay. §2 replaces its
  storage encoding and adds retention, which it did not have.
- `design-workflow-definition-store.md` (#179): data model §3, operations §5,
  diff §6 and surfaces §8. §4 below replaces its "keep forever" triggers and
  its blob table. The §6 diff becomes the shared diff.
- `design-automatic-retention.md`: the family planner, the protections, the
  reclaimer (§5.3) and invariant 1 ("no config means no deletion"). These are
  reused unchanged.
- `design-cancellation-and-orphan-session-resilience.md` §P4: the reconcile
  liveness predicate (flock). §6 below extends it to nested invocations.

Out of scope:

- The file-based workflow snapshot store behind `riela workflow versions`,
  `version show`, `version diff` and `restore` (`WorkflowHistoryStore`,
  content-addressed chunks). See QA Q2.
- The KV, cache and write-intent stores, which keep no history.
- Kaiba.
- Releases and `VERSION`.

## 1. Verified current state (`2dce3fd7`)

Memory (`Packages/RielaMemory`, `user_version` 6, `SQLiteMemorySupport.swift:13`):

- `memory_evolution(record_id, version, recorded_at, reverse_delta_json)`
  (`MemoryEvolutionHistory.swift:15-34`).
- The head version is `MAX(version)`. There is no heads table, and
  `memory_entries` has no version column.
- Every `save`, `update`, `commitSnapshot` and `restoreRecordVersion` calls
  `recordEvolution`. Its call sites are `RielaMemory.swift:84,171`,
  `MemorySnapshot.swift:92,158` and `MemoryEvolutionHistory.swift:102`.
- `EvolutionReverseDelta` stores one prefix/suffix splice. Its
  `previousMiddle: Data` is serialized as base64 inside JSON.
- KV, write-intent, collection-checkpoint and cache stores never call
  `recordEvolution`.
- `auto_vacuum` is never set on memory databases.
- RielaMemory uses its own raw `sqlite3` helpers (`SQLiteMemorySupport.swift`)
  and cannot import the root `RielaSQLite`.
- Root `RielaCore` already depends on the `RielaMemory` product
  (`Package.swift:138`).
- Neither zlib nor Apple Compression is used anywhere.
- Linux CI builds in `swift:6.3.3-noble` (`linux-amd64-build.yml`).

Workflow definitions (`Sources/RielaCore/WorkflowDefinitionStoreSchema.swift`)
live in the runtime database `<store>/runtime-records/runtime-message-log.sqlite`
at generation 10:

- `definition_blobs` is keyed by digest and referenced through a foreign key
  from `definition_versions.document_digest`.
- Version ids are UUIDs (`defv-…`). The only ordering is
  `definition_heads.revision` and the audit `created_order`.
- Triggers forbid UPDATE and DELETE on versions and audit rows, and UPDATE on
  blobs.
- **Pins have no table.** A pin is `definitionSource` inside
  `workflow_runtime_snapshots.session_json`. Its `storeRoot` may name a
  different store than the session's own store, under `auto` scope.
  `SessionCommands.swift:12-31` `resolveSessionBundle` loads the pinned
  version for both resume and rerun.
- The diff is `Sources/RielaCore/WorkflowDefinitionDiff.swift`: RFC 6901
  pointers with `add|remove|replace`.

Session store (same file):

- `workflow_runtime_snapshots.session_json` holds the whole `WorkflowSession`,
  including `executions`, as JSONB plus a `$._rielaCanonicalWrite` witness.
- `cli_workflow_sessions.record_json` is a `PersistedCLIWorkflowSession` that
  embeds the same full session (`CLIWorkflowSessionStore.swift:5-25,448-469`).
- The witnessed fast path (`SQLiteWorkflowRuntimePersistenceStore.swift:856-900`,
  commits `c1375bcb..a4e2cbfd`) patches changed indices with `jsonb_set`.
  SQLite still rewrites the whole row value on every save.
- `workflow_nested_invocations.reservation_json` and `child_terminal_json`
  each embed a full child snapshot (`+NestedInvocations.swift:35,79,195`).
- Retention treats a nested row as settled only when
  `child_terminal_json IS NOT NULL AND parent_message_json IS NOT NULL AND
  recovery_reason IS NULL` (`TerminalRetentionIndexes.swift:16`), and only
  when both sessions exist (`TerminalRetentionMetadata.swift:49-55`).
- Reconcile never touches nested rows (`SessionReconcileCommand.swift`).
- `session prune` already reclaims through `RetentionSQLiteReclaimer` and
  reports `reclaimedBytes`.
- `riela doctor` has no subcommands and no storage checks.

## 2. Shared component `VersionedHistory`

### 2.1 Placement (no root `Package.swift` edit)

`VersionedHistory` is a public namespace inside the existing `RielaMemory`
module, under `Packages/RielaMemory/Sources/RielaMemory/VersionedHistory/`.
RielaCore already imports `RielaMemory`, so the root `Package.swift` and every
dependency pin stay untouched.

`Packages/RielaMemory/Package.swift` gains one local `.systemLibrary(name:
"CZlib")` target with a `module.modulemap` (`header "shim.h"`, `link "z"`) and
the providers `.apt(["zlib1g-dev"])` and `.brew(["zlib"])`. The `RielaMemory`
target depends on it. The swift-crypto pin is unchanged.

There is exactly one implementation of the following. The memory store and
the definition store only adapt to it:

- the codec, the table layout and its SQL;
- write, undo, redo, restore, retention, pins and detachment;
- the diff.

SQL runs through a small executor protocol
(`VersionedHistorySQL`: `execute`, `query`, values `text|int|blob|null`):

- RielaMemory's helpers implement it.
- RielaCore implements it over `RielaSQLite.SQLiteDatabase`. To do so,
  `SQLiteValue` gains `.blob(Data)` and `SQLiteRow` gains a `data(_:)`
  accessor. That is a source change, not a manifest change.

Each store calls the engine inside its own `BEGIN IMMEDIATE` transaction. The
engine never opens databases or transactions.

### 2.2 Tables (instantiated per store with a prefix)

```
<p>_history_heads(key TEXT PRIMARY KEY, revision INTEGER NOT NULL, head_version INTEGER NOT NULL,
                  retained_generations INTEGER, updated_at TEXT NOT NULL)
<p>_history_versions(key TEXT NOT NULL, version INTEGER NOT NULL, created_at TEXT NOT NULL,
                  content_sha256 TEXT NOT NULL, byte_count INTEGER NOT NULL,
                  encoding TEXT NOT NULL CHECK (encoding IN ('head','full','delta','external')),
                  anchor_version INTEGER, codec TEXT NOT NULL CHECK (codec IN ('none','zlib')),
                  detached INTEGER NOT NULL DEFAULT 0, blob BLOB,
                  PRIMARY KEY (key, version))   -- rowid table, not WITHOUT ROWID (large blobs)
```

The prefixes are `memory` (key = record id as text) and `definition` (key =
workflow name).

- **`revision`** is the per-key compare-and-swap token. Every head change
  bumps it: write, restore, undo and redo. It never decreases and is never
  reused.
- **`version`** is the revision value at which a value version was written.
  Versions are therefore strictly increasing. Gaps are allowed: undo and redo
  bump the revision without creating a version, and retention removes rows.
- **Head row.** Exactly one row per key has encoding `head` or `external`.
  `external` means the owning store holds the head bytes. Memory uses it,
  because `memory_entries` is the head, so a copy is never stored twice.
  `head` stores the head value as a compressed full blob; definitions use it.
- **Non-head rows** are `full` (the compressed value) or `delta`. A delta is a
  compressed byte splice relative to `anchor_version`.
- **Blob format.** The blob is binary: `prefixLen u64le, suffixLen u64le,
  middle` for a delta, or the raw value for a full row. It is compressed with
  zlib deflate. `codec` is `none` when compression would not shrink it. No
  base64 and no JSON wrapping.

### 2.3 Anchors and reconstruction

A non-head row's anchor is its adjacent retained, non-detached version **in
the direction of the head**:

- the next newer version for versions older than the head;
- the next older version for versions newer than the head (the redo side).

Reconstruction starts at the head value and applies deltas outward until it
reaches the target or a `full` row. For an `external` head, the caller passes
the head bytes it already holds; memory reads them from `memory_entries`. It verifies `content_sha256` and
`byte_count`, then returns exact bytes. The walk is bounded by the number of
retained rows.

**Encoding rule.** At encode time the engine computes
`zlib(splice(anchorValue → value))` and `zlib(value)` and stores the smaller.
A tie stores `full`. A stored row is therefore never larger than a compressed
full copy. Detached rows are always `full`.

### 2.4 Operations (identical for both stores)

- **`write(key, value, expectedRevision?, force, retainedGenerations?, pins)`**:
  1. A stale `expectedRevision` throws `staleRevision(expected, actual)`.
  2. If `sha256(value)` equals the head's hash and `force` is false, the
     outcome is `unchanged`: no row and no revision bump. Memory restore keeps
     today's forced revision, so it passes `force: true`.
  3. Otherwise:
     - Detach the redo branch (rows newer than the head): pinned rows become
       `detached = 1, encoding = full`, and unpinned rows are deleted.
     - Encode the old head as a `delta` or `full` row anchored on the new
       value.
     - Insert the new head with `version = revision + 1` and bump `revision`.
     - Run §2.5 in the same transaction.
  4. Returns `{outcome: written|unchanged, version, revision, droppedVersions}`.
- **`undo(key, expectedRevision?)`**:
  - Moves the head to the nearest older retained, non-detached version.
  - The old head becomes a row anchored on the new head. The new head's row
    becomes `head` or `external`, and the caller receives its bytes.
  - Exactly those two rows are re-encoded. `revision` is bumped. Nothing is
    deleted.
  - When no older version exists it throws `nothingToUndo(oldestRetained)`.
- **`redo(key, expectedRevision?)`**: the same move toward the nearest newer
  non-detached version. When there is none it throws `nothingToRedo`.
- **`restore(version)`**: a store-level operation. It is `write(value(version))`,
  so it is an explicit new version, as today. It keeps each store's existing
  reason and CAS rules.
- **`value(key, version)`**: returns exact bytes, or throws
  `versionNotRetained(version, retainedVersions, retainedGenerations)`.
  Undo bumps and retention both create gaps, so the error says "not retained
  (dropped by retention or never a stored version)" and lists what is
  retained.
- **`versions(key, limit, beforeVersion)`**: newest first. Each entry is
  `{version, createdAt, isHead, detached, encoding, codec, storedBytes,
  byteCount, sha256}`.

### 2.5 Retention

`retainedGenerations` R counts versions **including the head**:

- `nil` means the store default.
- `0` means unlimited, and is allowed for definitions only.

R applies only on `write`, after the redo branch is detached, so the head is
then the newest version. Retention keeps:

- the newest R non-detached versions;
- every version in the caller's `pins` set;
- detached rows that are still pinned.

All other rows are deleted. An unpinned detached row is dropped at the next
write. The engine wraps every row deletion, including redo-branch drops, in
the adapter's `withGuardedDelete` hook. Definitions use the hook to set the
§4 guard; memory's hook only runs the delete.

Before deleting, the engine reconstructs every surviving row whose anchor will
disappear and re-encodes it against its new toward-head neighbor. A pinned
version outside the window therefore never depends on a dropped row.

The engine returns the bytes freed. The caller runs `PRAGMA
incremental_vacuum(min(freedPages, 4096))` after commit, as a best-effort
step, when `auto_vacuum = INCREMENTAL` (§7).

### 2.6 Diff

`VersionedHistory.diff(beforeJSON: Data, afterJSON: Data)` is the existing
#179 algorithm, moved from `WorkflowDefinitionDiff.swift` and kept
behavior-identical:

- RFC 6901 pointers;
- sorted object keys with `~0`/`~1` escaping;
- arrays compared index by index, with tail `add`/`remove`;
- `replace` otherwise.

Entries are `{path, op: add|remove|replace, before?, after?}`, with leaf JSON
values.

If either side is not JSON, the diff returns one entry:
`{path: "", op: "replace", encoding: "bytes", beforeSHA256, afterSHA256,
beforeByteCount, afterByteCount, prefixByteCount, suffixByteCount}`.

`WorkflowDefinitionDiff` becomes a thin adapter that maps the entries onto
`JSONValue`. The memory CLI emits the same JSON shape. The text form prints
`op path` and then the before and after JSON on one line each, for both
commands.

### 2.7 Errors

The closed error codes are:

- `stale_revision`
- `nothing_to_undo`
- `nothing_to_redo`
- `version_not_retained`
- `history_corrupt` (hash or anchor mismatch, which fails closed)

Each store maps them onto its CLI, GraphQL and JSON error envelope.

## 3. Memory on `VersionedHistory`

**Schema.** `user_version` goes from 6 to 7. The migration is additive DDL
only: `memory_history_heads` and `memory_history_versions`, with
`ON DELETE CASCADE` from `memory_entries`. A fresh database runs `PRAGMA
auto_vacuum = INCREMENTAL` before it creates its first table.

**Legacy rows** (`memory_evolution`, `memory_retirement`) stay readable. A
record without a heads row is a legacy record: reads use today's reverse-chain
walk and today's retired-floor errors.

The **first write** to a legacy record converts it, inside that write's
transaction:

1. Create the heads row with `revision = head_version = MAX(version)`.
2. Reconstruct the R-1 newest previous versions with one legacy chain walk,
   bounded by R, and store them in the new format.
3. Delete that record's `memory_evolution` and `memory_retirement` rows.

`storage compact --apply` converts all remaining records in batches (§8).

**Policy.** `historyRetention` is an integer from 1 to 1000. It is persisted
in `memory_history_heads.retained_generations` and resolved per write:

| Write | R |
| --- | --- |
| `riela/snapshot-store` writes (`commitSnapshot`, rotate/scan) | 1, always |
| Memory add-on, persona and runner `save`/`update`, when the workflow `memories[]` entry declares `historyRetention` | that value |
| CLI `memory save`, `update` and `restore-version` with `--history-retention <n>` | that value |
| Otherwise | the record's persisted value, else 2 |

`WorkflowMemoryDeclaration` gains `historyRetention: Int?`. The raw validator
allows the key and rejects values outside 1...1000. KV-backed state
(collection checkpoints, write intents, `riela/kv-*`) keeps no history, as
today.

**Pins** are `memory_snapshot_retention` rows with `expires_at > now`. They
store the head's value version, not the revision:

- `retainSnapshot` still checks the caller's `expectedHead` against the
  revision.
- It writes `memory_history_heads.head_version` into the `version` column
  instead of reusing `MemorySnapshotHead.version`.
- `loadRetainedSnapshot` reconstructs that value version.

**CAS.**
- `MemorySnapshotHead.version` and `--expected-head-version` now carry the
  head **revision**.
- Until an undo happens, revision equals the newest version, so existing CAS
  behavior and numbers are unchanged.
- Revisions keep increasing after retention drops versions.

**Undo, redo and attachments.**
- Undo and redo rewrite `memory_entries` (payload, tags, related ids, files)
  from the reconstructed `MemoryRecord` in the same transaction. They verify
  attachments through the existing `verifyEvolutionAttachments`.
- Attachment files of dropped versions are left in place (QA Q4).
  `doctor storage` reports them as `unreferencedAttachmentBytes`.

**Surfaces** (all take `--memory-root`):

- `memory history`:
  - New-format entries are the §2.4 entry shape.
  - The head entry also carries `revision`.
  - Legacy entries keep `reverseDelta`.
  - Text output shows each version's storage encoding and stored byte count, marks the head with its revision, and reports when retention dropped older versions.
  - A version below the retained window is reported as `version_not_retained`.
- `memory show-version` and `memory restore-version` work for retained
  versions and fail with `version_not_retained` otherwise.
- `show-version --diff-against <version|head>` adds the shared `diff` array.
- New `memory undo` and `memory redo` take
  `<memory-id> --record-id <id> --expected-head-version <revision>`. They
  return `{record, revision, headVersion, fromVersion}`.
- `memory retire-history` keeps its CLI contract and report. For a
  new-format record it drops every non-head version through the engine's
  delete path, with its existing ownership checks and blockers.

## 4. Workflow definitions on `VersionedHistory`

**Schema.** Generation 10 → 11 runs in one `SQLiteSchemaMigration(fromGeneration:
10)`. The definition tables are small, so this step converts their data in
full:

1. Create `definition_history_heads` and `definition_history_versions`.
2. Rebuild `definition_versions` with a new `history_version INTEGER NOT
   NULL` column and `UNIQUE(workflow_name, history_version)`. The foreign key
   to `definition_blobs` is removed. Per workflow, versions are numbered
   1...k in audit `created_order`.
3. Import each document from `definition_blobs` into the shared versions
   table. Set `definition_history_heads.revision` to the existing
   `definition_heads.revision` and the head to `current_version_id`.
4. Drop `definition_blobs`.

`version_id` (UUID), `digest` and `definitionSource` are unchanged, so
existing pins resolve. `definition_heads` keeps `current_version_id`,
`last_file_version_id` and `revision`, written in the same transaction as
the engine head.

**Retention.**
- R comes from, in order of precedence:
  1. `definition_heads.retained_generations`, set by `--history-retention
     <n>` on `import|update|update-prompt|restore` or by GraphQL
     `historyRetention`;
  2. `~/.riela/config.json` key `workflowDefinitions.historyRetention`;
  3. the default, 10.
- Allowed values are 0 (unlimited) and 1...10000.
- Retention runs inside every `commit` transaction.

**Pins.** A version is never dropped when it is any of these:

1. the current head;
2. `last_file_version_id`;
3. referenced by a live row in the new
   `definition_version_pins(workflow_name, history_version,
   session_store_root, session_id, created_at, PRIMARY KEY(session_store_root,
   session_id, workflow_name))`;
4. the head at some moment in the last 24 hours. This is derived from the
   audit table: the version is the `previous_version_id` of an audit row
   newer than 24 hours.

Rule 4 covers the gap between a service run reading its pinned version and
that session's first save.

Definition stores also keep `definition_version_identities` as an immutable,
document-free index for every committed version. It lets lookups distinguish a
known version whose payload was pruned from an unknown version id. These small
identity rows are permanent metadata and are not covered by payload retention.

How pin rows are written and released:

- **Written** by the first canonical save of any session whose
  `definitionSource.kind = store`: service runs, callee children, and
  resume/rerun sessions. The row goes to the definition database named by
  `definitionSource.storeRoot`.
  - When that is the same database, the insert is part of the snapshot
    transaction.
  - When it is a foreign store, a separate `BEGIN IMMEDIATE` runs before the
    session's first save, and a failure fails the run start.
- **Released lazily** during retention. A row is live while its session
  exists, meaning a snapshot or CLI row with no tombstone in
  `session_store_root`. A foreign store is checked by a read-only open.
  - An unopenable foreign store keeps the pin (fail closed).
  - A missing store directory releases it.
- **Pin protection does not depend on status** (QA Q3). Rerun of a terminal
  session uses its pin, so every existing session protects its version.
- **Backfill.**
  - The generation-11 migration inserts pin rows for same-store sessions from
    `json_extract(session_json, '$.definitionSource')`, but only when
    `SUM(length(session_json))` is at most 256 MiB.
  - Otherwise it records `definition_retention_state = pendingBackfill`. In
    that state, commits skip deletion until `storage compact --apply` has
    backfilled the pins.
  - Compact also backfills cross-store pins from the user and project stores
    it can resolve.
  - When the migration's backfill runs, the migration applies the window
    once.

**Guarded deletes.**
- The new `definition_retention_guard(id INTEGER PRIMARY KEY CHECK (id = 1))`
  table controls deletion.
- The `*_no_delete` triggers on `definition_versions` and
  `definition_change_audit` become `BEFORE DELETE … WHEN NOT EXISTS (SELECT 1
  FROM definition_retention_guard) BEGIN SELECT RAISE(ABORT, …); END`.
- `definition_history_versions` gets the same guarded trigger.
- UPDATE stays forbidden on versions and audit rows.
- Only the engine's retention step inserts the guard row. It does so at the
  start of the deletion and removes it before the transaction commits.
- A `BEFORE INSERT` trigger on the guard table aborts when a row already
  exists, so the guard cannot be left set by nesting.
- This protects against accidental and ad-hoc deletes. It is not a security
  boundary against a local writer who deliberately inserts the guard row.
  The doc says so.

**Audit and blob cleanup.**
- An audit row is deleted only when **both** its `version_id` and its
  `previous_version_id` were dropped (QA Q5). Every other audit row stays.
- History rows are the blobs. Dropping a version deletes its row, so no
  separate blob table and no blob GC remain.

**Undo and redo** are new operations, `undo` and `redo` in
`WorkflowDefinitionOperation`. They require `--reason`, accept
`--expected-revision <n>` or `--expected-version <id>` for CAS, and write one
audit row with the head-move diff. They move `current_version_id`, never move
`last_file_version_id`, and bump `revision`.

**Read errors.** `show --version`, `diff --from/--to` and `restore --version`
on a dropped version, and resume or rerun of a pin whose version is gone
(possible only for legacy cross-store pins compact could not see; see risks),
fail with `definition_version_not_retained`. The message names the retained
versions and the retention setting. `history` audit entries gain `retained:
Bool`.

## 5. Session store: one copy, execution rows, payload references

**One source of truth.** `workflow_runtime_snapshots` is canonical.

- New `cli_workflow_sessions.record_json` rows are an **envelope**:
  `{workflowName, resolution, mockScenarioPath?, runtimeVariables?,
  sessionStorage: "canonical", session: {sessionId, workflowId, status,
  updatedAt}}`.
- The tiny `session` stub keeps the existing generated columns
  (`workflow_name`, `workflow_id`, `status`) without a table rebuild. It
  holds scalars only, never executions.
- New canonical snapshot headers store `_rielaNewExecutionCount`, the count
  of non-imported executions. `list` reads that scalar without joining or
  decoding payload blobs. For older canonical headers that lack the scalar,
  list derives the count from inline executions or uses the legacy execution
  row fallback. The query is assembled according to the tables present, so
  read-only listing works against generation-10 stores before migration.
- `CLIWorkflowSessionStore` read, load and loadAll join the full canonical
  session in the same read transaction. `list` decodes only the canonical
  session header and projects the non-imported execution count separately;
  it does not assemble execution payloads. When filtering by status, the
  canonical status wins over the envelope stub. For legacy inline snapshots,
  list removes `executions` before decoding and derives the count in SQL.
- An envelope without a canonical snapshot is reported through the existing
  decode-resilience path as `canonicalSnapshotMissing`.
- Strict reads surface `canonicalSnapshotMissing`. Non-strict `load` warns
  and returns `notFound`, allowing family hydration to continue and skip the
  missing session while trying the canonical snapshot path.
- `list` returns header-only `PersistedCLIWorkflowSession` values with
  `executionCount` populated. Passing such a summary to CLI-only `save(_:)`
  throws `headerOnlyRecordCannotBeSaved` so its empty execution array cannot
  delete canonical execution rows.
- `observePersistedExecutionIdentities` reads the execution rows below.
- A CLI save always writes the canonical snapshot and the envelope in one
  transaction, as `save(_:runtimeSnapshot:)` does today. A CLI save without a
  snapshot builds one from its session.
- Legacy full rows stay readable. Their first save rewrites them as an
  envelope.

**Execution rows and content-addressed payloads:**

```
workflow_runtime_payloads(root_session_id TEXT, digest TEXT, bytes BLOB (JSONB) NOT NULL, byte_count INTEGER,
                          UNIQUE(root_session_id, digest))
workflow_runtime_executions(workflow_execution_id TEXT REFERENCES workflow_runtime_snapshots ON DELETE CASCADE,
                          ordinal INTEGER, execution_id TEXT, root_session_id TEXT, payload_digest TEXT,
                          PRIMARY KEY(workflow_execution_id, ordinal))
  INDEX (root_session_id, payload_digest) on workflow_runtime_executions
  INDEX (root_session_id, digest) on workflow_nested_invocation_refs
workflow_nested_invocation_refs(invocation_key TEXT, role TEXT, ordinal INTEGER, root_session_id TEXT, digest TEXT,
                          PRIMARY KEY(invocation_key, role, ordinal))
```

- **Header-only snapshot.** New `session_json` holds the header: the session
  without `executions`, plus `_rielaExecutionStorage: "rows"` and the
  existing witness. Generated columns, `loadStatus`, the terminal fence
  (`validateTaskTerminalWrite`) and lineage queries read the header and keep
  working.
- **Load.** Loads assemble `executions` from the rows in ordinal order,
  inside the read transaction. Web summaries and the reuse path query the
  rows instead of `json_each(session_json, '$.executions')`.
- **Save.** Each save upserts the header and touches only changed or
  appended execution rows:
  - `INSERT OR IGNORE` the payload `(root, sha256(executionJSON))`;
  - point the execution row at it;
  - delete the old payload in the same transaction when no execution row and
    no nested ref in that root still references it. Both checks are indexed
    point lookups on `(root_session_id, digest)`, so the per-step cost does
    not grow with store size.
- **Scope of deduplication.** Payloads are deduplicated within a lineage
  family, which is also the retention unit. Deleting a family deletes its
  payloads.
- **Other columns.** `root_output_json`, `diagnostics_json` and the loop
  columns are written only when they changed. The startup identity projection
  stores the full ordered execution-id list on each save because the snapshot
  update trigger invalidates its prior projection before completion runs.
- **Fast path.** The witnessed fast path keeps its contract (commits
  `c1375bcb..a4e2cbfd`):
  - cache, prefix and witness check;
  - a guarded single-row header update that throws `canonical execution
    witness changed`;
  - full rebuild on a cold cache, rollback or legacy writer.
  - The 60-argument cap is no longer needed, because each execution row is
    its own statement.
  - The full rebuild path rewrites the session's execution rows. Payload
    dedupe makes unchanged payloads cost no new payload bytes.
- **Legacy snapshots** with inline `executions` stay readable. Their first
  save converts them to rows.
- **Nested invocations.**
  - New reservations and child-terminal records store the child snapshot by
    reference: `childSnapshotRef: {headerDigest, executionDigests[],
    rootOutputDigest?, diagnosticsDigest?}`. The same applies to callee
    workflow and node payloads.
  - The digests are recorded in `workflow_nested_invocation_refs` and
    resolve through `workflow_runtime_payloads`. A child's execution payloads
    therefore deduplicate against the child's own execution rows.
  - `parent_message_json` stays inline.
  - The existing fences (parent publication and `recovery_reason`) are
    unchanged.
  - The decoder accepts embedded legacy rows.
  - Re-encoding replaces refs for that invocation role and releases payloads
    that become unreferenced. eh-07 retention must delete
    `workflow_nested_invocation_refs` together with each deleted
    `workflow_nested_invocations` row, including the `callee` role.

**Run end.** The automatic run-end work is bounded and family-local (QA Q1):

- release payloads of the finished family that nothing references (normally
  none, because GC is synchronous);
- run `PRAGMA incremental_vacuum(min(freelist, 4096))` on the session
  database when it is INCREMENTAL.

Deleting terminal sessions stays governed by the `retention` config
(`design-automatic-retention.md` invariant 1). `session prune`, `riela gc`
and automatic passes also delete the new tables' rows for pruned families.
Their tombstone insert triggers extend to `workflow_runtime_executions` and
`workflow_runtime_payloads`. Result byte accounting includes execution
payload bytes.

**Storage notes.** `fanoutGroups` and `reviewFindings` remain in the rewritten
session header, so per-save header bytes depend on the size of those fields.
The duplicate CLI `record_json` remains eh-06's migration scope; this plan does
not remove that second representation.

## 6. Abandoned runs (`riela session reconcile`)

The existing running-session step is unchanged: a free flock means orphaned,
`--apply` sets `cancelled`. Reconcile gains a nested step that runs after it,
gated by `--abandoned-after-hours <h>` (default 24, range 1...8760). A
`workflow_nested_invocations` row is **abandoned** when all of these hold:

- it is unsettled by the §1 predicate;
- its parent session is terminal (`completed|failed|cancelled`), possibly
  because the running-session step of this same pass cancelled it;
- its child is terminal, absent, or `created`;
- its `updated_at` and the parent's `updatedAt` are both older than the
  threshold;
- the parent's and child's execution locks are both acquirable without
  blocking.

**With `--apply`**, while holding both locks, the row is re-checked in the
transaction and then:

- the new column `abandoned_at` (generation 11, `ALTER TABLE ADD COLUMN`) is
  set;
- a `created` child is marked `cancelled` with reason `reservation abandoned;
  reconciled by riela session reconcile`.

Sessions in `suspended` state are never touched. Rows newer than the
threshold are reported as `recent`, and rows with a held lock as `live`.

The retention settled predicate becomes
`(<existing predicate>) OR abandoned_at IS NOT NULL`. An abandoned row with an
absent child no longer protects the family.

A conflicting cli-vs-snapshot status (the `nonterminalOrConflictingStatus`
families) resolves when compact rewrites the envelope from the canonical
snapshot, because the canonical snapshot wins.

**Output** adds `nestedInvocations: [{invocationKey, parentSessionId,
childSessionId, verdict: abandoned|live|recent|skipped, applied, reason?}]`.

## 7. Space reclamation

- **The pragma must be set before WAL.** `PRAGMA auto_vacuum = INCREMENTAL`
  only takes effect on a brand-new file, and only when it runs on the
  connection **before** `PRAGMA journal_mode=WAL` and outside any
  transaction. After the WAL switch, the file's auto_vacuum mode is fixed and
  SQLite silently ignores the pragma. `RielaCacheStore.swift:397-398` follows
  the same order (`auto_vacuum` first, then `journal_mode`).
- **Runtime store.** `SQLiteDatabase.open` switches to WAL inside
  `configure()` (`Sources/RielaSQLite/SQLiteDatabase.swift:354-366`), before
  any schema code runs, so the pragma moves into the open path:
  - `SQLiteOpenOptions` gains `incrementalAutoVacuumForNewFile: Bool`
    (default `false`). The runtime persistence store and the message log set
    it on their writable opens.
  - When it is set, `configure()` checks for a new file before calling
    `enableWAL`. A file is new when it did not exist or was zero length before
    `sqlite3_open_v2`, and `sqlite_master` has no rows.
  - For a new file it runs `PRAGMA auto_vacuum = INCREMENTAL` outside any
    transaction. For an existing file it does nothing.
  - This is a source change in the `RielaSQLite` target, not a manifest
    change.
- **Memory store.** `openDatabase` (`RielaMemory.swift:470-488`) never
  changes the journal mode. For a new file it runs `PRAGMA auto_vacuum =
  INCREMENTAL` right after open, before any journal-mode pragma and before
  `ensureSchema`'s `BEGIN IMMEDIATE` and first `CREATE TABLE`. A new file is
  one where `sqlite_master` has no rows and `user_version` is 0.
- **Verification.** Both stores read `PRAGMA auto_vacuum` back after schema
  creation. A fresh store that reads anything other than `2` gets a schema
  diagnostic (not a failure); §11 asserts the value.
- After a retention delete, the small bounded `incremental_vacuum` from
  §2.5 runs after commit.
- Existing `NONE` databases convert only through `RetentionSQLiteReclaimer`
  manual mode, which `storage compact --apply` and `session prune` use. It
  converts with `PRAGMA auto_vacuum = INCREMENTAL; VACUUM` when free space is
  at least 2 × (DB + WAL) + 256 MiB, and otherwise reports
  `deferredInsufficientSpace`.
- The reclaimer itself is reused unchanged.

## 8. Detection and repair commands

### 8.1 `riela doctor storage`

Usage:

```
riela doctor storage [--scope project|user|auto] [--working-dir <dir>]
                     [--session-store <dir>] [--memory-root <dir>] [--cache-root <dir>] [--kv-root <dir>]
                     [--top <n>] [--output text|json]
```

- With no explicit roots, it inspects the user and project stores through the
  existing resolvers.
- It is read-only. Every runtime database opens with
  `SQLiteOpenMode.strictReadOnly` or `strictReadOnlyWithImmutableFallback`,
  never `.readOnly`, because `.readOnly` falls back to a read-write open on
  CANTOPEN (`SQLiteDatabase.swift:127-134`). Memory, cache and KV databases
  open with `SQLITE_OPEN_READONLY`. Nothing migrates and nothing is created.

The per-file report:

```
{ path, kind: session|memory|cache|kv, fileBytes, walBytes, pageSize, pageCount, freePages, freeBytes,
  autoVacuum, schemaGeneration, tables: [{name, bytes, rows, estimated}],
  memory?: { records, historyBytes, currentBytes, amplification, maxVersionsPerRecord,
             legacyRecords, unreferencedAttachmentBytes, largestRecords: [{recordId, historyBytes, versions}] },
  session?: { sessions, legacyInlineSnapshots, legacyCLICopies, legacyCLICopyBytes, legacyNestedEmbeddedBytes,
              pruneBlocked: {reason: count}, abandonedCandidates, largestSessions: [{sessionId, bytes}] },
  definitions?: { workflows, versions, versionsOverWindow, pins, retentionState },
  reclaimable: { freePagesBytes, compactEstimateBytes, pruneEstimateBytes } }
```

- **Table bytes** come from `dbstat` when available. Otherwise the report
  uses `SUM(length(col))` over the known columns with `estimated: true`.
- **Prune-blocked reasons** come from a dry-run `TerminalRetentionPlan` over
  all workflows.
- **Definition pins are released lazily.** A session prune does not immediately
  reclaim pinned definition versions. They remain protected until the next
  definition commit after the 24-hour pin age; storage doctor must not report
  them as reclaimed by the session prune that removed the session rows.
- **Exit code** is 0. Text output prints one block per file.

### 8.2 `riela storage compact`

Usage:

```
riela storage compact [same root flags] [--apply] [--max-batch <n>] [--abandoned-after-hours <h>]
                      [--results-max-age-days N] [--results-max-total-bytes SIZE]
                      [--messages-max-age-days N] [--messages-max-total-bytes SIZE] [--output text|json]
```

It is a dry run by default: read-only, reporting what each step would do and
the estimated bytes. With `--apply` it runs these steps per store, in order:

1. **Convert.** In batches of `--max-batch` (default 500) records, each batch
   one transaction:
   - legacy memory records to the new history format, applying R;
   - legacy session rows to header plus execution rows;
   - legacy CLI records to envelopes;
   - embedded nested rows to refs;
   - the definition pin backfill, then the window.

   Session rows convert only while holding the session's non-blocking
   execution lock; a busy lock is skipped and reported.
2. **Reconcile.** Apply §6 with the threshold.
3. **Prune.** Delegate to `RielaRetentionService` in manual mode with the
   configured policy plus the override flags. With neither it reports
   `notConfigured` and deletes nothing.
4. **Vacuum.** The manual reclaimer, conversion included.

The work is resumable:

- A partial run leaves mixed old and new rows, and both stay readable.
- `workRemaining: true` means "run again".

The report is `{dryRun, stores: [{path, converted: {...counts, bytes},
reconciled, prune: <gc target report>, reclamation: [...]}], workRemaining,
warnings}`.

## 9. Surfaces

**CLI.** The new commands:

- `riela memory undo|redo`
- `memory show-version --diff-against`
- `--history-retention` on memory and definition writes
- `riela workflow definition undo|redo <workflow> --reason <r> [--expected-revision <n> | --expected-version <id>]`
- `riela doctor storage`
- `riela storage compact`

Help text is updated in `RielaCLIApplication.swift`.

**GraphQL.** Where restore is exposed today (`WorkflowDefinitionGraphQL.swift`),
two mutations are added:
`undoWorkflowDefinition(input: {workflowName, storeScope, reason,
expectedRevision, expectedVersionId, evidence, actorKind, actorId})` and
`redoWorkflowDefinition(...)`. Both return `{version, audit}`.

The `WorkflowDefinitionVersion` GraphQL object exposes its current `revision`
as a nullable field so clients can obtain the CAS token. Definition mutation
history errors use upper-snake codes: `DEFINITION_NOTHING_TO_UNDO`,
`DEFINITION_NOTHING_TO_REDO`, `DEFINITION_STALE_REVISION`, and
`DEFINITION_VERSION_NOT_RETAINED`. A revision mismatch uses the stale-revision
code; an expected-version mismatch remains `DEFINITION_STALE`.
Undo and redo return the revision created by their own committed head move.
This keeps the version and CAS token in the mutation payload from different
head updates from being paired if another writer advances the head before the
payload is assembled.
Existing `WorkflowDefinitionGraphQLProviding` conformers that do not support
the new mutations use default implementations that return
`DEFINITION_OPERATION_UNSUPPORTED`.

- `historyRetention` is added to the update, update-prompt, restore and
  import inputs.
- `retained` is added to the audit type.
- Memory has no GraphQL surface today, and none is added.

**Catalog and SDL.** New `SurfaceCatalog` rows:

| Row | Surfaces |
| --- | --- |
| `workflow.definition.undo`, `workflow.definition.redo` | `cli` and `graphql` |
| `memory.undo`, `memory.redo`, `doctor.storage`, `storage.compact` | CLI with `localToolDefaults` |

Regenerate the SDL with `scripts/surface-parity/generate-sdl.sh` and keep
`swift test --filter SurfaceParity` green.

## 10. Rollout constraints

- **Manifests.** The root `Package.swift` is not edited. The only manifest
  change is the `CZlib` system-library target in
  `Packages/RielaMemory/Package.swift`; no dependency pin changes. This
  avoids conflicts with the concurrent pin and cron work on main. Rebase on
  `origin/main` before the final push. No `VERSION` bump and no release.
- **Migration cost.**
  - Runtime generation 11 and memory version 7 run DDL only on open, plus
    the small definition data conversion and the bounded pin backfill.
  - No session or memory payload rewrite happens on open. Large stores (up
    to 41 GB) convert through `storage compact --apply` in resumable
    batches.
  - A full VACUUM happens only on an explicit compact or prune, and only
    after the free-space check.
- **Downgrades.** Older binaries reject generation 11 and memory version 7
  through the existing newer-generation errors. Data is never discarded:
  `shouldDiscardIncompatibleStore` still refuses stores that have definition
  heads.
- **Live runs.** Reconcile and compact act only under acquired execution
  locks with in-transaction re-checks. Retention and migration never touch
  sessions.

## 11. Verification

Tests use realpath temp roots and fake clocks. They never use the real
`~/.riela`.

**RielaMemoryTests**

- `VersionedHistoryTests`:
  - codec round trips;
  - the smaller-of-full-or-delta rule and the compressed bound;
  - malformed blob and hash mismatch;
  - identical writes;
  - monotonic revisions;
  - undo/redo boundaries;
  - a new write after undo detaches or drops the redo branch;
  - pins outside the window and re-anchoring;
  - detached pinned rows;
  - unlimited mode;
  - diff schema and the bytes fallback.
- `MemoryHistoryRetentionTests`:
  - a 660 KB JSON document with a header change plus an appended item per
    write; after 1000 writes at the default R, at most one previous row, with
    stored bytes ≤ `zlib(full)`;
  - snapshot-store at R=1 keeps zero rows;
  - R=N keeps exactly N-1 rows;
  - the head revision increases;
  - restore is byte-exact;
  - legacy schema-6 fixture: open, read, convert on write, compact;
  - the file shrinks after incremental vacuum.

**RielaCoreTests**

- `VersionedHistoryConformanceTests`: one parameterized suite run against
  both the memory adapter and the definition adapter. It checks the same diff
  output, undo/redo, redo truncation, the retention window and row GC.
- `WorkflowDefinitionRetentionTests`:
  - 25 updates leave exactly 10 versions plus pinned ones;
  - the head and `last_file_version_id` are kept;
  - the guarded DELETE aborts outside retention, and the guard cannot nest;
  - audit pruning follows the rule;
  - the generation-10 fixture migrates (documents imported, blobs dropped,
    UUIDs and digests unchanged);
  - over-window restore fails with `definition_version_not_retained`.
- `SQLiteRuntimeSchemaMigrationTests`: the generation-10 fixture opens,
  reads and compacts.
- `SQLiteRuntimeExecutionRowsTests`:
  - one canonical copy per session;
  - execution rows appended;
  - identical payload dedupe;
  - nested refs dedupe against child rows;
  - payload GC;
  - legacy inline snapshots readable.
- `RuntimePersistenceBoundedWriteTests`: for a 500-step session, the bytes
  bound per save and the WAL pages per save at step 500 are within 1.5× of
  step 50.
- `SQLiteRuntimeAutoVacuumTests`:
  - a freshly created runtime store (opened through the writable defaults,
    which enable WAL) reads `PRAGMA auto_vacuum = 2` and
    `journal_mode = wal`;
  - opening an existing NONE store leaves it at 0, because only the reclaimer
    converts existing stores;
  - after a definition-retention delete, or after a payload GC followed by
    the run-end bounded `incremental_vacuum`, `freelist_count` is lower than
    before the vacuum, and the file size does not grow.

A matching memory assertion goes in `MemoryHistoryRetentionTests`: a fresh
memory database reads `PRAGMA auto_vacuum = 2`, and the post-retention bounded
`incremental_vacuum` lowers `freelist_count`.

**RielaCLITests**

- `WorkflowDefinitionServiceResolutionTests`: a session pinned to version 3
  resumes and reruns after 25 updates, and the cross-store pin row protects
  the version.
- `WorkflowDefinitionCommandTests`, `WorkflowDefinitionGraphQLTests`:
  undo/redo, CAS and error codes.
- `CLIWorkflowSessionEnvelopeTests`: an envelope plus canonical join; a
  legacy row is readable and then converted.
- `PrivateWorkflowTests`: the four fast-path and fence tests stay green.
- `SessionReconcileCommandTests`:
  - an abandoned nested row becomes prunable;
  - live, recent and suspended rows are untouched;
  - a dry run writes nothing.
- `TerminalRetentionTests`, `RetentionReclamationTests`: prune reports freed
  bytes and the file shrinks.
- `StorageDoctorCommandTests`: JSON and text output, read-only (file
  checksums unchanged).
- `StorageCompactCommandTests`: dry run writes nothing; apply is resumable.
- `MemoryCommandTests`: undo, redo and `version_not_retained`.
- `CommandParsingTests` and `SurfaceParity`.

**Commands** (arm64 shell):

```
arch -arm64 /bin/zsh -lc 'swift build'
arch -arm64 /bin/zsh -lc 'swift test --package-path Packages/RielaMemory'
arch -arm64 /bin/zsh -lc 'swift test --filter "VersionedHistory|MemoryHistoryRetention|WorkflowDefinition|SQLiteRuntime|RuntimePersistenceBoundedWrite|CLIWorkflowSession|PrivateWorkflowTests|SessionReconcile|TerminalRetention|RetentionReclamation|StorageDoctor|StorageCompact|MemoryCommand|CommandParsing|SurfaceParity"'
arch -arm64 /bin/zsh -lc 'scripts/surface-parity/generate-sdl.sh'
arch -arm64 /bin/zsh -lc 'swift test'
arch -arm64 /bin/zsh -lc 'swiftlint --strict <touched files>'
```

Linux portability of `CZlib` is covered by the existing `linux-amd64-build`
workflow after push. That image ships `zlib1g-dev`.

## 12. Docs

Update:

- `docs/evolution-history.md`: retention, the new encoding, undo/redo and
  diff.
- `docs/memory-history-retirement.md`: manual retirement remains for explicit
  cleanup, and default retention makes it rarely needed.
- `docs/workflow-definition-store.md`: retention, pins, guarded deletes and
  undo/redo.
- `docs/session-cancellation-and-reconcile.md`: abandoned nested
  invocations.
- `docs/terminal-retention.md`: execution rows and payload bytes.

Add `docs/storage-doctor-and-compact.md`, covering session storage, `doctor
storage` and `storage compact`.

## 13. Continuation sequencing (session 523)

This section changes only how the accepted design is implemented. Behavior,
schemas and surfaces in §2-§12 are unchanged.

**State at `4d72853b`.**

- Wave 1 is accepted and uncommitted: eh-01 (`VersionedHistory/`, `CZlib`)
  and eh-02 (BLOB binding, generation-11 seams, pin-hook call sites,
  first-opener auto_vacuum). It is kept as is and not dispatched again.
- eh-03, eh-04 and eh-05 are partly done in the working tree. Every plan
  resumes from the files as they are. The current SHA-256 of each owned
  file is its pre-edit baseline. No plan reverts a foreign change.

**Why wave 2 blocked.**

- eh-03 needed `MemoryModels.swift` for
  `RielaMemoryError.invalidHistoryRetention`, which was not in its
  `writePaths`. It is now eh-03-owned. Edits there are limited to the
  history-retention error cases.
- eh-04 and eh-05 ran in parallel, but every fresh runtime-store open runs
  `WorkflowDefinitionHistorySchema.create` (generation 11). eh-04's
  in-progress `create(in:)` and `migrateToGeneration11(in:)` call
  `createVersionTriggers` (which creates the guarded-delete trigger on
  `definition_history_versions`) before `VersionedHistoryStore.ensureSchema()`
  creates that table. So every eh-05 suite failed with
  `no such table: main.definition_history_versions`
  (`tmp/efficient-history/eh-05-session-rows/test-final-source-2.log`).

**Ordering rule.** Generation-11 creation and migration create the engine
tables first. Triggers, indexes and views that reference them come after.
eh-04 owns this fix.

**Ownership.**

- eh-04 is the only plan that edits RielaCore schema code in its wave. It
  does not edit `SQLiteWorkflowRuntimePersistenceStore*.swift` or
  `SQLiteRuntimeExecutionRowsSchema.swift`, because the eh-02 seams already
  call its schema functions.
- eh-05 owns those store files and runs after eh-04.

**Waves.**

| Wave | Plans | Starts when |
| --- | --- | --- |
| W2a | eh-03, eh-04 (disjoint: RielaMemory package vs RielaCore/RielaWorkflowRegistry) | now |
| W2b | eh-05 | eh-04 accepted and the W2a gate passes |
| W3 | eh-06, eh-07, eh-08, eh-09 (disjoint `writePaths`) | each member's own `dependsOn` accepted; eh-08/eh-09 after W2a, eh-06/eh-07 after W2b |
| W4 | eh-10 | eh-03, eh-04, eh-06, eh-07, eh-09 accepted |
| W5 | eh-11 | eh-08, eh-09, eh-10 accepted |

**Compatibility across the W2a pair.** eh-03 keeps the public RielaMemory
API used by RielaCore and RielaCLI source-compatible (additive only), and it
does not edit `VersionedHistory/`. So eh-04's root `swift build` is never
broken by eh-03. A compile error inside a sibling's path is logged as
`outOfScope` and the command is rerun after the sibling reports its own build
green.

**Wave gate.**

- After each wave: `swift build` plus the union of the members' focused
  filters, in the foreground, logs under `tmp/efficient-history/wave-<id>/`.
  `SurfaceParityCLITests` is excepted until eh-11.
- A gate judges a wave only on code the wave owns. The W2a gate passes when
  all of these hold:
  - eh-03's verification passes;
  - eh-04's own definition suites pass;
  - the schema opens. The three `SQLiteRuntimeSchemaMigrationTests`
    generation-open tests pass (fresh store recreated at the current
    generation, 10→11, 9→10→11), and the
    `SQLiteRuntimeSchemaMigrationTests|PrivateWorkflowTests` log has zero
    `no such table`/`already exists` matches.
- Failure attribution in W2a:
  - A remaining failure in those two suites whose failing frame or assertion
    is in an eh-05 writePath, or in the eh-05 `PrivateWorkflowTests` fixture,
    is written to `tmp/efficient-history/wave-W2a/handover-eh-05.md` (test
    name, log line, first error). It is handed to eh-05 and does not block
    eh-04 or the W2b start. eh-04 does not edit those files.
  - A failure in an eh-04 writePath blocks eh-04.
  - A failure whose frame is in neither set is logged to the same file
    marked `unattributed`. It is non-blocking for W2a and must be green at
    W2b.
- The W2b gate (eh-05 acceptance) requires the full
  `SQLiteRuntimeSchemaMigrationTests` and `PrivateWorkflowTests` suites
  green, including the four fast-path/fence tests and every handover item.

**Finalization.**

1. Rebase onto `origin/main` (at or after `2f8cae64`, which has the
   `35a910d5` deps, cron `previousScheduledAt` and `agentToolPolicy`
   presets). On conflicts, keep main's side for `Package.swift`,
   `Package.resolved`, cron files and tool-policy code.
2. After the rebase, rerun `swift build`, the SDL regeneration,
   `SurfaceParity` and the final-gate focused filter.
3. The full `swift test` must show no new failures, by exact test name,
   against the baseline in the dispatch manifest.
4. Push to `origin` (`gitPush=true`).
