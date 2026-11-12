# riela/speech-to-text: agent-gateway hosted STT, whisper-cpp, fallback chain

Status: accepted for implementation (opus-terra session 852, 2026-11-12).
Amended 2026-11-12 (session 854): agent-gateway pin moved to v0.1.11
(`c659e9f0305e642d7c6e38582651ea2df16bfa16`), which exposes the structured
`GatewayTranscriptionFailure`. §2.1.1 replaces the old "implementation
precondition"; the scope-amendment blocker from session 852 is resolved.
Baseline: `design-voice-assistant.md` § "`riela/speech-to-text` providers" and
`docs/workflows/speech.md`. Everything in that baseline remains in force except
where this document changes it. No GitHub issue.

## 1. Scope

1. `openai`, and the new `gemini` and `openrouter` providers, transcribe
   through agent-gateway (`AgentGatewayAppCore`
   `ProductionGatewayExecutor(environment:).transcribe(GatewayTranscriptionParams)`)
   instead of Riela's own multipart HTTP client
   (`MediaPipelineService+Stages.swift` `transcribeChunk`, which is removed;
   it has no other caller).
2. Every STT failure is classified. Quota/credit exhaustion fails at once
   with no retry; rate limits, 5xx and transport errors retry with backoff.
   Failures name the HTTP status and vendor problem code, never secrets.
3. New built-in `whisper-cpp` provider configured by `options.whisperCpp`.
4. Ordered fallback chain declared only in node config:
   `options.fallback` + `options.fallbackOn`.
5. `.stt.json` cache stays provider/model-aware when a fallback produced the
   text.
6. `riela workflow validate` rejects bad providers / fallback config.
7. `docs/workflows/speech.md` documents all of it.

Out of scope: `deepgram`, `elevenlabs`, `google` keep their Riela HTTP
clients (they only gain failure classification, §4), `riela/text-to-speech`,
Home Assistant and the shared `send` they use are unchanged, `apple` behaviour
is unchanged, the RielaApp is not touched.

## 2. Providers

| provider | transport | `addon.env` | model |
|---|---|---|---|
| `openai` (default) | agent-gateway transcription | `OPENAI_API_KEY` (required), `OPENAI_BASE_URL` | default `gpt-4o-transcribe` |
| `gemini` (new) | agent-gateway transcription | `GEMINI_API_KEY` (required), `GEMINI_BASE_URL` | required, no default |
| `openrouter` (new) | agent-gateway transcription | `OPENROUTER_API_KEY` (required), `OPENROUTER_BASE_URL` | required, no default |
| `deepgram`, `elevenlabs`, `google` | unchanged Riela HTTP | unchanged | unchanged |
| `apple` | unchanged (Speech framework, host only) | none | none |
| `command` | unchanged (`options.command` argv, `{{path}}`/`{{language}}`) | `COMMAND_*` | none |
| `whisper-cpp` (new) | host process `whisper-cli` | none | none (`whisperCpp.model` is the model file) |

`gemini`/`openrouter` require `model` because a hard-coded default would go
stale; a missing model is a validation error (§7).

### 2.1 Gateway mapping (openai / gemini / openrouter)

- A Riela-owned seam `SpeechTranscriptionGateway` (a `@Sendable` closure
  typealias, injected on `BuiltinWorkflowAddonResolver` next to
  `mediaPipelineHTTP`, default = production gateway) takes a Riela request
  `{provider, model, apiKeyEnvironmentName, baseURL?, audioFile, language?,
  prompt?, timeoutSeconds}` and returns the transcript text or throws
  `SpeechProviderFailure` (§4). Tests stub it; the default implementation is
  the only code that imports `AgentGatewayAppCore` for STT. This follows the
  existing `AgentGatewayExecutorFactory` fail-closed seam pattern.
- The production implementation builds `ProductionGatewayExecutor(environment:)`
  with the **resolved, allowlisted** addon env only (same values the provider
  used before) and maps the request onto `GatewayTranscriptionParams`, passing
  the API key by environment-variable name (as `GatewayModelCatalogParams`
  does with `apiKeyEnvironment`). Secret values never enter params, logs, or
  failure text.
- `OPENAI_BASE_URL` keeps its current meaning: the value may or may not end in
  `/v1`; the mapping normalizes it exactly as `transcribeChunk` did, so
  existing OpenAI-compatible servers (Groq, local whisper servers) keep
  working.
- Riela owns the retry loop: one gateway call = exactly one vendor request
  (guaranteed by the pinned gateway, §2.1.1). Total vendor requests per
  provider are bounded by `maxAttempts`, and quota exhaustion issues exactly
  one request. These are required behaviours, not best-effort goals.
- The 25 MB upload limit and extension-based content type
  (`SpeechAudioUpload`) still apply before the gateway is called. The content
  type is passed as `GatewayTranscriptionParams.mimeType`; a type the gateway
  does not accept (only `aiff`/`aif` today, which OpenAI also rejects) maps to
  `rejected` (§2.1.1), the same class the vendor 400 produced before.
- `RielaCLI` already links `AgentGatewayAppCore` transitively via
  `RielaAdapters`; `Package.swift` adds the explicit product dependency to the
  `RielaCLI` target only. The agent-gateway pin is v0.1.11
  (`c659e9f0305e642d7c6e38582651ea2df16bfa16`, `Package.swift:82-85`,
  `Package.resolved`) and is not changed by this work.

#### 2.1.1 Pinned gateway contract (agent-gateway v0.1.11, c659e9f)

Facts read from `.build/checkouts/agent-gateway/Sources/AgentGatewayAppCore`
(read-only) on 2026-11-12:

- `GatewayTranscriptionParams` (`GatewayTranscription.swift:7-42`): `vendor`
  (`.openAI`/`.gemini`/`.openRouter`), `model`, `audioFile` (file URL),
  `mimeType`, `language?`, `prompt?`, `apiKeyEnvironment?` (env-var **name**;
  default `OPENAI_API_KEY`/`GEMINI_API_KEY`/`OPENROUTER_API_KEY`,
  `GatewayAPIRequest.swift:44-53`), `baseURL?` (default
  `https://api.openai.com/v1`, `…/v1beta`, `https://openrouter.ai/api/v1`,
  `GatewayAPIRequest.swift:56-61`), `timeoutSeconds: Int` (> 0). No retry
  field exists.
- `ProductionGatewayExecutor` conforms to the public `GatewayTranscribing`
  protocol (`GatewayTranscription.swift:56-77`). Each `transcribe` call makes
  exactly one `transport(request, timeout)` call
  (`GatewayTranscriptionPipeline`, `GatewayTranscription.swift:121-142`) and
  refuses redirects (`GatewayTranscriptionRedirectRefusal`, `:81-115`), so a
  call is one vendor request. The transport is not publicly injectable.
- Failures (`GatewayTranscriptionFailure.swift`) are the public struct
  `GatewayTranscriptionFailure { vendor, classification, httpStatus?,
  retryAfterSeconds?, vendorErrorType?, vendorErrorCode?, vendorMessage?,
  rawBody?, message }` with `classification ∈ {quotaExhausted, rateLimited,
  serverError, authFailed, invalidRequest, transport, unknown}`. `rawBody` is
  the redacted body cut at 16 KiB; `retryAfterSeconds` parses delta-seconds
  and HTTP-date `Retry-After`; `vendorErrorType` falls back to Gemini
  `error.status`. Pre-flight problems throw `GatewayRPCError`: `-32011`
  missing credential, `-32021` unsupported vendor, `-32602` invalid input
  (file, size, MIME type, base URL, timeout). `CancellationError` passes
  through.

Mapping (`SpeechTranscriptionAgentGateway.swift`, the only STT importer of
`AgentGatewayAppCore`):

| gateway outcome | `SpeechProviderFailure` |
|---|---|
| `GatewayTranscriptionFailure` | `httpStatus` = `httpStatus`; `retryAfter` = `retryAfterSeconds`; `providerProblem` = `vendorErrorCode` when non-nil and not purely numeric (not `^[0-9]+$`), else `vendorErrorType`, then kept only if it matches `^[A-Za-z0-9_.:-]{1,64}$`; class per the next table |
| `GatewayRPCError` -32011 / -32021 | `unavailable` |
| `GatewayRPCError` -32602 or any other code | `rejected` |
| `CancellationError` | rethrown |
| anything else | `transport-error` if `URLError`, else `rejected` |

Numeric codes are skipped because the gateway stringifies integer `error.code`
values (`GatewayTranscriptionFailure.swift:91`; its own test expects
`vendorErrorCode == "429"`, `vendorErrorType == "RESOURCE_EXHAUSTED"` for a
Gemini 429). Such a code only repeats the HTTP status, and `vendorErrorType`
already falls back to Gemini `error.status`. So a real Gemini 429 yields
`RESOURCE_EXHAUSTED`. An OpenRouter 402 with `code: 402` and no type yields no
`providerProblem` (its class still comes from `httpStatus`).

Class of a `GatewayTranscriptionFailure`, first match wins:

1. `quota-exhausted` if the gateway class is `quotaExhausted`, or
   `providerProblem` is in the §4 quota code table (adds
   `billing_hard_limit_reached`, `billing_not_active` to the gateway's own
   list), or `httpStatus == 429` and `rawBody` contains a Gemini
   `QuotaFailure` violation whose `quotaId` contains `PerDay`.
2. Otherwise by gateway class: `rateLimited` → `rate-limited`,
   `serverError` → `server-error`, `transport` → `transport-error`,
   `authFailed`/`invalidRequest`/`unknown` → `rejected`.

`rawBody`, `vendorMessage` and the gateway `message` are used only for
classification; none of them is copied into the Riela failure message,
output, cache, or logs. The Riela message is built from the fields above only
(§4 format) and passed through `MediaPipelineRedaction`.

Request mapping: provider → vendor; `model` as configured;
`apiKeyEnvironment` = the provider's key name (never the value); executor
environment = the resolved, allowlisted addon env only; `timeoutSeconds` =
`max(1, ceil(timeoutSeconds))`; `language`/`prompt` only when non-empty.
`baseURL`: openai normalizes `OPENAI_BASE_URL` as `transcribeChunk` did (trim
`/`, drop one trailing `/v1`) and passes `<normalized>/v1`; gemini/openrouter
pass `*_BASE_URL` with trailing `/` trimmed; unset → `nil` (gateway default).

The production implementation takes an injectable
`@Sendable ([String: String]) -> any GatewayTranscribing` factory (default
`ProductionGatewayExecutor(environment:)`), following
`AgentGatewayExecutorFactory`. Because the transport is not injectable,
boundary tests stub `GatewayTranscribing` and throw real
`GatewayTranscriptionFailure`/`GatewayRPCError` values; one stub call counts as
one vendor request on the strength of the citation above.

### 2.2 whisper-cpp

`options.whisperCpp`:

| key | type | rule |
|---|---|---|
| `model` | string | required; absolute or working-directory-relative path to a ggml model file; must exist at run time (else `unavailable`) |
| `binary` | string | optional; absolute path or bare name. Default: `whisper-cli` on the resolved search path (resolver `PATH`, process `PATH`, `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`) — i.e. PATH first, then `/opt/homebrew/bin/whisper-cli` |
| `threads` | integer | optional, 1...64 → `-t N` |
| `extraArgs` | [string] | optional, ≤ 64 items, no NUL, each ≤ 4096 bytes; appended last |

argv: `<binary> -m <model> -f <audio path> -l <language or "auto"> -nt -np
[-t threads] [extraArgs…]`. stdout trimmed is the transcript (plain text, no
timestamps). It runs once per invocation (no retry, like `command`) through
the resolver's process runner with the same base environment as `command`
(`PATH`, `HOME`, `XDG_CACHE_HOME`; no `addon.env` keys). Missing binary or
model → `unavailable`; non-zero exit → `unavailable` with the redacted stderr
tail; timeout → `transport-error`. No audio conversion is done: input formats
are whatever the installed `whisper-cli` accepts (documented).

Host-only rule: a node that uses `whisper-cpp` (as primary or in `fallback`)
together with `addon.container` or `addon.sandbox` is rejected by validation
and at run time with: `speech-to-text provider 'whisper-cpp' runs on the host;
remove addon.container/addon.sandbox`. (The container path would otherwise run
the add-on in the Linux media image where the host binary and model are
absent.) `apple` keeps its current run-time `policyBlocked` in containers.

Run-time host-only check (amended 2026-11-12, STT-DESIGN-001). Static
validation skips templated values (§7), and the worker renders options only
after the container resolver has removed `addon.container`/`addon.sandbox`
(`BuiltinAddonContainerResolver.swift:138-140`,
`MediaPipelineAddons.swift:71-93`). So the run-time check must use the
**effective** options and must run on the host before any worker launches:

1. In `BuiltinAddonContainerResolver.executeUnprocessed`, for
   `riela/speech-to-text` with `addon.container` or `addon.sandbox` set, run
   the check right after the sandbox/container combination guard. That is
   before the image is selected, before the isolation metadata is stripped,
   and before any runner, admission or transport call.
2. Effective options are computed exactly as `MediaPipelineContext.finish`
   computes them. The raw keys `command` and `fallback` are removed, the rest
   of the config is rendered with
   `renderAddonConfig(_, variables: addonVariables(for:))`
   (`Sources/RielaAddonSupport/WorkflowAddonSupport.swift:42-67`) on the
   unmodified input, and the raw keys are put back unrendered.
3. The decision does not depend on whether the full parser accepts the
   options. The node is rejected with the host-only `policyBlocked` message
   above if either of these holds:
   - the effective `provider` is the string `whisper-cpp`;
   - any object in the raw `fallback` array has `provider == "whisper-cpp"`.

   A failure of `SpeechToTextOptionsParser.parse` therefore cannot bypass the
   check. If rendering itself throws, the resolver throws the same
   `invalidInput` error the worker would raise ("invalid speech-to-text option
   'options'") before launching the worker. Otherwise, for providers other
   than whisper-cpp, dispatch is unchanged and the worker reports any parse
   error as it does today.
4. Nothing else changes. Valid templated options still validate and run, raw
   `command`/`fallback` stay unrendered, `apple` keeps its policyBlocked
   behaviour in containers, and openai-only container/sandbox execution still
   dispatches to the media image.

## 3. Options (additions)

| option | type | default | rule |
|---|---|---|---|
| `provider` | string | `openai` | one of §2 |
| `whisperCpp` | object | — | only when the provider is `whisper-cpp` (like `command`) |
| `fallback` | [object] | none | 1...3 entries, tried in order after the primary |
| `fallbackOn` | [string] | all five classes | non-empty subset of `quota-exhausted`, `rate-limited`, `server-error`, `transport-error`, `unavailable`; only allowed with `fallback` |
| `cacheAcceptsFallback` | bool | `false` | §6 |

Fallback entry keys: `provider` (required) plus that provider's own keys —
`model`, `onDevice` (apple), `command` (command), `whisperCpp`
(whisper-cpp), `maxAttempts`, `timeoutSeconds`. `path`, `language`, `prompt`
and `cache*` are shared from the top level. Unknown keys, nested
`fallback`/`fallbackOn`, provider-specific keys on the wrong provider, and
unknown providers are invalid. `fallback` is passed through without template
rendering (added to `rawOptionKeys` like `command`), so its `command`
placeholders stay literal.

`addon.env` allowlist for the node = union of the allowlists of the primary
and every fallback provider (`COMMAND_*` admitted only if some entry is
`command`). Each provider receives only its own keys. A required key missing
for the primary with no fallback keeps today's `policyBlocked` error; inside a
chain a missing key is failure class `unavailable` for that provider.

## 4. Failure classification and retry

`SpeechProviderFailure { failureClass, httpStatus?, providerProblem?,
retryAfter?, message }` — `message` is passed through
`MediaPipelineRedaction` and contains no secret values or request bodies.

| class | source | retry within provider |
|---|---|---|
| `quota-exhausted` | vendor code `insufficient_quota`, `credit_balance_exhausted`, `billing_hard_limit_reached`, `billing_not_active`; any HTTP 402 (OpenRouter insufficient credits); Gemini 429 whose `QuotaFailure` quota id contains `PerDay` | no — stop at once |
| `rate-limited` | HTTP 429 not classified above (`rate_limit_exceeded`, Gemini `RESOURCE_EXHAUSTED`) | yes |
| `server-error` | HTTP 5xx | yes |
| `transport-error` | connection/DNS/TLS error, per-attempt timeout | yes |
| `unavailable` | provider cannot run here: missing credential, missing binary/model, `apple` platform/permission, local process non-zero exit | no |
| `rejected` | any other 4xx (auth, invalid request), unparseable response, gateway `authFailed`/`invalidRequest`/`unknown`, gateway `-32602` | no; never eligible for fallback |

- `providerProblem` = vendor `error.code` (string, non-numeric), else
  `error.type`, else Gemini `error.status`. On the gateway path it is read
  from the failure fields per the §2.1.1 rule (a numeric `vendorErrorCode` is
  skipped). For the three Riela HTTP providers it is read from the JSON body,
  where only string codes are taken. The quota table is a single
  data table with table-driven tests, shared by both paths.
- `fallbackOn` class mapping (answers the intake question): `authFailed` and
  `invalidRequest` are `rejected` and never fall back (a bad key or request
  would fail the same way everywhere it is reused, and silently masking it
  hides misconfiguration). `unavailable` covers a missing credential, an
  unsupported vendor, a missing whisper-cli binary/model, `apple`
  platform/permission refusal, and a local process non-zero exit.
- Backoff: `Retry-After` seconds when present (gateway `retryAfterSeconds` or
  the Riela HTTP header), else `2^(attempt-1)` s; clamped
  0...60 s; up to `maxAttempts` (unchanged, default 3, 1...8). If the node
  deadline would pass before the next attempt the loop stops with the last
  failure.
- `deepgram`/`elevenlabs`/`google` use an STT-only classified variant of the
  existing HTTP send (same retry statuses as today, plus 402 →
  `quota-exhausted` and body `code`/`type` extraction). TTS/HA keep `send`.
- Final failure (no fallback, or chain exhausted) is
  `AdapterExecutionError(.providerError, …, isRetryable: false for
  quota-exhausted/unavailable/rejected)` with a deterministic message:
  `speech-to-text provider 'openai' failed: failureClass=quota-exhausted
  httpStatus=429 providerProblem=insufficient_quota` (absent fields omitted);
  with a chain, one such clause per tried provider in order.
- Invalid options keep `.invalidInput`; the existing `policyBlocked` messages
  (env allowlist, missing key without fallback, apple) are unchanged.

## 5. Fallback execution

1. Try the primary with its own retry policy.
2. On failure, if its class is in `fallbackOn` and an entry remains, move to
   the next entry (quota exhaustion therefore moves on immediately, with no
   retries); otherwise fail (§4).
3. Each entry uses its own `maxAttempts`/`timeoutSeconds` (defaulting to the
   top-level values); the whole chain stays bounded by the node deadline.
4. On success the output is the existing shape, with `provider`/`model` of the
   provider that produced the text, plus — only when at least one provider
   failed first —

```json
"fallbackFrom": [ { "provider": "openai", "model": "gpt-4o-transcribe",
  "failureClass": "quota-exhausted", "httpStatus": 429,
  "providerProblem": "insufficient_quota" } ]
```

Without fallback the output is byte-for-byte the existing shape.

## 6. Cache (`<audio>.stt.json`)

- Fingerprint rule (documented): SHA-256 of the canonical JSON of the producing
  provider's identity — `provider`, `model`, `language`, `prompt`,
  `contentSHA256`, plus `baseURL` (remote), `command` (command), `onDevice`
  (apple), `whisperCpp.{binary as configured, model, threads, extraArgs}`
  (whisper-cpp). Identity fields for existing providers are unchanged, so
  existing cache files still hit (provider and model were already included).
- The file keeps one entry. New writes always store the producer metadata
  `provider` and `model` (and `fallbackFrom` when a fallback produced the text)
  beside `optionsFingerprint`/`text`. Legacy files have only
  `optionsFingerprint`/`text`.
- Lookup, in order:
  1. Entry fingerprint equals the **primary** identity → hit, legacy or not.
     The output reports the primary provider/model (the fingerprint proves the
     primary produced it). Existing caches keep hitting.
  2. Entry fingerprint equals a **fallback** entry's identity, and
     `cacheAcceptsFallback: true`, and the entry carries producer metadata
     (`provider`, `model`) → hit. The output reports the stored provider,
     model and `fallbackFrom`, with `cached: true`.
  3. Anything else is a miss. This includes a legacy (metadata-less) entry that
     matches only a fallback identity, even with `cacheAcceptsFallback: true`.
     No fallback history is invented for it. With the default `false`, a
     transcript produced by a fallback provider is never returned, so the next
     run tries the primary again.
- Write: after success, the entry is written with the producing provider's
  fingerprint plus producer metadata. `cache: false` disables read and write as
  today.

## 7. Validation (`riela workflow validate`)

Add a `riela/speech-to-text` case to
`BuiltinGatewayRequestChecks.extendedIssues` (the existing production
`addonRequestChecker`). It uses the same option parser as the run time and
skips values that contain `{{` (rendered later). Errors:

- `options.provider` / `fallback[i].provider` not in §2.
- `fallback` not an array of 1...3 objects; unknown/forbidden keys; per-entry
  option errors (e.g. `whisperCpp` without `model`, `command` on a non-command
  entry, `gemini`/`openrouter` without `model`).
- `fallbackOn` empty, containing a value outside the five, or present without
  `fallback`.
- `whisper-cpp` anywhere in the chain with `addon.container`/`addon.sandbox`.
- `addon.env` keys outside the chain's union allowlist.

## 8. Tests (all stubbed; no network, no real whisper)

`Tests/RielaCLITests/SpeechProviderAddonTests.swift` (existing OpenAI HTTP
assertions rewritten for the gateway seam):

- openai via stubbed gateway: same output fields; request mapping (model,
  language, prompt, key passed by env name, base URL normalization).
- classification table: each quota code → 1 attempt, `isRetryable == false`,
  message names `providerProblem`; 429 `rate_limit_exceeded` and 503 retry up
  to `maxAttempts` honouring `Retry-After`; 401 `rejected` no retry.
- gemini/openrouter selected via provider/model; missing model rejected.
- whisper-cpp with only `whisperCpp.model`: argv shape via stub runner,
  `language` empty → `-l auto`, threads/extraArgs placement.
- fallback openai → whisper-cpp on `insufficient_quota` (1 gateway call) and
  on 429 exhaustion (`maxAttempts` calls); `fallbackFrom` recorded; class not
  in `fallbackOn` does not fall back.
- cache: a fallback result is not served unless `cacheAcceptsFallback` is
  true; a modern fallback hit reports the stored producer provider/model and
  `fallbackFrom`; a legacy primary-fingerprint file (e.g. written by
  `provider: command`) still hits for the same command config. Regression: the
  same legacy command file under primary `openai` + identical `command`
  fallback + `cacheAcceptsFallback: true` is a **miss** (the stubbed gateway is
  called; the output is never labelled `openai` with command text).
- production-boundary mapping tests
  (`Tests/RielaCLITests/SpeechAgentGatewayMappingTests.swift`), separate from
  the seam tests. They drive the production `SpeechTranscriptionGateway`
  through its `GatewayTranscribing` factory with a stub that captures params,
  counts calls (= vendor requests, §2.1.1), and throws real
  `GatewayTranscriptionFailure` values:
  - `quotaExhausted`, 429, `vendorErrorCode=insufficient_quota` →
    `quota-exhausted`, `httpStatus=429`, `providerProblem=insufficient_quota`,
    1 call under `SpeechRetry` with `maxAttempts: 3`;
  - `credit_balance_exhausted` and `billing_hard_limit_reached` (gateway class
    `rateLimited`/`invalidRequest`) → `quota-exhausted`, 1 call;
  - Gemini 429 with the realistic gateway values `vendorErrorCode="429"`,
    `vendorErrorType="RESOURCE_EXHAUSTED"` and a `PerDay` `QuotaFailure` in
    `rawBody` → `quota-exhausted`, `providerProblem=RESOURCE_EXHAUSTED`;
    without `PerDay` → `rate-limited`, `providerProblem=RESOURCE_EXHAUSTED`;
  - OpenRouter 402 with `vendorErrorCode="402"`, `vendorErrorType=nil`, gateway
    class `quotaExhausted` → `quota-exhausted`, `httpStatus=402`, no
    `providerProblem`;
  - `rateLimited` 429 `rate_limit_exceeded` with `retryAfterSeconds=0` and
    `maxAttempts: 3` → 3 calls, recorded sleeps `[0, 0]`;
  - `serverError` 503 → `server-error`, `httpStatus=503`; `transport` →
    `transport-error`; `authFailed` 401 → `rejected`, 1 call;
  - `GatewayRPCError` -32011 → `unavailable`; -32602 → `rejected`;
  - a failure whose `message`/`vendorMessage`/`rawBody` contains the key value
    and the text `SECRET-BODY` → neither appears in the Riela message;
  - request mapping: openai base `https://x.test/v1/` → `https://x.test/v1`,
    `apiKeyEnvironment=OPENAI_API_KEY`, `mimeType` from `SpeechAudioUpload`,
    `timeoutSeconds` ceil'd; gemini/openrouter → their vendors and model.
- `Tests/RielaCLITests/MediaPipelineMediaLogicTests.swift` (in scope for the
  orchestrator plan because it calls the removed `transcribeChunk` /
  `MediaPipelineSTTOptions`): its three `transcribeChunk` tests are moved onto
  surviving code without lowering coverage — the 25 MB boundary on
  `SpeechAudioUpload.read` (25_000_000 accepted, 25_000_001 rejected), retry
  bound and no-secret 401 on the classified Riela HTTP send (the stub returns
  `Retry-After: 0` on retried responses so no real backoff sleep runs), base-URL
  normalization covered by the mapping tests above. All other tests in the
  file are unchanged.
- validation issues for each §7 rule; command and apple paths unchanged.
- run-time host-only regressions (§2.2), each run with `addon.container` and
  again with `addon.sandbox`, using a recording runner. Each of these must
  produce the exact host-only `policyBlocked` message with zero runner,
  worker or transport calls:
  - `provider: "{{input.p}}"` that renders to `whisper-cpp` with
    `whisperCpp.model` set;
  - literal `provider: "whisper-cpp"` with a templated numeric option (for
    example `maxAttempts: "{{input.n}}"` or `whisperCpp.threads:
    "{{input.t}}"`);
  - `provider: "openai"` with a raw `fallback: [{provider: "whisper-cpp",
    whisperCpp: {model: "m.bin"}}]`.

  Also, an openai-only config with a container still dispatches to the media
  image, and with a sandbox still reaches the worker launch path.

`MediaPipelineAddonRegistrationTests` / `MediaPipelineWorkflowDocumentationTests`
updated only as far as the docs/registration change requires.

Verification (logs under `tmp/stt-agent-gateway/`, exit status recorded):
`arch -arm64 /bin/zsh -lc 'swift build'`,
`arch -arm64 /bin/zsh -lc 'swift test --filter SpeechProviderAddonTests'`,
`arch -arm64 /bin/zsh -lc 'swift test --filter MediaPipelineMediaLogicTests'`,
`arch -arm64 /bin/zsh -lc 'swift test --filter MediaPipeline'`,
`arch -arm64 /bin/zsh -lc "swift test --filter 'SpeechAgentGatewayMappingTests|SpeechToText|SpeechWhisperCppAndHTTPTests'"`,
`swiftlint` on touched files, `git grep -n "transcribeChunk\|MediaPipelineSTTOptions" Sources Tests`
→ no matches.

## 9. Risks

- R1 Resolved by the v0.1.11 pin (§2.1.1): status, vendor type/code,
  `Retry-After` and a 16 KiB redacted body are exposed, so the 500-byte
  truncation that blocked session 852 no longer applies. A quota identifier
  beyond 16 KiB of body is not considered realistic and is not handled.
- R2 Resolved: the pinned `transcribe` has no retry and refuses redirects; one
  call is one request (§2.1.1). The request-count tests count stub calls, so
  a future gateway that adds internal retry would only be caught by re-reading
  the gateway on the next pin bump.
- R5 Partial edits in `tmp/stt-agent-gateway/partial-wave-001-003.patch` and
  `partial-untracked/` were written against the old pin. The stt-02 mapping
  and its tests there (message-regex parsing of `GatewayRPCError -32010`) are
  obsolete and must be rewritten to §2.1.1; stt-01/03/05/06 partials may be
  reused after review. Their design/plan hunks are superseded by this
  amendment and must not be re-applied.
- R3 Linux media container: the openai path inside the container now runs the
  gateway client in the add-on worker; egress must stay `egress-allowed` as
  documented.
- R4 Cache: default `cacheAcceptsFallback: false` re-calls the primary after a
  fallback-produced transcript (cost, by design).
