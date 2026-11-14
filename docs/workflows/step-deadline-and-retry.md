# Step deadline and retry

Add-on steps can set a whole-step deadline and a per-attempt timeout. The deadline
covers waiting and backoff as well as execution; an HTTP request timeout inside a
gateway is not a save-job deadline.

```json
{
  "id": "save-page",
  "nodeId": "notion-write",
  "timeoutMs": 180000,
  "deadlineMs": 600000,
  "retry": {
    "maxAttempts": 4,
    "initialDelayMs": 2000,
    "multiplier": 2,
    "maxDelayMs": 60000,
    "jitter": "deterministic"
  },
  "transitions": [{"toStepId": "next"}]
}
```

## Fields and defaults

| Field | Range and default | Meaning |
| --- | --- | --- |
| `timeoutMs` | Existing timeout field | Per-attempt timeout. Effective timeout precedence remains request override, step, request default, workflow default. |
| `deadlineMs` | Integer 1–86400000; optional | Whole-step budget, anchored at `readyAt = max(input message time, run start)`; a fanout branch entry uses fanout dispatch as its run start. |
| `retry.maxAttempts` | Integer 1–10; required | Total attempts including the first; 1 disables retry. |
| `retry.initialDelayMs` | Integer 0–3600000; default 1000 | Delay before attempt 2. |
| `retry.multiplier` | Finite number 1–10; default 2 | Exponential multiplier for subsequent delays. |
| `retry.maxDelayMs` | Integer from `initialDelayMs` to 3600000; default 30000 | Maximum delay. |
| `retry.jitter` | `none` or `deterministic`; default `none` | Reproducible jitter based on session, execution and attempt. |

Without `deadlineMs` or `retry`, existing behavior is unchanged: one attempt and
no automatic retry. A deadline without retry still bounds a single attempt. The
attempt deadline is the earlier of the step deadline and attempt start plus the
effective timeout; a non-positive effective timeout uses the step deadline.

## Deadline coverage

A local fanout branch entry waiting for a slot expires actively at its deadline.
Projection, attempts and backoff actively expire through the supervisor's fixed
5-second backstop. Runner scheduling, history and store work before dispatch is
elapsed-accounted and checked at the dispatch guard; an already expired step
starts no attempt. Runtime-store writes cannot be preempted and are measured.
The bound is `stepDeadline + 5 s` plus the outcome store write; CPU and store
work cannot be preempted. Queued cross-workflow fanout branches are not actively
expired: at start they fail if expired with `attempts=0`.

A success returned before supervisor expiry is published even when the store write
ends after the deadline; `riela.step.deadline.exceededAfterSuccess` records this.
Late results after expiry are discarded, and an in-flight effect has unknown outcome.

## Retry eligibility

A failure is retried only when `isRetryable == true`, `effectOutcome` is not
`unknown`, attempts remain, the delay fits the budget, and the task is not
cancelled. Unclassified errors are not retryable. Delay after failed attempt `n`
is `initialDelayMs * multiplier^(n-1)`, capped at `maxDelayMs`, then jittered.
Deterministic jitter multiplies this by `0.5 + 0.5 * u`, where `u` is the first
eight bytes of SHA-256 of `<sessionId>/<executionId>/<attempt>` divided by 2^64.
Retry-After raises the resulting delay; a value above `maxDelayMs` stops with
`retry-after-exceeds-max-delay`. If the next delay reaches or exceeds the deadline,
`deadline-exhausted` stops retry before sleeping. Cancellation stops immediately.

## Validation

`riela workflow validate` reports path-qualified errors for invalid ranges, types,
unknown retry keys, or missing `maxAttempts`. `retry` requires `deadlineMs`;
`maxDelayMs` must be at least `initialDelayMs`. A step-authored `timeoutMs` cannot
exceed `deadlineMs`; inherited timeouts are clamped at runtime. Both fields are
limited to add-on-backed steps and cannot be combined with `placement`. `retry`
cannot be combined with add-on `config.writeRetry`. Fanout `fail-fast` is allowed.

## Diagnostics

Backend event `riela.step.attempt.finished` includes `attempt`, `maxAttempts`,
`attemptDurationMs`, `outcome`, `errorCode`, `retryable`, optional `effectOutcome`,
`timeoutKind`, `timeoutSource`, `retryAfterMs` and `nextDelayMs`, plus `elapsedMs`
and `budgetRemainingMs`. Attempt 1 includes `queueWaitMs` and
`recordStartedDurationMs`. `riela.step.retry.stopped` includes `attempts`,
`stopReason` and `elapsedMs`. Stop reasons are `succeeded`, `non-retryable`,
`outcome-unknown`, `retry-exhausted`, `deadline-exhausted`, `step-deadline`,
`retry-after-exceeds-max-delay` and `cancelled`.

Failure reasons include `[rielaRetry attempts=<n> stopReason=<r> elapsedMs=<ms>
timeoutKind=<k> effectOutcome=<o>]`, including in collect-partial join records and
session status. Telemetry `riela.step.publication.duration` records `durationMs`
and `exceededDeadline` after outcome publication.

## ART save jobs

For each Notion save step, use `timeoutMs: 180000`, `deadlineMs: 600000`, and
`retry: {"maxAttempts": 4, "initialDelayMs": 2000, "multiplier": 2,
"maxDelayMs": 60000, "jitter": "deterministic"}`. Set `failurePolicy` to `fail`
(or omit it for the default); never use `advisory` for a save, since it can make a
failed branch appear completed. Use `failurePolicy: "collect-partial"` on the
publish fanout. Use `deadlineMs: 120000` without retry on `riela/json-route`
steps. Keep the scheduled overlap policy unchanged.

A failed join record retains the original item, failure reason and, for a started
branch, session ID. Riela retains runtime evidence only; collect-partial does not
create a cross-run backlog. ART owns that backlog. Items with
`effectOutcome=unknown` require reconciliation by ART or an operator before
resubmission. When the save is the branch entry, an unstarted local branch fails
at dispatch plus its deadline; a started one stops save work by that deadline plus
5 seconds and the outcome store write. Later steps need their own deadlines.

## Not covered

This policy does not fix CPU or scheduling overhead, provide a run-level deadline,
automatically reconcile Notion or supply idempotency keys. It does not add retry to
agent, stdio or placement steps, and does not change resume or rerun semantics.
