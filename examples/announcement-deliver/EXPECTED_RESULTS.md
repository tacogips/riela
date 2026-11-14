# announcement-deliver expected results

Triggered by Home Assistant when a room becomes occupied:
`rest_command` → `riela serve` `/graphql` `executeWorkflow` with
`runtimeVariables: {"room": "office"}` (see `docs/home-assistant.md`).

The workflow drains `.riela/voice/announcements/<room>.json`
(`riela/durable-queue`) one item at a time: `next` (`pending`, label `found`)
→ `speak` (`riela/text-to-speech` with `notAfter`) → `finish-spoken` or
`finish-expired` → back to `next` until `found` is false.

## Mock run

```bash
riela workflow run announcement-deliver --workflow-definition-dir examples \
  --mock-scenario examples/announcement-deliver/mock-scenario.json --output json
```

Every step is mocked (a two-response sequence for `next`), so the path is
next → speak → finish-spoken → next and the session completes. No files are
touched.

## Expired items (unmocked)

With a queue row whose `request.notAfter` is in the past, the real
`riela/text-to-speech` returns `status: expired` without synthesizing or
playing audio, the `expired` label routes to `finish-expired`, and the row ends
`completed` with `last_result: expired`.
