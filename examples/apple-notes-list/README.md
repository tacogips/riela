# Apple Notes List

This example lists Apple Notes through the built-in `riela/apple-notes-list`
add-on. The add-on invokes the external `apple-gateway` executable as:

```bash
apple-gateway graphql --query '<query>'
```

## Setup

Install or build `apple-gateway` outside this repository:

```bash
git clone https://github.com/tacogips/apple-gateway.git
cd apple-gateway
swift build
```

Grant Notes automation permission:

```bash
apple-gateway permissions request --domain notes
apple-gateway permissions status --json
```

If `apple-gateway` is not on `PATH`, either set `APPLE_GATEWAY_BIN`:

```bash
export APPLE_GATEWAY_BIN=<apple-gateway-checkout>/.build/debug/apple-gateway
```

or add `binaryPath` to the add-on config in `workflow.json`.

## Run

Validate the bundle:

```bash
swift run riela workflow validate apple-notes-list --workflow-definition-dir examples
```

Run with optional filters:

```bash
swift run riela workflow run apple-notes-list \
  --workflow-definition-dir examples \
  --variables '{"workflowInput":{"query":"project","accountId":"","folderId":""}}'
```

The root output contains `appleNotes.accounts`, `appleNotes.folders`,
`appleNotes.notes`, `appleNotes.pageInfo`, `appleNotes.totalCount`, and the
upstream `requestId`.
