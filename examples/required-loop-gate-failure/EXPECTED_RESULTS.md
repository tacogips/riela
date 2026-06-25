# Expected Results

Stable assertions for required loop gate fail-closed verification. Ignore
`sessionId`, timestamps, and artifact paths.

## Validate

Command:

```bash
riela workflow validate required-loop-gate-failure --workflow-definition-dir ./examples
```

Expected result: the workflow is valid.

## Inspect

Command:

```bash
riela workflow inspect required-loop-gate-failure --workflow-definition-dir ./examples --output json
```

Expected stable inspection facts:

- `loop.required` is `true`
- `loop.kind` is `design-implement-review`
- the workflow declares one required `implementation-review` gate
- the `implementation-review` step is tagged as a loop `gate`

## Rejected Gate Run

Command:

```bash
riela workflow run required-loop-gate-failure \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/required-loop-gate-failure/mock-scenario-rejected.json \
  --session-store ./tmp/required-loop-gate-failure/sessions \
  --artifact-root ./tmp/required-loop-gate-failure/artifacts \
  --output json
```

Expected stable run summary:

```json
{
  "status": "failed",
  "workflowId": "required-loop-gate-failure",
  "nodeExecutions": 1,
  "transitions": 0,
  "exitCode": 1,
  "loopEvidence": {
    "gateCount": 1,
    "acceptedGateCount": 0,
    "rejectedGateCount": 1,
    "blockingFindingCount": 2
  }
}
```

Expected gate facts:

- `loopEvidence.rejectedGateCount` is `1`
- `loopEvidence.blockingFindingCount` is `2`: the authored finding plus the
  runtime gate-threshold finding
- `riela loop gates <session-id> --session-store ./tmp/required-loop-gate-failure/sessions --output json`
  reports `implementation-review` with decision `rejected`
