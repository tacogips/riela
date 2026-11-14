# Payload-independent startup identities

Issue: https://github.com/tacogips/riela/issues/164

The earlier fresh-run optimization avoided Swift hydration but still accessed
late generated columns behind multi-gigabyte SQLite BLOBs and json_each-scanned
all execution payloads. Sampling a live CLI confirmed overflow-page reads before
session creation. Keep the existing ID generator, reservation locks, tombstones,
and persisted existence checks. Store only session/workflow/step IDs in compact
per-snapshot projections, maintained alongside typed persistence writes.

Database INSERT/UPDATE/DELETE triggers invalidate projections even for older
writers and INSERT OR REPLACE. Install schema/triggers atomically. Unknown or
missing trigger lineage rebuilds every affected projection; unsupported schema
versions and malformed ID arrays fail closed. Legacy stores backfill missing
rows once, returning only ID strings from SQLite. Fresh reads check readiness
and load under one read savepoint; raced invalidation retries the bounded
startup seeding operation, never silently skipping IDs. Unchanged projections
never visit session/output/message payloads. Communication IDs use existing
covering message indexes. Resume/recovery hydration stays unchanged.

Verification: focused legacy/backfill, raw replacement, missing trigger,
rollback, future-version/corruption tests plus session resilience/reservation
regressions. Use a consistent read-only backup of the actual large store in a
private scratch directory for an explicit opt-in benchmark, never migrate the
live store as a test. Run a provider-free command workflow against that prepared
copy. Validate a separate immutable locally signed candidate; never overwrite a
running CLI. Public release must not widen private SDK dependencies.
