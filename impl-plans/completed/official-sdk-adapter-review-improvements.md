# Official SDK Adapter Review Improvements Implementation Plan

**Status**: Implemented and verified
**Design Reference**: design-docs/specs/design-official-sdk-adapter-review-improvements.md
**Created**: 2026-07-06
**Last Updated**: 2026-07-06

---

## Design Document Reference

**Source**: design-docs/specs/design-official-sdk-adapter-review-improvements.md

### Summary

Fix the defects found by the 2026-07-06 three-track adversarial review of
commit `76ed0cb` (official SDK adapter improvements): 5 major correctness
issues (streaming re-buffering, cancellation-as-success, duplicate paid call
on output-contract failure, SDK-worker usage drop, raw `DecodingError`
escape), a set of minor behavior/consistency fixes (fallback semantics,
retry-after throttling, stream-error classification, SSE parser UTF-8
robustness, env-toggle resolution, Gemini error envelope, Anthropic finalize
parity), tolerant-parsing honest descoping, parent-doc staleness corrections,
and the accompanying test-gap debt. Finding IDs (R1–R23) refer to the design
document.

### Scope

**Included**: R1–R18, R20 code fixes; R21 documentation corrections; R22/R23
test additions; `tmp/official-sdk-live-anthropic/` cleanup; one live
streaming re-verification after R1–R3.

**Excluded** (deferred, see design "Deferred Scope"):
- GraphQL/CLI exposure of `WorkflowStepExecution.usage`
- `stopReason` on `AdapterExecutionOutput` (beyond R17's decode fix)
- Cursor agent job polling
- Custom `URLSession` injection configuration field
- Parent design Phase 4 (structured output, tool calling, Anthropic vision)

---

## Modules

### 1. Streaming correctness (R1, R2, R15, R16)

#### Sources/RielaAdapters/OfficialSDKStreaming.swift (modify)

**Status**: IMPLEMENTED

**Checklist**:
- [x] R1: `URLSessionOfficialSDKStreamingTransport` yields data as it
      arrives — remove the 1024-byte accumulation gate (`:40-51`)
- [x] R2: `continuation.onTermination` cancels the inner byte-iteration
      `Task`
- [x] R15: empty-data / `[DONE]` payload guard hoisted so all interpreters
      skip blank `data:` payloads; `GenericOfficialSDKStreamInterpreter`
      deleted or documented as future-provider default with the guard
- [x] Nit: `lifecycleEvent(provider:eventType:raw:)` unused `raw` parameter
      removed or used

#### Sources/RielaAdapters/OfficialSDKAdapters.swift (modify — stream consume loop)

**Status**: IMPLEMENTED

**Checklist**:
- [x] R2: `try Task.checkCancellation()` after the event loop, before
      `finalize()` (`:720-749`)
- [x] R16: `CancellationError` rethrown un-normalized on the streaming
      branch (remove the `.timeout` conversion at `:524-532`)

---

### 2. Fallback semantics (R3, R6, R7, R8)

#### Sources/RielaAdapters/OfficialSDKAdapters.swift (modify — streaming/fallback orchestration)

**Status**: IMPLEMENTED

**Checklist**:
- [x] R3: output-contract normalization moved out of
      `executeOfficialSDKStreamingRequest`; runs once after the
      streaming/blocking branch resolves; `.invalidOutput` / `.policyBlocked`
      always rethrow (never trigger fallback)
- [x] R6: fallback leg runs with `RetryPolicy(maxAttempts: 1)` (deadline
      unchanged)
- [x] R7: caught stream error carrying `retryAfter` → sleep
      `min(retryAfter, deadline remainder)` before fallback; rethrow if the
      deadline cannot accommodate it
- [x] R8: usage-emitted flag from the streaming attempt suppresses the
      blocking-path `.usage` event on the fallback leg

---

### 3. Stream error classification (R9, R10)

#### Sources/RielaAdapters/OfficialSDKStreaming.swift + OfficialSDKErrors.swift (modify)

**Status**: IMPLEMENTED

**Checklist**:
- [x] R9: `throwIfStreamError` classifies by provider error `type`
      (`overloaded_error` / `rate_limit_error` / `api_error` → retryable;
      others non-retryable), reusing the envelope classification table
- [x] R10: OpenAI flat error shape matched (`object["type"] == "error"`);
      `streamErrorMessage` reads top-level `message`; `"error": .null` no
      longer treated as an error

---

### 4. SSE parser robustness (R12)

#### Sources/RielaAdapters/ServerSentEventsParser.swift (modify)

**Status**: IMPLEMENTED

**Checklist**:
- [x] R12: decode maximal valid UTF-8 prefix per `feed`; only the trailing
      incomplete sequence (≤3 bytes) stays pending
- [x] R12: pending-buffer bound (1 MiB) with typed error beyond it
- [x] `finish()` re-feed dead path removed/covered by the prefix decoding

---

### 5. Configuration/env toggles (R13)

#### Sources/RielaAdapters/OfficialSDKAdapters.swift (modify — toggle resolution)

**Status**: IMPLEMENTED

**Checklist**:
- [x] R13: `RIELA_OFFICIAL_SDK_STREAMING=off` in the process env wins
      unconditionally; node/agent env may disable but never re-enable
- [x] R13: `RIELA_OFFICIAL_SDK_RELAXED_PARSING` resolves through the same
      merged-environment helper as the kill switch
- [x] R13: `boolValue` accepts `"1"` / `"0"`

---

### 6. Foundation fixes (R4, R5, R14, R17, R18, R20)

#### Sources/RielaCLI/ProductionNodeAdapter.swift (modify)

**Status**: IMPLEMENTED

**Checklist**:
- [x] R4: `executeSDKWorker` rebuild forwards `usage: output.usage` (`:307`)

#### Sources/RielaAdapters/OfficialSDKAdapters.swift + OfficialSDKCodecs.swift (modify)

**Status**: IMPLEMENTED

**Checklist**:
- [x] R5: post-retry decode (`:552`) and in-retry decode wrap failures as
      `AdapterExecutionError(.invalidOutput, isRetryable: false)`, redacted
- [x] R17: OpenAI codec maps `status` (not `stop_reason`) into `stopReason`
- [x] R20: under `.relaxed`, usage token counts tolerate string-encoded
      integers; unknown `content[].type` entries are skipped, not thrown;
      `.ignoreUnknownEnumValues` given its one real use (unknown
      content-block types) or removed

#### Sources/RielaAdapters/OfficialSDKErrors.swift + AdapterUtilities.swift (modify)

**Status**: IMPLEMENTED

**Checklist**:
- [x] R14: top-level `.array` error bodies tried element-wise through the
      envelope decoder (Gemini `[{"error":{...}}]`); keep `{"error":[...]}`
      tolerated
- [x] R18: honored `retryAfter` capped at `RetryPolicy.maxDelay`

---

### 7. Documentation corrections (R19, R21)

#### design-docs/specs/design-official-sdk-adapter-improvements.md (modify)

**Status**: IMPLEMENTED

**Checklist**:
- [x] Remove/rewrite the stale "Current Review Slice (2026-07-06)" section
      (committed now; usage is not blocking-only; test filter outdated)
- [x] Rename `OfficialSDKUsage` → `AdapterUsage` in §1/§4 snippets
- [x] §5.3 fallback wording confirmed as one attempt (matches R6 fix)
- [x] Record R19 accepted deviations: empty `output_text` fallthrough,
      1xx/3xx non-retryable, executor-injection bypass semantics
      (middleware/headers/timeout ignored with `requestExecutor`; streaming
      disabled without explicit `streamingTransport`; streaming path applies
      request+chunk middleware but not `(response, data)`)

#### impl-plans/active/official-sdk-adapter-improvements.md (modify)

**Status**: IMPLEMENTED

**Checklist**:
- [x] Usage-plumbing snippet: `WorkflowModel.swift` → `RuntimeSession.swift`
- [x] Module table row added for
      `Sources/RielaAdapters/OfficialSDKHTTPRequestBuilding.swift`
- [x] Tolerant-parsing checkbox annotated with the R20 descope note

---

### 8. Test additions (R22, R23)

#### Tests/RielaAdaptersTests (modify/add)

**Status**: IMPLEMENTED

**Checklist** (streaming — R22):
- [x] SSE parser: CRLF pair split across two `feed()` chunks
- [x] SSE parser: invalid-UTF-8 prefix recovery + pending bound (pairs R12)
- [x] Non-2xx streaming response: envelope decode, `retry-after` throttle
      before fallback (pairs R7)
- [x] Cancellation mid-stream → error, not truncated success (pairs R2)
- [x] Transport yields per-arrival chunks without 1 KiB gate (pairs R1)
- [x] Cursor stays blocking with `streamingTransport` configured
- [x] Streamed delta redaction (API-key value in delta content)
- [x] Duplicate-usage suppression on fallback (fixture with usage chunk
      before transport failure; pairs R8)
- [x] Kill-switch precedence: process env `off` beats node/agent `on`
      (pairs R13)
- [x] Streaming node with output contract: validation failure → single
      provider call, `.invalidOutput` (pairs R3)
- [x] Anthropic multi-text-block finalize joins with `"\n"` (pairs R11)
- [x] OpenAI flat `event: error` shape → typed throw with message
      (pairs R10)

**Checklist** (foundation — R23):
- [x] `Retry-After` HTTP-date form parsing
- [x] 408/409 classification; transport-error classification
- [x] Gemini real object envelope + top-level array variant (pairs R14)
- [x] Direct backoff-delay assertions and jitter bounds with seeded non-zero
      RNG
- [x] Pre-change `WorkflowStepExecution` JSON (no `usage`) decodes
- [x] SDK-worker addon execution persists usage (pairs R4)
- [x] Injected-executor malformed body → typed redacted `.invalidOutput`
      (pairs R5)
- [x] `officialSDKRelaxedParsing` node-variable and env opt-in paths
      (pairs R13/R20)
- [x] Relaxed usage decode: string-encoded token counts (pairs R20)

#### Anthropic finalize parity (R11)

**Status**: IMPLEMENTED

**Checklist**:
- [x] `AnthropicMessagesStreamInterpreter` tracks `content_block_start`
      boundaries; text segments joined with `"\n"` to match the blocking
      codec

---

## Module Status

| Module | File Path | Status | Tests |
|--------|-----------|--------|-------|
| Streaming transport/cancellation (R1, R2, R15, R16) | `Sources/RielaAdapters/OfficialSDKStreaming.swift`, `OfficialSDKAdapters.swift` | IMPLEMENTED | Streaming tests |
| Fallback semantics (R3, R6, R7, R8) | `Sources/RielaAdapters/OfficialSDKAdapters.swift` | IMPLEMENTED | Streaming fallback tests |
| Stream error classification (R9, R10) | `Sources/RielaAdapters/OfficialSDKStreaming.swift`, `OfficialSDKErrors.swift` | IMPLEMENTED | Stream error tests |
| SSE parser robustness (R12) | `Sources/RielaAdapters/ServerSentEventsParser.swift` | IMPLEMENTED | SSE parser tests |
| Env toggles (R13) | `Sources/RielaAdapters/OfficialSDKAdapters.swift` | IMPLEMENTED | Config/streaming tests |
| SDK-worker usage forward (R4) | `Sources/RielaCLI/ProductionNodeAdapter.swift` | IMPLEMENTED | CLI addon test |
| Decode error contract + codec fixes (R5, R17, R20) | `Sources/RielaAdapters/OfficialSDKAdapters.swift`, `OfficialSDKCodecs.swift` | IMPLEMENTED | Adapter/codec tests |
| Error envelope + retry cap (R14, R18) | `Sources/RielaAdapters/OfficialSDKErrors.swift`, `AdapterUtilities.swift` | IMPLEMENTED | Error/utilities tests |
| Anthropic finalize parity (R11) | `Sources/RielaAdapters/OfficialSDKStreaming.swift` | IMPLEMENTED | Streaming test |
| Doc corrections (R19, R21) | parent design + plan | IMPLEMENTED | diff check |
| Test additions (R22, R23) | `Tests/RielaAdaptersTests/*`, CLI/Core tests | IMPLEMENTED | Focused test slice |

## Dependencies

| Feature | Depends On | Status |
|---------|------------|--------|
| This plan | `impl-plans/active/official-sdk-adapter-improvements.md` (commit 76ed0cb) | Implemented |
| Fallback tests (R22) | Fallback fixes (module 2) | Implemented |
| Live re-verification | R1–R3 landed | Verified |
| Usage read surface (GraphQL/CLI) | Deferred — belongs with loop-engineering consumer plans | External |

Modules 1–6 are independent of each other except that module 2 (fallback)
touches the same orchestration function as module 1's R16 — implement 1 then
2, or together. Modules 7–8 last.

## Completion Criteria

- [x] All R1–R18, R20 checklist items implemented
- [x] R21 parent-doc corrections applied
- [x] All R22/R23 deterministic tests added and passing
- [x] Full `swift test` passes; `xcrun swiftlint` clean; `git diff --check` clean
- [x] Live Anthropic streaming re-run after R1–R3: multiple incremental
      assistant delta events for a multi-sentence reply, exactly one
      persisted usage record, exit 0
- [x] `tmp/official-sdk-live-anthropic/` removed after verification
      (AGENTS.md tmp rule)

## Progress Log

### Session: 2026-07-06
**Tasks Completed**: Review executed (3 adversarial tracks over commit
76ed0cb); findings consolidated into design doc; this plan authored; Swift
fixes and deterministic regressions implemented in the working tree; full
suite and live Anthropic streaming re-verification completed.
**Tasks In Progress**: None.
**Blockers**: None
**Notes**: Expanded focused slice passed 136 deterministic tests covering the
adapter review fixes plus SDK-worker usage and legacy execution decoding.
Full `swift test` passed 1327 tests with 0 failures. Live Anthropic streaming
run exited 0 with two assistant delta events, one usage event, eight backend
events, and persisted usage on the step execution (`inputTokens: 111`,
`outputTokens: 25`). The scratch live fixture directory was removed afterward.

## Related Plans

- **Previous**: `impl-plans/active/official-sdk-adapter-improvements.md` (implemented; this plan is its review follow-up)
- **Next**: parent design Phase 4 (structured output, tool calling, vision) + usage read-surface exposure — separate plans when scheduled
