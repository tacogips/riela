# Workflow Progress Observability

## Summary

`codex-recent-change-quality-loop-session-336` returned
`maxStepsExceeded(12)` after twelve deterministic step executions. The
underlying workflow was still cycling through review, exit-gate, handoff, and
post-handoff because a mid-severity finding stayed open. The command was run
with `--output json`, so the operator saw no session id, current step, or
step progress until the final failure JSON appeared.

Riela already has two useful inspection commands once the session id is
known:

```bash
riela session status <session-id> --output json
riela session progress <session-id> --output json
```

For this run they report `currentStepId: step4-post-handoff`,
`executionCount: 12`, and one open review finding. That proves current-step
state is persisted, but the feature is not discoverable enough during a long
foreground `workflow run`, especially when the caller uses final-only JSON
output.

This document is a review request for making long workflow progress
observable early, terminal failures inspectable, and step-budget failures
actionable.

## Incident Evidence

Run:

```bash
.build/arm64-apple-macosx/debug/riela workflow run \
  codex-recent-change-quality-loop \
  --variables '{"hours":1,"targetPaths":["Sources/RielaApp/DaemonWorkflowGraphPaneView.swift","Tests/RielaAppSupportTests/RielaAppSettingsSectionLayoutTests.swift"],"instruction":"self review and improve"}' \
  --working-dir <workspace>/riela \
  --output json
```

Final command result:

```json
{
  "error": "maxStepsExceeded(12)",
  "exitCode": 1,
  "persistedSession": true,
  "sessionId": "codex-recent-change-quality-loop-session-336",
  "sessionStore": "<home>/.riela/sessions",
  "status": "failed",
  "target": "codex-recent-change-quality-loop"
}
```

Persisted session progress after the command returned:

```json
{
  "sessionId": "codex-recent-change-quality-loop-session-336",
  "workflowName": "codex-recent-change-quality-loop",
  "status": "running",
  "currentStepId": "step4-post-handoff",
  "executionCount": 12,
  "reviewFindingCount": 1
}
```

Observed step sequence:

| Execution | Step | Result |
|---:|---|---|
| 1 | `riela-manager` | completed |
| 2 | `step1-review` | completed, `needs_fix: true` |
| 3 | `step2-exit-gate` | completed, `decision: delegate` |
| 4 | `step3-handoff` | completed |
| 5 | `step4-post-handoff` | completed |
| 6 | `step1-review` | completed, `needs_fix: true` |
| 7 | `step2-exit-gate` | completed, `decision: delegate` |
| 8 | `step3-handoff` | completed |
| 9 | `step4-post-handoff` | completed |
| 10 | `step1-review` | completed, `needs_fix: true` |
| 11 | `step2-exit-gate` | completed, `decision: delegate` |
| 12 | `step3-handoff` | completed |

The next logical step would have been `step4-post-handoff`, but the runner
hit the twelve-step budget first.

## Root Causes

### RC1 - The workflow loop consumed the deterministic step budget

The workflow is intentionally cyclic: review findings route through the
exit-gate, handoff, post-handoff, and then back to review. A single open
mid-severity finding caused repeated delegation cycles. The default or
effective `--max-steps 12` budget was too low for that loop to complete a
fix, post-handoff, and a clean final review.

The code fix was later applied and committed manually, but the persisted
session still has the old open finding because the workflow stopped before it
could run another review and close out.

### RC2 - `--output json` hides session identity and progress until the end

`workflow run --output json` is final-only. It emits one JSON document after
completion or failure, which means a long-running foreground caller cannot
use `session status` or `session progress` unless it already knows the
session id from another source.

The current help text now says the default is `jsonl` and notes that `json`
is legacy and emits only after completion. Package and workflow guidance
should consistently steer long runs to JSONL.

### RC3 - Terminal CLI failure was not persisted as terminal session state

The command returned `status: failed` with `maxStepsExceeded(12)`, but
`riela session progress` still reports `status: running` and
`currentStepId: step4-post-handoff`. That makes the record look active even
though the driver process is gone and no active step exists.

The session should instead persist a terminal failure state with the failure
reason, step budget, last completed step, and next intended step.

### RC4 - Current-step inspection requires a session id

The existing commands are useful but session-id centric. When `workflow run`
is still running under a driver, users need a way to discover the active or
latest session for a workflow without scraping final JSON or scanning the
store manually.

## Existing Features

Riela already exposes current step and progress through:

```bash
riela session progress <session-id> --output json
riela session status <session-id> --output json
riela workflow run <workflow> --output jsonl
```

`session progress` is the right compact shape for quick polling: it includes
the session id, workflow name, status, `currentStepId`, execution count, and
review-finding summary. `session status` is better for full execution
history, but it can be very large.

JSONL run output is the right streaming shape for agents. It can expose the
session id and step transitions before final output, while `--output json`
cannot do that without breaking its single-document contract.

## Proposed Fixes

### P0 - Persist max-step exhaustion as a terminal failed session

When the deterministic runner throws `maxStepsExceeded(n)`, update the
session record to:

- `status: failed`
- `failureReason: maxStepsExceeded(n)`
- `failedAt`
- `lastCompletedStepId`
- `nextStepId` or `currentStepId` with clear failed semantics
- `stepBudget` and `executionCount`

Acceptance criteria:

- `riela session progress <session-id> --output json` reports `failed`, not
  `running`, after a max-step failure.
- The progress payload identifies the last completed step and the step that
  would have run next.
- Tests cover max-step failure persistence.

### P0 - Emit session id early for long runs

Keep `--output json` as a single final JSON document, but provide an explicit
escape hatch for drivers:

```bash
riela workflow run <workflow> --output json --print-session-id
riela workflow run <workflow> --output json --status-file tmp/run-status.json
```

Alternatively, document that any caller needing progress must use
`--output jsonl`. JSONL should always emit an early start event containing
the session id and session store path.

Acceptance criteria:

- A long-running JSONL run exposes the session id within seconds.
- A final-only JSON run has an explicit option to reveal the session id
  outside stdout without corrupting the final JSON payload.

### P0 - Add session discovery commands

Add compact discovery commands for active and recent workflow runs:

```bash
riela session list --workflow <workflow-name> --status running --limit 5 --output json
riela session latest --workflow <workflow-name> --output json
```

Acceptance criteria:

- A user can find the active session id for a workflow without knowing it in
  advance.
- The list shape includes session id, workflow name, status, current step,
  execution count, updated time, and session store path.

### P1 - Improve step-budget diagnostics

When a loop hits `maxStepsExceeded`, include a compact execution summary in
the final error and progress payload:

- repeated step cycle, when detectable
- step budget and loop budget values
- number of review findings still open
- next step that could not be scheduled
- suggested rerun flags, such as increasing `--max-steps`

Acceptance criteria:

- The final error tells the operator whether the workflow was stuck or simply
  budget-limited.
- The message distinguishes `maxStepsExceeded` from node timeout, adapter
  failure, cancellation, and policy block.

### P1 - Align loop defaults with workflow intent

For packaged review loops, make the expected budget explicit in package
workflow defaults or usage text. `maxLoopIterations: 6` does not help users
reason about a twelve-step deterministic budget when one loop cycle consumes
multiple steps.

Acceptance criteria:

- `riela workflow usage <workflow>` shows the workflow's expected max-step
  budget for common cases.
- Review-loop packages either raise their default max-step budget or explain
  when callers should pass `--max-steps`.

### P1 - Update agent skills and package guidance

The `riela-package` skill now tells agents to use JSONL for non-trivial
package workflow runs and to inspect session status/progress after obtaining
the session id. The same guidance should also be kept in workflow-run and
troubleshooting skills.

Acceptance criteria:

- Long workflow examples use `--output jsonl`.
- `--output json` is described as final-only and unsuitable for progress
  monitoring.
- Troubleshooting guidance starts with `session progress` for compact state
  and escalates to `session status` for full history.

### P2 - Add a watch/attach surface

Add a dedicated progress-following command:

```bash
riela session watch <session-id>
riela session attach <session-id>
```

This should stream current step changes, backend silence warnings, completed
execution count, and terminal result. It should not require parsing large
`session status` JSON repeatedly.

## Review Questions

- Should JSONL be the only supported machine-readable mode for long-running
  agent-driven workflows?
- Should `--output json` gain `--print-session-id`/`--status-file`, or should
  docs force callers to JSONL instead?
- Should `currentStepId` mean "currently executing" only, or "next step to
  run" after a failure? The current session shows a stale next-step value as
  if it were active.
- Should `maxStepsExceeded` be recoverable through `session resume`, or
  should callers always rerun with a higher budget?
- Should package workflows declare a recommended `maxSteps` alongside
  `maxLoopIterations`?

## Problems Observed In This Run

- The self-review workflow hit `maxStepsExceeded(12)` after three review
  cycles, before it could run a clean final review.
- `--output json` made the foreground run opaque until the final failure.
- The session id was unavailable during the run unless the operator already
  knew how to inspect the store.
- `session status` and `session progress` can return the current step, but
  both require the session id.
- The persisted session reports `running` even though the command returned a
  terminal failure.
- The open review finding is stale after a manual local fix because the
  workflow did not get another review pass.
- Full `session status` JSON is too large for quick status checks; `session
  progress` is better, but it should be easier to discover and use.

## Suggested Implementation Order

1. Persist max-step exhaustion as a terminal failed session.
2. Ensure JSONL emits a start event with session id and session store path.
3. Add `session latest` or `session list --workflow ...` discovery.
4. Update workflow-run/troubleshooting skill guidance to prefer JSONL and
   compact `session progress`.
5. Add richer step-budget diagnostics and package-level budget guidance.
6. Add `session watch` or `session attach` for live progress following.
