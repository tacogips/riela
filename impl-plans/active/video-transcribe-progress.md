# Video transcription addon progress

- [x] Register and catalog `riela/video-transcribe` version 1.
- [x] Implement source validation, media pipeline, dHash deduplication,
  silence-aware batching, OpenAI multipart transcription, per-batch images and
  completed-manifest caching.
- [x] Document the addon contract and workflow example.
- [x] Complete injected transport/process tests and local ffmpeg integration.
- [x] Run `swift build`, focused suites, and SwiftLint.
- [ ] Run the sample URL workflow and prove the second-run cache hit; kinko is
  currently locked, so the authorized API key cannot be injected.
- [x] Commit and push `feat/video-transcribe` (implementation commit
  `6adc239`).
