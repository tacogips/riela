# Wrike Project Kanban Agent

Polls one Wrike project folder on a 30-second cron, and each tick processes at
most one task waiting in the todo column:

1. `fetch-todo-task` (`riela/wrike-gateway-read`) lists Active tasks in the
   configured folder and selects the first one whose `customStatusId` matches
   the todo column. When nothing matches, the run ends at
   `no-actionable-tasks`.
2. `mark-task-doing` (`riela/wrike-gateway-write`) moves the selected task to
   the doing column and carries the task object forward.
3. `do-ticket-work` (claude-code-agent worker) produces the ticket deliverable
   text from the task title and description.
4. `post-result-comment` (`riela/wrike-gateway-write`) posts the deliverable as
   a comment on the task.
5. `mark-task-done` (`riela/wrike-gateway-write`) moves the task to the done
   column.

Newly added tasks enter the project in the todo column, so the poll picks them
up on a later tick; a tick with no waiting tasks is a cheap single read.

## Credentials

The wrike add-on nodes bind the wrike-gateway credential contract explicitly:

```json
"env": {
  "WRIKE_GATEWAY_ACCESS_TOKEN": { "fromEnv": "RIELA_WRIKE_ACCESS_TOKEN" },
  "WRIKE_GATEWAY_API_BASE_URL": { "fromEnv": "RIELA_WRIKE_API_BASE_URL" }
}
```

Register the riela-side names in kinko once and inject them when running:

```bash
kinko exec --force --env RIELA_WRIKE_ACCESS_TOKEN,RIELA_WRIKE_API_BASE_URL -- \
  riela workflow run --workflow-definition-dir examples/wrike-project-kanban-agent ...
```

Only `WRIKE_GATEWAY_*` target names are accepted by the add-ons; ambient
environment variables are never forwarded to the gateway binaries.

## Workflow input

| Key | Meaning |
| --- | --- |
| `projectFolderId` | Wrike folder id of the polled project (scope `WsFolder`) |
| `todoStatusId` | custom status id of the todo column |
| `doingStatusId` | custom status id of the doing column |
| `doneStatusId` | custom status id of the done column |
| `selfContactId` | Wrike contact id of the agent's own account (mention target) |

Discover the ids once with the reader binary:

```bash
wrike-gateway-reader graphql query '{ folders { id title scope } }'
wrike-gateway-reader graphql query '{ workflows { id name customStatuses { id name group } } }'
wrike-gateway-reader graphql query '{ contacts(me: true) { id } }'
```

## Follow-up mentions on completed tasks

When a tick finds no todo-column task, it checks for follow-up work instead:
tasks in the done column whose `updatedDate` changed in the last 15 minutes
(wrike-gateway 0.2.0+ exposes the `updatedDate` range filter) are inspected,
and if the newest comment mentions `selfContactId` (Wrike stores mentions as
`<a ... rel="<contact-id>">@Name</a>` markup) and is not itself a reply, an
agent node answers it as a new comment on the same task. The task's status is
not changed. Wrike returns task comments newest-first, so the default
`selectFirst` position picks the most recent mention.

Duplicate replies are prevented statelessly: every posted reply ends with a
`[re:<comment-id>]` marker, mention candidates whose text contains `[re:` are
skipped, and a mention that already has a matching marker comment is treated
as answered.

## One-shot run

```bash
kinko exec --force --env RIELA_WRIKE_ACCESS_TOKEN,RIELA_WRIKE_API_BASE_URL -- \
  riela workflow run wrike-project-kanban-agent \
  --workflow-definition-dir examples/wrike-project-kanban-agent \
  --variables '{"workflowInput": {"projectFolderId": "<folder-id>", "todoStatusId": "<todo-id>", "doingStatusId": "<doing-id>", "doneStatusId": "<done-id>"}}' \
  --max-steps 40
```

## Periodic run (every 30 seconds)

`.riela-events/` in this directory defines a six-field cron source
(`*/30 * * * * *`) and a binding that maps each `cron.tick` to this workflow.
Replace the `REPLACE_WITH_*` values in
`.riela-events/bindings/wrike-kanban-30s-to-workflow.json` with the ids above,
then serve the event root:

```bash
kinko exec --force --env RIELA_WRIKE_ACCESS_TOKEN,RIELA_WRIKE_API_BASE_URL -- \
  riela events serve \
  --workflow-definition-dir examples \
  --event-root examples/wrike-project-kanban-agent/.riela-events
```

`maxConcurrentPerKey: 1` keeps ticks from overlapping when a ticket takes
longer than 30 seconds; `dedupeWindowMs` stays below the tick interval so
consecutive ticks are not deduplicated.

Dry-run one tick against the binding (validates matching and input mapping,
records a receipt, and does not execute the workflow — use the one-shot run
above for actual execution):

```bash
riela events emit wrike-kanban-30s-cron \
  --workflow-definition-dir examples \
  --event-root examples/wrike-project-kanban-agent/.riela-events \
  --event-file examples/wrike-project-kanban-agent/payloads/wrike-kanban-cron-tick.json \
  --output json
```
