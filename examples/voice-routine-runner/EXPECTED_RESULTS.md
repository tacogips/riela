# voice-routine-runner expected results

Cron target for routines created by `voice-assistant`. The delivery policy is
stored in the routine's `origin.delivery`
(`room`, `presenceEntity`, `whenAbsent: defer|skip|speak`, `deferTtlMinutes`)
and read with `riela/routine-get`; no routine-store change is involved.

## Mock runs

```bash
riela workflow run voice-routine-runner --workflow-definition-dir examples \
  --mock-scenario examples/voice-routine-runner/mock-scenario.json --output json
```

- `mock-scenario.json` (present): get-routine → run-task (`defer_when_absent`)
  → presence-defer (`state_on`) → speak. No files are written.
- `mock-scenario-absent.json` (absent): get-routine → run-task → presence-defer
  (`state_off`) → defer. `defer` is the **real** `riela/durable-queue` and
  admits identity `<routineId>:<scheduledAt>` into
  `.riela/voice/announcements/office.json`, so run it from a scratch directory:

```bash
mkdir -p tmp/voice-demo && cd tmp/voice-demo
riela workflow run voice-routine-runner --workflow-definition-dir ../../examples \
  --mock-scenario ../../examples/voice-routine-runner/mock-scenario-absent.json \
  --variables '{"workflowInput":{"routineId":"routine-fixture-1","scheduledAt":"2026-11-02T00:00:00Z"}}'
```

The queue row's `request` is the run-task payload
(`announcement`, `room`, `presenceEntity`, `notAfter`). Running
`announcement-deliver` afterwards (unmocked speech, `{"room":"office"}`) speaks it
and finishes the row with `last_result: spoken`.

`skip_when_absent` goes to presence-skip, which only speaks on `state_on`;
`always_speak` speaks directly.
