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
  "entryStepId": "download",
  "nodes": [
    { "id": "download", "addon": { "name": "riela/media-download", "version": "1", "config": { "options": {
      "url": "https://www.youtube.com/watch?v=8QxKwYOyUaE",
      "outputDir": ".riela/artifacts/media-download"
    } } } },
    { "id": "audio", "addon": { "name": "riela/audio-segments", "version": "1", "config": { "options": {
      "path": "{{input.mediaDownload.path}}",
      "segmentSeconds": 180
    } } } },
    { "id": "videoFrames", "addon": { "name": "riela/video-frames", "version": "1", "config": { "options": {
      "path": "{{input.audioSegments.sourcePath}}",
      "segments": "{{input.audioSegments.segments}}"
    } } } },
    { "id": "segment-join", "kind": "output" }
  ],
  "steps": [
    { "id": "download", "nodeId": "download", "transitions": [{ "toStepId": "audio" }] },
    { "id": "audio", "nodeId": "audio", "transitions": [{ "toStepId": "videoFrames" }] },
    { "id": "videoFrames", "nodeId": "videoFrames", "transitions": [{
      "toWorkflowId": "video-pipeline-segment",
      "toStepId": "speechToText",
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
  "entryStepId": "speechToText",
  "nodes": [
    { "id": "speechToText", "addon": {
      "name": "riela/speech-to-text",
      "version": "1",
      "env": {
        "OPENAI_API_KEY": { "fromEnv": "OPENAI_API_KEY", "required": true },
        "OPENAI_BASE_URL": { "fromEnv": "OPENAI_BASE_URL" }
      },
      "config": { "options": { "path": "{{segment.path}}" } }
    } },
    { "id": "describeSegment", "nodeFile": "nodes/describe-segment.json" },
    { "id": "segment-output", "kind": "output" }
  ],
  "steps": [
    { "id": "speechToText", "nodeId": "speechToText", "transitions": [{ "toStepId": "describeSegment" }] },
    { "id": "describeSegment", "nodeId": "describeSegment", "transitions": [{ "toStepId": "segment-output" }] },
    { "id": "segment-output", "nodeId": "segment-output" }
  ]
}
```

Use this node definition for `nodes/describe-segment.json`:

```json
{
  "id": "describeSegment",
  "description": "Describe the current video segment from its transcript and images.",
  "executionBackend": "codex-agent",
  "agentSandbox": "read-only",
  "model": "gpt-5.4-mini",
  "modelFreeze": false,
  "promptTemplate": "Describe this video segment using its transcript and images.\nTranscript: {{speechToText.text}}\nSegment frames: {{segment.frames}}",
  "variables": {}
}
```

Riela templates do not support `steps.<id>.output` references. Use the current
step input (`{{input...}}`) for upstream values and the fanout item variable
inside the branch. An agent wired directly to the video-frames output receives
every segment's `imagePaths`, because adapters collect image attachments
recursively. Keep agents inside the fanout branch or set
`forwardImageAttachments` to `false` on a directly wired agent.

The default output directories are scoped to each video or input media file;
explicit output directories can be supplied when a workflow needs stable
locations. Set `cache` to `false` to recompute a stage. Download URLs are
canonicalized, local and private hosts are rejected, and `allowedHosts` can
restrict accepted suffixes.
