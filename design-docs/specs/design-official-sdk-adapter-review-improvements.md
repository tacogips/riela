# Official SDK Adapter Review Improvements

## Summary

Commit `76ed0cb` ("Improve official SDK adapters") implemented
`design-official-sdk-adapter-improvements.md` phases 1–3. A three-track
adversarial review of that commit (streaming path, typed foundation,
cross-cutting/claims) on 2026-07-06 confirmed the overall architecture is
sound — SSE parser WHATWG conformance, usage plumbing end-to-end on the
direct-node path, retry classification, request-building parity, middleware
and redaction all verified correct — but found **5 major defects**, a set of
minor correctness/consistency issues, documentation staleness, and test-gap
debt. This document specifies the fixes.

Review verification baseline: the focused suites
(`OfficialSDKAdapterTests|OfficialSDKAdapterStreamingTests|OfficialSDKAdapterUsageAndRetryTests|OfficialSDKAdapterConfigurationTests|OfficialSDKAdapterRequestGoldenTests|OfficialSDKCodecTests|OfficialSDKErrorEnvelopeTests|AdapterUtilitiesTests|ServerSentEventsParserTests`)
pass 93/93 at HEAD; the defects below are logic/behavior gaps the current
tests do not exercise.

## Findings and Decisions

IDs are stable references for the impl plan. Severity from the review.

### Major (correctness)

- **R1 (major) — Streaming transport re-buffers into 1 KiB blocks.**
  `URLSessionOfficialSDKStreamingTransport`
  (`Sources/RielaAdapters/OfficialSDKStreaming.swift:40-51`) accumulates
  bytes and yields only when ≥1024 bytes buffered or at stream end. Slow
  token streams — the exact case live streaming exists for (heartbeat, live
  tail, stall detection) — arrive in lurches.
  **Decision**: yield without a size threshold. Iterate
  `URLSession.AsyncBytes` and forward data as it arrives (chunked by the
  natural read granularity); no time-based flusher needed once the size gate
  is gone.

- **R2 (major) — Task cancellation returns truncated output as success; byte
  loop leaks.** `AsyncThrowingStream` ends without throwing on consumer
  cancellation, so the interpret loop exits cleanly, `finalize()` returns
  partial text, and `execute` returns truncated output as success
  (`OfficialSDKStreaming.swift:94`, `OfficialSDKAdapters.swift:720-749`).
  The transport also wraps iteration in an unstructured `Task` with no
  `onTermination` hook, so the HTTP connection survives consumer
  cancellation.
  **Decision**: `try Task.checkCancellation()` after the event loop and
  before `finalize()`; add `continuation.onTermination` cancelling the inner
  task in the transport.

- **R3 (major) — Output-contract validation failure triggers a duplicate
  paid provider call.** Envelope normalization runs inside
  `executeOfficialSDKStreamingRequest`; its `.invalidOutput` throw
  (`isRetryable == nil`) is swallowed by the generic stream-failure catch
  (`OfficialSDKAdapters.swift:524-533`, `:618-631`) and the whole request is
  re-issued on the blocking path, which fails identically. Two provider
  calls per attempt for every output-contract validation failure.
  **Decision**: the fallback catch wraps only the transport/stream phase;
  output-contract normalization moves after the do/catch (single place for
  both branches). `.invalidOutput` and `.policyBlocked` always rethrow.

- **R4 (major) — SDK-worker addon path drops `usage`.**
  `executeSDKWorker` (`Sources/RielaCLI/ProductionNodeAdapter.swift:307`)
  rebuilds `AdapterExecutionOutput` and omits `usage`, so codex/claude/cursor
  SDK-worker addon nodes lose token accounting at exactly the persistence
  boundary the parent design closed (the gemini-sdk-worker path at `:660`
  returns the output unmodified and is fine).
  **Decision**: forward `usage: output.usage` in the rebuild; add a
  regression test asserting SDK-worker addon executions persist usage.

- **R5 (major) — Raw `DecodingError` can escape `adapter.execute`; malformed
  shapes are retried.** The post-retry decode
  (`OfficialSDKAdapters.swift:552`) sits outside `normalizeOfficialSDKFailure`
  — with an injected `requestExecutor` a shape mismatch escapes as
  un-redacted Foundation `DecodingError`, breaking the adapter error
  contract. On the default path the decode happens inside the retry loop, so
  a deterministic decode failure is classified retryable `providerError` and
  retried up to 3 times (old extractors returned `""` and succeeded).
  **Decision**: decode failures are wrapped as
  `AdapterExecutionError(.invalidOutput, isRetryable: false)` (redacted) in
  both call sites. This is an intentional parity change vs the old
  silent-`""` behavior: fail loudly, but exactly once.

### Minor (behavior / consistency)

- **R6 (minor) — Stream-failure fallback is not "one attempt".** The
  fallback leg runs the full `configuration.retryPolicy` (default 3 attempts
  with backoff), contradicting the parent design §5.3.
  **Decision**: keep the design semantics — fallback leg uses
  `maxAttempts: 1` (deadline still applies). The streaming leg already uses
  `maxAttempts: 1`.

- **R7 (minor) — 429 on the stream is not throttled before fallback.** A
  rate-limited streaming response carries `retryAfter`, but the generic
  catch fires the blocking request immediately.
  **Decision**: if the caught stream error carries `retryAfter`, sleep
  `min(retryAfter, deadline remainder)` before the fallback attempt; if the
  deadline cannot accommodate it, rethrow instead of falling back.

- **R8 (minor) — Duplicate `.usage` events when the stream already emitted
  usage and the blocking fallback runs.** Consumers summing the `.usage`
  channel double-count (persisted `output.usage` is single-source and fine).
  **Decision**: track whether the streaming attempt emitted a usage event;
  suppress the blocking-path usage emit on the fallback leg when so.

- **R9 (minor) — In-stream provider errors are blanket `isRetryable: false`.**
  `throwIfStreamError` (`OfficialSDKStreaming.swift:376-383`) marks every
  in-stream error non-retryable; Anthropic mid-stream `overloaded_error`
  (529-equivalent) is retryable per provider docs, and non-retryable also
  blocks the fallback.
  **Decision**: classify by provider error `type`
  (`overloaded_error`, `rate_limit_error`, `api_error` → retryable; others →
  non-retryable), reusing the envelope classification table.

- **R10 (minor) — OpenAI flat stream-error shape unhandled.** OpenAI
  Responses emits `event: error` with flat
  `{"type":"error","code":...,"message":...}`; detection keys off
  `eventType == "error"` or a top-level `"error"` key only, and
  `streamErrorMessage` reads only nested `error.message` — the flat
  `message` is lost. Additionally `object["error"] != nil` treats a JSON
  literal `"error": null` as an error (`JSONValue.null` is non-nil).
  **Decision**: also match `object["type"] == "error"`; read top-level
  `message`; exclude `.null` in the `error`-key check.

- **R11 (minor) — Anthropic streamed finalize text differs from blocking
  path on multi-text-block responses.** Streaming joins text segments with
  `""`; the blocking codec joins text blocks with `"\n"`.
  **Decision**: track block boundaries via `content_block_start` and join
  segments with `"\n"` (parity is a stated design requirement).

- **R12 (minor) — SSE parser: invalid UTF-8 poisons the pending buffer.**
  `feed` decodes all-or-nothing over `pendingBytes`; a permanently invalid
  byte stalls parsing forever with unbounded buffer growth, and `finish()`'s
  re-feed can drop complete valid lines sitting before a trailing truncated
  scalar.
  **Decision**: decode the maximal valid UTF-8 prefix, keep only the
  trailing incomplete sequence (≤3 bytes) pending; cap pending at a sane
  bound (e.g. 1 MiB) with a typed error beyond it.

- **R13 (minor) — Kill switch and relaxed-parsing env resolution
  inconsistent and node-overridable.** `RIELA_OFFICIAL_SDK_STREAMING` is
  resolved from `(configuration.environment ?? process env) merged with
  agentEnvironment` — a node can silently re-enable streaming against an
  operator's process-level `off`, and a non-nil `configuration.environment`
  hides the process env entirely. `RIELA_OFFICIAL_SDK_RELAXED_PARSING` is
  read from `agentEnvironment` only, and `boolValue` parses only literal
  `"true"/"false"`.
  **Decision**: the kill switch is an operator control — `off` in the
  process env wins unconditionally (OR-combine sources; node/agent env may
  only disable, never re-enable). Relaxed parsing resolves through the same
  merged-environment helper as other toggles. `boolValue` additionally
  accepts `"1"/"0"`.

- **R14 (minor) — Gemini top-level array error envelope not handled.** The
  real-world Gemini array variant is a top-level array body
  `[{"error":{...}}]`; the implementation (and its test) handle
  `{"error":[...]}` instead, which no known provider emits.
  **Decision**: when the error body decodes to a top-level `.array`, try
  each element through the envelope decoder; fix the test fixture to the
  real shape (keep the old shape as an additional tolerated input).

- **R15 (minor) — Generic stream interpreter dead/fragile.**
  `GenericOfficialSDKStreamInterpreter` is unreachable (Cursor is excluded
  from streaming; no other provider maps to it), and an empty `data:`
  keepalive aborts non-OpenAI interpreters via `DecodingError` (empty-data
  guard exists only in the OpenAI interpreter).
  **Decision**: hoist the empty-data/`[DONE]` guard so every interpreter
  skips blank payloads; delete the generic interpreter or keep it explicitly
  documented as the future-provider default with the guard applied.

- **R16 (minor) — Streaming branch converts `CancellationError` to
  `.timeout`.** The blocking path deliberately rethrows `CancellationError`
  raw (tested); the streaming branch (`OfficialSDKAdapters.swift:524-532`)
  normalizes it to `.timeout`, so cancellation semantics differ by branch.
  **Decision**: rethrow `CancellationError` un-normalized on both branches
  (pairs with R2).

- **R17 (minor) — OpenAI `stopReason` decodes a nonexistent key.** The codec
  reads `stop_reason` for OpenAI; the Responses API field is `status`.
  `stopReason` is always nil for OpenAI and is currently dropped before
  `AdapterExecutionOutput` anyway.
  **Decision**: map OpenAI `status` into `stopReason`. Surfacing
  `stopReason` beyond `OfficialSDKDecodedResponse` stays deferred (see
  Deferred Scope).

- **R18 (minor) — `retryAfter` not capped by `maxDelay`.** A broken proxy
  sending `Retry-After: 86400` sleeps a day when no deadline is set.
  **Decision**: cap the honored `retryAfter` at `RetryPolicy.maxDelay`
  (deadline cap unchanged).

- **R19 (documented, no code change) — Accepted behavior deviations.** Three
  review flags are accepted as-is and documented rather than reverted:
  (a) empty-string `output_text` now falls through to segmented output
  (improvement over old parity); (b) 1xx/3xx responses are now non-retryable
  (old code retried any non-2xx); (c) middleware/customHeaders/timeout/
  parsingOptions are bypassed when a `requestExecutor` is injected, and
  streaming is disabled when `requestExecutor`/`httpTransport` is injected
  without `streamingTransport` (mock-friendly semantics). These are recorded
  in the parent design doc (see R21).

### Tolerant parsing (design–implementation gap)

- **R20 (minor) — `OfficialSDKParsingOptions` is mostly dead flags.**
  `.ignoreUnknownEnumValues` is consulted nowhere (wire models have no
  enums); `.fillRequiredStringIfMissing` has exactly one effect (OpenAI
  content entry with missing `type` treated as `output_text`). The parent
  design promised broader tolerant decoding (G6), and `.relaxed` does not
  protect against type mismatches (`"input_tokens": "12"` still throws —
  interacts with R5).
  **Decision**: implement the useful subset now, honestly descope the rest:
  under `.relaxed`, usage token counts tolerate string-encoded integers and
  unknown `content[].type` entries are skipped rather than throwing; the
  parent design's §1 wording is corrected to describe the actual semantics,
  and `.ignoreUnknownEnumValues` is either given its single real use
  (unknown content-block types → skipped) or removed.

### Documentation staleness (parent docs)

- **R21 (minor) — Parent design/plan corrections**, folded into this effort:
  - Remove/rewrite the "Current Review Slice (2026-07-06)" section of
    `design-official-sdk-adapter-improvements.md` (says "uncommitted",
    describes usage as blocking-only, lists a stale test filter).
  - Rename `OfficialSDKUsage` → `AdapterUsage` in the parent design's
    snippets (§1, §4) to match code.
  - Fix the parent plan's usage-plumbing snippet
    (`WorkflowModel.swift` → `RuntimeSession.swift`).
  - Add `Sources/RielaAdapters/OfficialSDKHTTPRequestBuilding.swift` to the
    parent plan's module table.
  - Record the R19 accepted deviations in the parent design (§5.3 fallback
    wording aligns with R6's one-attempt fix).

### Test-gap debt

- **R22 — Streaming tests**: CRLF pair split across two `feed()` chunks;
  non-2xx streaming response (envelope decode + `retry-after` + fallback
  throttle, pairs R7); cancellation/deadline mid-stream returns error not
  truncated success (pairs R2); Cursor stays blocking with a configured
  `streamingTransport`; streamed delta redaction (API key in delta);
  duplicate-usage suppression on fallback (pairs R8); kill-switch precedence
  (process env `off` vs node `on`, pairs R13); streaming node with an output
  contract (pairs R3); slow-stream chunk delivery is unbuffered (pairs R1).
- **R23 — Foundation tests**: `Retry-After` HTTP-date form; 408/409
  classification; Gemini real object envelope `{error:{code,message,status}}`
  and top-level array variant (pairs R14); transport-error classification;
  direct assertions on computed backoff delays and jitter bounds (seeded
  RNG with non-zero values); decoding a pre-change `WorkflowStepExecution`
  JSON without `usage`; SDK-worker addon usage persistence (pairs R4);
  injected-executor malformed body → typed redacted error (pairs R5);
  relaxed-parsing node-variable and env opt-in paths (pairs R13/R20).

## Deferred Scope (not this effort)

Carried over as candidates for the next planning round, in addition to the
parent design's Phase 4 (provider-native structured output, tool calling,
Anthropic vision):

- GraphQL/CLI read-surface exposure of `WorkflowStepExecution.usage`
  (currently persisted but unreadable via `RielaGraphQL`); belongs with the
  loop-engineering consumer work.
- Surfacing `stopReason` on `AdapterExecutionOutput` (or removing it from
  `OfficialSDKDecodedResponse`).
- Cursor agent job polling (creation-only today).
- Custom `URLSession` injection as a first-class configuration field.
- Cleanup of the leftover `tmp/official-sdk-live-anthropic/` scratch
  directory is included in this effort's hygiene tasks (AGENTS.md tmp rule),
  but re-running live verification is not required unless streaming-path
  fixes (R1/R2/R3) land — then one re-run is.

## Verification

- All focused suites listed in Summary, extended by R22/R23, pass.
- Full `swift test`, `xcrun swiftlint`, `git diff --check`.
- One live Anthropic streaming re-run (same procedure as the parent plan's
  Live Verification Evidence) after R1–R3 land, confirming: deltas arrive
  incrementally (multiple assistant events for a multi-sentence reply),
  usage persisted once, exit 0.

## Compatibility & Risk Notes

- All fixes preserve public signatures; R5 changes error *behavior* for
  malformed provider responses from silent-empty/retry to a single typed
  `.invalidOutput` failure — this is the intended loud-failure posture and
  only affects responses that were already broken.
- R6/R7/R8 only narrow the fallback (fewer duplicate calls, throttled 429) —
  no new call patterns.
- R13 makes the kill switch strictly stronger for operators; nodes lose the
  (unintended) ability to re-enable streaming.
- R12's bounded pending buffer introduces a new failure mode (pathological
  non-UTF-8 streams now fail typed instead of growing unbounded) — strictly
  safer.
