# memory-consolidation

Periodic consolidation of riela short-term memory into kaiba long-term memory,
followed by a recall pass that turns the durable memories back into prompt text.

## Who owns which memory

The two stores are deliberately non-overlapping:

- **riela owns short-term memory.** Raw events land in the SQLite memory store
  under the memory root (`.riela/memory/` by default, overridable with
  `--memory-root`, config `memoryRoot`, a workflow input, or
  `RIELA_MEMORY_ROOT`). Records are cheap, high-volume, and expendable; they are
  addressed by integer `recordId` and scoped by workflow and node.
- **kaiba owns long-term memory.** Consolidated summaries become notes in the
  canonical `Kaiba Long-Term Memory` notebook, carry `topic` tags, sit in the
  note graph, and are recalled by full-text search plus bounded graph
  association.

Because riela record ids are not kaiba note ids, `kaiba/memory-consolidate`
never turns `sourceMemoryRecordIds` into note links. They are stored in the
note's `metaJSON` as `{"sourceMemoryRecordIds":[...]}`, so a consolidated memory
keeps its provenance even after the short-term records it was distilled from are
pruned. Only `relatedNoteIds` — which must already resolve to kaiba notes —
become real links.

## Flow

| Step | Add-on | What it does |
| --- | --- | --- |
| `save-chat-event` | `riela/memory-save` | Appends the incoming chat event to the `chat-memory` short-term store. |
| `load-recent-memories` | `riela/memory-load` | Reads the most recent 50 short-term records as `recordsText`. |
| `summarize-memories` | agent worker | Distills the window into `memoryEntries[]` (the only mocked step). |
| `consolidate-long-term` | `kaiba/memory-consolidate` | Appends the entries as long-term notes and links their graph associations. |
| `recall-long-term` | `kaiba/memory-recall` | Recalls `project-atlas` memories and renders prompt-ready `recallText`. |
| `workflow-output` | output projection | Projects the consolidation counts and the recall results. |

`consolidate-long-term` and `recall-long-term` are consecutive steps, and an
output projection only sees the last payload, so the recall node carries the
consolidation counts forward through its `passthrough` config.

## Run it

```bash
riela workflow validate memory-consolidation --workflow-definition-dir examples

riela workflow run memory-consolidation \
  --workflow-definition-dir examples \
  --mock-scenario examples/memory-consolidation/mock-scenario.json \
  --variables '{
    "memoryRoot": "./tmp/memory-consolidation/memory",
    "noteRoot": "./tmp/memory-consolidation/notes",
    "workflowInput": {
      "text": "Kickoff review settled the project-atlas scope.",
      "actor": "taco",
      "conversationId": "example-conversation",
      "consolidationKey": "memory-consolidation-example-2026-08-01"
    }
  }'
```

`memoryRoot` and `noteRoot` are workflow inputs so a run can be pointed at
scratch stores instead of `.riela/memory` and `~/.kaiba`.

## Idempotency

`kaiba/memory-consolidate` derives its append key from the runtime step identity
(workflow execution id, workflow, step, node, and source step execution id), so
a session resume or an event redelivery replays the already-written memories
instead of duplicating them.

Periodic consolidation wants a stronger guarantee: two cron ticks covering the
same window should produce the same memory. Set `idempotencyKey` to a value
derived from the window — this example passes
`workflowInput.consolidationKey` — and a re-run over the same period returns
`idempotentReplay: true` with the original note ids.

## Trigger it periodically

riela owns the clock. Add a `cron` source and a binding under the event root,
following `examples/event-sources/`:

`.riela-events/sources/memory-consolidation-nightly-cron.json`

```json
{
  "id": "memory-consolidation-nightly-cron",
  "kind": "cron",
  "schedule": "0 0 3 * * *",
  "timezone": "Asia/Tokyo"
}
```

`.riela-events/bindings/memory-consolidation-nightly-to-workflow.json`

```json
{
  "id": "memory-consolidation-nightly-to-workflow",
  "sourceId": "memory-consolidation-nightly-cron",
  "workflowName": "memory-consolidation",
  "match": {
    "eventType": "cron.tick"
  },
  "inputMapping": {
    "mode": "template",
    "template": {
      "text": "Nightly consolidation tick.",
      "actor": "cron",
      "conversationId": "{{event.sourceId}}",
      "consolidationKey": "memory-consolidation-{{event.input.scheduledLocalTime}}"
    },
    "mirrorToHumanInput": false
  },
  "execution": {
    "async": false,
    "dedupeWindowMs": 300000,
    "maxConcurrentPerKey": 1,
    "concurrencyKey": "{{event.sourceId}}"
  },
  "taskPlanning": {
    "enabled": false
  }
}
```

`riela events serve` owns the clock and dispatches the workflow on every tick:

```bash
riela events serve --workflow-definition-dir ./examples --event-root ./examples/event-sources/.riela-events
```

`riela events emit` is a dry-run matcher rather than a dispatcher — it reports
which bindings a tick would trigger without running the workflow. The event file
must carry the `eventType` the binding matches on, or the tick is reported as
`ignored`:

```json
{
  "eventType": "cron.tick",
  "input": {
    "scheduledAt": "2026-08-09T18:00:00.000Z",
    "scheduledLocalTime": "2026-08-10 03:00:00",
    "firedAt": "2026-08-09T18:00:00.500Z",
    "timezone": "Asia/Tokyo"
  }
}
```

```bash
riela events emit memory-consolidation-nightly-cron \
  --workflow-definition-dir ./examples \
  --event-root ./examples/event-sources/.riela-events \
  --event-file ./examples/event-sources/payloads/memory-consolidation-nightly-cron.json \
  --artifact-root ./tmp/memory-consolidation/workflow-artifacts \
  --output json
```

A matching tick reports `status=dry-run`; the receipt store dedupes repeats, so
clear `.riela-events/receipts` to re-check the same tick.
