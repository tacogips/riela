# voice-assistant expected results

A home voice assistant assembled from ordinary riela nodes (issue #185). The
microphone side is `riela voice listen` (see `docs/voice.md`); everything after
a WAV lands in the inbox is this workflow.

## Deterministic mock runs

```bash
riela workflow run voice-assistant --workflow-definition-dir examples \
  --mock-scenario examples/voice-assistant/<scenario>.json --output json
```

`transcribe`, Home Assistant, agent and speech steps are mocked; `match`
(`riela/utterance-match`) runs for real in every scenario.

| scenario | transcript | path | asserted |
|---|---|---|---|
| `mock-scenario.json` | ねえリエラ、エアコン消して | transcribe → match → aircon-off → ack | `match` labels `wake`, `intent`, `intent_aircon_off`; `utterance.command` = エアコン消して |
| `mock-scenario-freeform.json` | ねえリエラ、明日の東京の天気は？ | transcribe → match → assistant → speak-reply | `freeform` label; assistant `answer` branch |
| `mock-scenario-schedule.json` | ねえリエラ、毎週月曜9時に… | transcribe → match → assistant → create-routine → confirm-routine | assistant `schedule` branch; routine `origin.delivery` carries `whenAbsent: defer` |
| `mock-scenario-no-wake.json` | 今日はエアコン消して寝ようかな | transcribe → match (session ends) | `no_wake`; nothing is spoken or sent to Home Assistant |

## Live wiring

1. Record: `riela voice listen --inbox examples/voice-assistant/inbox/office`.
2. Serve: `riela events serve --workflow-definition-dir examples --event-root examples/voice-assistant/.riela-events`
   (`office-voice-inbox` is a `file-change` source with `suffixes: [".wav"]`,
   `stabilityWindowMs: 0`; the binding passes `room` and `file`).
3. Environment: `OPENAI_API_KEY` (or switch `transcribe.options.provider` to
   `deepgram` / `elevenlabs` / `google` / `apple` / `command`, see
   `docs/workflows/speech.md`), `HOME_ASSISTANT_URL`, `HOME_ASSISTANT_TOKEN`.
4. Edit the entity ids (`light.office`, `climate.office`, `remote.living_room`)
   and their literal allowlists to match your Home Assistant.

Scheduling requests create a routine targeting `voice-routine-runner`; deferred
announcements are spoken by `announcement-deliver` when Home Assistant reports
the room occupied.
