# Apple Mail List

This example lists local Apple Mail account, mailbox, and recent message
metadata through the built-in `riela/apple-mail-list` add-on. It is read-only
and invokes the external `apple-gateway` executable as:

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

Grant Mail Full Disk Access to the terminal or host process that runs Riela,
then verify the gateway can see the permission state:

```bash
apple-gateway permissions status --json
```

If `apple-gateway` is not on `PATH`, either set `APPLE_GATEWAY_BIN`:

```bash
export APPLE_GATEWAY_BIN=<apple-gateway-checkout>/.build/debug/apple-gateway
```

or add `binaryPath` to the add-on config in `workflow.json`.

`riela/apple-mail-message` can materialize selected body and attachment
download keys by running `apple-gateway file download --key <downloadKey>` and
writing bytes into `downloadDir`, `APPLE_GATEWAY_DOWNLOAD_DIR`, or a private
temporary Riela directory.

## Run

Validate the bundle:

```bash
swift run riela workflow validate apple-mail-list --workflow-definition-dir examples
```

Run with optional filters:

```bash
swift run riela workflow run apple-mail-list \
  --workflow-definition-dir examples \
  --variables '{"workflowInput":{"query":"invoice","accountId":"","mailboxId":"","unreadOnly":false}}'
```

The root output contains `appleMail.accounts`, `appleMail.mailboxes`,
`appleMail.messages`, `appleMail.pageInfo`, `appleMail.totalCount`,
`appleMail.permissions.mailFullDiskAccess`, and the upstream `requestId`.
