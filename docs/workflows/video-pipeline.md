# Composable video pipeline

Install `yt-dlp` and `ffmpeg` with `brew install yt-dlp ffmpeg` on macOS or
`apt-get install yt-dlp ffmpeg` on Debian and Ubuntu. The download stage needs
network access. Audio extraction, frame sampling, and speech recognition can
run in separate stages with only the speech stage allowed to reach its API.

This example shows the data flow as two workflow definitions. The parent
downloads the video, extracts audio segments, samples frames for those time
boundaries, and fans each result into the segment workflow. Whole-value
templates preserve JSON arrays and objects as JSON values.

```json
{
  "workflowId": "video-pipeline",
  "description": "Download a video, segment its audio, sample frames, and fan out segment analysis.",
  "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 1, "fanoutConcurrency": 4 },
  "entryStepId": "download",
  "nodeRegistry": [
    { "id": "download", "addon": { "name": "riela/media-download", "version": "1", "config": { "options": {
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
    { "id": "download", "addon": { "name": "riela/media-download", "version": "1", "config": { "options": {
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
`outputDir` must be dedicated to that stage because recomputing a download
removes stale `video.*` files there, and recomputing frame sampling removes
stale `frame_*.jpg` files there. `outputDir` cannot be the workflow working
directory root or the user's home directory. Set `cache` to `false` to
recompute a stage. Download URLs are canonicalized, local and private hosts
are rejected, and `allowedHosts` can restrict accepted suffixes.
