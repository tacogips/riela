# Apple Reminders List

This example lists Apple Reminders lists and open reminders through the built-in
`riela/apple-reminder-lists` and `riela/apple-reminders-list` add-ons. The
add-ons invoke the external `apple-gateway` executable as:

```bash
apple-gateway graphql --query '<query>' --variables '<json>'
```

## Setup

Install or build `apple-gateway` outside this repository:

```bash
git clone https://github.com/tacogips/apple-gateway.git
cd apple-gateway
swift build
```

Grant Reminders automation permission:

```bash
apple-gateway permissions request --domain reminders
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
swift run riela workflow validate apple-reminders-list --workflow-definition-dir examples
```

Run with optional filters:

```bash
swift run riela workflow run apple-reminders-list \
  --workflow-definition-dir examples \
  --variables '{"workflowInput":{"listIds":[],"query":"project"}}'
```

The root output contains `appleReminders.reminders`,
`appleReminders.pageInfo`, `appleReminders.totalCount`, and the upstream
`requestId`. The example is read-only and does not call mutation add-ons.
