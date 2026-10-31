# Voice assistant on existing riela primitives (issue #185)

A home voice assistant (Alexa-like) is assembled from the primitives riela
already has: event sources, bindings, workflows, builtin add-ons, routines,
`riela/durable-queue`, `riela/kv-*` and the `riela serve` GraphQL control
plane. Voice is **not** a new runtime subsystem. The only new non-add-on code
is a thin microphone recorder that turns speech into audio files; everything
after the file exists is an ordinary workflow run.

Decisions (made for #185, replacing that issue's open questions):

| Question | Decision |
|---|---|
| Wake-word engine | No third-party wake-word engine. The recorder only segments speech (energy VAD + pre-roll). The wake phrase is checked **after transcription** by a deterministic add-on (`riela/utterance-match`), optionally followed by an LLM addressee judge node. "Heavy" wake analysis = transcription of the whole segment + phrase-at-start rule + optional LLM judgment, all inside the workflow. |
| Speech-to-text | Multi-vendor `riela/speech-to-text` (`openai` + OpenAI-compatible servers, `deepgram`, `elevenlabs`, `google`, `apple` on-device, `command` for any local CLI such as whisper.cpp). |
| Text-to-speech | New multi-vendor `riela/text-to-speech` (`apple` via `say`, `openai`-compatible, `elevenlabs`, `voicevox`, `command`), optional local playback. |
| Home Assistant placement | Builtin add-ons in riela (`riela/home-assistant-read`, `riela/home-assistant-write`) over the HA REST API. No separate gateway repository; no HA WebSocket event source. |
| HA → riela events | HA calls the existing `riela serve` `/graphql` `executeWorkflow` mutation with an API key (HA `rest_command`). No new event source kind. |
| Heavy dependencies | None. Apple frameworks (AVFoundation, Speech) on macOS plus HTTP. No WhisperKit / onnxruntime / Porcupine. Local models are reachable through the `command` and OpenAI-compatible providers. |
| Raspberry Pi satellites | Out of scope. |
| Presence-gated routines | No routine-store change. Delivery policy lives in the routine `origin` object and is read with `riela/routine-get`; deferral uses `riela/durable-queue`. |

## End-to-end flow

```
riela voice listen  (mic → voice-processing IO → energy VAD → pre-roll → 16 kHz mono WAV)
        │ atomic rename into <inbox>/<room>/
        ▼
file-change event source (existing, stabilityWindowMs: 0)
        ▼  binding → workflow `voice-assistant`, input {path, room}
riela/speech-to-text (vendor configurable)
        ▼
riela/utterance-match  — normalize, require wake phrase at start, strip it,
        │                match the fast-path intent table
        ├─ no_wake  → end (nothing spoken, nothing sent anywhere else)
        ├─ intent   → riela/home-assistant-write (allowlisted service) → riela/text-to-speech ack
        └─ freeform → agent node (LLM) → {answer | ha_service | routine | schedule}
                        → add-ons → riela/text-to-speech
```

Latency budget: the file-change poll loop sleeps 1 s between scans, so the
first version accepts ≈1–2 s dispatch latency on top of STT. This is measured
and recorded in the example's EXPECTED_RESULTS; a push path is a follow-up only
if the measurement makes the assistant unusable.

## `riela voice listen` (macOS only)

```
riela voice listen --inbox .riela/voice/inbox/office \
  [--device <uid>] [--threshold-db -45] [--min-speech-ms 300] \
  [--silence-ms 700] [--max-utterance-ms 15000] [--pre-roll-ms 400] \
  [--retain-seconds 600] [--voice-processing true]
```

- `AVAudioEngine` input with `setVoiceProcessingEnabled(true)` (echo
  cancellation / noise suppression) when available; falls back to the raw
  input when the device refuses voice processing.
- Pure, platform-independent `VoiceActivitySegmenter` (RMS dBFS frames,
  hysteresis, pre-roll ring buffer, min-speech / silence / max-length rules)
  and `WAVWriter` (16-bit PCM, 16 kHz mono) so they are unit-tested with
  synthetic buffers on any platform.
- Each utterance is written to `<inbox>/.tmp-<id>.wav` and renamed to
  `<inbox>/<UTC timestamp>-<id>.wav`; the dot-prefixed temp name is ignored by
  file-change sources (`filters.suffixes: [".wav"]`, hidden files skipped), so the
  watcher never sees partial files.
- `--retain-seconds` deletes old WAVs in the inbox (audio is not kept as a
  record; transcripts are kept in the session like any node output).
- Microphone permission: the CLI's embedded `Resources/RielaInfo.plist` gains
  `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`.
- Linux: the command exits with a clear "macOS only" usage error.

## `riela/speech-to-text` providers

Config shape stays `{ "options": {...}, "context": ... }`. New option
`provider` (default `openai`, unchanged behavior). Each provider whitelists
its own `addon.env` keys; unknown keys are `policyBlocked`.

| provider | endpoint | env | notes |
|---|---|---|---|
| `openai` | `POST {OPENAI_BASE_URL}/v1/audio/transcriptions` | `OPENAI_API_KEY`, `OPENAI_BASE_URL` | Existing. Also covers OpenAI-compatible servers (Groq, local faster-whisper / whisper.cpp servers). |
| `deepgram` | `POST {DEEPGRAM_BASE_URL or https://api.deepgram.com}/v1/listen?model=&language=&smart_format=true` raw body | `DEEPGRAM_API_KEY`, `DEEPGRAM_BASE_URL` | `Authorization: Token …`; text = `results.channels[0].alternatives[0].transcript`. |
| `elevenlabs` | `POST https://api.elevenlabs.io/v1/speech-to-text` multipart (`model_id`, `language_code`, `file`) | `ELEVENLABS_API_KEY`, `ELEVENLABS_BASE_URL` | `xi-api-key` header; text = `text`. |
| `google` | `POST https://speech.googleapis.com/v1/speech:recognize?key=` JSON with base64 audio | `GOOGLE_SPEECH_API_KEY`, `GOOGLE_SPEECH_BASE_URL` | Sync recognize (≤ 60 s, WAV/LINEAR16 or FLAC); text = joined `results[].alternatives[0].transcript`. |
| `apple` | Speech framework `SFSpeechURLRecognitionRequest`, `requiresOnDeviceRecognition` option | none | macOS only; fails `policyBlocked` elsewhere or inside a container. |
| `command` | runs `options.command` argv (`{{path}}`, `{{language}}` placeholders) through the resolver's process runner | none (env passes through `addon.env` allowlist `COMMAND_*`) | stdout (trimmed) is the transcript; non-zero exit = provider error. |

The upload Content-Type follows the file extension (`wav`, `mp3`, `m4a`,
`flac`, `ogg`, `webm`) instead of the current fixed `audio/mpeg`. Cache
fingerprint includes the provider. Output stays
`{"speechToText": {status, provider, model, language, text, path, cached}}`.

## `riela/text-to-speech`

```json
{ "name": "riela/text-to-speech", "version": "1",
  "config": { "options": {
    "provider": "apple", "text": "{{...}}", "voice": "Kyoko", "language": "ja-JP",
    "outputDir": ".riela/voice/out", "play": true } } }
```

| provider | how | env |
|---|---|---|
| `apple` | `/usr/bin/say [-v voice] [-r rate] -o <file>.aiff --file-format=AIFF` | none |
| `openai` | `POST {base}/v1/audio/speech` `{model, voice, input, response_format: "mp3"}` | `OPENAI_API_KEY`, `OPENAI_BASE_URL` |
| `elevenlabs` | `POST {base}/v1/text-to-speech/{voice}` `{text, model_id}` | `ELEVENLABS_API_KEY`, `ELEVENLABS_BASE_URL` |
| `voicevox` | `POST {base}/audio_query?text=&speaker=` then `POST {base}/synthesis?speaker=` (default base `http://127.0.0.1:50021`) | `VOICEVOX_BASE_URL` |
| `command` | argv with `{{text}}` / `{{output}}` placeholders | — |

`play: true` plays the produced file with `/usr/bin/afplay` (macOS) and waits
for completion; elsewhere `play` is rejected. Empty text is a no-op success
(`status: "skipped"`). Output: `{"textToSpeech": {status, provider, path, played}}`.

## `riela/utterance-match`

Deterministic, no network. Config:

```json
{ "options": {
  "text": "{{...speechToText.text}}",
  "wakePhrases": ["ねえリエラ", "リエラ"],
  "requireWakePhrase": true,
  "intents": [
    { "id": "aircon_off", "patterns": ["エアコン(を)?(消|け)して", "冷房止めて"] },
    { "id": "lights_on",  "patterns": ["電気(を)?つけて"] }
  ] } }
```

- Normalization: NFKC, katakana → hiragana, lowercase, strip whitespace and
  punctuation (`、。！？!?,.・ー` long-vowel kept). Wake phrases and patterns are
  normalized the same way before matching (patterns are regular expressions
  applied to the normalized text).
- Wake phrase must start the normalized utterance (optionally preceded by
  `ねえ`/`hey`-style fillers only if written in the phrase list).
- Output `{"utterance": {wake, wakePhrase, command, intent, normalized}}` and
  `when`: `wake`, `no_wake`, `intent` (an intent matched), `freeform` (wake but
  no intent), plus `intent_<id>` for each matched id so workflows can branch per
  intent without a separate json-route.

## Home Assistant add-ons

Env: `HOME_ASSISTANT_URL`, `HOME_ASSISTANT_TOKEN` (long-lived access token) via
`addon.env` (kinko-injected in practice).

- `riela/home-assistant-read`: `options.operation` = `state` (`entityId`) |
  `states` (`entityIds` and/or `domain` filter, bounded to 500 entries) |
  `config`. `GET /api/states/<id>`, `GET /api/states`, `GET /api/config`.
- `riela/home-assistant-write`: `operation: "service"`, `domain`, `service`,
  `target` / `data`. **Default deny**: config `allowedServices`
  (`"light.turn_on"`, `"remote.send_command"`, `"light.*"`) is required and
  non-empty; optional `allowedEntities` (exact ids or `domain.*`). Every
  `entity_id` in `target`/`data` must be allowed. `POST /api/services/<d>/<s>`.
  Output records the request and HA's changed states.
- IR devices are driven through HA (`remote.send_command` for Broadlink,
  ESPHome IR buttons / climate entities). IR has no feedback, so workflows
  record the assumed state with `riela/kv-set` when needed.

Confirmation for risky services is workflow-level: the voice workflow routes
such intents to an ask-and-confirm branch (speak the question, the next
utterance in the same room carries `yes/no`, stored in KV with a short TTL).
Locks / alarms are simply not in the example allowlist.

## HA-triggered workflows (presence)

`riela serve` with an API key already exposes `executeWorkflow`. HA config:

```yaml
rest_command:
  riela_presence:
    url: http://mac.local:PORT/graphql
    method: POST
    headers: { Authorization: "Bearer !secret riela_api_key" }
    content_type: application/json
    payload: >-
      {"query":"mutation($i:ExecuteWorkflowInput!){executeWorkflow(input:$i){sessionId status}}",
       "variables":{"i":{"workflowName":"announcement-deliver",
       "runtimeVariables":{"room":"{{ room }}","entityId":"{{ entity }}"}}}}
```

HA keeps owning sensor timing (`for: "00:05:00"` absence) so simple automations
keep working while riela or the LLM is down.

## Presence-gated routines and deferred announcements

- `voice-routine-manager` (voice version of `routine-chat-manager`) parses an
  utterance into `name/task/schedule/timezone/completionCriteria` plus
  `delivery {room, presenceEntity, whenAbsent: defer|skip|speak, deferTtlMinutes}`,
  reads the summary back with `riela/text-to-speech`, and on a confirmed reply
  calls `riela/routine-create` with `origin: {delivery}` and
  `workflowName: voice-routine-runner`.
- `voice-routine-runner` (cron target): agent node runs the task →
  `riela/routine-get` reads `origin.delivery` → `riela/home-assistant-read`
  presence state → speak, or `riela/durable-queue admit` (identity
  `<routineId>:<tick>`, request `{room, text, expiresAt}`), or skip.
- `announcement-deliver` (HA presence-on target): `durable-queue pending` →
  speak unexpired items for the room → `finish complete:true status:spoken`;
  expired → `finish status:expired`.

## Examples

- `examples/voice-assistant` — file-change source + binding, STT (`openai`
  default, vendor switchable), utterance-match, HA fast path, LLM fallback, TTS.
  Mock scenario covers wake / no-wake / intent / freeform.
- `examples/voice-routine` — `voice-routine-runner` + `announcement-deliver`
  with mock scenarios for present / absent-defer / expired.

## Testing

- STT/TTS/HA providers: request shape and response parsing through the
  injectable `MediaPipelineHTTP` seam; env allowlists; error mapping.
- utterance-match: normalization and matching tables (kana/width variants,
  wake not at start, multiple intents).
- VAD segmenter / WAV writer: synthetic sine/silence buffers (pre-roll,
  min-speech, max-length split, trailing silence).
- Examples registered in `rielaExampleWorkflowNames()` with mock-scenario runs.
