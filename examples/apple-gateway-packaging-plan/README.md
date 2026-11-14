# Apple Gateway Packaging Plan

This example documents the accepted Riela coverage for Apple Gateway packaging:
use a command node for a read-only dry-run plan, and keep signed release work
outside Riela.

The checked-in workflow runs `scripts/mock-task-jsonl.sh`. It does not require a
real Apple Gateway checkout, the `task` binary, Apple app access, signing
credentials, or a macOS keychain identity. It never publishes, signs,
notarizes, deletes, uploads, or overwrites user data. The mock fails closed with
redacted JSON if `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_PASSWORD`, or
`APPLE_TEAM_ID` is present in its command environment.

Validate the bundle:

```bash
riela workflow validate apple-gateway-packaging-plan --workflow-definition-dir ./examples
```

## Real Dry-run Use

For local use against a real Apple Gateway checkout, keep the workflow input
outside the committed bundle:

```json
{
  "workflowInput": {
    "appleGatewayCheckout": "/path/to/apple-gateway"
  }
}
```

Then replace the mock command node with a workflow-owned wrapper that runs:

```bash
task build:homebrew-cask -- --dry-run
```

Keep the wrapper under this workflow bundle, for example
`scripts/task-jsonl-wrapper.sh`, and pass
`{{workflowInput.appleGatewayCheckout}}` as an argument or environment value. Do
not set `command.workingDirectory` to `{{workflowInput.appleGatewayCheckout}}`,
because Riela does not render that field at command execution time.

The wrapper must validate the checkout path, reject empty or non-directory
values, avoid shell interpolation, scrub Apple credential variables from the
child environment, `cd` to the validated checkout itself, capture the
human-readable `task` output, redact credential-looking values, and emit exactly
one JSON object line on stdout. Use `task build:homebrew -- --dry-run` for the
formula dry-run plan when the selected checkout supports it.

Successful validation of this mock bundle proves only the example workflow
shape and JSONL command-output contract. It does not prove a real checkout
recipe until a wrapper-shaped command is smoke-tested with a real checkout path.

## Credential Boundary

Apple signing credentials live only in the operator's kinko-managed shell
environment and macOS keychain. Never put `APPLE_SIGNING_IDENTITY`, `APPLE_ID`,
`APPLE_PASSWORD`, or `APPLE_TEAM_ID` values in workflow JSON, node inputs,
config, examples, or logs.

Run Riela packaging-plan workflows outside credential-bearing kinko shells.
Local command execution can inherit the Riela process environment even when the
node JSON does not name credential variables. Real wrappers must fail closed or
scrub `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_PASSWORD`, and
`APPLE_TEAM_ID` before invoking `task`.

Signed/notarized Cask builds and local release publishing are human-run shell
commands outside Riela:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  task build:homebrew-cask -- darwin-arm64 darwin-x64

kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  task release:homebrew-cask-local -- v<version>
```

GitHub Actions such as gitleaks and Linux amd64 builds run in CI and are not
invoked by this local Riela example. Use local project commands such as
`task lint` and `task build` when you need local analogs.
