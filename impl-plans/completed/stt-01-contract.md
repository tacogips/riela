# stt-01 speech-to-text contract: providers, options chain, failure classes, retry, gateway seam

```json
{
  "planId": "stt-01-contract",
  "planPath": "impl-plans/active/stt-01-contract.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "Sources/RielaCLI/SpeechToTextContract.swift",
    "Sources/RielaCLI/MediaPipelineSpeechProviders.swift",
    "Sources/RielaCLI/SpeechTranscriptionAgentGateway.swift",
    "Sources/RielaCLI/ProductionNodeAdapter.swift",
    "Sources/RielaCLI/MediaPipelineAddons.swift",
    "Tests/RielaCLITests/SpeechToTextContractTests.swift",
    "impl-plans/progress/stt-01-contract.md"
  ],
  "sharedPaths": [],
  "artifactRoots": []
}
```

Artifacts: none. `.build/` is the shared SwiftPM cache and is owned by no plan.
Evidence logs go under the gitignored `tmp/stt-agent-gateway/stt-01/`.

- Design: `design-docs/specs/design-speech-to-text-agent-gateway.md` §2, §2.2 (options
  table only), §3, §4, §7 (rules only; wiring is stt-05).
- Progress log: `impl-plans/progress/stt-01-contract.md` (only this plan writes it).

## Intent and context

`riela/speech-to-text` (`Sources/RielaCLI/MediaPipelineAddons.swift:speechToText`) is
being changed in four ways. Hosted STT will go through agent-gateway. A `whisper-cpp`
provider is being added. Failures will be classified, and a node will be able to
declare a fallback chain in its config. This first-wave plan pins every shared
type, so that the wave-2 plans (stt-02 gateway mapping, stt-03 whisper-cpp and HTTP
classification, stt-05 validation, stt-06 docs) and the wave-3 plan (stt-04
orchestrator) can build on fixed shapes without editing this plan's files at the
same time.

## Amendment 2026-11-12 (session 854)

- Gateway v0.1.11 does not change this contract. The one addition is
  `SpeechFailureClassifier.isGeminiDailyQuota(_:)`, which stt-02 needs (design §2.1.1).
- A previous-run implementation of this plan exists (uncommitted):
  `tmp/stt-agent-gateway/partial-untracked/Sources/RielaCLI/SpeechToTextContract.swift`,
  `.../SpeechTranscriptionAgentGateway.swift`,
  `.../Tests/RielaCLITests/SpeechToTextContractTests.swift`, plus the stt-01 hunks for
  `MediaPipelineSpeechProviders.swift`, `ProductionNodeAdapter.swift` and `MediaPipelineAddons.swift`
  in `tmp/stt-agent-gateway/partial-wave-001-003.patch`. You may copy these into place, but
  first diff every symbol against this plan and fix any drift. Apply only Sources/Tests hunks
  for your own writePaths. Never apply the patch's design-docs or impl-plans hunks.

## Non-goals

- No change to the runtime transcription flow, cache, or output (stt-04 owns those).
- No agent-gateway import. The production gateway closure is a placeholder that
  stt-02 replaces.
- No whisper-cli execution and no HTTP classification wiring (stt-03 owns those).
- No `workflow validate` wiring (stt-05) and no docs (stt-06).
- Do not touch `Package.swift`, tests other than the new file, TTS, or Home Assistant.

## File-level changes

### `Sources/RielaCLI/MediaPipelineSpeechProviders.swift`
- `SpeechToTextProvider`: add `gemini`, `openrouter`, and `whisperCpp = "whisper-cpp"`.
  - `isRemote`: true for gemini and openrouter, false for whisperCpp.
  - `defaultModel`: nil for all three. Keep openai `gpt-4o-transcribe` and the
    deepgram/elevenlabs defaults exactly as they are.
  - `allowedEnvironment`, `apiKeyName`, `baseURLName`:
    - gemini: `GEMINI_API_KEY`, `GEMINI_BASE_URL`.
    - openrouter: `OPENROUTER_API_KEY`, `OPENROUTER_BASE_URL`.
    - whisperCpp: none.
  - `defaultBaseURL`: nil for the three new cases. Keep openai `https://api.openai.com`,
    because the cache fingerprint depends on it.
  - Add `var viaAgentGateway: Bool` (true for openai, gemini, openrouter) and
    `var requiresModel: Bool` (true for gemini and openrouter).
- Do not touch the deepgram/elevenlabs/google functions (stt-03 owns those edits).

### `Sources/RielaCLI/SpeechToTextContract.swift` (new)

The data shapes are a contract and their names must be exact.

- `enum SpeechFailureClass: String, CaseIterable, Sendable`
  - Cases: `quotaExhausted = "quota-exhausted"`, `rateLimited = "rate-limited"`,
    `serverError = "server-error"`, `transportError = "transport-error"`,
    `unavailable`, `rejected`.
  - `static let fallbackEligible: Set<Self>` holds the first five. `static let defaultFallbackOn` has the same value.
  - `var isRetryable: Bool` is true only for rateLimited, serverError, and transportError.
- `struct SpeechProviderFailure: Error, Equatable, Sendable, LocalizedError`
  - Fields: `failureClass`, `httpStatus: Int?`, `providerProblem: String?`,
    `retryAfter: Double?`, `message: String`.
  - `var fields: String` renders exactly `failureClass=<c>[ httpStatus=<n>][ providerProblem=<p>]`.
  - `errorDescription` is `"\(fields): \(message)"`.
  - `message` must never contain request bodies, headers, URLs with query strings, or env values.
- `enum SpeechFailureClassifier`
  - `static let quotaCodes: Set<String>` = `insufficient_quota`, `credit_balance_exhausted`,
    `billing_hard_limit_reached`, `billing_not_active`.
  - `static func isGeminiDailyQuota(_ body: Data) -> Bool` returns true when the JSON has an
    `error.details[]` entry whose `@type` ends in `google.rpc.QuotaFailure` and some
    `violations[].quotaId` contains `PerDay`. Invalid JSON returns false. stt-02 reuses it
    on the gateway `rawBody`, so this is a contract member.
  - `static func providerProblem(fromJSON body: Data) -> String?` returns the first of
    `error.code` (string only), `error.type`, `error.status`. If none is present it returns nil.
  - `static func classify(httpStatus: Int, body: Data?, retryAfter: Double?, label: String) -> SpeechProviderFailure`
    applies these rules in order:
    1. A provider problem in quotaCodes means quotaExhausted.
    2. HTTP 402 means quotaExhausted.
    3. HTTP 429 with `isGeminiDailyQuota(body) == true` means quotaExhausted.
    4. Any other 429 means rateLimited.
    5. 5xx means serverError.
    6. Any other status means rejected.
    - `message` is `"<label> returned HTTP <status>"`.
  - `static func transport(_ label: String) -> SpeechProviderFailure` returns transportError with
    the message `"<label> request failed"`.
- `enum SpeechRetry`
  - Signature: `static func run<T: Sendable>(maxAttempts: Int, deadline: Date?, now: @Sendable () -> Date = Date.init, sleep: @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }, operation: @Sendable (_ attempt: Int) async throws -> T) async throws -> T`
  - Rules:
    - Retry only a `SpeechProviderFailure` whose class `isRetryable`, and only while `attempt < maxAttempts`.
    - delay = `retryAfter ?? 2^(attempt-1)`, clamped to 0...60.
    - If `deadline != nil` and `now() + delay >= deadline`, rethrow the last failure.
    - Rethrow every other error, including `CancellationError`, unchanged and without retrying.
- `struct WhisperCppOptions: Equatable, Sendable` with fields `binary: String?`, `model: String`, `threads: Int?`, `extraArgs: [String]`.
- `struct SpeechProviderConfig: Equatable, Sendable` with fields `provider: SpeechToTextProvider`,
  `model: String?` (already defaulted from `provider.defaultModel`), `onDevice: Bool`,
  `command: [String]`, `whisperCpp: WhisperCppOptions?`, `maxAttempts: Int`, `timeoutSeconds: Double`.
- `struct SpeechToTextChain: Equatable, Sendable`
  - Fields: `primary`, `fallback: [SpeechProviderConfig]`, `fallbackOn: Set<SpeechFailureClass>`,
    `cacheAcceptsFallback: Bool`.
  - `var providers: [SpeechProviderConfig]` lists the primary first, then the fallback entries.
  - `var environmentAllowlist: (keys: [String], allowsCommandPrefix: Bool)` is the union over
    all providers, sorted and deduplicated. `allowsCommandPrefix` is true when any provider is `.command`.
  - `var usesWhisperCpp: Bool`.
- `enum SpeechToTextOptionsParser`
  - Signature: `static func parse(_ options: JSONObject) throws -> SpeechToTextChain`. It throws
    `MediaPipelineError.invalidOption(<name>)`. Top-level option names are unchanged
    (`provider`, `model`, `command`, `maxAttempts`, `timeoutSeconds`, `onDevice`). New names:
    `whisperCpp`, `whisperCpp.model`, `whisperCpp.binary`, `whisperCpp.threads`,
    `whisperCpp.extraArgs`, `fallback`, `fallback[<i>]`, `fallback[<i>].<key>`,
    `fallbackOn`, and `cacheAcceptsFallback`.
  - Rules (design §3 and §7):
    - The provider default is openai. An unknown provider fails with `provider`.
    - `maxAttempts` is in 1...8 with default 3. `timeoutSeconds` is in 1...3600 with default 300.
      Use `MediaPipelineOptions.number` the same way `speechToText` does today.
    - `command` is accepted only for the command provider and is parsed with `commandArgv`.
    - `whisperCpp` is accepted only for whisper-cpp, and whisper-cpp requires it.
      - `model` is a required non-empty string.
      - `binary` is an optional non-empty string with no NUL.
      - `threads` is an integer in 1...64.
      - `extraArgs` is an array of at most 64 strings, each with no NUL and at most 4096 bytes.
      - Unknown keys are rejected.
    - `onDevice` is a bool and is accepted only for apple (today it is read for every provider;
      keep accepting it on the top level for any provider to stay backward compatible, but
      reject it in fallback entries whose provider is not apple).
    - gemini and openrouter without `model` fail with `model` or `fallback[i].model`.
    - `fallback` is an array of 1...3 objects. Each entry allows only `provider` (required),
      `model`, `onDevice`, `command`, `whisperCpp`, `maxAttempts`, and `timeoutSeconds`.
      `maxAttempts` and `timeoutSeconds` default to the top-level values.
    - `fallbackOn` is a non-empty array of distinct strings from the five fallback-eligible classes.
      It is only allowed together with `fallback`. It defaults to all five.
    - `cacheAcceptsFallback` is a bool with default false.
    - Parsing does not read `path`, `language`, `prompt`, or `cache`.
  - Signature: `static func isTemplated(_ value: JSONValue?) -> Bool` returns true when a string
    contains `{{`. stt-05 uses it to skip provider values that are not yet rendered.
- `struct SpeechTranscriptionRequest: Equatable, Sendable`
  - Fields: `provider: SpeechToTextProvider`, `model: String`, `apiKeyEnvironmentName: String`,
    `environment: [String: String]`, `baseURL: String?`, `audioFile: URL`, `language: String?`,
    `prompt: String?`, `timeoutSeconds: Double`.
  - `environment` is the provider's own allowlisted keys merged over PATH, HOME, and XDG_CACHE_HOME.
  - `baseURL` is the raw env value or nil. stt-02 normalizes it.
- `typealias SpeechTranscriptionGateway = @Sendable (SpeechTranscriptionRequest) async throws -> String`
  - One call must make exactly one vendor request.
  - It throws `SpeechProviderFailure`, and passes `CancellationError` through.

### `Sources/RielaCLI/SpeechTranscriptionAgentGateway.swift` (new, placeholder)
- `let agentGatewaySpeechTranscription: SpeechTranscriptionGateway`. The placeholder always
  throws `SpeechProviderFailure(failureClass: .unavailable, …, message: "agent-gateway transcription is not wired")`.
- stt-02 replaces the body. Do not import AgentGatewayAppCore here.

### `Sources/RielaCLI/ProductionNodeAdapter.swift`
- `BuiltinWorkflowAddonResolver`: add `var speechTranscriptionGateway: SpeechTranscriptionGateway`.
- Add the init parameter `speechTranscriptionGateway: @escaping SpeechTranscriptionGateway = agentGatewaySpeechTranscription`
  directly after `mediaPipelineHTTP`, and assign it.
- Follow the pattern of `mediaPipelineHTTP` (around lines 401, 426, and 448). Change nothing else.

### `Sources/RielaCLI/MediaPipelineAddons.swift`
- This is the minimum needed to compile. In `speechToText`'s `switch provider`, add
  `case .gemini, .openrouter, .whisperCpp: throw MediaPipelineStageError.option("provider")`.
- stt-04 replaces this. No other edit.

## Pitfalls

- Do not change the raw values of existing providers, their env names, or openai's
  `defaultBaseURL`. Existing `.stt.json` fingerprints depend on them.
- `SpeechRetry` must never sleep after the final attempt, and must never retry `rejected`,
  `unavailable`, or `quotaExhausted`.
- The classifier must not echo the response body into `message`.
- `JSONValue` numbers can be `.integer` or `.number`. Accept integral `.number` values for
  `threads` and `maxAttempts` only where `MediaPipelineOptions.number` already does.

## Tests (`Tests/RielaCLITests/SpeechToTextContractTests.swift`)

Parser cases (input -> expected outcome):
- `{}` -> primary openai, model `gpt-4o-transcribe`, no fallback, fallbackOn = the five classes, cacheAcceptsFallback false.
- `{provider:"x"}` -> invalidOption `provider`.
- `{provider:"gemini"}` -> invalidOption `model`.
- `{provider:"openrouter", model:"m"}` -> ok.
- `{provider:"whisper-cpp"}` -> invalidOption `whisperCpp`.
- `{provider:"whisper-cpp", whisperCpp:{model:"/m.bin"}}` -> ok, binary nil, extraArgs [].
- `whisperCpp` with threads 0, threads 65, or the unknown key `foo` -> invalid.
- `whisperCpp` with provider openai -> invalid.
- `fallback` of [] or 4 entries, an entry that is not an object, a nested `fallback`, or an entry with an unknown key -> invalid with an indexed name.
- `fallbackOn` set to ["rejected"], [], or ["rate-limited","rate-limited"], or given without `fallback` -> invalid `fallbackOn`.
- Fallback entry `{provider:"command", command:["w","{{path}}"]}` keeps the argv literally.
- `environmentAllowlist` for openai + [command] -> OPENAI keys plus allowsCommandPrefix true.

Classifier cases (input -> expected outcome):
- 429 with `{"error":{"code":"insufficient_quota"}}` -> quotaExhausted with providerProblem insufficient_quota.
- 429 with `credit_balance_exhausted` -> quotaExhausted.
- 429 with `rate_limit_exceeded` -> rateLimited.
- 402 with no body -> quotaExhausted.
- `isGeminiDailyQuota`: PerDay QuotaFailure body -> true; PerMinute -> false; invalid JSON -> false.
- Gemini 429 with a PerDay QuotaFailure -> quotaExhausted. Gemini 429 with a PerMinute QuotaFailure -> rateLimited, providerProblem RESOURCE_EXHAUSTED.
- 503 -> serverError. 401 -> rejected.
- A body containing "sk-secret" -> the message does not contain it.

Retry cases (with recorded `sleep` and a fixed `now`):
- 3 rateLimited failures with maxAttempts 3 -> 3 operations and sleeps [1,2]. With retryAfter 0 -> sleeps [0,0].
- retryAfter 120 -> sleep clamped to 60.
- quotaExhausted -> 1 operation and no sleep.
- A deadline that the next delay would pass -> stops early.
- CancellationError -> rethrown after 1 operation.

## Verification (evidence in `tmp/stt-agent-gateway/stt-01/`)

- `mkdir -p tmp/stt-agent-gateway/stt-01`
- `arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/stt-agent-gateway/stt-01/build.log 2>&1` -> exit 0.
- `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter 'SpeechToTextContractTests|SpeechProviderAddonTests|MediaPipeline'" > tmp/stt-agent-gateway/stt-01/test.log 2>&1`
  -> exit 0 and 0 failures. Existing speech tests still pass unchanged, because openai still uses the old path in this wave.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaCLI/SpeechToTextContract.swift Sources/RielaCLI/MediaPipelineSpeechProviders.swift Sources/RielaCLI/SpeechTranscriptionAgentGateway.swift Sources/RielaCLI/ProductionNodeAdapter.swift Sources/RielaCLI/MediaPipelineAddons.swift Tests/RielaCLITests/SpeechToTextContractTests.swift' > tmp/stt-agent-gateway/stt-01/lint.log 2>&1`
  -> 0 new violations in the touched lines.
- `git diff --stat -- Sources/RielaCLI/MediaPipelineAddons.swift` -> only the single switch-arm addition.

## Done criteria

- Every type and member named above exists with the exact names, and the tests above pass.
- `git grep -n "import AgentGatewayAppCore" Sources/RielaCLI/SpeechTranscriptionAgentGateway.swift` returns nothing.
- The progress log records the commands, exit codes, test counts, and pre/post SHA-256 of each owned file.

## Concurrency and progress rules

- Before every edit, re-read the file fresh and record its SHA-256 and a one-line intent in the evidence directory.
- After every edit, record the SHA-256 again. If the pre-hash does not match your last post-hash, the file drifted: stop, re-read it, and re-apply only your intent.
- Write only the progress log listed for this plan.

## Implementation progress (2026-11-12)

Contract, placeholder seam, and focused tests implemented; build, 45 selected tests, and selected-file lint passed. Formal review and integration remain downstream. See `impl-plans/progress/stt-01-contract.md` for evidence.
