# Issue sweep 2026-10-24: decisions taken by default

None of these blocks implementation. Each one records the default the design
adopted, so the user can overturn it later.

1. **#135: plain rerun carries the target inbox by default.** There is no
   opt-out flag, so getting the old fresh-input behavior would need a new flag.
   Default: no flag is added (design D2 in
   `design-docs/specs/design-rerun-input-carryover-and-finalization-evidence.md`).
2. **#135: importer accepts `completed` sources.** A rerun from a `created` or
   `running` source is now rejected in preflight. Default: accepted (D2).
3. **#104: bind, don't reject, when evidence is unambiguous.** Git-evidence
   steps (commit, push, integration, plan commit/push) are bound whenever
   their latest attempt is accepted; re-executed evidence supersedes them.
   Mode-determining steps are bound only when the rerun cannot reach them.
   Default: bind; otherwise reject in preflight with a recovery message (D3).
4. **#176: gateway validation runs only in `riela workflow validate`.** Run
   preflight, inspect, the registry and the server remain context-free.
   Default: explicit validate only (V0 in
   `design-docs/specs/design-gateway-sdk-addons.md`). Superseded for
   `workflow run` by non-blocking warnings; see
   `qa-issue-176-gateway-json-remainder.md` item 1.
