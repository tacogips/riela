# SQLite Store Schema Generation and Storage-Layer Hardening

Status: implemented (2026-08-23)

## Problem

The SQLite storage layer accumulated three classes of problems:

1. **Drift-prone denormalized summary columns.** `workflow_runtime_snapshots`
   and `cli_workflow_sessions` duplicated fields out of their JSON payloads
   (`workflow_id`, `session_status`, `created_at`, parent/root ids, …) via
   hand-written upsert lists, backed by an ALTER-TABLE migration ladder, two
   backfill passes, and legacy fallback read paths. Any new writer had to keep
   the copies in sync by hand.
2. **No integrity between related tables.** `workflow_message_payload_index`
   rows and `memory_entry_references` / `memory_files` rows had no foreign
   keys to their parents, so delete choreography was manual and orphans were
   possible.
3. **Upgrade friction and avoidable I/O costs.** Old stores either migrated
   silently (expensive, drift-prone) or would fail forever; WAL connections
   ran at `synchronous=FULL`; memory regex search materialized entire tables
   into memory before filtering.

## Design

### Generated summary columns (single source of truth)

The projection columns are now `GENERATED ALWAYS AS (json_extract(...)) STORED`
with `NOT NULL` where the payload guarantees presence:

- `workflow_runtime_snapshots`: `workflow_id`, `session_status`,
  `parent_session_id`, `root_session_id` (with
  `COALESCE(json_extract(...), workflow_execution_id)`).
- `cli_workflow_sessions`: `workflow_name`, `workflow_id`, `status`.

`created_at` / `updated_at` stay explicit columns: the JSON dates are
second-granularity ISO8601 while ordering relies on the fractional-second
timestamps the stores write themselves.

### Schema generation (no in-place migration)

`SQLiteWorkflowRuntimePersistenceStore.schemaGeneration` (currently `2`) is
stamped into `PRAGMA user_version` when a session store database is created.
The store never migrates old layouts in place:

- **Writable opens discard incompatible stores.**
  `discardIncompatibleStoreIfNeeded(databasePath:)` runs before every writable
  open (runtime store, CLI session store, standalone message log). A database
  whose `user_version` predates the generation and which contains any of the
  session-store tables is deleted together with its WAL/SHM sidecars, a
  warning is written to stderr, and the open recreates the current schema.
  Session stores hold regenerable run history, so discarding beats failing
  every run after an upgrade.
- **`requireCompatibleSchemaGeneration(in:)`** remains as the in-connection
  safety net and the stamping point; every schema-ensuring path calls it,
  including the message-log-only path (so a store created through it is never
  mistaken for a pre-generation store later).
- **Memory stores keep a hard error instead.** `RielaMemoryStore` data is not
  regenerable, so a pre-`currentSchemaVersion` database throws
  `sqliteFailed("memory store schema predates version …")` and is never
  auto-deleted. Version 3 stores remain valid: the v3 layout differs from a
  fresh store only by the absence of the new FK constraints.

### Referential integrity

- `workflow_message_payload_index` → composite FK to `workflow_messages`
  `ON DELETE CASCADE` (RielaSQLite enables `foreign_keys` per connection).
  Explicit index-row deletes remain for pre-generation stores reached through
  the standalone message-log path.
- `memory_entry_references.record_id` and `memory_files.record_id` →
  `REFERENCES memory_entries(record_id) ON DELETE CASCADE`;
  `PRAGMA foreign_keys=ON` is set right after opening a memory database.
- `loop_baselines` / `loop_concurrency_leases` are `WITHOUT ROWID` (small
  fixed rows addressed by their TEXT primary key).

### Query-shape cleanups enabled by the new schema

- `loadSessionOverviews`: one SQL query; all filters (including
  `lastGateDecision` via `json_extract(loop_summary_json, …)`) resolve in SQL.
  The 200-row batching loop and Swift-side re-filtering are gone.
- `loadSessionSummaries`: one query ordered by
  `(updated_at DESC, workflow_execution_id)` served sort-free by the new
  `idx_workflow_runtime_snapshots_workflow_updated
  (workflow_id, updated_at DESC, workflow_execution_id)` index. The previous
  per-status query loop existed only because no index covered the
  workflow-only ordering.

### Storage-layer performance

- WAL connections set `PRAGMA synchronous=NORMAL` (the recommended WAL
  pairing): the database cannot corrupt on power loss; at most the last
  transaction rolls back.
- Memory regex search streams rows (`streamRows`) instead of materializing
  the full result set, checks the payload regex before building the record
  (skipping the `memory_files` sub-query for filtered rows), and stops
  stepping at the requested limit.

## Operational notes

- Upgrading past generation 2 requires no manual action: the first workflow
  run discards the old session store (project and user scope) with a stderr
  warning. `.riela/kv` and `.riela/memory` stores are unaffected.
- Bumping `schemaGeneration` is the intended way to ship a future
  incompatible session-store layout. Bumping RielaMemory's
  `currentSchemaVersion` invalidates real user memories — do it only for a
  layout the old code cannot read.

## Test coverage

- `SQLiteWorkflowMessageLogTests.testSQLiteRuntimePersistenceSaveDiscardsPreGenerationStoreAndRebuilds`
- `SQLiteWorkflowMessageLogTests` overview/summary tests (generated columns,
  SQL-side filters, blob-poisoning kept decode-free)
- `RielaMemoryTests.testOpeningLegacyDatabaseFailsWithSchemaVersionError`
- `RielaMemoryTests.testMatchPatternSearchStopsAtLimitAndKeepsNewestFirstOrder`
- `SQLiteDatabaseTests.testWritableOpenAppliesWALBusyTimeoutAndJSONBProbe`
  (asserts `synchronous=NORMAL`)
