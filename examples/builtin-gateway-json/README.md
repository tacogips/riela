# Gateway JSON without a helper script

Requires Riela 0.2.45 or later.

From the repository root:

```sh
riela workflow validate builtin-gateway-json --workflow-definition-dir examples
riela workflow run builtin-gateway-json --workflow-definition-dir examples \
  --mock-scenario examples/builtin-gateway-json/mock-scenario.json --output json
```

The mock needs no gateway account or credentials. It returns one account, a
thread page with `mock-gmail-next`, and a draft receipt. The account and thread
outputs are postprocessed to stable IDs; the final draft output is
`"fixture-draft"`. The config-path environment bindings are optional for the
mock; real SDK execution still requires the configured path below.

For a real run, set `GMAIL_GATEWAY_CONFIG` to your configured Gmail gateway TOML
path and supply `workflowInput.accountId` and `workflowInput.cursor` (use null
for the first thread page). The `threads` node requests one page of at most 10
threads. Pass its `pageInfo.endCursor` as the next run's `workflowInput.cursor`.
The final node creates a **draft** with a fixed review message; the draft-only
role cannot send mail. Provider/runtime configuration requirements remain in
effect.

See [the gateway request reference](../../docs/builtin-gateway-json.md) for other
providers, typed arguments, isolation and postprocess failure flags.
