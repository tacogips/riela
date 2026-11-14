# Expected Results

Stable assertions for the loop budget-guard example, verified with the bundled
mock scenario. Ignore `sessionId` suffixes, timestamps, exact elapsed
milliseconds, and artifact paths.

## Validate

```bash
riela workflow validate loop-budget-guard --workflow-definition-dir ./examples --output json
```

Expected: `"valid": true` with no diagnostics.

## Run (mock scenario)

```bash
riela workflow run loop-budget-guard --workflow-definition-dir ./examples \
  --mock-scenario ./examples/loop-budget-guard/mock-scenario-exceeded.json \
  --session-store <store> --output jsonl
```

Expected (CLI exit code **1**):

- `plan` emits `step_started`/`step_completed`; `summarize` never starts.
- exactly one `budget_exceeded` event:

```json
{
  "type": "budget_exceeded",
  "loopBudgetAction": "fail",
  "loopBudgetMaxWallClockMs": 1,
  "loopBudgetElapsedMs": "<measured, > 1>",
  "loopBudgetDiagnostic": "loop budget exceeded: session wall-clock <n>ms; maximum is 1ms"
}
```

- the final record has `"status": "failed"`,
  `"failureKind": "budgetExceeded"`, and `nodeExecutions` = 1.
