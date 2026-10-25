# X JSON search without a helper script

Requires the Riela runtime with X JSON operations and structured reader failure
outputs. Validate from the repository root with
`riela workflow validate x-gateway-json-search --workflow-definition-dir examples`.

The credential-free mock fetches one search page and returns two shaped posts
plus the provider cursor. A real first page supplies
`workflowInput: {"query":"...","cursor":null}`. Pass the returned
`nextCursor` as `cursor` on the next run; each run makes one page request.

Set the five `X_GW_*` environment variables for a real provider call. The
reader's `providerFailure: "output"` setting routes retryable provider failures
to a terminal `retry-later` result and other provider or postprocess failures
to `report-failure`. Riela does not retry or loop. X has no writer tier in
Riela, so this example is read-only.

See [expected results](EXPECTED_RESULTS.md) and the
[gateway JSON reference](../../docs/builtin-gateway-json.md).
