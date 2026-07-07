# Expected Results

Stable assertions for deterministic verification with the bundled mock scenario.
Ignore `sessionId`, timestamps, and artifact paths.

## Validate

Command:

```bash
riela workflow validate seatbelt-sandboxed-worker --workflow-definition-dir ./examples
```

Expected result: the workflow is valid.

## Run (mock scenario)

Command:

```bash
riela workflow run seatbelt-sandboxed-worker \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/seatbelt-sandboxed-worker/mock-scenario.json \
  --output json
```

Expected stable facts:

- the run completes with status `completed`
- the `main-worker` step output payload contains
  `"writesAttempted": false` and the Seatbelt summary string
- no manager node is involved (`entryStepId` is `main-worker`)

## Live behavior (macOS, not asserted in CI)

With a real `claude` CLI on macOS, the node's
`agentEnvironment.RIELA_SANDBOX_SEATBELT=auto` plus
`agentSandbox: read-only` cause riela to launch the agent process as
`/usr/bin/sandbox-exec -p <generated profile> …`. Writes outside the
agent state directories (`~/.claude`, caches) and temp directories
are denied by the OS; the repository stays untouched. Setting the
binding value to `required` instead makes the run fail loudly on
hosts without Seatbelt. See
`design-docs/specs/design-riela-seatbelt-sandbox.md`.
