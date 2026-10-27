# Storage inspection and compaction

`riela doctor storage` reports where runtime data is stored and how much space
is used or reclaimable. It is read-only: it does not create stores, migrate
schemas, take session locks, or change database files.

```sh
riela doctor storage [--scope project|user|auto] [--working-dir <dir>]
  [--session-store <dir>] [--memory-root <dir>] [--cache-root <dir>] [--kv-root <dir>]
  [--top <n>] [--output text|json]
```

Without explicit roots, the command inspects project and user stores through the
normal resolvers. Runtime session data is at
`<session-root>/runtime-records/runtime-message-log.sqlite`; workflow definition
history is at `<session-root>/runtime-message-log.sqlite`.

For each database, the report includes its path and kind, database and WAL
bytes, page size/count, free pages/bytes, auto-vacuum mode, schema generation,
and per-table bytes and row counts. Table byte counts use SQLite `dbstat` when
available and are marked estimated when calculated from known columns. Memory
details include current and history bytes, amplification, legacy record count,
unreferenced attachment bytes, and largest records. Session details include
legacy inline snapshots and CLI copies, nested embedded bytes, prune blockers,
abandoned invocation candidates, and largest sessions. Definition details
include workflow/version counts, versions outside the retention window, pins,
and retention state. Reclaimable estimates separate free pages, compaction,
and terminal pruning.

`riela storage compact` converts old representations and applies configured
maintenance. It is a dry run unless `--apply` is supplied:

```sh
riela storage compact [--scope project|user|auto] [root options]
  [--max-batch <n>] [--abandoned-after-hours <h>]
  [--results-max-age-days <n>] [--results-max-total-bytes <size>]
  [--messages-max-age-days <n>] [--messages-max-total-bytes <size>]
  [--apply] [--allow-live-vacuum] [--output text|json]
```

The default batch is 500 (maximum 10,000). In order, compact converts legacy
memory records to compressed full/splice history, converts old session snapshots
to canonical headers plus execution rows, replaces legacy CLI session copies
with envelopes, moves nested payloads to references, backfills definition pins
and applies definition retention, reconciles abandoned nested invocations,
applies the configured retention policy, and reclaims SQLite space. Session
conversion holds a non-blocking per-session execution lock; a busy session is
reported and left for a later run.

The process is resumable. Partial batches leave a mixture of old and new rows;
both formats remain readable. `workRemaining: true` means run compact again.
Dry-run reports planned work without writing or taking/creating execution
locks.

Full `VACUUM` on an existing `auto_vacuum=NONE` database needs free space of at
least 2 times the combined database and WAL size, plus 256 MiB. Below that
threshold, conversion is deferred with `deferredInsufficientSpace`. The report
includes the `VACUUM INTO` recovery sequence: create and validate a copy on the
destination filesystem, stop writers, checkpoint and close the source, replace
it, then remove stale `-wal`/`-shm` files before reopening. Cross-volume rename
is not atomic, and the CLI does not provide a store-wide lock for that procedure.

By default, full vacuum waits until no session execution lock is held. The
explicit `--allow-live-vacuum` flag overrides that safeguard for full conversion
only; use it only after coordinating writers. Incremental vacuum remains
bounded. A held-reader checkpoint can leave a warning and make apply fail, so
inspect the report and retry after the reader exits.

After an applicable workflow run ends, Riela also releases any unreferenced
payloads in that run's family and runs a bounded incremental vacuum of at most
4,096 free pages on incremental-auto-vacuum session stores. This run-end pass is
family-local and does not perform a full vacuum or change terminal-session
retention policy.
