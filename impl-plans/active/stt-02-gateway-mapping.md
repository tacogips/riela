# stt-02 agent-gateway transcription mapping (openai / gemini / openrouter)

```json
{
  "planId": "stt-02-gateway-mapping",
  "planPath": "impl-plans/active/stt-02-gateway-mapping.md",
  "dependsOn": ["stt-01-contract"],
  "wave": 2,
  "writePaths": [
    "Sources/RielaCLI/SpeechTranscriptionAgentGateway.swift",
    "Package.swift",
    "Tests/RielaCLITests/SpeechAgentGatewayMappingTests.swift",
    "impl-plans/progress/stt-02-gateway-mapping.md"
  ],
  "sharedPaths": [],
  "artifactRoots": []
}
```

Artifacts: none. Package resolution populates the shared `.build/` cache, which no
plan owns. Evidence goes in `tmp/stt-agent-gateway/stt-02/`.

- Design: `design-docs/specs/design-speech-to-text-agent-gateway.md` §2.1 (including the
  implementation precondition), §4, §8 (production-boundary tests), §9 R1–R2.
- Progress log: `impl-plans/progress/stt-02-gateway-mapping.md`.

## Intent and context

Replace the stt-01 placeholder `agentGatewaySpeechTranscription` with the production
implementation. It maps a `SpeechTranscriptionRequest` onto the pinned agent-gateway
(revision `64361c28bfaf1dcea1b28ccf99329796053454ab`, `Package.swift:83-85`) through
`AgentGatewayAppCore` `ProductionGatewayExecutor(environment:)` and `transcribe(GatewayTranscriptionParams)`,
and maps gateway errors to `SpeechProviderFailure` using `SpeechFailureClassifier`.

Patterns to follow:
- `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift:AgentGatewayExecutorFactory` and `defaultAgentGatewayExecutorFactory`: an injectable executor factory.
- `Sources/RielaAppSupport/RielaAppAssistantModelLoader.swift:models(for:)`: passes the API key by env-var *name* (`apiKeyEnvironment`).

## Step 0 — mandatory precondition (do this before writing any code)

1. Run `arch -arm64 /bin/zsh -lc 'swift package resolve'`. Read the pinned checkout under
   `.build/checkouts/agent-gateway` (read only, never edit it).
2. Record in the progress log, with `file:line` citations:
   - (a) the `GatewayTranscriptionParams` fields: vendor/provider selector, model, API-key env-name
     field, base URL, audio input form, language, prompt, timeout, and any retry/maxRetries field;
   - (b) the `transcribe` signature and the protocol that the executor conforms to;
   - (c) the error type(s) `transcribe` throws, and whether they expose the HTTP status, the vendor
     JSON body or code/type, and Retry-After;
   - (d) whether the executor retries internally, and how to turn that off;
   - (e) whether gemini and openrouter are supported vendors;
   - (f) whether an HTTP transport can be injected, for request counting.
3. Gate. Continue only if, for a given provider, the evidence shows the mapping can
   (1) preserve the HTTP status and vendor code/type (and Retry-After when the vendor sends it), and
   (2) send exactly one vendor request per call.
   - If either check fails for a provider, do **not** implement a degraded mapping for it. Make it
     throw `.unavailable` with the message `"agent-gateway transcription for <provider> is not supported at the pinned revision"`.
   - Mark the plan `blocked: scope-amendment-required` in the progress log, with the evidence, and finish.
   - Never invent gateway APIs, change the pin, edit `Package.resolved`, or route back to Riela's HTTP client.

## Non-goals

- No orchestrator or cache changes (stt-04), and no edits to stt-01 types. If a contract gap is found, record it in the progress log as a blocker and do not edit `SpeechToTextContract.swift`.
- deepgram, elevenlabs, and google stay off the gateway.

## File-level changes

### `Package.swift`
- Add `.product(name: "AgentGatewayAppCore", package: "agent-gateway")` to the `RielaCLI` target's dependencies, next to the existing `AgentGateway` product entry (around line 269). No other change.
- `git diff Package.resolved` must stay empty.

### `Sources/RielaCLI/SpeechTranscriptionAgentGateway.swift`
- `func makeAgentGatewaySpeechTranscription(executorFactory: @escaping @Sendable ([String: String]) -> <the executor protocol found in Step 0 (b)> = { ProductionGatewayExecutor(environment: $0) }) -> SpeechTranscriptionGateway`.
  - Set `let agentGatewaySpeechTranscription = makeAgentGatewaySpeechTranscription()`.
- Mapping:
  - Map provider to the gateway vendor. `model` passes through.
  - Pass the API key by `apiKeyEnvironmentName`. Never pass the value itself.
  - The executor environment is `request.environment`, already allowlisted by stt-04.
  - Normalize the openai base URL exactly as the removed `transcribeChunk` did: trim `/` and drop one trailing `/v1`. Then supply it in the form the gateway expects (cite Step 0). A nil base URL means the gateway default.
  - Set the gateway internal retry to off if that field exists. Set timeout = `timeoutSeconds`.
  - Pass the audio file, language, and prompt. Send `prompt` only when non-nil.
- Error mapping:
  - A gateway HTTP error becomes `SpeechFailureClassifier.classify(httpStatus:body:retryAfter:label:)`, with label `"<provider> transcription"`.
  - A transport, URLError, or timeout error becomes `.transport`.
  - `CancellationError` is rethrown.
  - Anything else becomes `.rejected` with a fixed message and no `String(describing:)` of the error, because it may carry headers.
  - The returned text is used as-is. An empty transcript is valid.

## Pitfalls

- A request whose env lacks the key is caught by stt-04 before calling. Do not read the process environment here.
- Do not log the request, the environment, or the error description.
- The tests must not reach the network. Inject the executor or transport.

## Tests (`Tests/RielaCLITests/SpeechAgentGatewayMappingTests.swift`)

These drive `makeAgentGatewaySpeechTranscription(executorFactory:)` with a stub executor. If
Step 0 (f) found an injectable transport, drive the real `ProductionGatewayExecutor` through
a stub transport instead and count vendor requests there.

- openai request with base `https://x.test/v1/` -> the captured params carry the normalized base, model, language, prompt, and key env name `OPENAI_API_KEY`. The captured environment has no other secrets.
- gemini and openrouter map to their vendors with the given model.
- Vendor 429 with `insufficient_quota` -> `SpeechProviderFailure` quotaExhausted, httpStatus 429, providerProblem `insufficient_quota`. Exactly 1 vendor request is counted.
- 429 `rate_limit_exceeded` driven through `SpeechRetry.run(maxAttempts: 3, …, sleep: no-op)` -> exactly 3 vendor requests.
- 503 -> serverError with httpStatus 503.
- Transport error -> transportError.
- An error containing the key value -> the message does not contain it.
- Record in the progress log whether request counts were observed at the transport (preferred) or at the executor. If at the executor, include the Step 0 (d) citation that proves one executor call sends one request.

## Verification (evidence in `tmp/stt-agent-gateway/stt-02/`)

- `mkdir -p tmp/stt-agent-gateway/stt-02`
- `arch -arm64 /bin/zsh -lc 'swift package resolve' > tmp/stt-agent-gateway/stt-02/resolve.log 2>&1` -> exit 0.
- `arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/stt-agent-gateway/stt-02/build.log 2>&1` -> exit 0.
- `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter 'SpeechAgentGatewayMappingTests|SpeechToTextContractTests'" > tmp/stt-agent-gateway/stt-02/test.log 2>&1` -> exit 0, 0 failures.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaCLI/SpeechTranscriptionAgentGateway.swift Tests/RielaCLITests/SpeechAgentGatewayMappingTests.swift' > tmp/stt-agent-gateway/stt-02/lint.log 2>&1` -> 0 violations.
- `git diff --exit-code -- Package.resolved` -> exit 0.

## Done criteria

- The Step 0 evidence is recorded with citations.
- Either all three providers are mapped and the tests above pass, or the plan is marked `blocked: scope-amendment-required` with evidence.
- `git grep -n "transcribeChunk" Sources/RielaCLI/SpeechTranscriptionAgentGateway.swift` returns nothing.
- Pre/post SHA-256 of the owned files is recorded. Follow the same fresh-read and drift rules as stt-01.
