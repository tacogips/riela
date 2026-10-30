# Automatic retention: default decisions open to revisit

## Issue reference

workflowInput `automatic-config-driven-retention`: "Automatic, config-driven
retention for Riela session results, messages and logs". Design:
`design-docs/specs/design-automatic-retention.md`.

## Status

None of these block implementation. Each question below already has a decided
default in the design. Implementation follows the default unless the user
changes it.

Note (2026-10-30): "no config means no deletion" is superseded by the
built-in default policy in `design-session-storage-efficiency-and-default-gc.md`
§4.

## Questions

1. **What happens to messages when `messages` is not configured?**
   Default: a family's message rows are deleted together with its pruned
   results, which matches today's behavior. Set `messages.keepForever` or
   `messages` limits to judge messages independently.
2. **Does `keepWorkflowIds` cover messages?**
   Default: no. It applies to results only, as the request specified. Messages of
   kept workflows follow the messages policy, and a family whose messages are
   pruned can no longer be resumed or rerun.
3. **How long is the log grace window?**
   Default: a fixed 24 hours. Byte caps cannot remove logs modified within the
   last 24 hours. The report shows `capAchieved: false` when those files keep the
   total over the cap.
4. **Which size units are used?**
   Default: KB/MB/GB/TB are 1000-based and KiB/MiB/GiB/TiB are 1024-based.
   Decimals are rejected.
5. **When can a large DB be converted to `auto_vacuum=INCREMENTAL`?**
   Default: only manual `riela gc` or `riela session prune` converts a DB larger
   than 64 MiB, and only with at least 2 × (DB + WAL) + 256 MiB of free space.
   Automatic passes defer the conversion. Until then, freed pages are reused, so
   the file stops growing. On the operator machine (6.0G DB), run `riela gc` once
   with about 12.3G free.
6. **Are alternate stores discovered automatically?**
   Default: no. Only the user store, the project store and an explicit store
   (`--session-store` or `RIELA_SESSION_STORE`) are managed.
   `~/.riela/sessions-telescreen` is pruned when a command runs with
   `RIELA_SESSION_STORE` pointing at it, or with `riela gc --session-store
   ~/.riela/sessions-telescreen`.
