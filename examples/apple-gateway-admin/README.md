# Apple Gateway Admin

This example uses built-in Apple Gateway admin add-ons to read permission status
and run a read-only GraphQL passthrough query:

```bash
apple-gateway permissions status --json
apple-gateway graphql --query '{ noteAccounts { id name isDefault } }'
```

## Setup

Install or build `apple-gateway` outside this repository:

```bash
git clone https://github.com/tacogips/apple-gateway.git
cd apple-gateway
swift build
```

If `apple-gateway` is not on `PATH`, either set `APPLE_GATEWAY_BIN`:

```bash
export APPLE_GATEWAY_BIN=<apple-gateway-checkout>/.build/debug/apple-gateway
```

or add a literal `binaryPath` to the add-on config in `workflow.json`.

Check local permission state:

```bash
apple-gateway permissions status --json
```

`riela/apple-gateway-permissions-request` and
`riela/apple-gateway-cache-prune` are state-changing.
`riela/apple-gateway-file-download` writes files to the local filesystem.
This example deliberately uses only read-only add-ons.

## Run

Validate the bundle without invoking a live `apple-gateway` binary:

```bash
swift run riela workflow validate apple-gateway-admin --workflow-definition-dir examples
```

Run it after installing and authorizing `apple-gateway`:

```bash
swift run riela workflow run apple-gateway-admin --workflow-definition-dir examples
```

The root output is the latest passthrough GraphQL add-on payload under
`appleGateway.data`, with permission status available in the preceding
`check-permissions` step output.
