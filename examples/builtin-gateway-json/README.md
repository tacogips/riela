# Gateway JSON without a helper script

Requires the issue #176 source changes, newer than published 0.2.44.

From the repository root:

```sh
riela workflow validate builtin-gateway-json --workflow-definition-dir examples
riela workflow run builtin-gateway-json --workflow-definition-dir examples \
  --mock-scenario examples/builtin-gateway-json/mock-scenario.json --output json
```

The mock needs no gateway account or credentials. Its original account metadata
remains in the payload, and postprocess produces `[{"id":"fixture-account"}]`.
The config-path environment binding is optional for that mock; real SDK
execution still requires the configured path below.

For real metadata execution, set `GMAIL_GATEWAY_CONFIG` to your configured Gmail
gateway TOML path and omit `--mock-scenario`. The node selects only configured
account IDs; it does not fetch messages or perform a write. Provider/runtime
configuration requirements remain in effect.

See [the gateway request reference](../../docs/builtin-gateway-json.md) for other
providers, typed arguments, isolation and postprocess failure flags.
