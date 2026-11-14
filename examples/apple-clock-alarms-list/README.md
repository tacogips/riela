# Apple Clock Alarms List

This example lists Apple Clock alarms through the built-in
`riela/apple-clock-alarms-list` add-on. The example is read-only and invokes the
external `apple-gateway` executable as:

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

Install the Clock alarm Shortcuts from the `apple-gateway` checkout's
`packaging/shortcuts` directory:

- `apple-gateway-get-alarms`
- `apple-gateway-create-alarm`
- `apple-gateway-toggle-alarm`
- `apple-gateway-update-alarm`
- `apple-gateway-delete-alarm`

Grant and verify the Shortcuts Clock bridge permission:

```bash
apple-gateway permissions status --json
```

The permission status should include `shortcutsClockBridge`.

The `apple-gateway` code is linked into `riela`; there is no executable to
install, no `APPLE_GATEWAY_BIN`, and no `binaryPath` add-on config. macOS
attaches Apple permission grants to the executable that asks, so grants given
to a standalone `apple-gateway` do not carry over — approve `riela` once from
an interactive run before using this from a daemon.

The mutation add-ons `riela/apple-clock-alarm-update` and
`riela/apple-clock-alarm-delete` require macOS 26 or newer. This example uses
only `riela/apple-clock-alarms-list` and does not mutate Clock data.

## Run

Validate the bundle:

```bash
riela workflow validate apple-clock-alarms-list --workflow-definition-dir examples
```

Run:

```bash
riela workflow run apple-clock-alarms-list --workflow-definition-dir examples
```

The root output contains `clockAlarms`, `alarmCount`, `replyText`, and
`appleGateway.requestId`.
