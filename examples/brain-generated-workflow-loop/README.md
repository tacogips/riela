# Brain-Generated Workflow Loop

This example shows a read-only brain generating two small workflows, using the first result to shape the second, and returning a final decision. Generated workflows run as session-scoped child sessions under the parent's dynamic-workflow allowlist.

Validate the authored contract:

```bash
riela workflow validate brain-generated-workflow-loop --workflow-definition-dir ./examples
```

Run with a live `claude-code-agent` backend:

```bash
riela workflow run brain-generated-workflow-loop --workflow-definition-dir ./examples --output json
```

Run the deterministic two-iteration scenario:

```bash
riela workflow run brain-generated-workflow-loop \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/brain-generated-workflow-loop/mock-scenario.json \
  --output json
```

The parent grants only agent nodes using `claude-code-agent` and `claude-opus-5-5`. Runtime policy rejects generated authority-bearing fields and disallowed JSON keys; generated definitions are bounded and are not promoted into the workflow registry.

See [EXPECTED_RESULTS.md](EXPECTED_RESULTS.md) for session inspection commands and assertions.
