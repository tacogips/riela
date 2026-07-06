# Official SDK Adapter Improvements Implementation Plan

**Status**: Implemented
**Design Reference**: design-docs/specs/design-official-sdk-adapter-improvements.md
**Created**: 2026-07-06
**Last Updated**: 2026-07-06

---

## Design Document Reference

**Source**: design-docs/specs/design-official-sdk-adapter-improvements.md

### Summary

Improve Riela's self-built official SDK adapters (`official-openai-sdk`,
`official-anthropic-sdk`, `official-gemini-sdk`, `official-cursor-sdk`) using
MacPaw/OpenAI's architecture as reference: typed Codable provider codecs with
opt-in tolerant decoding, typed API error envelopes driving classified retry
(exponential backoff + jitter + `retry-after`), usage/token extraction into
the existing `AdapterBackendEvent` `.usage` channel and adapter output, a
spec-compliant SSE parser + per-provider stream interpreters for live
streaming (reusing the agent-response-streaming Phase 1 runner pipeline), and
a middleware/configuration layer (custom headers, timeout, logging).

### Scope

**Included** (design phases 1–3):
- Typed request/response codecs per provider + `OfficialSDKParsingOptions`
- Typed error envelopes + `OfficialSDKErrorClassification`
- `RetryPolicy` backoff/jitter/`retry-after` upgrade (additive, defaults preserve current behavior)
- Usage extraction (blocking + streaming) → `.usage` backend events + `AdapterExecutionOutput.usage` + `WorkflowStepExecution.usage`
- `ServerSentEventsParser` (WHATWG §9.2.6)
- Streaming transport protocol + OpenAI/Anthropic/Gemini stream interpreters + adapter integration with blocking fallback, node opt-out, env kill switch
- `OfficialSDKMiddleware` chain, `customHeaders`, `timeout`, logging middleware

**Excluded**:
- MacPaw/OpenAI as a dependency
- Provider-native structured output, tool calling, Anthropic vision (design Phase 4, separate follow-up plan)
- New read surfaces (GraphQL subscriptions, viewer panes, `session logs --follow`)
- Cursor streaming (agent job API — stays blocking)
- CLI-agent adapter changes

---

## Modules

### 1. Typed Foundation (design §1, §2, §3, §4 — Phase 1)

#### Sources/RielaAdapters/OfficialSDKCodecs.swift (new)

**Status**: DONE (blocking response decode wired; canonical request encoding golden tests added)

```swift
public struct OfficialSDKParsingOptions: OptionSet, Sendable {
    public static let fillRequiredStringIfMissing: Self
    public static let ignoreUnknownEnumValues: Self
    public static let relaxed: Self
}

public struct OfficialSDKDecodedResponse: Sendable {
    public var text: String
    public var usage: AdapterUsage?
    public var stopReason: String?
    public var raw: JSONValue
}

// Per-provider namespaces with Codable wire models:
enum OpenAIResponsesWire { struct Response: Decodable { ... } }
enum AnthropicWire { struct Message: Decodable { ... } }
enum GeminiWire { struct GenerateContentResponse: Decodable { ... } }
enum CursorWire { struct Agent: Decodable { ... } }

// decodeOfficialSDKResponse(provider:data:options:) and JSONValue overload
// per-provider response wire models; request encoding uses sorted-key canonical JSON
```

**Checklist**:
- [x] `OfficialSDKParsingOptions` + tolerant decoding (OpenAI codec only; auto-on for non-`api.openai.com` base URL, node variable/env `officialSDKRelaxedParsing`)
- [x] `AdapterUsage` normalization from OpenAI `usage` / Anthropic `usage` / Gemini `usageMetadata`
- [x] Request encoding produces canonical byte-identical JSON fixtures from `makeURLRequest` bodies (golden tests)
- [x] Response decoding replaces `extractOpenAIText` / `extractAnthropicText` / `extractGeminiText` / `extractCursorAgentText`
- [x] Legacy ad-hoc response extraction helpers removed after codec tests migrated
- [x] Unit tests for provider response text, usage extraction, Cursor summary, and OpenAI tolerant-decode mutations
- [x] Unit tests for request-body golden fixtures and codec-specific error-body shapes

#### Sources/RielaAdapters/OfficialSDKErrors.swift (new)

**Status**: DONE (initial blocking-path slice)

```swift
public struct OfficialSDKAPIError: Error, Equatable, Sendable {
    public var provider: String
    public var statusCode: Int
    public var type: String?
    public var message: String          // redacted
    public var retryAfter: Duration?
    public var classification: OfficialSDKErrorClassification
}

public enum OfficialSDKErrorClassification: Sendable {
    case retryable      // 408, 409, 429, 5xx, transport
    case nonRetryable   // other 4xx
}

// decodeErrorEnvelope(provider:statusCode:headers:body:) -> OfficialSDKAPIError
```

**Checklist**:
- [x] Envelope decoders: OpenAI (`error.message` string-or-array), Anthropic (`type: "error"`), Gemini (`error.{code,message,status}` + array variant), Cursor generic fallback
- [x] `retry-after` header parsing (seconds and HTTP-date forms)
- [x] Mapping to `AdapterExecutionError` preserving `.policyBlocked` for missing keys and `redactOfficialSDKSensitiveText` on messages
- [x] `AdapterExecutionError.isRetryable: Bool?` additive field (RielaCore/AdapterContracts.swift; nil keeps code-based behavior)
- [x] Focused tests for HTTP failure normalization, non-retryable 4xx, retry-after, and redaction

#### Sources/RielaAdapters/AdapterUtilities.swift (modify)

**Status**: DONE

```swift
public struct RetryPolicy: Equatable, Sendable {
    public var maxAttempts: Int = 2
    public var retryDelay: Duration = .milliseconds(50)
    public var backoffMultiplier: Double = 1.0      // new; 1.0 == current fixed delay
    public var maxDelay: Duration = .seconds(30)    // new
    public var useJitter: Bool = false              // new; full jitter
}
```

**Checklist**:
- [x] Additive `RetryPolicy` fields; existing call sites compile unchanged
- [x] `executeWithRetry`: exponential backoff, full jitter (seedable RNG for tests), `retryAfter` precedence, `isRetryable == false` immediate rethrow, deadline cap unchanged
- [x] Official SDK default policy: `maxAttempts: 3, retryDelay: 500ms, backoffMultiplier: 2.0, useJitter: true`
- [x] Deadline propagated into `URLRequest.timeoutInterval` (remaining time, ≥1s floor) in `makeURLRequest`
- [x] Unit tests (backoff sequence, jitter bounds, retry-after wins, non-retryable rethrow)

#### Usage plumbing (RielaCore, modify)

**Status**: DONE (blocking-path slice)

```swift
// Sources/RielaCore/AdapterContracts.swift — additive
public struct AdapterExecutionOutput { ... public var usage: OfficialSDKUsage? }
// Sources/RielaCore/WorkflowModel.swift (step execution record) — additive
public struct WorkflowStepExecution { ... public var usage: OfficialSDKUsage? }
```

Note: `OfficialSDKUsage` must live in RielaCore (not RielaAdapters) to avoid a
dependency inversion — place the type in RielaCore and re-export/typealias in
RielaAdapters.

**Checklist**:
- [x] `OfficialSDKUsage` hosted in RielaCore as `AdapterUsage`
- [x] `AdapterExecutionOutput.usage` additive field
- [x] `WorkflowStepExecution.usage` additive-optional field; session JSON round-trips both directions
- [x] Runner records adapter output usage onto the step execution
- [x] Blocking path emits `AdapterBackendEvent(channel: .usage, eventType: "response.usage", usage: ...)` via `context.backendEventHandler`
- [x] Integration test coverage: fake transport returns usage → event emitted + output field; runtime publication persists usage

---

### 2. Streaming (design §5 — Phase 2)

#### Sources/RielaAdapters/ServerSentEventsParser.swift (new)

**Status**: DONE

```swift
public struct ServerSentEvent: Equatable, Sendable {
    public var id: String?
    public var event: String?
    public var data: String
}

public final class ServerSentEventsParser {
    public func feed(_ chunk: Data) -> [ServerSentEvent]
    public func finish() -> [ServerSentEvent]
}
```

**Checklist**:
- [x] WHATWG §9.2.6 conformance: BOM strip (first chunk), CRLF/CR/LF, comment lines, multi-line `data:` join, dispatch on blank line
- [x] Incomplete-line buffering across `feed` calls
- [x] `finish()` flushes trailing event
- [x] Fixture-driven conformance test table

#### Sources/RielaAdapters/OfficialSDKStreaming.swift (new)

**Status**: DONE

```swift
public protocol OfficialSDKStreamingHTTPTransporting: Sendable {
    func bytes(for request: URLRequest) async throws
        -> OfficialSDKStreamingHTTPResponse
}

protocol OfficialSDKStreamInterpreter: Sendable {
    mutating func interpret(_ event: ServerSentEvent) throws -> [AdapterBackendEvent]
    func finalize() throws -> OfficialSDKDecodedResponse
}

struct OpenAIResponsesStreamInterpreter: OfficialSDKStreamInterpreter { ... }
struct AnthropicMessagesStreamInterpreter: OfficialSDKStreamInterpreter { ... }
struct GeminiStreamInterpreter: OfficialSDKStreamInterpreter { ... }
```

Event mapping (from design §5.2):
- OpenAI: `response.output_text.delta` → `.assistant` delta; `response.completed` usage → `.usage`; `response.failed` → typed throw; others → `.lifecycle`
- Anthropic: `content_block_delta` `text_delta` → `.assistant` / `thinking_delta` → `.thinking`; `message_delta` usage (+ `message_start` input tokens) → `.usage`; `error` event → typed throw; `ping`/start/stop → `.lifecycle`
- Gemini: `:streamGenerateContent?alt=sse` chunks → `.assistant` deltas; final `usageMetadata` → `.usage`
- Unknown event types → `.lifecycle` with raw type string; never throw on unknowns

**Checklist**:
- [x] `URLSessionOfficialSDKStreamingTransport` default impl (`URLSession.bytes(for:)`)
- [x] Error-envelope sniffing on each event's data before success decode
- [x] Final-text accumulation per provider (`finalize()` equals blocking-path text for same content)
- [x] Usage extraction from terminal events
- [x] Fixture-driven interpreter tests per provider (scripted SSE stream shapes)

#### Sources/RielaAdapters/OfficialSDKAdapters.swift (modify — streaming branch)

**Status**: DONE

**Checklist**:
- [x] Request body gains `"stream": true` (OpenAI/Anthropic) / endpoint switch (Gemini) only on the streaming branch
- [x] Branch selection: streaming transport available AND provider supports it AND `variables.streamBackendContent != false` AND `RIELA_OFFICIAL_SDK_STREAMING != "off"`
- [x] Backend events emitted via `context.backendEventHandler` with `redactOfficialSDKSensitiveText` applied to content
- [x] `AdapterExecutionOutput` built from `finalize()`; output-contract normalization unchanged
- [x] Mid-stream failure → single blocking-path fallback within deadline
- [x] Cursor unchanged (blocking)
- [x] Integration tests: scripted streaming transport (delta ordering, fallback, opt-out downgrade, kill switch)

---

### 3. Extensibility (design §6 — Phase 3)

#### Sources/RielaAdapters/OfficialSDKMiddleware.swift (new)

**Status**: DONE (blocking HTTP + streaming chunk middleware + logging wired)

```swift
public protocol OfficialSDKMiddleware: Sendable {
    func intercept(request: URLRequest) -> URLRequest
    func intercept(response: HTTPURLResponse, data: Data) -> Data
    func interceptStreamChunk(_ chunk: Data) -> Data
}

public struct OfficialSDKLoggingMiddleware: OfficialSDKMiddleware { ... } // redacted, off by default
```

**Checklist**:
- [x] Protocol with identity default implementations
- [x] Reduce-in-order application for blocking HTTP: request before send, (response, data) after receive
- [x] Stream chunks pass through middleware before SSE parser
- [x] `OfficialSDKLoggingMiddleware` (redacted via existing redaction utilities)
- [x] Unit tests for blocking request/response middleware invocation
- [x] Unit tests for chunk interception

#### Sources/RielaAdapters/OfficialSDKAdapters.swift (modify — configuration)

**Status**: DONE (headers/timeout/middleware/parsing/streaming transport wired)

```swift
public struct OfficialSDKAdapterConfiguration {
    // existing fields unchanged, new additive:
    public var customHeaders: [String: String] = [:]   // applied AFTER defaults
    public var timeout: Duration? = nil
    public var middlewares: [OfficialSDKMiddleware] = []
    public var parsingOptions: OfficialSDKParsingOptions = []
    public var streamingTransport: (any OfficialSDKStreamingHTTPTransporting)? = nil
}
```

**Checklist**:
- [x] Additive configuration fields with defaults; existing call sites compile unchanged
- [x] `customHeaders` applied after default headers (may override `Authorization` / `anthropic-version` / `x-goog-api-key`)
- [x] `timeout` overrides deadline-derived `URLRequest.timeoutInterval` when smaller
- [x] Deadline propagated into `URLRequest.timeoutInterval` when no smaller timeout is configured
- [x] Tests: header override, timeout/deadline propagation, middleware wiring through adapter execution
- [x] `parsingOptions` additive field and codec integration
- [x] `streamingTransport` additive field and streaming branch integration

---

## Module Status

| Module | File Path | Status | Tests |
|--------|-----------|--------|-------|
| Provider codecs + parsing options | `Sources/RielaAdapters/OfficialSDKCodecs.swift` | DONE | Response codec + usage + relaxed parsing + canonical request golden tests |
| Error envelopes + classification | `Sources/RielaAdapters/OfficialSDKErrors.swift` | DONE | Focused HTTP failure/retry/redaction tests |
| Retry backoff/jitter | `Sources/RielaAdapters/AdapterUtilities.swift` | DONE | Retry semantics tests + request timeout propagation tests |
| Usage plumbing (core contracts) | `Sources/RielaCore/AdapterContracts.swift`, `Sources/RielaCore/RuntimeSession.swift` | DONE | Adapter usage-event tests + runtime publication test |
| SSE parser | `Sources/RielaAdapters/ServerSentEventsParser.swift` | DONE | Added parser + conformance tests |
| Streaming transport + interpreters | `Sources/RielaAdapters/OfficialSDKStreaming.swift` | DONE | Scripted OpenAI/Anthropic/Gemini stream tests |
| Adapter streaming branch | `Sources/RielaAdapters/OfficialSDKAdapters.swift` | DONE | Streaming branch, fallback, opt-out, kill-switch tests |
| Middleware | `Sources/RielaAdapters/OfficialSDKMiddleware.swift` | DONE | Blocking request/response + streaming chunk + redacted logging tests |
| Configuration extensions | `Sources/RielaAdapters/OfficialSDKAdapters.swift` | DONE | Headers/timeout/middleware/parsing/streaming tests |

## Dependencies

| Feature | Depends On | Status |
|---------|------------|--------|
| Streaming (module 2) | Typed foundation (module 1: codecs, errors) | Done |
| Streaming event pipeline | agent-response-streaming Phase 1 (`AdapterBackendEvent` channels, runner coalescer/ring, `WorkflowRunEvent` enrichment) | Shipped |
| Usage persistence consumers | loop-engineering-application plans (consume `WorkflowStepExecution.usage`) | External (they consume, this produces) |
| Extensibility (module 3) | Module 1 (config struct changes co-located) | Done |

Module 1, the SSE parser, module 2, and module 3 have all landed. Module 3
remains independent of module 2 except for `streamingTransport` config wiring.

## Completion Criteria

- [x] All modules implemented
- [x] `swift build` and full `swift test` pass
- [x] Existing `OfficialSDKAdapterTests` / `CursorSDKAdapterTests` pass (updated only where they asserted deleted extractor internals)
- [x] Golden tests confirm request bodies use deterministic canonical JSON for each provider request shape
- [x] Live verification: `riela workflow run` with an `official-anthropic-sdk` node and `--output jsonl` shows `backend_event` lines with `backendEventChannel: "assistant"` deltas and a `usage` event before `step_completed`
- [x] Usage visible on persisted step execution record after a real run
- [x] Kill switch (`RIELA_OFFICIAL_SDK_STREAMING=off`) and node opt-out (`streamBackendContent: false`) verified to restore blocking behavior

### Live Verification Evidence: Official Anthropic Streaming

Command executed on 2026-07-06 with `ANTHROPIC_API_KEY` supplied from the
environment; no credential value is recorded here:

```bash
swift run riela workflow run live-official-anthropic \
  --workflow-definition-dir tmp/official-sdk-live-anthropic/workflows \
  --artifact-root tmp/official-sdk-live-anthropic/artifacts \
  --session-store tmp/official-sdk-live-anthropic/sessions \
  --output jsonl \
  --max-steps 4
```

Durable redacted result summary:

- Exit status: `0`
- Session: `live-official-anthropic-session-1`
- Provider/model: `official-anthropic-sdk` / `claude-haiku-4-5-20251001`
- JSONL event order:
  - `backend_event` sequence 4: `backendEventChannel: "assistant"`,
    `backendEventType: "content_block_delta"`, `backendEventIsDelta: true`
  - `backend_event` sequence 5: `backendEventChannel: "assistant"`,
    `backendEventType: "content_block_delta"`, `backendEventIsDelta: true`
  - `backend_event` sequence 7: `backendEventChannel: "usage"`,
    `backendEventType: "message_delta"`, usage `{ input_tokens: 111,
    output_tokens: 25 }`
  - `step_completed`
  - `session_completed`
- Persisted step execution usage:
  `inputTokens: 111`, `outputTokens: 25`,
  `providerRaw.input_tokens: 111`, `providerRaw.output_tokens: 25`
- Root output:
  `{ "status": "ok", "message": "live official SDK streaming works for Riela" }`

## Progress Log

### Session: 2026-07-06
**Tasks Completed**: Design doc + implementation plan authored; blocking-path typed errors, retry policy, usage plumbing, SSE parser, blocking HTTP middleware/configuration, response codecs, canonical request-body golden fixtures, redacted logging middleware, streaming transport/interpreters, adapter streaming branch, streaming fallback/opt-out/kill-switch tests, streaming chunk middleware tests, and live official Anthropic streaming verification wired.
**Tasks In Progress**: None for this plan.
**Blockers**: None. Full `swift test` passes after resolving Note command/app/example parity regressions observed during final verification.
**Notes**: Research inputs: MacPaw/OpenAI v0.5.0 feature inventory (SSE
parser/interpreter split, ParsingOptions, middleware, APIErrorResponse,
Configuration shape); current-code audit of
`OfficialSDKAdapters.swift` / `AdapterUtilities.swift` /
`AdapterContracts.swift`. Streaming reuses agent-response-streaming Phase 1
runner pipeline; official-SDK streaming was that design's explicit non-goal,
implemented here.

## Related Plans

- **Depends On**: `impl-plans/active/agent-response-streaming.md` (Phase 1 shipped — event pipeline reused)
- **Feeds**: `impl-plans/active/loop-engineering-application-gap-closure.md` (usage persistence)
- **Next**: design Phase 4 follow-up (provider-native structured output, tool calling, Anthropic vision) — separate plan when scheduled
