# Issue sweep 2 (2026-10-24): decisions taken by default

None of these blocks implementation. Each one records the default the design
adopted, so the user can overturn it later.

1. **#32: resume/rerun hydrate the session family, not just the target.**
   The family is every canonical snapshot sharing the target's
   `root_session_id`. Nested resume re-enters reserved children, so
   hydrating the target alone would break it. Default: family
   (`design-cli-session-store-decode-resilience.md`, "Recovery hydration
   scope").
2. **#32: the low-CPU 15-minute wait was not reproduced.** The fix removes the
   confirmed O(store) pre-first-event work and adds no speculative
   timeout/abort logic. Default: treat it as residual risk.
3. **#27: `cancelled` sessions remain non-resumable; rerun accepts them.**
   This keeps today's behavior for `failed`+`cancelled`. Default: no resume
   change (`design-cancellation-and-orphan-session-resilience.md`,
   "2026-10-24 Contract", P1 item 6).
4. **#27: cancelled runs keep exit code 1.** The `128 + signal` mapping is a
   follow-up. Default: exit code unchanged.
5. **#27: orphan detection uses the existing per-session `flock`.** There are
   no pid/host/heartbeat fields. `session reconcile` is a dry run unless
   `--apply` is given, and it marks orphans `cancelled` with a stable "runner
   process lost" reason. It does not add a new `abandoned` status. Default:
   as stated.
6. **#27: unknown persisted status values decode as `failed`.** The raw string
   is not preserved. Default: as stated.
7. **#74: runner-level `transition.dynamicWorkflow`, not a builtin add-on.**
   Default: transition extension
   (`design-loop-engineering-brain-generated-workflow-loop.md`).
8. **#74: generated workflows are deny-by-default.** Only `agent` nodes are
   allowed, backends and models default to the parent's, there are no add-ons,
   and authority-bearing payload fields are forbidden. Generated workflows can
   neither call registered workflows nor nest dynamic calls. Widening is only
   possible through the parent's authored `dynamicWorkflow.allow`. A key
   allowlist covers the whole generated definition, so `handover`, `memories`,
   `requiredEnvironment`, workflow `loop`, `triggerDefaults`, `nodeRef`,
   `inputFilters`, step `placement`/`stepFile` and unknown keys are all
   rejected. Nodes come only from the envelope's `nodePayloads`, with no file
   fallback. Default: as stated (design rules 9-10).
9. **#74: invalid definitions and child failures go back to the brain**
   (`onFailure: "return"`) and count toward `maxIterations` (default 4,
   ceiling 16). Default: as stated.
10. **#74: wall-clock and token/cost budgets for the whole loop are a
    follow-up.** The child inherits the parent's step, timeout and loop
    bounds. Default: follow-up.
