# stt-03 whisper-cpp and classified HTTP progress

Implemented the local runner and classified sender; the three HTTP providers retain their request and response shapes. The downstream stt-04 plan owns orchestration. Formal review and integration remain pending.

- `arch -arm64 /bin/zsh -lc 'swift build --build-tests'`: exit 0, `tmp/stt-agent-gateway/stt-03-whisper-and-http/build-final.log`.
- `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter 'SpeechWhisperCppAndHTTPTests|SpeechProviderAddonTests'"`: exit 0, 23 tests, 0 failures, `tmp/stt-agent-gateway/stt-03-whisper-and-http/test-final.log`.
- Scoped SwiftLint and strict NUL-manifest SwiftLint: exit 0; `lint-final.log` and `strict-lint-final.log` in the same evidence directory.
- `git diff --exit-code -- Sources/RielaCLI/MediaPipelineService+Stages.swift Sources/RielaCLI/MediaPipelineService.swift`: exit 0, `service-diff.log`.
- Pre/post hashes and per-edit intentions are in `pre-hashes.log`, `post-hashes.log`, and `edit-intentions.log` in the evidence directory. New files were absent before implementation. Verification ran on the shared, moving tree.
