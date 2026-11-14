# Expected Results

Worker-only echo callee used by `workflow-call-live-echo` to verify live
cross-workflow dispatch without an agent backend.

## Validate

Command:

```bash
riela workflow validate workflow-call-live-echo-callee --workflow-definition-dir ./examples
```

Expected result: the workflow is valid.

## Run (standalone, live)

Command:

```bash
riela workflow run workflow-call-live-echo-callee \
  --workflow-definition-dir ./examples \
  --variables '{"handoff":"standalone"}' \
  --output json
```

Expected stable facts:

- `status` is `completed`
- `rootOutput.calleeResult` is `echoed:standalone`
