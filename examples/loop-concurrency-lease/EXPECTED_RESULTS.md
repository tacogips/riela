# Expected Results

Stable assertions for the concurrency-lease example. Ignore `sessionId`
suffixes and timestamps. The demo is timing-based (a real 6s sleep holds the
lease), so drive it with `run-demo.sh` or two terminals.

## Validate

```bash
riela workflow validate loop-concurrency-lease --workflow-definition-dir ./examples --output json
```

Expected: `"valid": true` with no diagnostics.

## Run 1 (holds the lease)

```bash
riela workflow run loop-concurrency-lease --workflow-definition-dir ./examples \
  --mock-scenario ./examples/loop-concurrency-lease/mock-scenario.json \
  --session-store <store> --output json
```

Expected (exit **0**, after ~6s): `"status": "completed"` with two
executions — the `hold` step's payload is
`{"provider": "sleep", "status": "completed", "durationMs": 6000}` and the
mocked `report` step returns the bundled summary.

## Run 2 (concurrent, while run 1 is sleeping)

Same command in a second terminal within the 6s window.

Expected (exit **1**): a single busy record and **no new session**:

```json
{
  "type": "loop_concurrency_busy",
  "workflowId": "loop-concurrency-lease",
  "holderSessionId": "loop-concurrency-lease-session-1",
  "holderHeartbeatAt": "<timestamp>",
  "onBusy": "fail"
}
```

`riela loop list --workflow loop-concurrency-lease --session-store <store>`
during the hold shows only `…-session-1` with `sessionStatus` `running`.

## Run 3 (after run 1 finishes)

Same command again.

Expected (exit **0**): the lease was released at terminal persistence, so a
new session runs and completes normally.
