# Video transcription workflow input

`riela/video-transcribe` turns a URL or local media file into time-ordered
transcript batches with batch-scoped screenshots. Install `yt-dlp` and `ffmpeg`
(`brew install yt-dlp ffmpeg` on macOS) for URL processing and media extraction.
Provide the API key through the workflow's environment binding:

```json
{
  "id": "transcribe",
  "addon": {
    "name": "riela/video-transcribe",
    "version": "1",
    "config": {
      "options": {
        "url": "https://www.youtube.com/watch?v=8QxKwYOyUaE&t=482s",
        "language": "ja",
        "frameIntervalSeconds": 10,
        "batchSeconds": 180,
        "sttPrompt": "Video title and domain vocabulary"
      }
    },
    "env": {
      "OPENAI_API_KEY": { "fromEnv": "OPENAI_API_KEY", "required": true }
    }
  }
}
```

The `t` parameter is removed so the whole video is processed. Fan out over
`output.videoTranscribe.batches`; each item has its own transcript, `frames`
and `imagePaths`. Do not fan out over a global image list: images are scoped to
each batch for the downstream tool-less summarizer. `outputDir` can select a
persistent cache location; a matching completed manifest avoids downloading
and transcribing again. Use `path` instead of `url` for local files.

YouTube URLs are canonicalized to `https://www.youtube.com/watch?v=ID`; the
`t`, `si`, `feature`, and `pp` query parameters are removed. URL inputs reject
local and private network addresses. Set `allowedHosts` to an array of host
suffixes to restrict URL sources further, for example `["youtube.com",
"youtu.be"]`. `maxFileSizeMB` limits downloaded media and defaults to 2048.

`OPENAI_BASE_URL` may be the API origin (for example
`https://api.openai.com`) or may end in `/v1`; the addon appends
`/v1/audio/transcriptions` in either case.
