# Official SDK Adapter Improvements (MacPaw/OpenAI-Informed)

## Summary

Riela's `official/*-sdk` backends (`official-openai-sdk`, `official-anthropic-sdk`,
`official-gemini-sdk`, `official-cursor-sdk`) are implemented as a self-built
URLSession HTTP client in `Sources/RielaAdapters/OfficialSDKAdapters.swift`.
They work, but they are blocking-only, hand-roll every request/response as
ad-hoc `JSONValue` pattern matching, discard provider usage data, retry with a
fixed delay, and expose no extension hooks.

This document specifies improvements to that self-built AI SDK layer, using the
architecture of the MacPaw/OpenAI Swift package (MIT, actively maintained,
v0.5.0 2026-06) as the design reference. We do **not** add MacPaw/OpenAI as a
dependency — it covers only OpenAI-compatible providers while Riela speaks four
native provider protocols — but we adopt its proven structural patterns:

1. A spec-compliant **SSE parser** separated from per-provider JSON
   interpretation, with cross-chunk incomplete-line buffering and error-body
   sniffing on stream data.
2. **Typed Codable request/response models** per provider instead of ad-hoc
   `JSONValue` navigation, with an opt-in **tolerant decoding** option set for
   OpenAI-compatible third-party endpoints.
3. **Typed API error envelopes** decoded before the success type, feeding an
   error classification that drives retry decisions (429/5xx retryable with
   backoff + `retry-after`; 4xx not).
4. A reduce-style **middleware chain** over request, response, and streaming
   data (logging, header injection) plus richer configuration
   (`customHeaders`, per-request timeout, custom `URLSession`).
5. **Usage/token extraction** from every provider response, emitted through the
   existing `AdapterBackendEvent` `.usage` channel and surfaced on the adapter
   output.

This is the "separate effort" that `design-agent-response-streaming.md`
explicitly deferred in its Non-Goals ("Streaming for `official/*-sdk` backends
... SSE support there is a separate effort"). The streaming design below plugs
into the contracts that document already shipped (`AdapterBackendEvent`
channels, the runner-side coalescer/ring-buffer, `WorkflowRunEvent`
enrichment), so no new runner or store surface is required.

## Review Follow-Up Slice (2026-07-06)

The initial implementation landed in commit `76ed0cb` and a follow-up
adversarial review found streaming, fallback, codec, environment-toggle, and
test-coverage defects. The corrected implementation remains design-consistent
when these boundaries hold:

- `ServerSentEventsParser` stays a provider-agnostic RielaAdapters primitive:
  it strips a leading UTF-8 BOM, accepts CRLF/CR/LF line endings, ignores
  comments, joins repeated `data:` fields with newlines, buffers incomplete
  lines across chunks, and flushes a trailing event on `finish()`.
- The `OfficialSDKAdapters.swift` split is a boundary cleanup only:
  request/transport orchestration remains in the adapter, response text and
  usage extraction live in `OfficialSDKCodecs.swift`, and typed
  non-2xx error envelope handling lives in `OfficialSDKErrors.swift`.
- Usage crosses the adapter/core boundary as optional `AdapterUsage` in
  RielaCore. Blocking official-SDK responses emit one
  `AdapterBackendEvent(channel: .usage, eventType: "response.usage")`, return
  `AdapterExecutionOutput.usage`, and persist the same usage on
  `WorkflowStepExecution.usage`. The event payload keeps normalized snake_case
  token keys plus `provider_raw`.
- Retry classification is additive: `AdapterExecutionError.isRetryable` and
  `retryAfter` are optional so non-SDK callers retain existing code-based retry
  behavior. Official SDK non-retryable 4xx responses stop retry immediately;
  408, 409, 429, 5xx, and transport failures remain retryable; `Retry-After`
  is capped by `RetryPolicy.maxDelay` and the deadline.
- Cursor remains a blocking official-SDK job adapter in this slice. Cursor has
  no SSE streaming contract, no usage payload unless a future provider response
  adds one, and only generic error-envelope fallback. Cursor-specific behavior
  stays isolated in adapter response extraction and request-building modules;
  no `cursor-cli-agent` or `codex-agent` behavior changes are part of this
  work.
- Streaming fallback is observational only: stream transport failures may fall
  back to one blocking attempt, but output-contract validation failures,
  policy failures, and cancellation do not trigger a second provider call.
- Operator controls win over node configuration: process-level
  `RIELA_OFFICIAL_SDK_STREAMING=off` disables streaming even if adapter or node
  environment values say otherwise.
- Accepted behavior deviations from the pre-codec implementation are
  intentional: empty OpenAI `output_text` falls through to segmented output,
  1xx/3xx HTTP responses are non-retryable provider errors, and injected
  request executors bypass HTTP middleware/header/timeout construction for
  deterministic tests.

## Reference: MacPaw/OpenAI feature inventory (what we borrow)

| MacPaw/OpenAI feature | Borrow? | Riela translation |
|---|---|---|
| `Configuration` (token, host, basePath, port, timeoutInterval, customHeaders applied last) | Yes | Extend `OfficialSDKAdapterConfiguration` with `customHeaders`, `timeout` |
| Protocol split by call style (closure/async/Combine) under one umbrella | Partially | Riela is async-only; keep `OfficialSDKRequestExecuting`, add a streaming sibling protocol |
| `ServerSentEventsStreamParser` (WHATWG §9.2.6: BOM strip, CRLF/CR/LF, comments, incomplete-line buffering) | Yes | New `ServerSentEventsParser` in RielaAdapters |
| `ServerSentEventsStreamInterpreter` (error-body sniffing before parse, `[DONE]` skip, typed decode per event) | Yes | Per-provider stream interpreters producing `AdapterBackendEvent`s |
| `ParsingOptions` (`.fillRequiredFieldIfKeyNotFound`, `.relaxed`) for Gemini/DeepSeek/OpenRouter compatibility | Yes | `OfficialSDKParsingOptions` OptionSet on the OpenAI codec (custom `baseURL` endpoints) |
| `APIErrorResponse` typed error decode before success decode | Yes | Per-provider error envelope types + `OfficialSDKErrorClassification` |
| `OpenAIMiddleware` (intercept request / response / streaming data) | Yes | `OfficialSDKMiddleware` protocol, reduced in order |
| Custom `URLSession` injection, `SSLDelegateProtocol` | Partially | Custom `URLSession` injection (transport already pluggable); SSL pinning out of scope |
| `CancellableRequest` closure-style cancellation | No | Swift structured-concurrency `Task` cancellation already covers this (`runWithDeadline`) |
| `JSONSchemaConvertible` derived structured outputs | Deferred | Riela's output contract is workflow-level; provider-native JSON schema mode is a later phase |
| Assistants/Images/Audio/Embeddings endpoints | No | Out of Riela's node-execution scope |

## Current Architecture (verified 2026-07-06)

- Adapters: `OpenAiSDKAdapter` (`Sources/RielaAdapters/OfficialSDKAdapters.swift:238`),
  `AnthropicSDKAdapter` (`:279`), `GeminiSDKAdapter` (`:320`),
  `CursorSDKAdapter` (`:361`), all `NodeAdapter`s routed by
  `DispatchingNodeAdapter` (`Sources/RielaAdapters/DispatchingNodeAdapter.swift:32`).
- Requests are built in `makeURLRequest(for:)` (`OfficialSDKAdapters.swift:576-678`)
  as hand-assembled `JSONObject`s; responses are decoded to `JSONValue` and
  navigated by per-provider extractors (`extractOpenAIText` `:735`,
  `extractAnthropicText` `:766`, `extractGeminiText` `:786`,
  `extractCursorAgentText` `:814`).
- Transport: `URLSessionOfficialSDKHTTPTransport` (`:203`) —
  `URLSession.shared.data(for:)`, no timeout config, no headers hook.
- Errors: non-2xx throws `AdapterExecutionError(.providerError)` with the
  redacted body (`:222-235`); the provider's structured error JSON is never
  decoded; status codes are not classified.
- Retry: `executeWithRetry` (`Sources/RielaAdapters/AdapterUtilities.swift:105-146`)
  — fixed `retryDelay` (default 50 ms), `maxAttempts` (default 2), retries
  `providerError`/`timeout` indiscriminately; no backoff, no jitter, no
  `Retry-After`, no 429/5xx distinction.
- Timeouts: `runWithDeadline` task-race (`OfficialSDKAdapters.swift:517-546`);
  deadline is not propagated into `URLRequest.timeoutInterval`.
- Usage: every provider returns usage
  (`usage` on OpenAI Responses / Anthropic Messages, `usageMetadata` on
  Gemini) but the extractors drop it. `AdapterBackendEvent.usage: JSONObject?`
  and the `.usage` channel already exist
  (`Sources/RielaCore/AdapterContracts.swift:63-98`) and official SDK adapters
  never emit any backend event.
- Streaming: none. `LocalAgentCommandAdapter` (CLI agents) already streams
  line events through an `AsyncStream` bridge + `BackendEventCoalescer` into
  `WorkflowRunEvent` JSONL and the runtime-store live tail
  (`design-agent-response-streaming.md` Phase 1, shipped).
- Tests: `Tests/RielaAdaptersTests/OfficialSDKAdapterTests.swift` (request
  building, extraction, retry, redaction) with `RecordingOfficialSDKExecutor` /
  `RecordingOfficialSDKHTTPTransport` mocks.

### Gaps

- **G1 — No streaming.** Official SDK nodes are invisible while running: no
  heartbeat, no assistant/thinking tail, no auto-improve stall signal, unlike
  CLI agent backends after the agent-response-streaming Phase 1 work.
- **G2 — Usage dropped.** Token accounting exists in every provider response
  and in the `AdapterBackendEvent` contract, but is never extracted. (The
  loop-engineering design also depends on usage reaching persistence.)
- **G3 — Untyped codecs.** Hand-rolled `JSONValue` construction and
  pattern-matching extraction are duplicated per provider, silently ignore
  unknown shapes, and give no compile-time safety.
- **G4 — Opaque errors, naive retry.** Provider error envelopes are thrown as
  redacted strings; retry treats a 401 the same as a 529, with a fixed 50 ms
  delay and no `retry-after` support.
- **G5 — No extension hooks.** No custom headers, no request/response
  logging seam, no per-adapter `URLSession`/timeout configuration.
- **G6 — No tolerant decode for OpenAI-compatible hosts.** A custom
  `OPENAI_BASE_URL` pointing at an OpenAI-compatible server (OpenRouter,
  DeepSeek, local inference) fails on minor response-shape deviations.
- **G7 — Capability gaps (deferred).** No provider-native structured output,
  no tool calling, no Anthropic vision. Tracked as a later phase, not this
  effort's core.

## Goals

- Stream official SDK responses live (assistant deltas, thinking where the
  provider exposes it, usage, lifecycle) through the **existing**
  `AdapterBackendEvent` → runner coalescer → `WorkflowRunEvent` JSONL /
  runtime-store live-tail pipeline. No new consumer surface.
- Preserve the completion contract exactly: `AdapterExecutionOutput` built
  from the full accumulated response remains the source of truth; a streaming
  failure downgrades to the buffered path rather than failing the node.
- Extract and propagate usage on every response (streaming and blocking) via
  `.usage` backend events and a typed field on the adapter output.
- Replace ad-hoc JSON handling with typed Codable request/response models per
  provider, with opt-in tolerant decoding for OpenAI-compatible hosts.
- Decode provider error envelopes into typed errors; classify status codes;
  retry with exponential backoff + full jitter, honoring `retry-after`.
- Add a middleware chain and configuration extensions (custom headers,
  timeout, custom session) without breaking existing configuration call sites.
- Keep all changes backward compatible: existing `OfficialSDKRequestExecuting`
  mocks, `AnthropicSDKAdapterConfiguration`, and persisted session schemas
  keep working unchanged.

## Non-Goals

- Adding MacPaw/OpenAI (or any provider SDK) as a SwiftPM dependency.
- New read surfaces (GraphQL subscriptions, viewer panes, `session logs
  --follow`) — covered by the agent-response-streaming rollout phases.
- Assistants, images-generation, audio, embeddings, moderations endpoints.
- Closure/Combine API variants — Riela is async/await-only.
- SSL pinning / custom TLS delegates.
- Changing CLI-agent (`codex-agent`, `claude-code-agent`, `cursor-cli-agent`)
  adapters.
- Provider-native structured outputs, tool calling, and Anthropic vision are
  specified as **Phase 4** boundaries only; implementation is a follow-up
  plan.

## Design

### 1. Typed provider codecs (G3, G6)

New file `Sources/RielaAdapters/OfficialSDKCodecs.swift`. Each provider gets a
codec namespace with Codable wire models and two functions:

```swift
protocol OfficialSDKProviderCodec: Sendable {
  associatedtype WireResponse: Decodable & Sendable
  func encodeRequestBody(_ body: OfficialSDKRequestBody) throws -> Data
  func decodeResponse(_ data: Data, options: OfficialSDKParsingOptions) throws -> OfficialSDKDecodedResponse
}

public struct OfficialSDKParsingOptions: OptionSet, Sendable {
  public let rawValue: Int
  public static let fillRequiredStringIfMissing = Self(rawValue: 1 << 0)
  public static let ignoreUnknownEnumValues     = Self(rawValue: 1 << 1)
  public static let relaxed: Self = [.fillRequiredStringIfMissing, .ignoreUnknownEnumValues]
}

public struct OfficialSDKDecodedResponse: Sendable {
  public var text: String
  public var usage: AdapterUsage?
  public var stopReason: String?
  public var raw: JSONValue        // preserved for output-contract handling
}
```

Wire models (response side; request side mirrors today's fields):

- **OpenAI Responses**: `OpenAIResponsesWire.Response { output_text?, output[],
  usage { input_tokens, output_tokens, total_tokens } , status }`.
- **Anthropic Messages**: `AnthropicWire.Message { content[] (text blocks),
  stop_reason, usage { input_tokens, output_tokens,
  cache_creation_input_tokens?, cache_read_input_tokens? } }`.
- **Gemini**: `GeminiWire.GenerateContentResponse { candidates[],
  usageMetadata { promptTokenCount, candidatesTokenCount, totalTokenCount } }`.
- **Cursor**: `CursorWire.Agent { id, status, result?, latestRunId?, url? }`
  (no usage).

Tolerant decoding (MacPaw `ParsingOptions` analog) applies to the OpenAI codec
only, activated automatically when the resolved base URL differs from
`https://api.openai.com` and explicitly via node variable
`officialSDKRelaxedParsing: true`. Unknown enum values decode to a `raw` case
instead of throwing; missing non-essential required strings decode to `""`.

The previous
`extractOpenAIText`/`extractAnthropicText`/`extractGeminiText`/`extractCursorAgentText`
helpers are replaced by codec calls covered directly by
`OfficialSDKCodecTests`.

Usage normalization:

```swift
public struct AdapterUsage: Codable, Equatable, Sendable {
  public var inputTokens: Int?
  public var outputTokens: Int?
  public var totalTokens: Int?
  public var cacheReadInputTokens: Int?
  public var cacheCreationInputTokens: Int?
  public var providerRaw: JSONObject   // untouched provider payload
}
```

### 2. Typed errors and classification (G4)

New file `Sources/RielaAdapters/OfficialSDKErrors.swift`.

```swift
public struct OfficialSDKAPIError: Error, Equatable, Sendable {
  public var provider: String
  public var statusCode: Int
  public var type: String?        // e.g. "rate_limit_error", "invalid_request_error"
  public var message: String      // redacted
  public var retryAfter: Duration? // parsed from retry-after header
  public var classification: OfficialSDKErrorClassification
}

public enum OfficialSDKErrorClassification: Sendable {
  case retryable          // 408, 409, 429, 5xx, transport errors
  case nonRetryable       // other 4xx
}
```

Error envelope decoders per provider, tried before the success decode exactly
as MacPaw's `JSONResponseErrorDecoder` does:

- OpenAI / OpenAI-compatible: `{ "error": { message, type, param, code } }`
  (message may be a string or array of strings — join).
- Anthropic: `{ "type": "error", "error": { type, message } }`.
- Gemini: `{ "error": { code, message, status } }` (also the array-wrapped
  variant some compatible servers return).
- Cursor: fall back to generic `{ error | message }` sniffing.

Non-2xx handling in the executor changes from "throw redacted body string" to
"decode envelope → build `OfficialSDKAPIError` → map to
`AdapterExecutionError`" so the existing error surface is preserved:
`.providerError` for retryable and generic 4xx, `.policyBlocked` stays for
missing API keys, message format `"<provider> HTTP <status> <type>: <message>"`
after `redactOfficialSDKSensitiveText`.

### 3. Retry with backoff, jitter, and `retry-after` (G4)

`RetryPolicy` (`AdapterUtilities.swift:4`) gains additive fields with defaults
that reproduce current behavior when untouched:

```swift
public struct RetryPolicy: Equatable, Sendable {
  public var maxAttempts: Int = 2
  public var retryDelay: Duration = .milliseconds(50)   // base delay
  public var backoffMultiplier: Double = 1.0            // 1.0 == today's fixed delay
  public var maxDelay: Duration = .seconds(30)
  public var useJitter: Bool = false                    // full jitter when true
}
```

Official SDK adapters construct their default policy as
`RetryPolicy(maxAttempts: 3, retryDelay: .milliseconds(500), backoffMultiplier: 2.0, useJitter: true)`.
`executeWithRetry` changes:

- Delay for attempt *n*: `min(maxDelay, retryDelay * backoffMultiplier^(n-1))`,
  multiplied by `Double.random(in: 0...1)` when `useJitter` (full jitter).
- If the thrown error carries `retryAfter` (from a 429/529 header), that value
  wins over the computed delay (still capped by deadline).
- Errors classified `nonRetryable` are rethrown immediately even when the code
  is `.providerError` — classification is carried via a new
  `AdapterExecutionError.isRetryable: Bool?` optional (nil = today's
  code-based behavior, so non-SDK callers are unaffected).
- Deadline awareness and cancellation propagation are unchanged.

The deadline is now also propagated into `URLRequest.timeoutInterval`
(remaining time, floored at 1 s) so the socket enforces it, not just the task
race.

### 4. Usage extraction and emission (G2)

Blocking path: after decode, the adapter

1. Emits `AdapterBackendEvent(provider:, eventType: "response.usage",
   channel: .usage, usage: usage.providerRaw + normalized keys)` through
   `context.backendEventHandler` (the same handler CLI agents use — the runner
   already records `.usage` channel events into the live tail and JSONL).
2. Sets `AdapterExecutionOutput.usage` — a new optional field on the output
   contract:

```swift
// Sources/RielaCore/AdapterContracts.swift — additive
public struct AdapterExecutionOutput {
  ...
  public var usage: AdapterUsage?   // nil for adapters that don't report
}
```

The runner persists it on the step execution record
(`WorkflowStepExecution.usage: AdapterUsage?`, additive-optional so
existing session JSON round-trips). This closes the "usage payloads dropped at
persistence" gap that the loop-engineering work depends on; that plan consumes
the field, this plan produces it.

Streaming path: usage arrives in terminal stream events
(OpenAI `response.completed`, Anthropic `message_delta`/`message_stop`, Gemini
final chunk `usageMetadata`) and is emitted the same way.

### 5. SSE streaming layer (G1)

Three new pieces, mirroring MacPaw's parser/interpreter/session split.

#### 5.1 `ServerSentEventsParser` (new file `Sources/RielaAdapters/ServerSentEventsParser.swift`)

Pure, allocation-light implementation of WHATWG HTML §9.2.6:

```swift
public struct ServerSentEvent: Equatable, Sendable {
  public var id: String?
  public var event: String?      // event type field
  public var data: String        // joined data lines
}

public final class ServerSentEventsParser {
  public func feed(_ chunk: Data) throws -> [ServerSentEvent]
  public func finish() throws -> [ServerSentEvent]   // flush trailing event without blank line
}
```

Requirements copied from MacPaw's parser: strip UTF-8 BOM on the first chunk;
accept `\r\n`, `\r`, `\n` line endings; ignore comment lines (`:`); dispatch
on blank line; **buffer incomplete lines across `feed` calls**; multi-line
`data:` accumulation with `\n` joins. No JSON knowledge.

#### 5.2 Streaming transport + interpreters (new file `Sources/RielaAdapters/OfficialSDKStreaming.swift`)

```swift
public protocol OfficialSDKStreamingHTTPTransporting: Sendable {
  func bytes(for request: URLRequest) async throws
    -> OfficialSDKStreamingHTTPResponse
}
// Default: URLSession.bytes(for:) wrapper. Mock: scripted chunk replay.

protocol OfficialSDKStreamInterpreter: Sendable {
  /// Feed one SSE event; returns backend events to emit (already channel-tagged).
  mutating func interpret(_ event: ServerSentEvent) throws -> [AdapterBackendEvent]
  /// Called at stream end; returns the accumulated final result.
  func finalize() throws -> OfficialSDKDecodedResponse
}
```

Per-provider interpreters and the flags/endpoints they use:

| Provider | Request change | Stream shape | Interpreter mapping |
|---|---|---|---|
| OpenAI Responses | `"stream": true` on `POST /v1/responses` | typed events: `response.output_text.delta`, `response.output_item.*`, `response.completed`, `response.failed` | delta → `.assistant` (isDelta), `response.completed.response.usage` → `.usage`, others → `.lifecycle`; accumulate output text |
| Anthropic Messages | `"stream": true` on `POST /v1/messages` | `message_start`, `content_block_start`, `content_block_delta` (`text_delta` / `thinking_delta`), `content_block_stop`, `message_delta` (stop_reason + usage), `message_stop`, `ping`, `error` | `text_delta` → `.assistant` delta, `thinking_delta` → `.thinking` delta, `message_delta.usage` (+ `message_start.message.usage.input_tokens`) → `.usage`, `ping`/starts/stops → `.lifecycle`, `error` event → typed throw; accumulate text blocks |
| Gemini | endpoint switches to `:streamGenerateContent?alt=sse` | SSE `data:` chunks each a `GenerateContentResponse` fragment | candidate part text → `.assistant` delta, final `usageMetadata` → `.usage`; accumulate parts |
| Cursor | none | not supported (agent job API) | stays blocking |

Every interpreter first sniffs each event's `data` for the provider error
envelope (§2) before success decoding — MacPaw's error-body-on-stream rule —
and unknown event types map to `.lifecycle` with the raw type string, never a
throw (same resilience posture as the CLI classifiers).

#### 5.3 Adapter integration

`executeOfficialSDKRequest` grows a streaming branch:

- **Opt-in/opt-out**: streaming is used when the transport supports it, the
  provider supports it (not Cursor), and the node has not set
  `variables.streamBackendContent: false` (the existing opt-out from
  agent-response-streaming §6). A global kill switch
  `RIELA_OFFICIAL_SDK_STREAMING=off` env var covers operational rollback.
- Backend events flow through `context.backendEventHandler` — the runner-side
  ordered bridge, coalescer, redaction (`redactAdapterSensitiveText`), 16 KiB
  truncation, ring buffer, and `WorkflowRunEvent` enrichment all already exist
  from agent-response-streaming Phase 1 and are reused as-is. The adapter
  applies `redactOfficialSDKSensitiveText` to content before emitting (same
  values it redacts today).
- The final `AdapterExecutionOutput` is built from
  `interpreter.finalize()` — the accumulated full text — and then goes through
  the existing output-contract normalization (`normalizeOutputContractEnvelope`)
  unchanged. **Note**: when the node declares an output contract (JSON
  envelope), streamed deltas are the raw model text; consumers already treat
  streamed content as observability-only, so this is acceptable and matches
  CLI-agent behavior.
- **Fallback**: if the stream fails after partial output (transport error
  mid-stream), the adapter retries the whole request via the blocking path
  (one attempt, within deadline) before surfacing the error. Duplicate
  streamed deltas from the failed attempt are tolerated by consumers
  (observability-only guarantee).

### 6. Middleware and configuration (G5)

New file `Sources/RielaAdapters/OfficialSDKMiddleware.swift`:

```swift
public protocol OfficialSDKMiddleware: Sendable {
  func intercept(request: URLRequest) -> URLRequest
  func intercept(response: HTTPURLResponse, data: Data) -> Data
  func interceptStreamChunk(_ chunk: Data) -> Data
}
// Default implementations are identity, so conformers override selectively.
```

`OfficialSDKAdapterConfiguration` gains additive fields:

```swift
public struct OfficialSDKAdapterConfiguration {
  ...
  public var customHeaders: [String: String] = [:]   // applied AFTER defaults (can override auth)
  public var timeout: Duration? = nil                // per-request URLSession timeout
  public var middlewares: [OfficialSDKMiddleware] = []
  public var parsingOptions: OfficialSDKParsingOptions = []
  public var streamingTransport: (any OfficialSDKStreamingHTTPTransporting)? = nil
}
```

Middlewares are reduced in declaration order over the request before send and
over (response, data) after receive; stream chunks pass through
`interceptStreamChunk` before the SSE parser. A built-in
`OfficialSDKLoggingMiddleware` (redacted, off by default) ships as the first
conformer and the test vehicle.

`customHeaders` are applied after default headers, matching MacPaw's rule that
custom headers may override `Authorization`/`anthropic-version` — this is what
makes proxy/gateway deployments possible without code changes.

### 7. Testing

- **Unit — SSE parser**: WHATWG conformance table (BOM, CRLF/CR/LF, comments,
  multi-line data, incomplete-line buffering across feeds, trailing event on
  finish). Fixture-driven.
- **Unit — interpreters**: real captured stream fixtures per provider
  (OpenAI `response.output_text.delta`… sequence, Anthropic
  `message_start`→`message_stop` with text + thinking deltas + usage, Gemini
  `alt=sse` chunks); assert emitted `AdapterBackendEvent` sequences, final
  accumulated text, usage extraction, unknown-event → `.lifecycle`, error
  event → typed throw.
- **Unit — codecs**: request encoding emits deterministic sorted-key wire bytes
  (golden JSON), response decoding for simple/segmented/error shapes,
  tolerant-decode behavior on mutated OpenAI-compatible fixtures.
- **Unit — errors/retry**: envelope decode per provider, classification table,
  backoff sequence determinism (jitter injected via seeded generator),
  `retry-after` precedence, non-retryable immediate rethrow, deadline cap.
- **Integration — adapter**: `RecordingOfficialSDKHTTPTransport` extended with
  a scripted streaming variant; assert blocking fallback on stream failure,
  `streamBackendContent: false` downgrade, usage on
  `AdapterExecutionOutput`, middleware invocation order, custom header
  override.
- **Compatibility**: existing `OfficialSDKAdapterTests` must pass unmodified
  except where they assert on now-deleted extractor internals.

## Rollout Plan

1. **Phase 1 — typed foundation**: codecs (§1), error envelopes +
   classification (§2), retry upgrade (§3), usage extraction on the blocking
   path (§4). No behavior change visible to workflows except better errors,
   smarter retry, and usage appearing in events/output.
2. **Phase 2 — streaming**: SSE parser (§5.1), streaming transport +
   OpenAI/Anthropic/Gemini interpreters (§5.2), adapter integration with
   fallback (§5.3). Ships live output for official SDK nodes.
3. **Phase 3 — extensibility**: middleware chain, `customHeaders`, timeout,
   logging middleware (§6); tolerant parsing exposed via node variable (§1).
4. **Phase 4 (separate follow-up plan)** — provider-native structured output
   (`output_config.format` json_schema on OpenAI; tool-based structured
   output on Anthropic), tool calling, Anthropic vision inputs.

Phases 1–3 are this design's implementation scope
(`impl-plans/active/official-sdk-adapter-improvements.md`).

## Compatibility & Risk Notes

- All type changes are additive-optional (`RetryPolicy` fields with
  behavior-preserving defaults, `AdapterExecutionOutput.usage`,
  configuration fields). Existing initializer call sites compile unchanged
  (memberwise defaults).
- `OfficialSDKRequestExecuting` and `OfficialSDKHTTPTransporting` signatures
  are untouched; streaming uses a new sibling protocol, so existing mocks and
  the GraphQL/library parity surface keep working.
- Persisted session schema change is one optional field
  (`WorkflowStepExecution.usage`), decodable both directions.
- Provider stream vocabularies drift; interpreters must treat unknown events
  as `.lifecycle` and never gate the result path (identical posture to the
  CLI classifiers, which has held up in production).
- Streaming increases connection lifetime; the deadline race and
  `URLRequest.timeoutInterval` cap it, and the env kill switch +
  per-node opt-out provide rollback without a release.
- Tolerant decoding is opt-in (custom base URL or explicit variable) so the
  strict path against first-party endpoints keeps failing loudly on schema
  drift, which is what we want for early detection.
