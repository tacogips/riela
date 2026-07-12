# loop-budget-guard

Demonstrates **loop budget enforcement** (`loop.budget`): an authored budget
is checked at every step boundary (before the next step is dispatched). When a
bound is exceeded the runtime emits one `budget_exceeded` event and — with
`onExceeded: "fail"` — fails the session closed with
`failureKind: "budgetExceeded"`.

This example uses a deliberately impossible wall-clock budget so the demo is
deterministic:

```json
"budget": {
  "maxWallClockMs": 1,
  "onExceeded": "fail"
}
```

The first step (`plan`) completes normally; the boundary check before the
second step (`summarize`) sees elapsed wall-clock > 1ms and stops the run, so
`summarize` is never dispatched.

## Reproduce locally

```bash
riela workflow run loop-budget-guard \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/loop-budget-guard/mock-scenario-exceeded.json \
  --session-store /tmp/riela-loop-budget --output jsonl
```

## What to look for

- One `budget_exceeded` event with `loopBudgetAction: "fail"`,
  `loopBudgetMaxWallClockMs: 1`, the measured `loopBudgetElapsedMs`, and a
  `loopBudgetDiagnostic` such as
  `loop budget exceeded: session wall-clock 12ms; maximum is 1ms`.
- The final record has `status: "failed"` and
  `failureKind: "budgetExceeded"`; `nodeExecutions` stays at 1.

## Other budget bounds

- `maxTotalTokens` — enforced against recorded backend usage totals; absent
  usage never fabricates a violation (mock runs record no usage, so a token
  bound would not trip here).
- `maxSessionAttempts` — bounds recovery lineage: only `session rerun`
  increments the attempt number, so plain run/resume never trips it.
- `onExceeded: "warn"` — emits the same `budget_exceeded` event but lets the
  session continue; the exceedance is projected into the loop evidence as a
  residual risk.

See `EXPECTED_RESULTS.md` for the stable assertions verified with the bundled
mock scenario.
