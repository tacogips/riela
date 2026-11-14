# stt-04 implementation progress

The accepted stt-01, stt-02, and stt-03 dependencies are integrated. Implemented gateway dispatch and classified retries, ordered fallback, provider-aware caching and legacy identity compatibility, and removed the old OpenAI HTTP implementation. Added gateway stubs and fallback/cache tests; the fixed command identity vector is asserted in `SpeechToTextFallbackTests`.

The removed multipart test is covered by `SpeechAgentGatewayMappingTests` for base URL normalization, `SpeechWhisperCppAndHTTPTests` for multipart behavior, and `SpeechToTextContractTests` for retry policy. The media logic suite directly checks the 25 MB boundary and classified HTTP retries/redaction; its other three tests remain unchanged.

Verification on the shared tree after the last Swift edit (logs in `tmp/stt-agent-gateway/stt-04-orchestrator/`):

- `arch -arm64 /bin/zsh -lc 'swift build --build-tests'`: exit 0, `build-final.log`.
- `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter 'SpeechToTextFallbackTests|SpeechProviderAddonTests|MediaPipeline|SpeechToTextContractTests|SpeechWhisperCppAndHTTPTests'"`: exit 0, 55 tests, 0 failures, `test-final.log`.
- `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter MediaPipelineMediaLogicTests"`: exit 0, 5 tests, 0 failures, `media-logic-final.log`.
- Selected-file SwiftLint and strict NUL-manifest SwiftLint: both exit 0, `lint-final.log` and `strict-lint-final.log`. The initial strict lint detected statement position; it was corrected and all final checks rerun.
- Symbol removal check: exit 0, `symbols.log`.

Pre-edit source hashes and edit intentions are in the evidence directory; `main-pre.sha256`, `stages-pre.sha256`, and the test pre-edit evidence record the starting state. `final-source.sha256` records all six final Swift files. These checks ran on the shared tree; independent review and integration are downstream.
