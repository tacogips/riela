# Expected Results

Stable assertions for deterministic verification with the bundled mock scenario.
Ignore `sessionId`, timestamps, and artifact paths.

## Validate

Command:

```bash
riela workflow validate worker-only-single-step --workflow-definition-dir ./examples
```

Expected result: the workflow is valid.

## Inspect

Command:

```bash
riela workflow inspect worker-only-single-step --workflow-definition-dir ./examples --output json
```

Expected stable inspection facts:

- `hasManagerNode` is `false`
- authored `entryStepId` is `main-worker`
- the step-first inspection summary does not emit removed top-level node-addressed entry/manager fields; `managerStepId` is absent for this worker-only bundle

## Run

Command:

```bash
riela workflow run worker-only-single-step \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/worker-only-single-step/mock-scenario.json \
  --output json
```

Expected stable run summary:

```json
{
  "status": "completed",
  "workflowName": "worker-only-single-step",
  "workflowId": "worker-only-single-step",
  "nodeExecutions": 1,
  "transitions": 0,
  "exitCode": 0
}
```

Expected `main-worker` payload:

```json
{
  "summary": "Worker-only workflow completed from its explicit entry node.",
  "status": "ready",
  "verification": [
    "workflow validate",
    "workflow inspect",
    "workflow run --mock-scenario"
  ],
  "risks": []
}
```

## Named Instances

Commands:

```bash
riela instance create cheap-model \
  --workflow worker-only-single-step \
  --workflow-definition-dir ./examples \
  --node-patch '{"main-worker":{"model":"gpt-5.3-codex-spark"}}'

riela instance create high-effort \
  --workflow worker-only-single-step \
  --workflow-definition-dir ./examples \
  --variables '{"workflowInput":{"mode":"thorough"}}' \
  --node-patch '{"main-worker":{"model":"gpt-5.3-codex-spark","effort":"high"}}'

riela workflow run worker-only-single-step \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/worker-only-single-step/mock-scenario.json \
  --instance cheap-model \
  --output json

riela workflow run worker-only-single-step \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/worker-only-single-step/mock-scenario.json \
  --instance high-effort \
  --output json
```

Expected stable assertions:

- both runs complete successfully with one `main-worker` execution
- the cheap-model run records `session.instanceIdentity == "cheap-model"` and `session.instanceKind == "named"`
- the high-effort run records `session.instanceIdentity == "high-effort"`, `session.instanceKind == "named"`, and `session.instanceConfiguration.defaultVariables.workflowInput.mode == "thorough"`
