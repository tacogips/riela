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
and terminal pruning. `remainingBytes` is the sum of compaction and pruning
estimates and is an upper bound, since they may overlap. `session.payloadFragments`
reports fragment and reduced-payload rows, bytes, references, dangling references
and unreferenced payloads; unreferenced payload bytes are not added to the
remaining estimate. `session.maintenance` reports parked, busy and failed rows,
queue completion and examples when a cursor exists. For session and definition
databases with `auto_vacuum=NONE`, `recovery` reports required and available
free space and the recovery path.

New execution payloads use root-scoped SHA-256 content-addressed fragments for
input snapshot subtrees of at least 1024 bytes, with `$rielaPayloadRef` and
`_rielaPayloadRefs` markers. Fragments are released only when no references
remain. Older formats remain readable; reads fail closed for missing or corrupt
fragments. Schema generation 12 makes older binaries reject the store. Fragments
are not compressed.

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

The prune step uses the effective policy, including the built-in default of
30 days for results and logs; messages follow results and there is no default
byte cap. The process is resumable and older formats remain readable.
`workRemaining` indicates pending conversion or reclamation: a batch limit,
locked or failed legacy conversion, pending or failed memory conversion or
definition-pin backfill, a dry-run estimate of convertible rows, or deferred,
busy, failed or incomplete SQLite reclamation. Retention warnings or busy
retention targets and abandoned-invocation verdicts alone do not set it.
Dry-run reports planned work without writing or taking/creating execution locks.

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

Automatic maintenance runs after workflow run, resume, rerun and continue, and
periodically in `events serve`, `serve` and RielaApp. It converts only terminal
legacy rows and skips held execution locks. Rows can be converted, busy, failed,
retired or parked; after three conversion failures a row is parked with a
warning and can be addressed with `riela storage compact --apply`. The cursor
is `storage-maintenance.json` in the target retention state directory: for an
explicit store this is `<store>/retention`, and for a project store it is
`<project>/.riela/retention`. Doctor reads it without creating or changing it.

Run-end conversion is bounded to 16 conversions, 256 examined rows and 2 seconds;
scheduled conversion allows 64, 1024 and 10 seconds. Retries use at most half
each budget, leaving room for forward progress. Incremental vacuum is capped
at 4,096 pages at run end and 65,536 on scheduled passes; automatic maintenance
never performs a full `VACUUM`. Set `automatic: false` or
`RIELA_RETENTION_AUTOMATIC=0` to disable automatic passes.

`keepForever` disables limits for a category; `RIELA_RETENTION` takes precedence
over project and user configuration, and gc flags override limits. The generated
sweep runs only with an explicitly configured or flag-provided results age.
Expired read-only snapshot directories inside the store can be made
owner-writable and removed; unremovable paths produce warnings, not failures.
See [terminal retention](terminal-retention.md) for policy and upgrade details.
