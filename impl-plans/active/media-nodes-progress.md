# Composable media nodes

- [x] Reuse the existing URL safety, yt-dlp, silence boundary, dHash/frame,
  multipart STT, process diagnostics and cache logic for independent stages.
- [x] Register the four media builtins and update the catalog.
- [x] Replace the monolithic workflow guide and update the design spec and README.
- [x] Add injected download and speech transport tests, plus a composed run against
  a loopback OpenAI-compatible server.
- [x] Re-target generated ffmpeg integration coverage to audio segments and frames.
- [x] Build, focused tests and SwiftLint. The current live yt-dlp metadata request
  for the sample URL was blocked by YouTube's bot check; audio segmentation and
  frame sampling completed against the existing local copy of that sample.
- [x] Commit and push `feat/media-nodes`.
