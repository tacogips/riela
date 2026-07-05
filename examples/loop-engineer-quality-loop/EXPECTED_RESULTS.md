# Expected Results

Stable assertions for deterministic verification with the bundled mock scenario.
Ignore `sessionId`, timestamps, and artifact paths.

## Validate

Command:

```bash
riela workflow validate loop-engineer-quality-loop --workflow-definition-dir ./examples
```

Expected result: the workflow is valid.

## Run

Command:

```bash
riela workflow run loop-engineer-quality-loop \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/loop-engineer-quality-loop/mock-scenario.json \
  --output json
```

Expected stable run summary:

```json
{
  "status": "completed",
  "workflowName": "loop-engineer-quality-loop",
  "workflowId": "loop-engineer-quality-loop",
  "nodeExecutions": 12,
  "transitions": 11,
  "exitCode": 0
}
```

Expected final output node: `workflow-output`

Expected stable loop evidence facts:

- one required gate is recorded with `gateId = "loop-engineer-review"`
- the gate decision is `accepted`
- the loop evidence summary has zero rejected gates and zero blocking findings
- the deterministic path repeats `loop-plan` once before final review

Expected final output payload:

```json
{
  "status": "accepted",
  "iterations": 2,
  "gate": {
    "gateId": "loop-engineer-review",
    "decision": "accepted",
    "blockingFindings": 0
  },
  "residualRisks": [
    "Future examples could include a live command-node probe instead of mock-only evidence."
  ]
}
```
