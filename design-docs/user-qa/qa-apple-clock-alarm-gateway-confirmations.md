# Apple Clock Alarm Gateway Confirmations

## Question

Before implementation locks the Apple Clock Alarm add-on transport and error
classifier, confirm the remaining upstream `apple-gateway` Clock behavior.

## Context

The `riela/apple-clock-alarm-*` design invokes fixed Clock GraphQL operations
through:

```bash
apple-gateway graphql --query <fixed-document>
apple-gateway graphql --query <fixed-document> --variables <json>
```

The implementation plan assumes mutation inputs can be passed with
`--variables`, that Clock alarm `time` accepts a strict `HH:mm` 24-hour string,
and that missing Shortcuts bridge and unsupported macOS errors expose stable
GraphQL envelopes. Those upstream details must be confirmed before fake gateway
fixtures and policy-blocked classifiers are treated as final.

## Confirmations Needed

1. Confirm `apple-gateway graphql --help` supports `--variables <json>` for
   Clock mutations and that values passed through the variables document are
   accepted by `createClockAlarm`, `toggleClockAlarm`, `updateClockAlarm`, and
   `deleteClockAlarm`.
2. Capture the exact missing Shortcuts bridge GraphQL envelope for Clock alarm
   operations, including `errors[].message` and any
   `errors[].extensions.code`. Capture at least the read path
   `apple-gateway-get-alarms` and one mutation shortcut failure.
3. Capture the exact unsupported macOS GraphQL envelope for
   `updateClockAlarm` and `deleteClockAlarm`, including `errors[].message` and
   any `errors[].extensions.code`.
4. Confirm the accepted Clock alarm time format, including whether the upstream
   gateway accepts only `HH:mm` 24-hour strings or also accepts looser variants.

## Default Until Answered

Treat the exact upstream envelopes as open QA confirmations. Use fake gateway
fixtures to keep tests deterministic, but do not claim the classifier's exact
codes or message tokens are final until the upstream envelopes above are
captured. Mutation transport requires `--variables`; if a local
`apple-gateway` build rejects that flag or exits nonzero after receiving a
mutation request, the implementation fails closed and does not issue a second
mutation attempt.

## Implementation Session Note

During Step 6 implementation on 2026-07-07, `which apple-gateway` returned no
local executable. The implementation therefore kept `--variables` as the
required mutation transport and used fake executable fixtures with classifier
tokens `SHORTCUT_BRIDGE_MISSING`, `UNSUPPORTED_OS_VERSION`, nonzero GraphQL
envelopes on stdout/stderr, and message-token fallbacks. Exact upstream
envelopes still need a follow-up confirmation on a machine with `apple-gateway`
installed.

## Impact

These confirmations affect `--variables` argument construction, Clock fake
gateway fixtures, `.policyBlocked` mapping for missing Shortcuts bridge and
macOS 26+ gating, Clock time validation, and README/operator guidance for
`examples/apple-clock-alarms-list`.
