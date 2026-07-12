# Expected Results

Stable assertions for the outcome-notification example, verified with the
bundled mock scenarios. Ignore `sessionId` suffixes and timestamps.

## Validate

```bash
riela workflow validate loop-outcome-notifications --workflow-definition-dir ./examples --output json
```

Expected: `"valid": true` with no diagnostics.

## Accepted outcome

```bash
RIELA_DEMO_NOTIFY_OUT=/tmp/riela-loop-notify-accepted.json \
riela workflow run loop-outcome-notifications --workflow-definition-dir ./examples \
  --mock-scenario ./examples/loop-outcome-notifications/mock-scenario-accepted.json \
  --session-store <store> --output json
```

Expected: run exits **0**; the notify file contains

```json
{
  "schemaVersion": 1,
  "workflowId": "loop-outcome-notifications",
  "outcome": "accepted",
  "entryMode": "run",
  "lastGateDecision": "accepted",
  "gateDecisions": [{"gateId": "implementation-review", "decision": "accepted"}],
  "blockingFindingCount": 0,
  "costSummary": {"stepsWithUsage": 0, "stepsWithoutUsage": 1}
}
```

plus `sessionId`, `startedAt`, `endedAt`.

## Failed outcome (gate rejects, loop fails closed)

```bash
RIELA_DEMO_NOTIFY_OUT=/tmp/riela-loop-notify-failed.json \
riela workflow run loop-outcome-notifications --workflow-definition-dir ./examples \
  --mock-scenario ./examples/loop-outcome-notifications/mock-scenario-rejected.json \
  --session-store <store> --output json
```

Expected: run exits **1** (required gate fail-closed); the notify file
contains `"outcome": "failed"`, `"lastGateDecision": "rejected"`,
`gateDecisions[0].decision` = `"rejected"`, and `"blockingFindingCount": 3`
(one authored finding plus the two synthesized gate-policy findings).

## Dispatch diagnostics

Every attempt/delivery/skip is appended to the session's persisted
diagnostics after terminal persistence, e.g.:

```text
loop notification channel[0] (command, outcome accepted): attempted
loop notification channel[0] (command, outcome accepted): delivered on attempt 1
loop notification channel[1] (webhook, outcome accepted): skipped — environment variable 'RIELA_DEMO_LOOP_WEBHOOK_URL' is not set
```

The webhook channel is skipped (not failed) while
`RIELA_DEMO_LOOP_WEBHOOK_URL` is unset; exporting it (plus optionally
`RIELA_DEMO_LOOP_WEBHOOK_TOKEN`) makes the dispatcher POST the same JSON
payload with `Content-Type: application/json` and a `Bearer` header. To peek
at the persisted diagnostics directly:

```bash
sqlite3 <store>/runtime-records/runtime-message-log.sqlite \
  "select json(diagnostics_json) from workflow_runtime_snapshots
   where workflow_execution_id='loop-outcome-notifications-session-1';"
```

Notification failures never change the run exit code.
