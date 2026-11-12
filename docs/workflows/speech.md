# Speech-to-text and text-to-speech add-ons

`riela/speech-to-text` turns one audio file into text and
`riela/text-to-speech` turns text into an audio file (and can play it). Both
use the media-pipeline config shape `{ "options": {...}, "context": ... }` and
choose a vendor with `options.provider`. Each provider accepts only its own
`addon.env` keys; any other key fails with `policyBlocked`.

`options.command` is not rendered as a workflow template: its `{{path}}`,
`{{language}}`, `{{text}}`, `{{output}}` and `{{voice}}` placeholders are filled
by the add-on itself. Command providers receive only `COMMAND_*` keys from
`addon.env`, on top of `PATH`, `HOME` and `XDG_CACHE_HOME`.

## `riela/speech-to-text`

| provider | how | `addon.env` | model |
|---|---|---|---|
| `openai` (default) | agent-gateway transcription; OpenAI-compatible servers supported, with or without `/v1` in the base URL | `OPENAI_API_KEY` (required), `OPENAI_BASE_URL` | `gpt-4o-transcribe` by default |
| `gemini` | agent-gateway transcription | `GEMINI_API_KEY` (required), `GEMINI_BASE_URL` | required |
| `openrouter` | agent-gateway transcription | `OPENROUTER_API_KEY` (required), `OPENROUTER_BASE_URL` | required |
| `deepgram` | Riela HTTP `POST /v1/listen`, raw audio | `DEEPGRAM_API_KEY` (required), `DEEPGRAM_BASE_URL` | `nova-3` by default |
| `elevenlabs` | Riela HTTP `POST /v1/speech-to-text`, multipart audio | `ELEVENLABS_API_KEY` (required), `ELEVENLABS_BASE_URL` | `scribe_v1` by default |
| `google` | Riela HTTP `POST /v1/speech:recognize`; WAV or FLAC, about 60 s maximum | `GOOGLE_SPEECH_API_KEY` (required), `GOOGLE_SPEECH_BASE_URL` | none |
| `apple` | macOS Speech framework; `onDevice: true` requires on-device recognition | none | none |
| `command` | runs `command` argv; trimmed stdout is the transcript | `COMMAND_*` | none |
| `whisper-cpp` | host `whisper-cli`; trimmed plain-text stdout without timestamps | none | `whisperCpp.model` file required |

Options include `path` (required), `provider`, `model`, `language` (blank
lets the provider detect it; `google` defaults to `en-US`), `prompt` (`openai`),
`onDevice` (`apple`), `command` (`command`), `maxAttempts` (default 3, 1–8),
`timeoutSeconds`, and `cache`. Remote uploads are limited to 25 MB; content
type follows the file extension (`wav`, `mp3`, `m4a`, `flac`, `ogg`, `webm`).
Credentials are supplied via `addon.env`; gateway requests reference the key by
environment-variable name. The `apple` provider needs Speech Recognition
permission and is unavailable on Linux and inside containers.

For `whisper-cpp`, configure `whisperCpp.model` as an absolute or working-directory
relative model path. Optional `binary` defaults to `whisper-cli` on PATH, then
`/opt/homebrew/bin/whisper-cli`; `threads` is 1–64 and `extraArgs` is an array
of at most 64 strings, each at most 4096 bytes and without NUL. The command is
`whisper-cli -m <model> -f <path> -l <language-or-auto> -nt -np [-t N] [extraArgs]`.
It receives no `addon.env` keys and accepts the input formats supported by the
installed whisper-cli; Riela does not convert audio. Missing binary or model and
nonzero exit are `unavailable`; a timeout is `transport-error`.

### Retry and failures

`rate-limited` (429), `server-error` (5xx), and `transport-error` retry up to
`maxAttempts`, subject to the node deadline. Riela uses `Retry-After` when
provided, including for openai, gemini and openrouter through agent-gateway;
otherwise it waits 1, 2, 4… seconds. Delays are clamped to 0–60 seconds. Each
gateway attempt is one vendor request. Local command and whisper-cpp processes
run once per invocation.

`quota-exhausted` is not retried: it includes `insufficient_quota`,
`credit_balance_exhausted`, `billing_hard_limit_reached`, `billing_not_active`,
HTTP 402, and Gemini per-day quota exhaustion. `unavailable` is not retried
and includes missing credentials, missing local binary/model, unavailable apple,
and local process failure. `rejected` is not retried and never falls back: it
includes authentication failures (401/403), other 4xx, unsupported gateway
audio such as aiff, and unparseable responses. Without a fallback chain, a
missing required credential retains the `policyBlocked` error; in a chain it is
`unavailable`.

Failure messages include `failureClass=…` and, when available,
`httpStatus=… providerProblem=…`; they do not include secrets or request bodies.
`providerProblem` is a safe vendor error code or type when available.

### Fallback and cache

`fallback` is an ordered array of 1–3 provider objects. Each requires `provider`
and may specify its provider's `model`, `onDevice`, `command`, or `whisperCpp`,
as applicable, plus `maxAttempts` and `timeoutSeconds`. Path, language and
prompt are shared from the top level; fallback entries are not template-rendered.
The retry and timeout settings inherit the top-level values when omitted.
`fallbackOn` is a non-empty subset of `quota-exhausted`, `rate-limited`,
`server-error`, `transport-error`, and `unavailable`; it defaults to all five
and requires `fallback`. Quota exhaustion moves immediately to the next entry.
Each provider receives its own allowed environment keys; the node allowlist is
the union of the chain's keys.

The output reports the producing provider and model. When an earlier provider
failed, `fallbackFrom` records its failure; without fallback the output shape is
unchanged:

```json
{ "speechToText": { "status": "completed", "provider": "whisper-cpp", "model": "",
  "language": "ja", "text": "transcript", "path": "/audio/clip.wav", "cached": false,
  "fallbackFrom": [{ "provider": "openai", "model": "gpt-4o-transcribe",
    "failureClass": "quota-exhausted", "httpStatus": 429,
    "providerProblem": "insufficient_quota" }] } }
```

The single `<audio>.stt.json` cache entry fingerprints the producing provider,
model, language, prompt and audio content hash, plus base URL for remote
providers, command argv for `command`, `onDevice` for `apple`, or configured
`whisperCpp` binary, model, threads and extraArgs for `whisper-cpp`. Existing
provider fingerprints remain compatible. By default `cacheAcceptsFallback` is
false: a fallback transcript is not reused and the primary is tried again. With
`cacheAcceptsFallback: true`, a matching fallback entry is reused only when it
contains producer metadata. Legacy entries are reused only for the primary,
even if their fingerprint matches a fallback.

`riela workflow validate` rejects unknown providers, malformed fallback entries,
invalid `fallbackOn`, and `addon.env` keys outside the chain allowlist. Templated
option values are deferred to runtime; raw fallback and command and literal
`fallbackOn` are still checked. `whisper-cpp` anywhere in the chain is host-only:
validation and runtime reject it with `addon.container` or `addon.sandbox`. The
runtime host check uses rendered options before starting a container or sandbox,
so it also catches a templated provider resolving to `whisper-cpp`.

```json
{ "name": "riela/speech-to-text", "version": "1",
  "config": { "options": {
    "path": "{{input.utterance.path}}", "provider": "command", "language": "ja",
    "command": ["whisper-cli", "-m", "/models/ggml-large-v3.bin", "-l", "{{language}}",
                "-nt", "-np", "-f", "{{path}}"] } } }
```

```json
{ "name": "riela/speech-to-text", "version": "1",
  "config": { "options": { "path": "{{input.utterance.path}}", "provider": "whisper-cpp",
    "language": "ja", "whisperCpp": { "model": "/models/ggml-large-v3.bin" } } } }
```

```json
{ "name": "riela/speech-to-text", "version": "1",
  "env": { "OPENAI_API_KEY": { "fromEnv": "OPENAI_API_KEY" } },
  "config": { "options": { "path": "{{input.utterance.path}}", "provider": "openai",
    "fallback": [{ "provider": "whisper-cpp", "whisperCpp": { "model": "/models/ggml-large-v3.bin" } }],
    "fallbackOn": ["quota-exhausted", "rate-limited"] } } }
```

## `riela/text-to-speech`

| provider | how | `addon.env` |
|---|---|---|
| `apple` (default) | `/usr/bin/say [-v voice] [-r rate] -o <file>.aiff --file-format=AIFF` (macOS) | none |
| `openai` | `POST {base}/v1/audio/speech` `{model, voice, input, response_format}` | `OPENAI_API_KEY` (required), `OPENAI_BASE_URL` |
| `elevenlabs` | `POST {base}/v1/text-to-speech/{voice}?output_format=mp3_44100_128` `{text, model_id}` | `ELEVENLABS_API_KEY` (required), `ELEVENLABS_BASE_URL` |
| `voicevox` | `POST {base}/audio_query?text=&speaker=` then `POST {base}/synthesis?speaker=` (default base `http://127.0.0.1:50021`) | `VOICEVOX_BASE_URL` |
| `command` | runs `command` argv; it must write the file named by `{{output}}` | `COMMAND_*` |

Options: `text` (required), `provider`, `voice` (`openai` default `alloy`;
required for `elevenlabs`, where it is the voice id), `language`, `model`
(`gpt-4o-mini-tts`, `eleven_multilingual_v2`), `instructions` (`openai`),
`rate` (`apple`, words per minute), `speaker` (`voicevox`, default `1`),
`format` (`aiff` for apple, `mp3` for openai/elevenlabs, `wav` for
voicevox/command; openai accepts its other `response_format` values),
`outputDir` (default `<artifact root>/text-to-speech`), `cache` (default
`true`: identical requests reuse the produced file), `play`, `notAfter`,
`maxAttempts`, `timeoutSeconds`.

- `play: true` plays the file with `/usr/bin/afplay` and waits for it; it is
  rejected outside macOS.
- Empty or whitespace-only text is a no-op with `status: "skipped"`.
- `notAfter` is an ISO-8601 instant (fractional seconds and offsets accepted).
  When the current time is past it, nothing is synthesized or played and the
  status is `expired`. Use it for announcements that are pointless when late.

Output and `when` labels:

```json
{ "textToSpeech": { "status": "completed", "provider": "apple",
  "path": "/…/text-to-speech/tts-….aiff", "played": true, "cached": false } }
```

Every result carries `when.always` plus exactly one of `spoken` (status
`completed`), `skipped`, or `expired`, so transitions can branch on them.

`riela/text-to-speech` runs on the host; it has no default container image.
