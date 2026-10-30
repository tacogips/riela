# QA: session store efficiency and default GC

Design: `design-docs/specs/design-session-storage-efficiency-and-default-gc.md`.
Source: the inline workflowInput (no GitHub issue).

## Status

None of these block implementation. Each question has a default that the
design already assumes. Implementation follows the default unless the user
changes it.

## Questions

1. **What are the built-in default retention values?**
   Default: results 30 days, messages deleted with their results, logs 30 days.
   There is no default byte cap. Byte caps stay opt-in through config or
   `riela gc` flags, so a default can never select a family because of store
   size.
   Alternative: also ship a default `results.maxTotalBytes`, for example 10 GB,
   for stores that grow quickly within 30 days.
2. **Do defaults fill categories missing from an existing `retention`
   object?**
   Default: yes, per category. To keep a category, set
   `{"keepForever": true}`.
   Alternative: any `retention` object disables every default.
3. **Do defaults delete workflow-history snapshots, event receipts and
   handover files (the generated sweep)?**
   Default: no. The sweep runs only when `results.maxAgeDays` is set
   explicitly.
4. **Does RielaApp run automatic maintenance?**
   Default: yes. RielaApp shares the scheduled pass with `events serve` and
   `serve`.
5. **Are existing generation-11 canonical execution rows re-encoded into the
   reduced form?**
   Default: no bulk rewrite. Each row is re-encoded on its session's next save.
   Otherwise it ages out under retention.
6. **Should automatic maintenance convert legacy rows of non-terminal
   sessions?**
   Default: no. Only terminal sessions whose locks are free are converted.
   Non-terminal sessions convert on their next save, and
   `riela storage compact --apply` still converts any lock-free session.
7. **What happens to a legacy row that automatic conversion cannot convert?**
   Default: after 3 failed attempts across passes the row is *parked*. It is
   never retried automatically, never deleted and never rewritten, and it stays
   readable. Riela writes one stderr warning, and `riela doctor storage` reports
   the row. `riela storage compact --apply` can still convert it. Retries never
   take more than half of a pass's budget, so parked or busy rows cannot stall
   the conversion of other rows.
   Alternative: retry failing rows forever at a lower rate.
8. **Does "remove the small incremental-vacuum cap" mean no cap at all?**
   Default: no. The 128-page cap is replaced by 4,096 pages per run-end pass
   and 65,536 pages per scheduled pass (design §5.3 Step 2), so one pass never
   holds the write lock for an unbounded time and a large free list shrinks
   over consecutive passes.
   Alternative: vacuum the whole free list in one pass.
9. **Which `storage compact` results count as remaining work?**
   Default: only pending conversion or reclamation (design §10.2). A failed
   or busy retention pass and abandoned-invocation verdicts (`live`,
   `skipped`) are reported as warnings or in `reconciled`, but do not set
   `workRemaining`.
   Alternative: keep abandoned-invocation `skipped` verdicts as remaining
   work.
