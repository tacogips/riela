# Expected Results

Stable assertions for deterministic verification with the bundled mock scenario.
Ignore `sessionId`, timestamps, and artifact paths.

## Validate

Command:

```bash
swift run riela workflow validate claude-riela-codex-coding --workflow-definition-dir ./examples
```

Expected result: the workflow is valid.

## Run

Command:

```bash
swift run riela workflow run claude-riela-codex-coding \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/claude-riela-codex-coding/mock-scenario.json \
  --output json
```

Expected stable run summary:

```json
{
  "status": "completed",
  "workflowName": "claude-riela-codex-coding",
  "workflowId": "claude-riela-codex-coding",
  "nodeExecutions": 6,
  "transitions": 5,
  "exitCode": 0
}
```

Expected final output node: `workflow-output`

Expected final output payload:

```json
{
  "summary": "Reference workflow bundle is ready under examples/ with an explicit claude-code and codex split.",
  "status": "ready",
  "changedFiles": [
    "examples/README.md",
    "examples/claude-riela-codex-coding/"
  ],
  "verification": [
    "workflow validate",
    "workflow inspect",
    "workflow run --mock-scenario"
  ],
  "risks": []
}
```
