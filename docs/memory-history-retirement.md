# Retire obsolete memory history

Available in Riela 0.2.17 and later.

Normal memory updates use bounded automatic history retention (2 versions by
default; runtime snapshot state retains 1). Manual retirement is therefore
rarely needed for routine cleanup. Replacing a payload with a cache reference
does not itself erase retained bodies. Cache TTL and terminal session prune do
not retire application-owned checkpoint history.

After an application's own migration verifies its cache and current checkpoint, quiesce that application's acquisition writers (ART holds its acquisition lock), inspect its exact head, then plan a single-record retirement:

```sh
riela memory retire-history <memory-id> \
  --memory-root /absolute/owned/memory \
  --record-id <record-id> --workflow-id <owner-workflow> --node-id <owner-node> \
  --tag acquisition-checkpoint \
  --expected-head-version <head> --through-version <head-minus-one> \
  --dry-run --output json
```

Remove `--dry-run` to apply. The command requires every scope/ownership argument and retires only versions before that exact head. It does not update/delete current records, metadata, related references, receipt data, or attachments. Its tag arguments are required membership checks, not replacement tags. For a new-format record, retirement drops every non-head version through the shared history engine; the current head remains. Legacy records keep the original head number and use a retained floor; future updates continue monotonically. `show-version` and `restore-version` below a legacy floor fail with `retiredVersion`; new-format history outside the retained set reports `version_not_retained`. No older-value fallback occurs. `history` lists only retained revisions.

Dry-run opens the existing database read-only and does not migrate it or create missing state. Apply requires exclusive SQLite admission and rechecks ownership and head CAS. Busy readers/writers, current or historical related links, any retained attachment, unknown schemas, other records with uninspectable historical links, and chains over 1,000 revisions cause conservative blocking. A malformed chain is an error. Load/search audit rows are access logs with no version pin/release semantics; retirement preserves them and they do not block retirement.

Retirement validation walks the retained reverse-delta chain once from the head, reconstructing and inspecting every historical snapshot. It does not reconstruct each version independently from the head. The chain limit, historical reference and attachment checks, exclusive admission, and expected-head comparison still apply.

Reports contain only status, dryRun, headVersion, retainedFloor, retiredRevisionCount, retiredDeltaBytes, and reclaimed. A successful process exit means a report was returned: callers must inspect status. `planned` is read-only eligibility, `retired` confirms logical retirement and native reclaim, and `pending_reclaim` means retirement committed but native reclaim did not finish. Other statuses describe blockers; they do not authorize an independent deletion fallback. Retrying the same exact head permits reclaim retry without resetting the version.

Apply uses secure deletion, VACUUM, and WAL truncation while keeping exclusive admission until connection close. It preserves other live database values; it is not whole-disk secure erasure of filesystem snapshots/backups. Exclusive SQLite admission detects active database transactions/connections; it cannot prove broader application process liveness, revoke already-loaded values in heaps, or discover application-specific version references encoded inside arbitrary JSON or external stores. Applications must verify those dependencies and quiesce their own writers before apply. When multiple heads need migration, first cache and verify their union, then compact and retire one head at a time; another head with unretired history conservatively blocks apply. Already-retired identity markers do not block the next head. Current and obsolete acquisition heads must all be migrated safely; do not assume one current head covers an older head's unique cached posts.

Schema 5 adds a per-record retained floor. The head's reverse edge becomes an identity marker with no old body bytes. Historical delta removal does not append another revision containing the retired body. This feature is explicit and irreversible; ordinary update and terminal retention keep their existing behavior.
