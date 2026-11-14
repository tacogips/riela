# loop-outcome-notifications

Demonstrates **terminal loop-outcome notifications** (`loop.notifications`):
after the terminal session state is persisted, the runtime classifies the
outcome and dispatches an export-safe, schema-versioned payload to every
declared channel. Dispatch is best-effort — 5s timeout, one retry per
channel — and never changes the session outcome or exit code.

```json
"notifications": {
  "on": ["accepted", "failed"],
  "channels": [
    { "type": "command", "argv": ["scripts/record-notification.sh"] },
    { "type": "webhook",
      "urlEnv": "RIELA_DEMO_LOOP_WEBHOOK_URL",
      "bearerTokenEnv": "RIELA_DEMO_LOOP_WEBHOOK_TOKEN" }
  ]
}
```

- **command** channels resolve the executable workflow-relative first
  (`scripts/record-notification.sh` inside this bundle) and receive the JSON
  payload on **stdin**. The demo script just records it to
  `$RIELA_DEMO_NOTIFY_OUT`.
- **webhook** channels never embed URLs or tokens in the workflow: both are
  resolved from the named environment variables at dispatch time. When the
  variable is unset the channel is skipped with a persisted session
  diagnostic — safe to keep declared in checked-in workflows.

## Outcome classification

| Outcome | When |
| ------- | ---- |
| `accepted` | session completed and every required gate is `accepted` |
| `rejected` | session completed but a required gate is not `accepted` (e.g. a skipped required gate) |
| `stalled` | session failed with `failureKind: loopNotConverging` (see `loop-stall-guard`) |
| `failed` | session failed for any other reason — including a required gate failing the run closed, as here |

## Reproduce locally

```bash
STORE=/tmp/riela-loop-notify
WF=loop-outcome-notifications

# 1. Accepted outcome -> notification delivered by the command channel.
RIELA_DEMO_NOTIFY_OUT=/tmp/riela-loop-notify-accepted.json \
riela workflow run $WF --workflow-definition-dir ./examples \
  --mock-scenario ./examples/$WF/mock-scenario-accepted.json \
  --session-store $STORE --output json

cat /tmp/riela-loop-notify-accepted.json

# 2. The gate rejects with a high finding -> the required loop fails closed
#    (run exits 1) -> outcome "failed" is still notified.
RIELA_DEMO_NOTIFY_OUT=/tmp/riela-loop-notify-failed.json \
riela workflow run $WF --workflow-definition-dir ./examples \
  --mock-scenario ./examples/$WF/mock-scenario-rejected.json \
  --session-store $STORE --output json

cat /tmp/riela-loop-notify-failed.json
```

The payload contains only ids, counts, decisions, and timestamps — no prompt
text, finding messages, variables, or file paths — so it is safe to forward.

See `EXPECTED_RESULTS.md` for the stable assertions verified with the bundled
mock scenarios.
