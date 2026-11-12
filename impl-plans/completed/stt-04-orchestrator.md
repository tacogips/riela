# stt-04 speech-to-text orchestrator: chain, retry, fallback, cache, output

```json
{
  "planId": "stt-04-orchestrator",
  "planPath": "impl-plans/active/stt-04-orchestrator.md",
  "dependsOn": ["stt-01-contract", "stt-02-gateway-mapping", "stt-03-whisper-and-http"],
  "wave": 3,
  "writePaths": [
    "Sources/RielaCLI/MediaPipelineAddons.swift",
    "Sources/RielaCLI/MediaPipelineService+Stages.swift",
    "Tests/RielaCLITests/SpeechProviderAddonTests.swift",
    "Tests/RielaCLITests/MediaPipelineAddonRegistrationTests.swift",
    "Tests/RielaCLITests/MediaPipelineMediaLogicTests.swift",
    "Tests/RielaCLITests/SpeechToTextFallbackTests.swift",
    "impl-plans/progress/stt-04-orchestrator.md"
  ],
  "sharedPaths": [],
  "artifactRoots": []
}
```

Artifacts: none. Evidence goes in `tmp/stt-agent-gateway/stt-04/`.

- Design: §2.1 (seam usage), §3, §4 (final failure), §5, §6, §8.
- Progress log: `impl-plans/progress/stt-04-orchestrator.md`.

## Intent and context

Rewrite `BuiltinWorkflowAddonResolver.speechToText` (`Sources/RielaCLI/MediaPipelineAddons.swift`, currently lines 417-520) so that:
- it parses options with `SpeechToTextOptionsParser.parse`;
- it runs the primary provider and then the fallback providers;
- openai, gemini, and openrouter go through `speechTranscriptionGateway`, the resolver seam from stt-01, wrapped in `SpeechRetry.run`;
- whisper-cpp goes through `whisperCppTranscribe` (stt-03);
- deepgram, elevenlabs, and google go through their existing functions, which now use `sendClassified`;
- apple and command work as today;
- it applies the §6 cache rules and the §4 final-error format;
- it removes `transcribeChunk`.

## Non-goals

- Do not edit the stt-01, stt-02, stt-03, or stt-05 files. If a contract gap appears, record it in the progress log and stop rather than editing them.
- No TTS, Home Assistant, `send`, `MediaPipelineSTTOptions` consumers outside STT, or docs.

## File-level changes

### `Sources/RielaCLI/MediaPipelineAddons.swift`

Registration: in `speechToTextRegistration`, change `rawOptionKeys` to `["command", "fallback"]`.

`speechToText(_:bindings:deadline:)`. Keep the signature.

1. Read `path` (the required option), `language` (blank becomes nil, as today), `prompt`, and `cache` (default true) as today. Then `chain = try SpeechToTextOptionsParser.parse(values)`.
2. Call `validateSpeechEnvironment(bindings, …, provider: chain.primary.provider.rawValue, allowed: chain.environmentAllowlist.keys, allowsCommandPrefix: chain.environmentAllowlist.allowsCommandPrefix)`. When there is no fallback, this is byte-identical to today.
3. Check that the audio file exists. Read it once (`Data(contentsOf:options:.mappedIfSafe)`). Compute `contentSHA256 = JSONCanonical.sha256Hex(data)` from the file bytes, as today. If the primary `isRemote`, keep today's `SpeechAudioUpload.read` limit error for the primary before any call. For a remote *fallback* provider, enforce the limit in its own attempt: an over-limit file there becomes `rejected`.
4. Identity per provider (`identity(for config)`). It must reproduce today's object exactly:
   - `provider`, `model` (or null), `language` (or null), `prompt` (or null), `contentSHA256`;
   - plus `baseURL` when non-nil: env value, else `defaultBaseURL`, which is nil for gemini and openrouter, so they get no key;
   - plus `command` for command and `onDevice` for apple;
   - plus `whisperCpp: {binary (as configured, or null), model, threads (or null), extraArgs}` for whisper-cpp.
   - The fingerprint is `c.fingerprint(.object(identity))`.
5. Cache read when `cache` is true. Decode the file object; `optionsFingerprint` is required.
   - If it equals the primary fingerprint, it is a hit. Output the primary provider and model, with no `fallbackFrom` (even if one is stored).
   - Otherwise, if `chain.cacheAcceptsFallback` is true and it equals some fallback fingerprint, and the file has `provider` and `model` keys (model may be JSON null), it is a hit. Output the stored provider, model, and `fallbackFrom`.
   - Anything else is a miss.
   - `cached: true` on a hit.
6. Execute each provider in order.
   - Missing key:
     - Gateway or HTTP providers with no `env[apiKeyName]`, and no fallback configured: throw today's `AdapterExecutionError(.policyBlocked, "speech-to-text requires addon.env.<KEY>")`.
     - Inside a chain: record an `.unavailable` failure with the message `"addon.env.<KEY> is not set"`.
   - Gateway providers:
     - Build a `SpeechTranscriptionRequest`. Its `environment` is the provider's own allowlisted resolved keys merged over `service.processEnvironment`. `baseURL` is the env value or nil. `model` is non-nil.
     - Run `SpeechRetry.run(maxAttempts: cfg.maxAttempts, deadline: deadline) { _ in try await speechTranscriptionGateway(request) }`.
   - whisper-cpp: call `service.whisperCppTranscribe` with no retry.
   - deepgram, elevenlabs, google: use the existing functions with `RemoteSpeechRequest`. They retry internally through `sendClassified`.
   - apple: as today. Map `AdapterExecutionError(.policyBlocked)` to `.unavailable` only when a fallback exists; otherwise rethrow it unchanged.
   - command: as today, with no retry. With a fallback, a stage error becomes `.unavailable`; without one, rethrow unchanged.
   - Error normalization while a chain exists:
     - `SpeechProviderFailure` stays as it is.
     - `AdapterExecutionError.timeout` becomes transportError.
     - `MediaPipelineError.stage` becomes rejected.
     - `CancellationError` is rethrown immediately.
   - Without a fallback, every non-`SpeechProviderFailure` error is rethrown unchanged, so existing messages and codes are preserved.
   - On failure, if `fallbackOn.contains(class)` and a next entry exists, append it to `fallbackFrom` and continue. Otherwise stop.
7. Final failure: throw `AdapterExecutionError(.providerError, msg, isRetryable: lastClass ∈ {quotaExhausted, unavailable, rejected} ? false : nil)`.
   - A single provider gives `speech-to-text provider '<p>' failed: <failure.fields>: <redacted message>`.
   - More than one provider tried gives `speech-to-text fallback chain failed: '<p1>' <fields>: <msg>; '<p2>' <fields>: <msg>`.
   - Pass every message through `c.redacted`. `MediaPipelineContext.finish` passes `AdapterExecutionError` through unchanged.
8. Success output: today's `speechToText` object, with `provider` and `model` taken from the producing config. Add `fallbackFrom` only if it is non-empty: an array of `{provider, model|null, failureClass, httpStatus?, providerProblem?}`. Never include `message` there.
9. Cache write: keep today's behavior, a `try?` write that happens even when `cache` is false (unchanged). The object is `{optionsFingerprint: <producer fp>, text, provider, model|null, fallbackFrom?}`.

### `Sources/RielaCLI/MediaPipelineService+Stages.swift`

Delete `transcribeChunk` and `MediaPipelineSTTOptions`, but first confirm with `git grep -n "MediaPipelineSTTOptions\|transcribeChunk"` that they are unused. Keep `send` and `extractFrames` unchanged.

### Tests

- `SpeechProviderAddonTests.swift`:
  - Rewrite `testOpenAIUploadFollowsFileExtensionAndKeepsOutputContract` to inject a stub `speechTranscriptionGateway`, capturing requests in a file-private actor. Assert the output fields, `request.model == "gpt-4o-transcribe"`, `apiKeyEnvironmentName == "OPENAI_API_KEY"`, and that `request.environment["OPENAI_API_KEY"]` exists. Assert that no `mediaPipelineHTTP` request was made.
  - The `resolver(...)` helper gains an optional gateway parameter, which defaults to a stub that fails the test if called. That default makes the helper fail closed.
  - Keep every other test.
- `MediaPipelineAddonRegistrationTests.swift`:
  - `testSpeechToTextUsesTransportAndCachesTranscriptByOptionsAndFileMetadata`: inject a gateway stub and count calls (1 after the cache hit, 2 after the language change). Assert `timeoutSeconds` 12 on both captured requests.
  - `testSpeechToTextBlankLanguageLetsProviderDetectIt`: assert that the captured `request.language == nil`.
  - Any other speech-to-text test in this file that executes openai: inject the stub. No test may reach the production gateway.
- `SpeechToTextFallbackTests.swift` (new):
  - openai stub throws quotaExhausted (429, `insufficient_quota`), with fallback `[whisper-cpp]` and a fake runner that prints "local text" -> 1 gateway call. Output provider `whisper-cpp`, model null, text "local text", `fallbackFrom == [{provider:openai, model:gpt-4o-transcribe, failureClass:quota-exhausted, httpStatus:429, providerProblem:insufficient_quota}]`.
  - openai stub throws rateLimited with retryAfter 0 and `maxAttempts` 3 -> 3 gateway calls, then whisper-cpp. `fallbackFrom[0].failureClass == rate-limited`.
  - `fallbackOn:["quota-exhausted"]` with a rate-limited primary -> no fallback. providerError, the message contains `failureClass=rate-limited`, and `isRetryable == nil`.
  - quotaExhausted with no fallback -> 1 call. The message contains `providerProblem=insufficient_quota` and `httpStatus=429`, and `isRetryable == false`.
  - Every provider fails (openai quota, then whisper-cpp missing model) -> the message is `fallback chain failed` with both clauses, and the key value is absent.
  - Cache: run 1 falls back to whisper-cpp and writes a file with provider whisper-cpp. Run 2 with default `cacheAcceptsFallback` -> the gateway is called again (miss). Run 3 with `cacheAcceptsFallback:true` and the gateway failing -> a hit with provider whisper-cpp, the stored `fallbackFrom`, and `cached:true`, with 0 new gateway calls.
  - Legacy regression:
    - Write a legacy `{optionsFingerprint:<command identity fp>, text:"cmd text"}` file. A run with `provider:"command"` and the same argv -> hit, provider command (the legacy primary hit).
    - The same file with primary openai, an identical command fallback, and `cacheAcceptsFallback:true` -> miss. The gateway stub is called, and the output is never `provider: openai` with "cmd text".
  - No-fallback openai success -> the output has no `fallbackFrom` key, and its key set equals `{status, provider, model, language, text, path, cached}`.
  - A missing `OPENAI_API_KEY` with no fallback -> policyBlocked with today's message. With `fallback:[whisper-cpp]` -> whisper-cpp text, and `fallbackFrom[0].failureClass == unavailable`.
  - A fallback entry `command` argv with `{{path}}` -> rendered by the add-on, not by the template engine (raw `fallback`).
- `MediaPipelineMediaLogicTests.swift` (amendment 2026-11-12, session 854; design §8). The file
  calls `transcribeChunk` and `MediaPipelineSTTOptions` (lines 84-200), so deleting those
  symbols breaks the test build. Edit only the three tests that use them, without lowering
  coverage:
  - `testMultipartSTTRetriesAndNormalizesBaseURL`: delete. Base-URL `/v1` normalization is
    covered by stt-02 `SpeechAgentGatewayMappingTests`; multipart shape and retry by
    `SpeechWhisperCppAndHTTPTests` and `SpeechToTextContractTests`. Record the mapping in the
    progress log.
  - `testMultipartSTTAcceptsExactDecimalTwentyFiveMegabyteLimit`: keep the name; assert on
    `SpeechAudioUpload.read` directly (25_000_000 bytes accepted, 25_000_001 throws the existing
    25 MB error).
  - `testProcessTimeoutIsPreservedAndNetworkRetryStopsAtMaximumAttempts`: keep the
    process-timeout half unchanged; replace the `transcribeChunk` halves with `sendClassified`
    through the same `RetryableMediaPipelineHTTPStub`. Every retried stub response must carry
    `Retry-After: 0`, because `sendClassified` has no injectable sleep (design §8). Transport-error
    retries have no header, so give that case `maxAttempts` 2 and accept the single 1 s backoff,
    or assert it through `SpeechRetry` with a recording sleep: one transient failure then success -> 2
    requests; transport failure with maxAttempts 2 -> exactly 2 requests; 401 with body
    `api-secret must not be shown` -> `rejected`, 1 request, message without `api-secret`.
  - Leave `testDifferenceHashAndDedupeUse256Bits`, `testSilenceBoundaryChoiceRemainderMergeAndCarryForward`
    and `testProcessEnvironmentLookupAndRedactedStderrTail` untouched.
- Dependency note: stt-04 wires openai/gemini/openrouter to `speechTranscriptionGateway`; it is
  dispatched only after stt-02 is accepted, otherwise the placeholder seam would make every
  existing `provider: openai` workflow fail closed.

## Amendment 2026-11-12 (blocked-wave-scope-or-contract, round 1)

Blocker (wave-003): "Build-output ownership". `artifactRoots` is empty, while the required
`swift build` / `swift test` commands write to `.build/`.

Decision (explicit authorization; no new ownership):
- `.build/` is the repository's shared, gitignored SwiftPM build cache. No plan owns it, and it
  is not a source path. Every earlier plan in this manifest (stt-01, 02, 03, 05, 06) built and
  tested there. Running the verification commands below is authorized and does not count as a
  write.
- Do not add `.build` to `writePaths` or `artifactRoots`, because it would exceed the
  artifact-scan limits. Do not use an alternate `--scratch-path`, because that would re-resolve
  dependencies and bypass the pinned checkout.
- Evidence logs go to `tmp/stt-agent-gateway/stt-04/`, which is gitignored.
- `writePaths`, `dependsOn` and the plan content are unchanged. All three dependencies (stt-01, 02, 03) are accepted.
- `Tests/RielaCLITests/BuiltinAddonContainerResolverTests.swift` belongs to stt-05; do not edit it.
  The stt-04 test filter does not include that suite. If that suite fails, record it in the
  progress log as a sibling-owned issue and do not fix it.

Proceed with the full file-level changes and tests above. No partial stt-04 code exists in
`tmp/stt-agent-gateway/`, so implement from scratch against the accepted stt-01, 02 and 03
symbols: `SpeechToTextOptionsParser`, `SpeechRetry`, `speechTranscriptionGateway`,
`whisperCppTranscribe` and `sendClassified`.

## Pitfalls

- Build the identity of existing providers key-for-key as today. Use a fixed regression vector: compute the fp for a known config before and after, and hard-code the expected hex in the test.
- Do not apply `SpeechRetry` around the HTTP providers. `sendClassified` already retries, and wrapping it would multiply attempts.
- Do not write `fallbackFrom` on a primary-fingerprint hit.
- `deadline` bounds the whole chain. Each provider still uses its own `timeoutSeconds`.
- Never put env values, request URLs, or bodies in the output or the messages.

## Verification (evidence in `tmp/stt-agent-gateway/stt-04/`)

- `mkdir -p tmp/stt-agent-gateway/stt-04`
- `arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/stt-agent-gateway/stt-04/build.log 2>&1` -> exit 0.
- `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter 'SpeechToTextFallbackTests|SpeechProviderAddonTests|MediaPipeline|SpeechToTextContractTests|SpeechWhisperCppAndHTTPTests'" > tmp/stt-agent-gateway/stt-04/test.log 2>&1` -> exit 0, 0 failures.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaCLI/MediaPipelineAddons.swift Sources/RielaCLI/MediaPipelineService+Stages.swift Tests/RielaCLITests/SpeechProviderAddonTests.swift Tests/RielaCLITests/MediaPipelineAddonRegistrationTests.swift Tests/RielaCLITests/MediaPipelineMediaLogicTests.swift Tests/RielaCLITests/SpeechToTextFallbackTests.swift' > tmp/stt-agent-gateway/stt-04/lint.log 2>&1` -> 0 new violations.
- `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter MediaPipelineMediaLogicTests" > tmp/stt-agent-gateway/stt-04/media-logic.log 2>&1` -> exit 0.
- `git grep -n "transcribeChunk\|MediaPipelineSTTOptions" Sources Tests` -> no matches.

## Done criteria

- All the listed tests pass.
- The output shape is unchanged without fallback.
- The progress log has commands, exit codes, test counts, and pre/post hashes. Follow the stt-01 fresh-read and drift rules.

## Implementation status

Implemented and verified in the shared tree; see `impl-plans/progress/stt-04-orchestrator.md` for source hashes and gate results. Formal review and final integration remain downstream.
