# riela/speech-to-text: agent-gateway hosted STT, whisper-cpp, fallback chain

Status: accepted for implementation (opus-terra session 852, 2026-11-12).
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
- Riela owns the retry loop: one gateway call = exactly one vendor request.
  The mapping must disable any gateway-internal retry. Total vendor requests
  per provider are bounded by `maxAttempts`, and quota exhaustion issues
  exactly one request. These are required behaviours, not best-effort goals.
- The 25 MB upload limit and extension-based content type
  (`SpeechAudioUpload`) still apply before the gateway is called.
- `RielaCLI` already links `AgentGatewayAppCore` transitively via
  `RielaAdapters`; `Package.swift` adds the explicit product dependency to the
  `RielaCLI` target only. The agent-gateway pin (64361c28) is not changed.

Implementation precondition (first plan task): after `swift package resolve`,
read the pinned `GatewayTranscriptionParams` / `transcribe` / error types and
record in the impl plan, with file/line citations, the evidence that the
production mapping can:

1. preserve the HTTP status and vendor `error.code`/`error.type` (and
   `Retry-After` when sent) for every failed transcription, so §4 can classify
   it, and
2. issue exactly one vendor request per Riela attempt (internal retry off or
   absent).

The Riela-side contract (§2.1, §4, §5) does not change with the gateway's
shape; only the mapping code does. If the evidence shows the pinned gateway
cannot meet (1) or (2) for a provider, implementation stops for that provider
and the gap is escalated as an explicit scope amendment to the user. An
implementation that loses an available status/code, misclassifies quota
exhaustion, or exceeds the request bound must not be accepted. The
implementer must not invent gateway APIs, change the agent-gateway pin, or
fall back to Riela's HTTP client without that amendment.

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
| `rejected` | any other 4xx (auth, invalid request), unparseable response | no; never eligible for fallback |

- `providerProblem` = vendor `error.code`, else `error.type`, else Gemini
  `error.status`, read from the gateway error (or, for the three Riela HTTP
  providers, from the JSON body). The quota table is a single data table with
  table-driven tests.
- Backoff: `Retry-After` seconds when present, else `2^(attempt-1)` s; clamped
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
- production-boundary mapping tests, separate from the seam tests (they drive
  the production `SpeechTranscriptionGateway` implementation with a stubbed
  `GatewayExecuting`/vendor transport, whichever the pinned gateway allows,
  without network): an OpenAI `insufficient_quota` 429 body becomes
  `quota-exhausted` with `httpStatus=429` and
  `providerProblem=insufficient_quota`, and exactly 1 vendor request is
  counted; a `rate_limit_exceeded` 429 with `maxAttempts: 3` counts exactly 3
  vendor requests (not seam calls); a 503 keeps `httpStatus=503`.
- validation issues for each §7 rule; command and apple paths unchanged.

`MediaPipelineAddonRegistrationTests` / `MediaPipelineWorkflowDocumentationTests`
updated only as far as the docs/registration change requires.

Verification:
`arch -arm64 /bin/zsh -lc 'swift build'`,
`arch -arm64 /bin/zsh -lc 'swift test --filter SpeechProviderAddonTests'`,
`arch -arm64 /bin/zsh -lc 'swift test --filter MediaPipeline'`, `swiftlint`.

## 9. Risks

- R1 The gateway API shape at 64361c28 (fields, and whether the error type
  exposes status/vendor code) is confirmed only at implementation start
  (§2.1 precondition). A gap is a scope-amendment trigger, not an accepted
  degradation.
- R2 Gateway-internal retry: it must be disabled or absent (§2.1); the
  production-boundary request-count tests (§8) enforce this.
- R3 Linux media container: the openai path inside the container now runs the
  gateway client in the add-on worker; egress must stay `egress-allowed` as
  documented.
- R4 Cache: default `cacheAcceptsFallback: false` re-calls the primary after a
  fallback-produced transcript (cost, by design).
