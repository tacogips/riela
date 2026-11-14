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

The `apple-gateway` code is linked into `riela`; there is no executable to
install, no `APPLE_GATEWAY_BIN`, and no `binaryPath` add-on config. macOS
attaches Apple permission grants to the executable that asks, so grants given
to a standalone `apple-gateway` do not carry over — approve `riela` once from
an interactive run before using this from a daemon.

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
