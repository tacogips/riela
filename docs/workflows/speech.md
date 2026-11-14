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

| provider | how | `addon.env` |
|---|---|---|
| `openai` (default) | `POST {base}/v1/audio/transcriptions`; also any OpenAI-compatible server (Groq, faster-whisper, whisper.cpp server) | `OPENAI_API_KEY` (required), `OPENAI_BASE_URL` |
| `deepgram` | `POST {base or https://api.deepgram.com}/v1/listen?model=&language=&smart_format=true`, raw audio body, `Authorization: Token …` | `DEEPGRAM_API_KEY` (required), `DEEPGRAM_BASE_URL` |
| `elevenlabs` | `POST {base or https://api.elevenlabs.io}/v1/speech-to-text` multipart (`model_id`, `language_code`, `file`), `xi-api-key` header | `ELEVENLABS_API_KEY` (required), `ELEVENLABS_BASE_URL` |
| `google` | `POST {base or https://speech.googleapis.com}/v1/speech:recognize?key=` with base64 audio; WAV or FLAC only, about 60 s max | `GOOGLE_SPEECH_API_KEY` (required), `GOOGLE_SPEECH_BASE_URL` |
| `apple` | macOS Speech framework file recognition; `onDevice: true` requires on-device recognition | none |
| `command` | runs `command` argv, stdout (trimmed) is the transcript, non-zero exit is a provider error | `COMMAND_*` |

Options: `path` (required), `provider`, `model` (defaults: `gpt-4o-transcribe`,
`nova-3`, `scribe_v1`; none for the others), `language` (blank lets the
provider detect it; `google` defaults to `en-US`), `prompt` (`openai` only),
`onDevice` (`apple`), `command` (`command`), `maxAttempts`, `timeoutSeconds`,
`cache`. Remote uploads are limited to 25 MB and their Content-Type follows the
file extension (`wav`, `mp3`, `m4a`, `flac`, `ogg`, `webm`).

The transcript is cached next to the audio file as `<file>.stt.json`; the cache
key covers provider, model, base URL, language, prompt, command argv and the
audio content hash. Output:

```json
{ "speechToText": { "status": "completed", "provider": "deepgram", "model": "nova-3",
  "language": "ja", "text": "…", "path": "/…/clip.wav", "cached": false } }
```

The `apple` provider needs Speech Recognition permission for `riela` and is
unavailable on Linux and inside containers.

```json
{ "name": "riela/speech-to-text", "version": "1",
  "config": { "options": {
    "path": "{{input.utterance.path}}", "provider": "command", "language": "ja",
    "command": ["whisper-cli", "-m", "/models/ggml-large-v3.bin", "-l", "{{language}}",
                "-nt", "-np", "-f", "{{path}}"] } } }
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
