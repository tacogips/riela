# Instance cancel post-merge: defaults taken (override if wrong)

1. **Selected-host stop-proof test vs. C8 5 s grace.** The intake asked to fix
   code, not the test. The verified cause is the branch's own, documented 5 s
   SIGTERM grace (`design-instance-cancel.md` C8, `docs/app-instance-control.md`)
   against a fixture that ignores SIGTERM and waits only 4 s. Default: keep the
   5 s grace and widen only the fixture's wait bound, with every assertion
   unchanged (`design-instance-cancel.md` §8.2). Alternative, not taken: shorten
   the grace, which changes documented cancel behavior.
2. **Post-cancel busy window (decided; the fix is required).** Source order
   is confirmed:
   - The runner persists `cancelled` before `job.finish` flips the launch
     snapshot.
   - `instance cancel --wait` returns as soon as the store reads `cancelled`.

   Decision: the in-process busy rule (rule 1) ignores a `running` launch
   whose known root session is persisted as terminal (`design-instance-cancel.md`
   §8.1).

   These still block: pending launches (no session id), persisted
   `created`/`running` sessions, unreadable persisted status (fail-closed),
   and store-probe blockers. `allowOverlap`, `--allow-overlap` and the 409
   shape are unchanged.

   A deterministic regression test is required:
   - a running snapshot with its session persisted as `cancelled` → 202;
   - a pending launch, or a launch whose session is persisted `running`, → 409.
