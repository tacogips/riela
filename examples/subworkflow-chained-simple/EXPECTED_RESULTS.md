# Expected Results

Stable assertions for deterministic verification with the bundled mock scenario.
Ignore `sessionId`, timestamps, and artifact paths.

## Validate

Command:

```bash
riela workflow validate subworkflow-chained-simple --workflow-definition-dir ./examples
```

Expected result: the workflow is valid.

## Inspect

Command:

```bash
riela workflow inspect subworkflow-chained-simple --workflow-definition-dir ./examples --output json
```

Expected stable inspection facts:

- authored `managerStepId` is `riela-manager`
- authored `entryStepId` is `riela-manager`
- `stepIds` list `riela-manager`, `alpha-manager`, `alpha-input`, `alpha-worker`, `alpha-output`, `beta-manager`, `beta-input`, `beta-worker`, and `beta-output`

## Run

Command:

```bash
riela workflow run subworkflow-chained-simple \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/subworkflow-chained-simple/mock-scenario.json \
  --output json
```

Expected stable run summary:

```json
{
  "status": "completed",
  "workflowName": "subworkflow-chained-simple",
  "workflowId": "subworkflow-chained-simple",
  "nodeExecutions": 9,
  "transitions": 8,
  "exitCode": 0
}
```

Expected final output node: `beta-output`

Expected final output payload:

```json
{
  "summary": "Chained lane example completed.",
  "status": "ready",
  "notes": ["beta-lane followed alpha-lane in ordered node flow"]
}
```
