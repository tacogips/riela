# Apple Notifications

This example posts one notification through the built-in
`riela/apple-notification-post` add-on and immediately dismisses only the
returned `postedNotificationId` through `riela/apple-notifications-dismiss`.
It does not use dismiss-all. The related read-only add-on is
`riela/apple-notifications-list`, which queries delivered notifications without
posting or dismissing anything.

The add-ons invoke the external `apple-gateway` executable as:

```bash
apple-gateway graphql --query '<query-or-mutation>'
```

## Setup

Install or build `apple-gateway` outside this repository:

```bash
git clone https://github.com/tacogips/apple-gateway.git
cd apple-gateway
swift build
```

Notification posting depends on AppleGatewayNotifier.app. The first post on a
macOS host may trigger the helper notification authorization prompt. Check the
host state with:

```bash
apple-gateway permissions status --json
```

Request the notifications helper permission before running post flows. Reading
notifications from `SYSTEM_DB` also requires granting Full Disk Access to the
apple-gateway host process.

If `apple-gateway` is not on `PATH`, either set `APPLE_GATEWAY_BIN`:

```bash
export APPLE_GATEWAY_BIN=<apple-gateway-checkout>/.build/debug/apple-gateway
```

or add `binaryPath` to each add-on config in `workflow.json`.

The runtime resolves the executable from literal `addon.config.binaryPath`,
then `APPLE_GATEWAY_BIN`, then `PATH`. These built-ins reject authored
`addon.env`; secret-like process environment values are not forwarded to the
gateway subprocess.

## Run

Validate the bundle without posting a notification:

```bash
swift run riela workflow validate apple-notifications --workflow-definition-dir examples
```

Run the demo:

```bash
swift run riela workflow run apple-notifications --workflow-definition-dir examples
```

The root output contains the latest Apple Notifications add-on payload. The
demo cleanup step targets only the notification id returned by its own post
node.
