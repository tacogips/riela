# Voice input: `riela voice listen`

`riela voice listen` is a thin microphone recorder (macOS only). It segments
speech with an energy voice-activity detector and writes one WAV file per
utterance into an inbox directory. It is **not** an event source and never runs
a workflow itself: an ordinary `file-change` event source watches the inbox and
dispatches the bound workflow (speech-to-text, wake-phrase match, actions).
See `design-docs/specs/design-voice-assistant.md` for the full assistant flow.

## Recorder

```sh
riela voice listen --inbox .riela/voice/inbox/office \
  [--device <uid>] [--threshold-db -45] [--min-speech-ms 300] \
  [--silence-ms 700] [--max-utterance-ms 15000] [--pre-roll-ms 400] \
  [--retain-seconds 600] [--voice-processing true]

riela voice devices      # one JSON line per input device: {"isDefault":..,"name":..,"uid":..}
```

| Option | Default | Meaning |
|---|---|---|
| `--inbox` | required | Directory that receives the WAV files (created if missing; relative to the current directory). |
| `--device` | system default input | Input device UID from `riela voice devices`. |
| `--threshold-db` | `-45` | Speech onset level, RMS dBFS per 20 ms frame. Speech continues down to 6 dB below it (hysteresis). Use `--threshold-db=-50` or `--threshold-db -50`. |
| `--min-speech-ms` | `300` | Utterances with less voiced audio are dropped (clicks, coughs). |
| `--silence-ms` | `700` | Continuous silence that ends an utterance. |
| `--max-utterance-ms` | `15000` | Longer speech is emitted and recording continues in a new file. |
| `--pre-roll-ms` | `400` | Audio kept from before the speech onset; at most this much trailing silence is kept too. |
| `--retain-seconds` | `600` | `*.wav` files in the inbox older than this are deleted (checked at start and after every write). `0` disables deletion. Other files are never touched. |
| `--voice-processing` | `true` | Enables the macOS voice-processing IO (echo cancellation, noise suppression). When the device refuses it the recorder logs that to stderr and uses the raw input. |

Behavior:

- Capture is `AVAudioEngine` input converted to 16 kHz mono Float32. Files are
  16-bit PCM, 16 kHz, mono RIFF/WAVE.
- Each utterance is written to `<inbox>/.tmp-<id>.wav` and then renamed to
  `<inbox>/<UTC yyyyMMdd'T'HHmmss'Z'>-<id>.wav`. The watcher skips hidden
  (dot-prefixed) files, so it never sees a partial file.
- One JSON line per written file goes to stdout:
  `{"durationMs":1820,"path":"/abs/inbox/20261031T103045Z-1a2b3c4d5e6f.wav","peakDb":-7.4}`.
  Diagnostics go to stderr.
- It runs until SIGINT or SIGTERM; an utterance in progress at that point is
  still written.
- On Linux and other platforms the command exits with the usage error
  `riela voice listen is only available on macOS`.
- An input-device change while running (unplugging a headset) is not
  followed; restart the recorder.

## Pairing with a `file-change` source

Run one recorder and one source per room inbox. The room is the inbox name, so
the binding can pass it to the workflow.

`.riela-events/sources/voice-office.json` (`directory` resolves relative to the
`sources/` directory):

```json
{
  "id": "voice-office",
  "kind": "file-change",
  "directory": "../../.riela/voice/inbox/office",
  "changeTypes": ["create"],
  "recursive": false,
  "filters": { "suffixes": [".wav"] },
  "stabilityWindowMs": 0
}
```

`stabilityWindowMs: 0` is safe because the recorder only ever renames complete
files into the inbox.

`.riela-events/bindings/voice-office-to-assistant.json`:

```json
{
  "id": "voice-office-to-assistant",
  "sourceId": "voice-office",
  "match": { "eventType": "file.change.created" },
  "workflowName": "voice-assistant",
  "inputMapping": {
    "mode": "template",
    "template": {
      "path": "{{event.input.file.absolutePath}}",
      "room": "office"
    },
    "mirrorToHumanInput": false
  },
  "execution": { "async": true, "concurrencyKey": "voice-office" }
}
```

Then run both processes:

```sh
riela voice listen --inbox .riela/voice/inbox/office &
riela events serve
```

The file-change poll loop sleeps about 1 s between scans, so expect roughly
1-2 s of dispatch latency before speech-to-text starts.

## Permissions

The `riela` binary embeds `NSMicrophoneUsageDescription` (and
`NSSpeechRecognitionUsageDescription` for the on-device Apple speech-to-text
provider) in its Info.plist section. macOS attributes the microphone grant to
the responsible process: when `riela voice listen` is started from Terminal,
iTerm or another terminal app, the first run prompts for **that app's**
microphone access; when it runs under launchd or RielaApp, the prompt names
riela. If access was denied the command exits with an error; re-enable it in
System Settings > Privacy & Security > Microphone and restart the recorder.
