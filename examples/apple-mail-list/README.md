# Apple Mail List

This example lists local Apple Mail account, mailbox, and recent message
metadata through the built-in `riela/apple-mail-list` add-on. It is read-only
and invokes the external `apple-gateway` executable as:

```bash
apple-gateway graphql --query '<query>'
```

## Setup

Install `apple-gateway` 0.1.6 or newer outside this repository. Version 0.1.6
added runtime Mail Envelope Index schema detection required by current Mail
databases. For a Homebrew installation, verify and update it with:

```bash
apple-gateway --version
brew upgrade apple-gateway
```

Alternatively, build the current source checkout:

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

The `apple-gateway` code is linked into `riela`; there is no executable to
install, no `APPLE_GATEWAY_BIN`, and no `binaryPath` add-on config. macOS
attaches Apple permission grants to the executable that asks, so grants given
to a standalone `apple-gateway` do not carry over — approve `riela` once from
an interactive run before using this from a daemon.

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
