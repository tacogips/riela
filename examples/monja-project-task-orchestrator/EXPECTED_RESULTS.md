# Expected results

Run commands from `examples/monja-project-task-orchestrator` with Bun and the
current Riela CLI on PATH. This checkout includes the cancellation-finalization
fix required by the real pause verifier. Build the checkout's CLI from the
repository root with `swift build --product riela` and set `RIELA_BIN` to the
absolute path of `.build/debug/riela` when an older installed CLI is on PATH:

```sh
bun install --frozen-lockfile --ignore-scripts
bun run lint
bun run typecheck
bun run test
bun run verify
```

The verifier runs deterministic integration tests and a real temporary Riela
workflow using a mock scenario. No Monja, Wrike, or model credentials are needed
for these fixture checks. The real CLI path must reach every implementation
step and the final verification step; the result must contain a completed
session and positive verification evidence. Mock node responses make this check
deterministic, while Riela itself performs workflow execution and persistence.
The verifier also starts a real sleep workflow, cancels its actual process, and
requires persisted `failed`/`cancelled` acknowledgment. Installed version 0.1.38
was observed to leave a running session after process exit; that behavior must
fail this check and must never be treated as permission to merge.

The integration suite must prove:

- Receipt delivery precedes persisted decomposition/workflow, doing status, and
  start delivery. Progress precedes verified completion and final done status.
- The HTTP adapter uses native Monja `open`/`in_progress`/`done` statuses and real
  task/comment/channel endpoints; Wrike receives comments and completion updates.
- Duplicate events and listener restart do not start duplicate generations.
- Failed notification delivery remains pending and cannot silently disappear.
- Newly discovered tasks can create Wrike counterparts in the configured folder;
  stable markers and durable reservations reconcile ambiguous creation replies.
- Prelaunch persistence failure can recover without losing or launching the task
  twice. Unknown execution observations are inspected again.
- Overlapping work waits, disjoint scopes run concurrently, and unmet
  dependencies or unowned doing work wait.
- Merge occurs only after cancellation acknowledgment and produces a new goal,
  updated description, absorbed-task links, and a new workflow generation.
- Failed execution/verification never changes the task to done.

Task IDs in fixture JSON are stable. Session IDs, absolute artifact paths,
timestamps, subprocess IDs, and notification transport ordering between separate
providers are not stable assertions. Notification markers are stable, and an
ambiguous network failure permits duplicate delivery with the same marker.

## Live acceptance is separate

`bun main.ts <live-project.json>` runs actual Codex planning and execution with
the configured Monja and Wrike services. Record the following only after
observing each corresponding live resource:

| Requirement | Evidence |
| --- | --- |
| Cloudflare deployment | URL, deployment version, migration result |
| Project Kanban isolation | Project A task query and cross-project isolation check |
| Registration receipt | Created task ID and channel message ID |
| Plan before execution | Task description/comments containing goal, steps, and workflow |
| Actual execution | Riela session ID and completed step/verification outputs |
| Progress/completion | Monja message IDs and Wrike task/comment/status responses |
| Final task state | Monja task `done` after successful verification |

Passing local fixtures does not fill this table. Keep live acceptance evidence
under the repository's ignored `tmp/` tree and never include secret values.
