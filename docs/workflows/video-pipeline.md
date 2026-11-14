# Composable video pipeline

Install `ffmpeg` with `brew install ffmpeg` on macOS or `apt-get install ffmpeg`
on Debian and Ubuntu. Riela has no built-in downloader: the download stage is
an installable package add-on such as `media/yt-dlp-download`, which builds its
own container image with yt-dlp, Deno and ffmpeg and needs network egress.
Audio extraction, frame sampling, and speech recognition can run in separate
stages with only the speech stage allowed to reach its API.

This example shows the data flow as two workflow definitions. The parent
downloads the video, extracts audio segments, samples frames for those time
boundaries, and fans each result into the segment workflow. Whole-value
templates preserve JSON arrays and objects as JSON values.

The parent is a workflow package that vendors `addons/yt-dlp-download` from
[the yt-dlp package example](../../examples/video-pipeline-yt-dlp/README.md) in
its `riela-package.json` `addons[]`, so `media/yt-dlp-download` resolves during
validation. Install it with `riela package install` in project or user scope.

```json
{
  "workflowId": "video-pipeline",
  "description": "Download a video, segment its audio, sample frames, and fan out segment analysis.",
  "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 1, "fanoutConcurrency": 4 },
  "entryStepId": "download",
  "nodeRegistry": [
    { "id": "download", "addon": { "name": "media/yt-dlp-download", "version": "1", "config": { "options": {
      "url": "https://www.youtube.com/watch?v=8QxKwYOyUaE"
    } } } },
    { "id": "audio", "addon": { "name": "riela/audio-segments", "version": "1", "config": { "options": {
      "path": "{{input.mediaDownload.path}}",
      "segmentSeconds": 180
    } } } },
    { "id": "video-frames", "addon": { "name": "riela/video-frames", "version": "1", "config": { "options": {
      "path": "{{input.audioSegments.sourcePath}}",
      "segments": "{{input.audioSegments.segments}}"
    } } } },
    { "id": "segment-join", "addon": { "name": "riela/json-compose", "version": "1", "config": {
      "payload": { "joined": "{{input}}" }
    } } }
  ],
  "nodes": [
    { "id": "download", "addon": { "name": "media/yt-dlp-download", "version": "1", "config": { "options": {
      "url": "https://www.youtube.com/watch?v=8QxKwYOyUaE"
    } } } },
    { "id": "audio", "addon": { "name": "riela/audio-segments", "version": "1", "config": { "options": {
      "path": "{{input.mediaDownload.path}}",
      "segmentSeconds": 180
    } } } },
    { "id": "video-frames", "addon": { "name": "riela/video-frames", "version": "1", "config": { "options": {
      "path": "{{input.audioSegments.sourcePath}}",
      "segments": "{{input.audioSegments.segments}}"
    } } } },
    { "id": "segment-join", "addon": { "name": "riela/json-compose", "version": "1", "config": {
      "payload": { "joined": "{{input}}" }
    } } }
  ],
  "steps": [
    { "id": "download", "nodeId": "download", "transitions": [{ "toStepId": "audio" }] },
    { "id": "audio", "nodeId": "audio", "transitions": [{ "toStepId": "video-frames" }] },
    { "id": "video-frames", "nodeId": "video-frames", "transitions": [{
      "toWorkflowId": "video-pipeline-segment",
      "toStepId": "speech-to-text",
      "resumeStepId": "segment-join",
      "fanout": {
        "groupId": "video-segments",
        "itemsFrom": "/videoFrames/segments",
        "itemVariable": "segment",
        "concurrency": 4,
        "joinStepId": "segment-join",
        "failurePolicy": "fail-fast",
        "resultOrder": "input"
      }
    }] },
    { "id": "segment-join", "nodeId": "segment-join" }
  ]
}
```

The fanout branch transcribes each matching audio segment, then sends that
transcript and only that segment's frames to the agent:

```json
{
  "workflowId": "video-pipeline-segment",
  "description": "Transcribe and describe one video segment.",
  "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 1 },
  "entryStepId": "speech-to-text",
  "nodeRegistry": [
    { "id": "speech-to-text", "addon": {
      "name": "riela/speech-to-text",
      "version": "1",
      "env": {
        "OPENAI_API_KEY": { "fromEnv": "OPENAI_API_KEY", "required": true },
        "OPENAI_BASE_URL": { "fromEnv": "OPENAI_BASE_URL" }
      },
      "config": { "options": { "path": "{{segment.path}}" } }
    } },
    { "id": "describe-segment", "nodeFile": "nodes/describe-segment.json" },
    { "id": "segment-output", "addon": { "name": "riela/json-compose", "version": "1", "config": {
      "payload": { "segment": "{{input}}" }
    } } }
  ],
  "nodes": [
    { "id": "speech-to-text", "addon": {
      "name": "riela/speech-to-text",
      "version": "1",
      "env": {
        "OPENAI_API_KEY": { "fromEnv": "OPENAI_API_KEY", "required": true },
        "OPENAI_BASE_URL": { "fromEnv": "OPENAI_BASE_URL" }
      },
      "config": { "options": { "path": "{{segment.path}}" } }
    } },
    { "id": "describe-segment", "nodeFile": "nodes/describe-segment.json" },
    { "id": "segment-output", "addon": { "name": "riela/json-compose", "version": "1", "config": {
      "payload": { "segment": "{{input}}" }
    } } }
  ],
  "steps": [
    { "id": "speech-to-text", "nodeId": "speech-to-text", "transitions": [{ "toStepId": "describe-segment" }] },
    { "id": "describe-segment", "nodeId": "describe-segment", "transitions": [{ "toStepId": "segment-output" }] },
    { "id": "segment-output", "nodeId": "segment-output" }
  ]
}
```

Use this node definition for `nodes/describe-segment.json`:

```json
{
  "id": "describe-segment",
  "description": "Describe the current video segment from its transcript and images.",
  "executionBackend": "codex-agent",
  "agentSandbox": "read-only",
  "model": "gpt-5.4-mini",
  "modelFreeze": false,
  "promptTemplate": "Describe this video segment using its transcript and images.\nTranscript: {{speech-to-text.text}}\nSegment frames: {{segment.frames}}",
  "variables": {}
}
```

Riela templates do not support `steps.<id>.output` references. Use the current
step input (`{{input...}}`) for upstream values and the fanout item variable
inside the branch. An agent wired directly to the video-frames output receives
every segment's `imagePaths`, because adapters collect image attachments
recursively. Keep agents inside the fanout branch or set
`forwardImageAttachments` to `false` on a directly wired agent.

Each media input gets a separate default artifact directory. An explicit
`outputDir` must be dedicated to that stage because recomputing frame sampling
removes stale `frame_*.jpg` files there. `outputDir` cannot be the workflow
working directory root or the user's home directory. Set `cache` to `false` to
recompute a stage. `media/yt-dlp-download` always writes under
`$RIELA_ARTIFACT_DIR/media-download/`, rejects local and private hosts, and
accepts `allowedHosts` to restrict host suffixes.

`riela/video-frames` reports the input it read as `videoFrames.sourcePath`
(the resolved absolute media path, also on cached results), next to `status`,
`intervalSeconds`, `dedupeThreshold`, `sampled`, `kept`, `frames`,
`outputDir`, `cached` and, when `segments` is given, the per-segment
attachments. A fanout can carry it into every branch with
`"contextFrom": "/videoFrames/sourcePath"`, for example to delete the
downloaded file once the results are published.

## Media download contract

A downloader produces a `mediaDownload` object with this tool-neutral v1 contract:

| Field | Required | Meaning |
| --- | --- | --- |
| `status` | Yes | `downloaded` |
| `path` | Yes | Absolute path to a regular media file |
| `url` | No | Source URL |
| `videoId` | No | Video identifier, string or null |
| `title` | No | Media title |
| `durationSeconds` | No | Duration in seconds |
| `outputDir` | No | Output directory |
| `cached` | No | Whether the result was cached |

The file must be readable where the consumer runs. For container stages, place
it under the workflow working directory or the artifact root.
`riela/audio-segments`, `riela/video-frames`, and `riela/speech-to-text` read
only `options.path`: wire `{{input.mediaDownload.path}}` from any producer, or
provide a plain local path.
`riela/speech-to-text` sends `options.language` to the provider when it is set;
a missing or blank value lets the provider detect the spoken language.
It uses OpenAI (or an OpenAI-compatible server) by default; set
`options.provider` to `deepgram`, `elevenlabs`, `google`, `apple` or `command`
to use another vendor or a local recognizer. See
[speech add-ons](speech.md) for each provider's options and `addon.env` keys.

## Plugging in a different downloader

Use any add-on or step that emits `mediaDownload.path` and meets the contract
above. A package container add-on is declared in `addons[]` with
`execution.kind: container`; it communicates over JSONL on stdin and stdout
and can write artifacts under `RIELA_ARTIFACT_DIR`. See
[the yt-dlp package example](../../examples/video-pipeline-yt-dlp/README.md).

A workflow that is not part of a package, such as a project workflow loaded with
`--workflow-definition-dir`, can reference any container add-on installed in a
project or user package or in the shared add-on store. Install the downloader once
with `riela node install video-pipeline-yt-dlp --source examples/video-pipeline-yt-dlp --scope user`;
`workflow validate` and runs then resolve `media/yt-dlp-download`. Package-owned
workflows still resolve external add-ons only through their own `addons[]` or a
dependency lock.
