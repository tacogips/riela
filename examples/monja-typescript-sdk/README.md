# Monja TypeScript SDK From A Riela Command Node

This example proves that Riela can run the ESM-only `@monja/client` package in
Node.js, call a typed Monja REST operation, and execute an arbitrary GraphQL
document through the SDK's `client.graphql.executeStrict` escape hatch.

The command reads one Riela JSONL invocation from stdin. It calls
`client.core.me()` first, then the SDK performs `GET /api/v1/server-capabilities`
before `POST /api/v1/graphql`. A successful run writes one JSON object with
`status`, a safe `rest` principal summary, and the requested `graphql` data.

## Deterministic Verification

From the Riela repository root:

```bash
bash examples/monja-typescript-sdk/scripts/verify.sh
```

The verifier builds and tests the sibling Monja SDK, creates an npm tarball,
inspects its contents, and installs it with lifecycle scripts disabled into a
fresh private consumer below `tmp/monja-typescript-sdk/`. That generated
consumer uses ESM, TypeScript 5.7.2, `@types/node` 20.12.14, and a standalone
strict NodeNext configuration. The compiled command retains the bare
`@monja/client` import and must resolve it from the isolated consumer's
`node_modules`.

The deterministic HTTP server binds only to `127.0.0.1`. Separate network-free
tests verify that URL policy accepts HTTPS and permits plain HTTP only for the
exact normalized hosts `localhost`, `127.0.0.1`, and `[::1]`. The verifier also
checks malformed and oversized inputs, configuration failures, transport and
GraphQL failures, timeout and response/output limits, fixed empty command
arguments/environment, request order, and credential leakage.

Set `RIELA_BIN` when the executable is not in a standard `.build` debug or
release location. Set `MONJA_REPOSITORY_ROOT` only when Monja is not the sibling
directory `../monja`. These variables contain paths, not credentials.

## Live Read-Only Run

Prepare a direct runtime after starting and configuring Monja separately:

```bash
export MONJA_BASE_URL='https://monja.example'
export MONJA_API_KEY='operator-provided-value'
export MONJA_EXAMPLE_RUNTIME_DIR="$PWD/tmp/monja-typescript-sdk/single-run"
examples/monja-typescript-sdk/scripts/prepare.sh
.build/arm64-apple-macosx/debug/riela workflow run monja-typescript-sdk \
  --workflow-definition-dir ./examples \
  --variables '{"workflowInput":{"graphql":{"query":"query RielaSdkProbe { me { kind user { id username displayName } } }","operationName":"RielaSdkProbe"}}}' \
  --output json
```

`MONJA_API_KEY` is inherited from the process environment. Never put it in
workflow variables, command arguments, committed files, or captured output.
`MONJA_REQUEST_TIMEOUT_MS` is optional, defaults to 15000, and must be an
integer from 1 through 60000. `MONJA_BASE_URL` must normally use HTTPS; the
loopback-only HTTP exception exists for local verification.

The GraphQL input is `variables.workflowInput.graphql` with a required `query`,
optional `operationName`, and optional object `variables`. The same boundary
can carry a mutation, but live mutation requires an operator-approved target
and cleanup contract. Server startup, migrations, seed data, API-key issuance,
secret storage, remote TLS policy, and formal minimum Node support remain
operator-owned; see the linked user-QA document in `design-docs/user-qa/`.

Input, query, serialized variables, SDK JSON responses, and final output are
bounded. Failures write no stdout record and emit only a compact stage/kind
classification to stderr.
