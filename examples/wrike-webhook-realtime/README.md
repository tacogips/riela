# Wrike Webhook Realtime Trigger

Replaces the 30-second cron poll of `wrike-project-kanban-agent` with a
realtime chain: Wrike webhooks are delivered to a
[web-hooky](https://github.com/tacogips/web-hooky) server, and riela subscribes
to that server's `/_ws/{fetchUuid}` WebSocket stream through the `webhooky`
event source kind. A `TaskCreated`, `TaskStatusChanged`, or `CommentAdded`
event triggers one kanban pass within seconds instead of waiting for the next
poll tick.

```
Wrike ──HTTP POST (X-Hook-Signature)──▶ web-hooky (Cloudflare Workers / bun)
                                          │  wrike vendor addon: HMAC verify +
                                          │  secure-webhook handshake
                                          ▼
riela events serve ◀──WebSocket stream── /_ws/{fetchUuid}
  └─ binding → wrike-project-kanban-agent (todo claim / mention reply)
```

## One-time setup

1. **web-hooky destination** (admin API; keep every value out of shell history):

```bash
# destination with the wrike vendor addon and a generated signing secret
POST /_admin/api/destinations {"name": "wrike-kanban", "vendorAddon": "wrike",
                               "vendorConfig": {"secret": "<generated>"}}
# fetch API user + grant
POST /_admin/api/users {"label": "riela-consumer"}
PUT  /_admin/api/users/{userId}/grants/{destinationId}
```

Store in kinko: the signing secret (`RIELA_WRIKE_WEBHOOK_SECRET`), the fetch
credential `keyId:secret` (`RIELA_WEBHOOKY_WRIKE_CREDENTIAL`), the destination
`fetchUuid` (`RIELA_WEBHOOKY_WRIKE_FETCH_UUID`), and the server base URL
(`RIELA_WEBHOOKY_URL`).

2. **Wrike webhook** (wrike-gateway 0.2.2+ accepts the write-only `secret`;
   use file-based input so the secret never reaches a command line):

```bash
wrike-gateway-writer graphql query-file create-webhook.graphql \
  --variables-file create-webhook-vars.json
# document: mutation W($scope: ScopeInput, $input: CreateWebhookInput!)
#   { createWebhook(scope: $scope, input: $input) { webhook { id status } } }
# variables: {"scope": {"folderId": "<project-folder-id>"},
#             "input": {"hookUrl": "<base-url>/wrike/<inboundUuid>",
#                       "events": ["TaskCreated", "TaskStatusChanged", "CommentAdded"],
#                       "secret": "<the same signing secret>"}}
```

A `status: Active` response proves the secure-webhook `X-Hook-Secret`
handshake succeeded against the web-hooky wrike addon.

3. Replace the `REPLACE_WITH_*` values in
   `.riela-events/bindings/wrike-webhook-to-kanban.json` with the same ids the
   kanban example documents (folder, three status columns, self contact id).

## Source contract

`.riela-events/sources/wrike-webhooky-stream.json`:

| Field | Meaning |
| --- | --- |
| `kind` | `webhooky` — live WebSocket subscription to a web-hooky server |
| `baseUrlEnv` | env var naming the server base URL |
| `credentialEnv` | env var holding the fetch credential as `keyId:secret` |
| `fetchUuidEnv` | env var naming the destination fetch UUID |
| `eventType` | envelope event type bindings match on (default `webhook.record`) |
| `includeFetched` | also dispatch records already marked fetched (default false) |

Each streamed record becomes one envelope with
`input.payload` (the vendor addon output: `{"source": "wrike", "events":
[...]}`), `input.receivedAt`, and `input.fetched`. Reconnects use capped
exponential backoff; records replayed after a reconnect are skipped through
their server-side fetched flag, and a payload digest dedupe key guards the
remainder.

## Serve

```bash
kinko exec --force --env RIELA_WEBHOOKY_URL,RIELA_WEBHOOKY_WRIKE_CREDENTIAL,RIELA_WEBHOOKY_WRIKE_FETCH_UUID,RIELA_WRIKE_ACCESS_TOKEN,RIELA_WRIKE_API_BASE_URL -- \
  riela events serve \
  --workflow-definition-dir examples \
  --event-root examples/wrike-webhook-realtime/.riela-events
```

Creating a Wrike task in the watched folder now triggers the kanban workflow
within seconds. The cron example remains useful as a low-frequency
reconciliation sweep because Wrike webhook delivery is at-least-once and can
be suspended when the endpoint is unreachable.

Dry-run the binding without a server:

```bash
riela events emit wrike-webhooky-stream \
  --workflow-definition-dir examples \
  --event-root examples/wrike-webhook-realtime/.riela-events \
  --event-file examples/wrike-webhook-realtime/payloads/wrike-taskcreated-record.json \
  --output json
```
