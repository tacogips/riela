# Composable video pipeline

The media pipeline uses four single purpose builtins. Install `yt-dlp` and
`ffmpeg` on macOS with `brew install yt-dlp ffmpeg`, or on Debian/Ubuntu with
`apt-get install yt-dlp ffmpeg`. Keep stage output directories under the
workflow working directory so a container stage sees the same paths as its
neighbors. The download stage needs network access; local extraction stages
can run with networking denied.

```json
{
  "id": "download",
  "addon": {
    "name": "riela/media-download",
    "version": "1",
    "container": { "image": "riela-video-addons:local", "networkPolicy": "egress-allowed" },
    "config": { "options": {
      "url": "https://www.youtube.com/watch?v=8QxKwYOyUaE",
      "outputDir": ".riela/artifacts/media-download"
    } }
  }
}
```

Pass `download.output.mediaDownload.path` to the next stages. Split audio and
sample frames independently, then provide the audio segment boundaries as the
frame stage's `segments` option. Fan out over
`videoFrames.segments`; each item has the segment's time boundaries, its frame
objects and `imagePaths`, ready for an agent to receive image context.

```json
{
  "id": "audio",
  "addon": {
    "name": "riela/audio-segments", "version": "1",
    "container": { "image": "riela-video-addons:local", "networkPolicy": "denied" },
    "config": { "options": {
      "path": "{{steps.download.output.mediaDownload.path}}",
      "outputDir": ".riela/artifacts/audio-segments"
    } }
  }
}
```

```json
{
  "id": "frames",
  "addon": {
    "name": "riela/video-frames", "version": "1",
    "container": { "image": "riela-video-addons:local", "networkPolicy": "denied" },
    "config": { "options": {
      "path": "{{steps.download.output.mediaDownload.path}}",
      "segments": "{{steps.audio.output.audioSegments.segments}}",
      "outputDir": ".riela/artifacts/video-frames"
    } }
  }
}
```

For each item from `/steps/frames/output/videoFrames/segments`, run
`riela/speech-to-text` with that item's matching audio path, then pass the
transcript and the same item to an agent node. The speech stage needs
`OPENAI_API_KEY`; optional `OPENAI_BASE_URL` accepts an API origin with or
without `/v1`. Bind only those variables to the speech stage.

```json
{
  "id": "speech",
  "addon": {
    "name": "riela/speech-to-text", "version": "1",
    "container": { "image": "riela-video-addons:local", "networkPolicy": "egress-allowed" },
    "env": { "OPENAI_API_KEY": { "fromEnv": "OPENAI_API_KEY", "required": true } },
    "config": { "options": { "path": "{{item.path}}" } }
  }
}
```

Every stage writes a stage-specific manifest and reuses outputs when its
options and inputs match (`cache` defaults to `true`). Set `cache` to `false`
to force a stage to run again. Download URLs are canonicalized; private and
local hosts are rejected, and `allowedHosts` can restrict accepted suffixes.
