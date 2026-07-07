# Expected Results

Stable assertions for deterministic verification. This bundle runs **live**
(no mock scenario, no agent backend): both steps are command nodes, and the
cross-workflow transition dispatches `workflow-call-live-echo-callee` through
the runner's live callee resolver. Ignore `sessionId`, timestamps, and
artifact paths.

## Validate

Command:

```bash
riela workflow validate workflow-call-live-echo --workflow-definition-dir ./examples
```

Expected result: the workflow is valid with **no** capability-gap diagnostics.
The `toWorkflowId` + `resumeStepId` transition shape is supported by live runs.

## Run (live)

Command:

```bash
riela workflow run workflow-call-live-echo \
  --workflow-definition-dir ./examples \
  --output json
```

Expected stable facts:

- `status` is `completed`
- caller executions are `["produce-request", "apply-result"]`
- a separate `workflow-call-live-echo-callee` session is created and completed
  with execution `["echo-worker"]`
- `rootOutput.status` is `applied`
- `rootOutput.receivedCalleeResult` is `echoed:outbound-request` — the callee
  root output (which templated the caller handoff `{"handoff":"outbound-request"}`)
  is delivered to `apply-result`; the outbound handoff itself is **not** echoed
  to the resume step
- the message delivered to `apply-result` carries a `_rielaCrossWorkflow`
  object with the callee `workflowId`, child `sessionId`, and `status`
