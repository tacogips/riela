# Terminal workflow payload retention

The retrieval cache owns only its own SQLite database. Workflow snapshots,
message logs and automatic node-memory journals can contain separate body copies.
Use opt-in terminal retention to bound those managed copies without deleting
user-authored memory, persona records, checkpoints or export receipts.

```sh
riela session prune \
  --session-store /srv/example/sessions \
  --artifact-root /srv/example/artifacts \
  --memory-root /srv/example/memory \
  --workflow-id latest-digest --workflow-id liked-posts \
  --retention-hours 24 --max-payload-bytes 268435456 --dry-run --output json
```

All three roots must be explicit absolute, non-overlapping paths without symlinks.
`--session-store` is a directory, resolving to
`session-store/runtime-records/runtime-message-log.sqlite`; it is not a database
filename. The artifact and memory roots must belong to the same workflow runs.
At least one workflow ID is required. The default age is 24 hours (1–8760); the
default charged-payload cap is 256 MiB (1 byte–64 GiB). Remove `--dry-run` to apply.
Schedule the same scoped command hourly; no hidden background pruning is started.
Upgrade every writer sharing these roots to this version before enabling pruning.
Writers must use the same session admission/execution locks. Canonical runtime
SQLite guards reject stale writes to retired IDs; arbitrary library clients that
write artifact files or secondary databases outside that admission protocol are
not covered and must not share roots under this policy.

Only complete root/parent families whose statuses consistently agree on completed
or failed are eligible. The family's newest update determines age. Oldest eligible
families are removed first when over budget. Created, running, suspended, orphaned,
locked, conflicting or future-dated families remain protected. The command does
not resume workflows, call providers, or infer termination from a missing process.

Work Runtime/specialist-owned sessions, active concurrency leases, unsettled nested
invocations, edited automatic journals and journals with external attachments
remain protected. Their separate ownership cannot be safely inferred from age.

Before deletion, the command acquires the existing execution locks and rechecks
all family metadata in the runtime database transaction. Compact tombstones reserve
the old session IDs and reject resume/admission after payload expiry. Tombstones
record only IDs, roots, timestamps, pending cleanup and byte counts, never bodies.
An interrupted secondary cleanup is retried by the next invocation with the same
roots and workflow scope. Errors are nonzero and never silently report completion.

Managed copies are runtime session/message rows and settled nested invocation
payloads; `artifact-root/runtime-message-log.sqlite`; each exact
`artifact-root/<session-id>/runtime-snapshot.json`; and memory rows whose source is
`riela-node-manager`, direction is inbox/outbox, and workflow/session IDs match.
Other memory is preserved even in the same database. Extra files in a session
artifact directory protect that family. Arbitrary artifact-reference paths,
external files, application logs and user outputs are never recursively deleted.
Keep those caller-owned outputs compact or give them a separate ownership policy.

JSON reports include selected families, removed session count, protected reasons,
pending cleanup, before/remaining charged payload bytes and `capAchieved`.
A protected family can prevent the cap from being achieved; callers must inspect
that field. Dry-run is a metadata-only estimate and does not acquire/create locks,
write tombstones, reclaim storage or delete files. Apply always rechecks eligibility.

The cap measures managed payload bytes, not total filesystem allocation. SQLite
indexes, compact tombstones, page allocation and concurrent rollback/WAL overhead
are additional. Successful cleanup uses secure deletion, checkpointing and VACUUM
to reclaim database storage. It never truncates files directly or bypasses SQLite
writer locks. Durable memory records in the same database remain intact.

The older `riela gc` command no longer deletes runtime sessions, artifacts or logs
based only on age. Its existing workflow-history/event-receipt and terminal task
handover behavior remains separate.
