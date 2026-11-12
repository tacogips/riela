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

- Design: `design-docs/specs/design-speech-to-text-agent-gateway.md` §2.1, §2.1.1, §4,
  §8 (production-boundary tests), §9 R1, R2, R5.
- Progress log: `impl-plans/progress/stt-02-gateway-mapping.md`.

## Amendment 2026-11-12 (session 854)

The session-852 `blocked: scope-amendment-required` status is withdrawn. The old pin
(64361c28) threw `GatewayRPCError(-32010, "vendor HTTP <status>: <first 500 bytes>")` and
dropped Retry-After. The pin is now agent-gateway v0.1.11
(`c659e9f0305e642d7c6e38582651ea2df16bfa16`, `Package.swift:82-85`, `Package.resolved`),
which throws the structured `GatewayTranscriptionFailure` (design §2.1.1). The partial
stt-02 code and tests in `tmp/stt-agent-gateway/partial-untracked/` parse the `-32010`
message text and are obsolete: rewrite them, do not reuse that mapping.

## Intent and context

Replace the stt-01 placeholder `agentGatewaySpeechTranscription` with the production
implementation. It maps a `SpeechTranscriptionRequest` onto `AgentGatewayAppCore`
`ProductionGatewayExecutor(environment:)` through the public `GatewayTranscribing`
protocol (`transcribe(GatewayTranscriptionParams)`), and maps `GatewayTranscriptionFailure`
/ `GatewayRPCError` to `SpeechProviderFailure` exactly as the design §2.1.1 tables say.

Patterns to follow:
- `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift:AgentGatewayExecutorFactory` and `defaultAgentGatewayExecutorFactory`: an injectable executor factory.
- `Sources/RielaAppSupport/RielaAppAssistantModelLoader.swift:models(for:)`: passes the API key by env-var *name* (`apiKeyEnvironment`).

## Step 0 — confirm the cited contract

1. Run `arch -arm64 /bin/zsh -lc 'swift package resolve'` and confirm
   `.build/checkouts/agent-gateway` is at `c659e9f` (read only, never edit it).
2. Re-check and record in the progress log, with `file:line` citations, the facts design
   §2.1.1 lists: `GatewayTranscriptionParams` fields (`GatewayTranscription.swift:7-42`),
   `GatewayTranscribing` and the `ProductionGatewayExecutor` conformance (`:56-77`), one
   transport call per `transcribe` and redirect refusal (`:81-142`),
   `GatewayTranscriptionFailure` fields and classification
   (`GatewayTranscriptionFailure.swift:7-116`), and `GatewayRPCError` codes
   -32011 / -32021 / -32602.
3. If a cited fact differs from the checkout, stop and report it as a design
   contradiction. Do not improvise a mapping, change the pin, or route back to Riela's HTTP
   client.

## Non-goals

- No orchestrator or cache changes (stt-04), and no edits to stt-01 types. If a contract gap is found, record it in the progress log as a blocker and do not edit `SpeechToTextContract.swift`.
- deepgram, elevenlabs, and google stay off the gateway.
- No pin or `Package.resolved` change.

## File-level changes

### `Package.swift`
- Add `.product(name: "AgentGatewayAppCore", package: "agent-gateway")` to the `RielaCLI` target's dependencies, next to the existing `AgentGateway` product entry (around line 269). No other change.
- `git diff Package.resolved` must stay empty.

### `Sources/RielaCLI/SpeechTranscriptionAgentGateway.swift`
- `func makeAgentGatewaySpeechTranscription(transcriberFactory: @escaping @Sendable ([String: String]) -> any GatewayTranscribing = { ProductionGatewayExecutor(environment: $0) }) -> SpeechTranscriptionGateway`.
  - Set `let agentGatewaySpeechTranscription = makeAgentGatewaySpeechTranscription()`.
- Request mapping (design §2.1.1 "Request mapping"):
  - provider -> `GatewayVendor` (`.openAI`, `.gemini`, `.openRouter`). `model` passes through.
  - `apiKeyEnvironment` = the provider's key name. Never pass the value.
  - Factory environment = `request.environment`, already allowlisted by stt-04.
  - `mimeType` = the `SpeechAudioUpload` content type. `timeoutSeconds` = `max(1, Int(ceil(timeoutSeconds)))`.
  - openai base URL: trim `/`, drop one trailing `/v1`, pass `<normalized>/v1`. gemini/openrouter: trim a trailing `/`. Unset -> nil (gateway default).
  - `language` and `prompt` only when non-empty.
- Error mapping (design §2.1.1, both tables):
  - `GatewayTranscriptionFailure`: `httpStatus` as is; `retryAfter = retryAfterSeconds`; `providerProblem` = `vendorErrorCode` when non-nil and not purely numeric (not `^[0-9]+$`), else `vendorErrorType`, then kept only if it matches `^[A-Za-z0-9_.:-]{1,64}$`. Numeric codes are skipped because the gateway stringifies integer `error.code` (`GatewayTranscriptionFailure.swift:91`; gateway test expects code "429", type "RESOURCE_EXHAUSTED" for Gemini). Do not use `vendorErrorCode ?? vendorErrorType`.
  - Class, first match wins: `quota-exhausted` if the gateway class is `quotaExhausted`, or `providerProblem` is in `SpeechFailureClassifier`'s quota code table, or `httpStatus == 429` and `SpeechFailureClassifier.isGeminiDailyQuota(Data(rawBody.utf8))` (stt-01 contract member; do not re-implement it). Otherwise `rateLimited` -> rate-limited, `serverError` -> server-error, `transport` -> transport-error, and `authFailed`/`invalidRequest`/`unknown` -> rejected.
  - `GatewayRPCError` -32011 / -32021 -> unavailable. Any other code -> rejected.
  - `CancellationError` is rethrown. `URLError` -> transport-error. Anything else -> rejected.
  - Message: label `"<provider> transcription"` plus the fields only. Never copy `message`, `vendorMessage`, `rawBody`, or `String(describing:)` of the error.
  - The returned text is used as-is. An empty transcript is valid.

## Pitfalls

- A request whose env lacks the key is caught by stt-04 before calling. Do not read the process environment here.
- Do not log the request, the environment, or the error description.
- The tests must not reach the network. The gateway transport is not publicly injectable, so stub `GatewayTranscribing`.

## Tests (`Tests/RielaCLITests/SpeechAgentGatewayMappingTests.swift`)

Drive `makeAgentGatewaySpeechTranscription(transcriberFactory:)` with a stub
`GatewayTranscribing`. The stub captures params and the factory environment, counts calls,
and throws real `GatewayTranscriptionFailure(...)` / `GatewayRPCError(...)` values (public
initializers). One stub call = one vendor request; cite design §2.1.1 in the progress log.
Retry cases run through `SpeechRetry.run` with a recording no-op sleep.

Cover every bullet of design §8 "production-boundary mapping tests":
- quota 429 `insufficient_quota` -> quota-exhausted, httpStatus 429, providerProblem `insufficient_quota`, 1 call with `maxAttempts` 3;
- `credit_balance_exhausted` and `billing_hard_limit_reached` -> quota-exhausted, 1 call;
- Gemini 429 stubs use the realistic gateway values `vendorErrorCode: "429"`, `vendorErrorType: "RESOURCE_EXHAUSTED"`, classification `rateLimited`: with a `PerDay` `QuotaFailure` in `rawBody` -> quota-exhausted, providerProblem `RESOURCE_EXHAUSTED`; without `PerDay` -> rate-limited, providerProblem `RESOURCE_EXHAUSTED` (never "429");
- OpenRouter 402 stub: `vendorErrorCode: "402"`, `vendorErrorType: nil`, httpStatus 402, classification `quotaExhausted` -> quota-exhausted, httpStatus 402, providerProblem absent;
- `rate_limit_exceeded` 429 with `retryAfterSeconds` 0 and `maxAttempts` 3 -> 3 calls, sleeps `[0, 0]`;
- 503 -> server-error with httpStatus 503; transport -> transport-error; 401 authFailed -> rejected, 1 call;
- `GatewayRPCError` -32011 -> unavailable; -32602 -> rejected;
- the key value and `SECRET-BODY` placed in `message`/`vendorMessage`/`rawBody` never appear in the Riela message;
- request mapping: openai base `https://x.test/v1/` -> `https://x.test/v1`, `apiKeyEnvironment` `OPENAI_API_KEY`, `mimeType`, ceil'd timeout; gemini and openrouter map to their vendors with the given model.

## Verification (evidence in `tmp/stt-agent-gateway/stt-02/`)

- `mkdir -p tmp/stt-agent-gateway/stt-02`
- `arch -arm64 /bin/zsh -lc 'swift package resolve' > tmp/stt-agent-gateway/stt-02/resolve.log 2>&1` -> exit 0.
- `arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/stt-agent-gateway/stt-02/build.log 2>&1` -> exit 0.
- `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter 'SpeechAgentGatewayMappingTests|SpeechToTextContractTests'" > tmp/stt-agent-gateway/stt-02/test.log 2>&1` -> exit 0, 0 failures.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaCLI/SpeechTranscriptionAgentGateway.swift Tests/RielaCLITests/SpeechAgentGatewayMappingTests.swift' > tmp/stt-agent-gateway/stt-02/lint.log 2>&1` -> 0 violations.
- `git diff --exit-code -- Package.resolved` -> exit 0.

## Done criteria

- The Step 0 confirmation is recorded with citations.
- All three providers are mapped and the tests above pass.
- `git grep -n "transcribeChunk" Sources/RielaCLI/SpeechTranscriptionAgentGateway.swift` returns nothing.
- Pre/post SHA-256 of the owned files is recorded. Follow the same fresh-read and drift rules as stt-01.

## Implementation progress

- Gateway mapping and stub boundary tests implemented; see `impl-plans/progress/stt-02-gateway-mapping.md` for contract citations and current verification. Formal review and downstream orchestration remain pending.
- Implementation criteria verified: build and 7 focused tests pass; selected-file lint passes; `Package.resolved` is unchanged. Independent review remains pending.
