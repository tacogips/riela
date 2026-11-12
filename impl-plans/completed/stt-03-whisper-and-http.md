# stt-03 whisper-cpp provider runner + classified HTTP for deepgram/elevenlabs/google

```json
{
  "planId": "stt-03-whisper-and-http",
  "planPath": "impl-plans/active/stt-03-whisper-and-http.md",
  "dependsOn": ["stt-01-contract"],
  "wave": 2,
  "writePaths": [
    "Sources/RielaCLI/SpeechWhisperCpp.swift",
    "Sources/RielaCLI/MediaPipelineSpeechHTTP.swift",
    "Sources/RielaCLI/MediaPipelineSpeechProviders.swift",
    "Tests/RielaCLITests/SpeechWhisperCppAndHTTPTests.swift",
    "impl-plans/progress/stt-03-whisper-and-http.md"
  ],
  "sharedPaths": [],
  "artifactRoots": []
}
```

Artifacts: none. Evidence goes in `tmp/stt-agent-gateway/stt-03/`.

- Design: §2.2 (whisper-cpp argv and the host-only rule; the rejection itself is stt-05) and §4 (classified HTTP for the three existing remote providers).
- Progress log: `impl-plans/progress/stt-03-whisper-and-http.md`.

## Intent and context

This plan adds the whisper-cpp runner that stt-04 will call. It also switches deepgram,
elevenlabs, and google from the generic `MediaPipelineService.send`
(`Sources/RielaCLI/MediaPipelineService+Stages.swift:send`) to an STT-only classified
send, so that they can take part in a fallback chain and report HTTP status and
providerProblem. TTS and Home Assistant keep using `send`, which is not edited.

Patterns to follow:
- `MediaPipelineAddons.swift:speechToText` `.command` branch, for running a command through `service.command`/`service.run` with a deadline.
- `MediaPipelineService.swift:command(_:stage:)`, for binary lookup over `resolvedSearchPath`, which already includes `/opt/homebrew/bin`.

## Amendment 2026-11-12 (session 854)

A previous-run implementation exists (uncommitted):
`tmp/stt-agent-gateway/partial-untracked/Sources/RielaCLI/{SpeechWhisperCpp.swift,MediaPipelineSpeechHTTP.swift}`,
`.../Tests/RielaCLITests/SpeechWhisperCppAndHTTPTests.swift`, and the
`MediaPipelineSpeechProviders.swift` hunk in `tmp/stt-agent-gateway/partial-wave-001-003.patch`.
It may be reused after a symbol-by-symbol diff against this plan, including the Retry-After
header rule above. Gateway v0.1.11 does not affect this plan. `sendClassified` is also the
target of stt-04's migrated `MediaPipelineMediaLogicTests` cases, so keep its signature exact.

## Non-goals

- Do not wire whisper-cpp into `speechToText` (stt-04). Do not edit `MediaPipelineAddons.swift`, `MediaPipelineService+Stages.swift`, `MediaPipelineService.swift`, or the stt-01 contract file.
- No audio conversion for whisper-cpp. No retry for whisper-cpp.
- No vendor-specific quota tables beyond `SpeechFailureClassifier`.

## File-level changes

### `Sources/RielaCLI/SpeechWhisperCpp.swift` (new)

- `extension MediaPipelineService { func whisperCppTranscribe(audio: URL, options: WhisperCppOptions, language: String?, timeoutSeconds: Double, deadline: Date?) async throws -> String }`. It throws `SpeechProviderFailure`.
- Binary:
  - When `options.binary` is nil, resolve the bare name `whisper-cli` with `command(_:stage:)`, which searches PATH and then `/opt/homebrew/bin`.
  - When it is set, pass it to `command`.
  - A lookup failure becomes `.unavailable` with the message `"whisper-cli is not installed or not on PATH"`.
- Model:
  - An absolute path is used as-is. A relative path is resolved against `workingDirectory`.
  - If the file is missing, fail with `.unavailable` and the message `"whisper-cpp model file not found"`. Do not include the path, because it may sit in the user's home directory.
- argv, in exactly this order:
  - `-m <model> -f <audio.path> -l <language ?? "auto"> -nt -np`
  - then `-t <threads>` if set
  - then `extraArgs…`
- Deadline: `min(deadline ?? .distantFuture, now + timeoutSeconds)`. Environment: the base process environment only, with no overlay.
- Results:
  - stdout trimmed of whitespace and newlines is the transcript.
  - A non-zero exit (`MediaPipelineError.stage` with "process exited with status N: …") becomes `.unavailable`. Its message keeps the already-redacted stage text.
  - `AdapterExecutionError` with code `.timeout` becomes `.transportError`.
  - `CancellationError` is rethrown.

### `Sources/RielaCLI/MediaPipelineSpeechHTTP.swift` (new)

- `extension MediaPipelineService { func sendClassified(_ request: URLRequest, maxAttempts: Int, label: String, deadline: Date?) async throws -> Data }`.
- Use `SpeechRetry.run`. Each attempt calls `http(request)` once.
  - A 2xx response returns the body.
  - Any other status throws `SpeechFailureClassifier.classify(httpStatus:body:retryAfter:label:)`. Set `retryAfter` from the response `Retry-After` header when it is a non-negative delta-seconds number, otherwise nil. Ignore HTTP-date values; the 2^(n-1) backoff then applies, as design §4 allows.
  - A thrown non-cancellation error throws `.transport(label)`.

### `Sources/RielaCLI/MediaPipelineSpeechProviders.swift`

- In `deepgramTranscribe`, `elevenLabsTranscribe`, and `googleTranscribe`, replace `send(…, stage: "stt", label: …)` with `sendClassified(…, label: <same label>)`.
- The request shapes and response parsing stay byte-identical.

## Pitfalls

- `language` empty or nil maps to `auto`. stt-04 already turns blank into nil. Here, treat both nil and empty as auto.
- Do not put `extraArgs` before `-f`. The argv order is part of the test contract.
- `sendClassified` must not change the retry statuses for 429 and 5xx. 402 and quota codes are added as non-retryable.
- Do not edit or rename `send`. Home Assistant and TTS depend on it.

## Tests (`Tests/RielaCLITests/SpeechWhisperCppAndHTTPTests.swift`)

Use a file-private fake runner modeled on `SpeechFakeRunner` in `SpeechProviderAddonTests.swift`, and a fake executable file in a temp directory placed on the resolver PATH.

- Only `model` set, language nil -> argv `[-m, model, -f, audio, -l, auto, -nt, -np]`, and the text is trimmed stdout.
- language `ja`, threads 4, extraArgs `["--best-of","5"]` -> `-l ja` and `-t 4` before `--best-of 5`.
- A relative model path -> resolved under the working directory.
- A missing model file -> `.unavailable`, and the runner is never invoked.
- Runner exit status 3 -> `.unavailable`, and the message contains "status 3".
- Runner timeout -> `.transportError`.
- `binary` set to an absolute fake path -> that executable is used.
- deepgram stub 429 with body `{"error":{"code":"insufficient_quota"}}` -> 1 request, quotaExhausted.
- deepgram 503 ×3 with `maxAttempts` 3 and Retry-After 0 -> 3 requests, serverError with httpStatus 503.
- deepgram 429 `rate_limit_exceeded` with header `Retry-After: 7` -> the failure carries retryAfter 7 (assert on a single-attempt run, or with a recording sleep if injectable; do not sleep for real).
- elevenlabs 402 -> quotaExhausted after 1 request.
- google 200 -> parsing unchanged.

## Verification (evidence in `tmp/stt-agent-gateway/stt-03/`)

- `mkdir -p tmp/stt-agent-gateway/stt-03`
- `arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/stt-agent-gateway/stt-03/build.log 2>&1` -> exit 0.
- `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter 'SpeechWhisperCppAndHTTPTests|SpeechProviderAddonTests'" > tmp/stt-agent-gateway/stt-03/test.log 2>&1` -> exit 0, 0 failures. The existing deepgram, elevenlabs, and google request-shape tests stay green.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaCLI/SpeechWhisperCpp.swift Sources/RielaCLI/MediaPipelineSpeechHTTP.swift Sources/RielaCLI/MediaPipelineSpeechProviders.swift Tests/RielaCLITests/SpeechWhisperCppAndHTTPTests.swift' > tmp/stt-agent-gateway/stt-03/lint.log 2>&1` -> 0 new violations.
- `git diff --exit-code -- Sources/RielaCLI/MediaPipelineService+Stages.swift Sources/RielaCLI/MediaPipelineService.swift` -> exit 0.

## Done criteria

- The tests above pass.
- `send` is unchanged.
- The three providers use `sendClassified`.
- The progress log has commands, exit codes, test counts, and pre/post hashes. Follow the stt-01 drift rules.

Implementation progress: assigned runner and HTTP changes are implemented and verified; see `impl-plans/progress/stt-03-whisper-and-http.md`. Formal review and downstream orchestration remain pending.
