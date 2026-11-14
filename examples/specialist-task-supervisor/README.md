# Specialist task supervisor

Development status: this is a deterministic stub-verified, uncommitted vertical slice, not
evidence of a live Matrix, Wrike, or model-provider deployment. The service
persists request routing, ownership, child reservation, recovery receipts and
outbox delivery independently; `/status [taskId]` and `/cancel <taskId>` are
direct controls and never enter classification. Operational rollout still
requires operator validation of live credentials, transport readiness, and
receipt reconciliation.

This example configures the production supervisor boundary. The classifier is
an authenticated HTTPS, tool-free decision service; credentials are supplied
outside this file. The smoke uses an explicitly gated fixture classifier only
with `--mock-scenario`, and cannot enable that fixture on a normal submission.

This example uses the existing workflow registry rather than creating a new
node type. Register or install a normal Riela workflow first, then persist a
nonblocking specialist receipt:

```bash
riela specialist catalog --state-root .riela/specialist --output json
riela specialist submit sample-request --workflow REPLACE_WITH_REGISTERED_WORKFLOW_ID \
  --specialist-config specialists.json --state-root .riela/specialist \
  --variables '{"workflowInput":{"request":"example"}}' --output json
riela specialist status task-sample-request --state-root .riela/specialist --output json
riela specialist execute dispatch-sample-request --state-root .riela/specialist --output json
```

`specialists.json` is trusted operator configuration. It names authorized
specialists, capacities, domains, an explicit `allowedOriginIds` ceiling, and
an authenticated classifier identity. Origin IDs are path- and revision-bound,
so first run `riela specialist catalog --output json` and replace
`REPLACE_WITH_EXACT_CATALOG_ORIGIN_ID` in both bundled configurations with the
selected card's exact `originId`. Add `allowedWorkflowIds` when a specialist
needs a tighter ceiling. The placeholder config intentionally fails closed
until this operator authorization step is completed.
`classifier.secretEnvironment` names an approved process secret-provider entry
(for example `RIELA_SPECIALIST_CLASSIFIER_TOKEN`); the credential itself is
never accepted in configuration or command arguments. `--owner` is not
accepted as an authorization boundary. `submit` validates the selected
active registry entry, seals the routing result, atomically records its owner,
reserves one child identity, and returns without executing it.
`execute` consumes that reservation and uses the ordinary workflow runner.

For automatic workflow and input selection, use `specialists-sdk.json` instead
of the custom HTTPS classifier. Replace its model placeholder with your
configured SDK model and supply credentials through the existing Riela SDK
backend configuration. Run from the repository root:

```bash
riela specialist catalog-refresh --state-root .riela/specialist --output json
riela specialist submit sdk-request --state-root .riela/specialist \
  --specialist-config examples/specialist-task-supervisor/specialists-sdk.json \
  --body 'Explain the selected project and update its documentation' --output json
riela specialist execute dispatch-sdk-request --state-root .riela/specialist --output json
```

Each specialist classifies independently from its domain and compact cards.
The selected specialist chooses an exact workflow/origin/revision tuple; only
then is the callable input contract loaded. Input generation validates against
that contract and permits at most two attempts per call. A clarification
response does not launch a child. A subsequent authenticated request with
`--route clarification` durably reopens the pending clarification for routing;
it remains explicitly uncertain until a normal routing pass settles it.
The local command supports automatic selection without `--workflow` or
`--variables`; explicit variables remain schema-checked before reservation.

The custom HTTPS configuration in `specialists.json` requires an operator-hosted
classifier implementing the documented decision envelope and an explicit
`--workflow`. Its example.invalid endpoint is a placeholder, not a bundled service.

Re-run `status` while a child runs; it reads durable factual child step,
observation time, tracker observation, and uncertainty (never an invented
percent or ETA), and does not create a task, owner claim, tracker record, or
child. `reconcile` reports prepared/running
or terminal-not-yet-delivered dispatch records after restart.

Before reservation, the selected closure is copied under
`<state-root>/workflow-snapshots/<dispatch-id>` and sealed against the compact
catalog revision. Execution verifies that capture before the ordinary runner
uses it, so it does not switch from a checked mutable registry directory to an
unverified one.

Refresh registry-integrated compact cards after package/registry changes with
`riela specialist catalog-refresh --state-root .riela/specialist --output json`.
The normal catalog response contains only bounded card metadata and preserves
origin, activation, and mutable-origin state; selection rechecks the pinned
revision before launch.

`serve` also polls an authenticated Matrix `/sync` boundary when its trusted
transport configuration contains an HTTPS `homeserver`, `accountId`,
`localUserId`, `roomId`, and `accessTokenEnvironment`. The latter names an
approved secret-provider entry; a production transport file never contains a
Matrix token. It persists
the cursor only after inbound receipts are committed, ignores the configured
bot user, and derives the actor, room, thread, and source event from Matrix.
`serve` is a continuously supervised fenced worker. Use `--once` only for
diagnostics: normal operation renews its lease and repeatedly drives intake,
execution/recovery, and delivery lanes. Status commands remain direct durable
reads while execution and delivery run in separately leased service lanes.
Matrix transaction IDs and Wrike correlation records have different
provider guarantees. Wrike projection uses the linked writer-tier
`wrike-gateway`, not an arbitrary HTTP endpoint: configuration supplies only
the folder/status mapping and gateway credentials remain in its approved
environment/keychain contract. A verified ownership receipt is durably bound
to the local task before later tracker updates. Receipt-less responses remain
uncertain; retryable events use durable backoff and hold later events for that
destination. Keep the SQLite state directory private and on a single-host
filesystem.
