# note-kanban-orchestrate — expected mock results

Run:

```
riela workflow run note-kanban-orchestrate \
  --workflow-definition-dir examples \
  --mock-scenario examples/note-kanban-orchestrate/mock-scenario.json \
  --input task="demo orchestration"
```

Every node is canned in the scenario (add-on nodes included), so the run
touches no real note store and is deterministic at any fan-out concurrency:
branch responses are identical per node, and the only sequenced node
(`step6-review`) is executed once per round by the parent session.

Expected flow:

1. `riela-manager` → `step1-decompose` emits 2 tasks
   (`analysis-brief`, `draft-plan`).
2. `step2-board-setup` reports both cards created `pending`.
3. Fan-out `task-execution` (collect-partial) runs both cards through
   `step3-claim` (no conflict) → `step4-execute` → `step5-record-result` →
   `step5b-mark-review`, joining at `step6-review`.
4. Review round 1: `analysis-brief` passes, `draft-plan` fails →
   `needs_rework` dispatches fan-out `task-rework` over `/failedTasks`
   (1 item, round 2) through the same branch path, joining back at
   `step6-review`.
5. Review round 2: `all_pass` dispatches fan-out `finalize-done` over
   `/passedTasks` (2 items) through `step7-move-done`, joining at
   `step8-summary`.
6. `step8-summary` → `step9-record-summary` → `workflow-output` publishes
   `{goal, verdicts (both passed), unresolvedTasks: []}` with exit code 0.

Assertions to check on the session record:

- `step6-review` executed exactly twice; `step3-claim`/`step4-execute`/
  `step5-record-result`/`step5b-mark-review` executed 3 times total
  (2 first-round branches + 1 rework branch); `step7-move-done` twice.
- The root output payload equals the `step9-record-summary` payload
  (`{noteId: "note-mock-summary", notebookId: "nb-mock-summary", status:
  "ok"}`) — the output node projects the latest input payload.
- Add-on payload shapes are asserted by the canned entries themselves; the
  real add-on behavior (idempotent task creation, CAS conflicts, board
  grouping) is covered by `NoteAddonTests` in `RielaCLITests`.

Live-run notes:

- Recovery contract is `session rerun` (fan-out sessions are not resumable
  mid-dispatch); `riela/note-kanban-task-create` reuses non-done cards by
  `taskKey` and `step3-claim`'s compare-and-set skips cards that already
  advanced, so reruns converge without duplicating work.
- Subtasks must be notebook-content deliverables only (the decompose prompt
  enforces this); workspace-mutating tasks are out of scope for this
  workflow.
