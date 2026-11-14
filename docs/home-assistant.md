# Home Assistant

Riela talks to [Home Assistant](https://www.home-assistant.io/) through two
builtin add-ons over the HA REST API, and Home Assistant starts Riela workflows
through the existing `riela serve` GraphQL control plane. There is no separate
gateway process and no HA WebSocket event source.

| Add-on | Purpose |
|---|---|
| `riela/home-assistant-read` (v1) | `state`, `states`, `config` reads |
| `riela/home-assistant-write` (v1) | allowlisted service calls (`POST /api/services/<domain>/<service>`) |

The voice assistant design (issue #185) uses these together with
[`riela/utterance-match`](workflows/utterance-match.md).

## 1. Create a long-lived access token

In Home Assistant open your profile → **Security** → **Long-lived access
tokens** → **Create token**. Copy the value once. Prefer a dedicated HA user for
Riela so the token can be revoked without touching your own login; a non-admin
user is enough for state reads and service calls.

## 2. Inject the URL and token

Both add-ons read credentials only from `addon.env`, which maps an add-on
variable to a process environment variable. Only `HOME_ASSISTANT_URL` and
`HOME_ASSISTANT_TOKEN` are accepted; any other key is `policyBlocked`.

```json
"env": {
  "HOME_ASSISTANT_URL": { "fromEnv": "HOME_ASSISTANT_URL" },
  "HOME_ASSISTANT_TOKEN": { "fromEnv": "HOME_ASSISTANT_TOKEN" }
}
```

Keep the token out of shell profiles and workflow files; inject it with kinko:

```sh
kinko exec --env HOME_ASSISTANT_URL --env HOME_ASSISTANT_TOKEN -- \
  riela events serve
```

`HOME_ASSISTANT_URL` must be an `http(s)` base URL without credentials, query or
fragment (for example `http://homeassistant.local:8123`). Use HTTPS for
anything beyond the local network. The token is sent as
`Authorization: Bearer …` and is redacted from error messages.

## 3. Read state

```json
{
  "id": "presence",
  "addon": {
    "name": "riela/home-assistant-read", "version": "1",
    "config": { "options": { "operation": "state", "entityId": "person.taco" } },
    "env": { "...": "as above" }
  }
}
```

| `operation` | Options | Request | Output (`homeAssistant.*`) |
|---|---|---|---|
| `state` | `entityId` | `GET /api/states/<entityId>` | `entityId`, `state` (HA state object) |
| `states` | `entityIds` and/or `domain`, `limit` (≤ 500) | `GET /api/states` | `states`, `count`, `matched`, `truncated` |
| `config` | — | `GET /api/config` | `config` |

All operations accept `timeoutSeconds` (1–120, default 10). `states` returns at
most 500 entries.

`state` also emits `when` labels so a workflow can branch on the entity state
without another add-on: `always` plus `state_<sanitized>`, where the state is
lowercased, every character outside `[a-z0-9_]` becomes `_`, and the result is
truncated to 64 characters. Examples: `state_on`, `state_off`,
`state_unavailable`, `state_home`, `state_not_home`.

## 4. Call services (default deny)

```json
{
  "name": "riela/home-assistant-write", "version": "1",
  "config": { "options": {
    "operation": "service",
    "domain": "light", "service": "turn_on",
    "target": { "entity_id": "{{light}}" },
    "data": { "brightness_pct": 60 },
    "allowedServices": ["light.turn_on", "light.turn_off", "remote.send_command"],
    "allowedEntities": ["light.*", "remote.living_room"]
  } }
}
```

- `allowedServices` is required and non-empty. Entries are `domain.service` or
  `domain.*`.
- `allowedEntities` is optional. Entries are exact entity ids or `domain.*`.
  When it is set, at least one `entity_id` must be targeted, and `device_id`,
  `area_id`, `floor_id` and `label_id` are refused because they cannot be
  checked against the list.
- Every `entity_id` in `target` and `data` (a string, a comma-separated string,
  or an array) must be a concrete entity id (`all` is refused) and, when an
  entity allowlist is set, must match it.
- Both allowlists must be literal in the workflow file. Template values there are
  refused, so an upstream step or model cannot widen its own permissions.
- `target` and `data` are merged into the request body; a key present in both is
  rejected.

Any violation fails with `policyBlocked` before a request is sent. The output
records the request and HA's changed states:
`homeAssistant.request {domain, service, body}`, `changedStates` (≤ 500),
`changedCount`.

Keep risky domains (locks, alarm panels, garage doors) out of the allowlist. If a
workflow needs them, route the intent to an explicit confirmation branch first.

## 5. Infrared devices

IR appliances are driven through HA, not through Riela directly: a Broadlink (or
similar) remote entity with `remote.send_command`, or ESPHome IR buttons /
climate entities.

```json
"options": {
  "operation": "service", "domain": "remote", "service": "send_command",
  "target": { "entity_id": "remote.living_room" },
  "data": { "device": "aircon", "command": "off" },
  "allowedServices": ["remote.send_command"],
  "allowedEntities": ["remote.living_room"]
}
```

IR has no feedback. When a workflow needs the assumed state, record it with
`riela/kv-set` after the call.

## 6. Error mapping

| HA response | Riela error |
|---|---|
| 401 / 403 | `policyBlocked` (check the token) |
| 400 / 404 | `invalidInput` (HA's `message` is included, e.g. `Entity not found.`) |
| 429 / 5xx, connection failure | `providerError`, retryable |
| 2xx with a non-JSON body | `providerError` |

## 7. Home Assistant → Riela (presence and other triggers)

Run `riela serve` with API keys (see [API keys](api-keys.md)) and let HA call the
`executeWorkflow` mutation with a `rest_command`. HA keeps owning sensor timing
(`for: "00:05:00"` style conditions), so simple automations keep working while
Riela or a model is down.

```yaml
# configuration.yaml
rest_command:
  riela_presence:
    url: http://mac.local:19091/graphql
    method: POST
    timeout: 60
    headers:
      Authorization: !secret riela_api_key   # "Bearer <issued client key>"
    content_type: application/json
    payload: >-
      {"query":"mutation($i:ExecuteWorkflowInput!){executeWorkflow(input:$i){sessionId status}}",
       "variables":{"i":{"workflowName":"announcement-deliver",
       "runtimeVariables":{"room":"{{ room }}","entityId":"{{ entity }}"}}}}
```

```yaml
# automation
- alias: Office presence → deliver announcements
  triggers:
    - trigger: state
      entity_id: binary_sensor.office_occupancy
      to: "on"
  actions:
    - action: rest_command.riela_presence
      data: { room: office, entity: binary_sensor.office_occupancy }
```

Workflow inputs arrive as `runtimeVariables`. Issue a dedicated **Client API**
key for Home Assistant so it can be revoked independently, store it in HA's
`secrets.yaml`, and use HTTPS when HA and Riela are on different hosts.
