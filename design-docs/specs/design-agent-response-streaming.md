# Agent Response Streaming For CLI Agent Backends

## Summary

Riela workflow runs that execute `codex-agent`, `claude-code-agent`, and
`cursor-cli-agent` nodes currently buffer the child process stdout until the
process exits, then collapse it into a single final response through the
adapter's `normalizeStdout` function. The only live signal is a
`backend_event` workflow run event whose payload is a bare event-type string
(`item.completed`, `turn.started`, ...). Consumers — the CLI `--output jsonl`
stream, `riela session progress`, RielaApp viewers, and auto-improve stall
detection — can see *that* the agent is alive, but never *what* it is saying
while it runs.

This document defines the Phase 1 issue-resolution slice for response
streaming: surfacing CLI agent output content (assistant text, thinking, tool
activity, usage) incrementally while a node executes, from the child process
pipe to live `WorkflowRunEvent` JSONL and runtime-store live-tail fields. It
also records the explicit boundaries for later read surfaces so Phase 1 does
not fan out into unrelated UI, GraphQL, log-follow, artifact-tail, or Claude
output-format work.

## Issue-Resolution Scope (Phase 1 Only)

The current implementation pass is limited to Phase 1 from the rollout plan:
additive backend-event contracts, codex/cursor content classifiers, a
non-blocking local process bridge, `WorkflowRunEvent` JSONL enrichment, runtime
store live-tail fields, and focused tests. It intentionally does not migrate
Claude to stream-json, add GraphQL polling, add RielaApp panes, add
`session logs --follow`, print live lines in text output mode, or make unrelated
RielaApp UX changes.

The only JSONL surface in scope for Phase 1 is the existing live
`riela workflow run --output jsonl` stream. Full-fidelity
`backend-events.jsonl` artifacts and post-hoc log-following are later read
surface work.

## Current Architecture (verified 2026-07-02)

### Pipe-to-event path

1. `FoundationLocalAgentProcessRunner` (`Sources/RielaAdapters/LocalAgentProcess.swift`)
   already implements `LocalAgentProcessEventStreaming`: a
   `LocalProcessPipeReader` splits stdout/stderr into lines as they arrive and
   invokes `outputEventHandler(LocalAgentProcessOutputEvent(stream:line:))`
   per line, while also accumulating the full buffer for the final result.
2. `LocalAgentCommandAdapter.execute` wraps that handler: for each stdout line
   it calls `command.backendEventType(line)` — a
   `@Sendable (String) -> String?` provided per backend — and if non-nil,
   emits `AdapterBackendEvent(provider:eventType:)` through
   `context.backendEventHandler`. **The line content is discarded.**
3. `DeterministicWorkflowRunner` (`+ExecutionEvents.swift`) receives the
   backend event, calls `store.recordStepBackendEvent` (which only updates
   `lastBackendEventAt` / `lastBackendEventType` on the running
   `WorkflowStepExecution`), then emits a `WorkflowRunEvent(type: .backendEvent,
   backendEventType: ...)` to the run event handler.
4. `WorkflowRunCommand` forwards every `WorkflowRunEvent` to the JSONL
   recorder, which writes to stdout live (verified: `backend_event` lines
   appear in real time during a codex-agent run).
5. Only after process exit does `LocalAgentCommandAdapter` run
   `command.normalizeStdout(result.stdout)` to extract the final assistant
   message and build `AdapterExecutionOutput`.

### Per-backend reality

| Backend | Child invocation (workflow adapter) | Line events available | Content granularity |
|---|---|---|---|
| codex-agent | `codex exec --json -` (prompt via stdin) | `thread.started`, `turn.started`, `item.completed`, `turn.completed` | item-level: full `agent_message` text arrives inside `item.completed`; no token deltas |
| claude-code-agent | `claude -p --output-format text --model ...` | **none** — plain text output, `claudeBackendEventType` never matches | nothing until exit |
| cursor-cli-agent | `cursor-agent --print --output-format stream-json` | `system`, `user`, `thinking` (delta), `assistant`, `result` | token-level `thinking`/`assistant` deltas with `subtype: "delta"` |

Verified live (CLI versions: codex-cli 0.142.5, claude 2.1.185,
cursor-agent 2026.06.24):

```jsonc
// codex exec --json
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"ok"}}
{"type":"turn.completed","usage":{"input_tokens":16048,"output_tokens":5,...}}

// claude -p --output-format stream-json --verbose
{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}],...},"session_id":"..."}
// plus optional per-token stream_event chunks with --include-partial-messages

// cursor-agent --print --output-format stream-json
{"type":"thinking","subtype":"delta","text":"The user is asking...","session_id":"...","timestamp_ms":...}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]},...}
{"type":"result","subtype":"success","result":"ok","usage":{...}}
```

Note that `ClaudeCodeAgentProcess` / `CodexAgentProcess` (the
GraphQL-command-executor side used by `claude-code-agent-cli` etc.) already
build `stream-json` / `--json` invocations and have rollout watchers
(`CodexSessionWatchSubscription`) — but the workflow adapter path does not use
them.

### Gaps and Phase 1 closure

- G1. Backend events carry no content — only a type string. Phase 1 closes this
  for `codex-agent` and `cursor-cli-agent` by adding optional content fields.
- G2. `claude-code-agent` emits zero backend events (text output format), so
  it has no heartbeat either, despite
  `workflowAutoImproveBackendSupportsHeartbeat` claiming heartbeat support for
  it. Phase 1 documents this as a deferred Phase 2 migration and does not
  change Claude invocation or final-result extraction.
- G3. The runtime store keeps only the *last* event type/timestamp. Phase 1
  adds bounded live-tail data to the store, but `session progress`, viewer,
  GraphQL, and artifact readers remain later read-surface work.
- G4. The per-event bridge in `LocalAgentCommandAdapter.outputEventHandler`
  blocks the pipe-reader thread with a `DispatchSemaphore` around an async
  store write for *every* line. Acceptable at 4 events/run; hostile at
  token-delta rates (cursor emits dozens of events per second). Phase 1
  replaces this with a non-blocking ordered async bridge.
- G5. No content-bearing streaming surface exists for consumers. Phase 1
  exposes only the existing live `riela workflow run --output jsonl` surface
  and runtime-store fields; library, GraphQL, app, and post-hoc log surfaces
  are deferred.

## Goals

- Stream agent response content (assistant text, thinking, tool activity,
  usage, lifecycle) per executing node, live. Phase 1 ships this for
  `codex-agent` and `cursor-cli-agent`; `claude-code-agent` is a later isolated
  migration because it requires changing CLI output format and final-response
  normalization.
- Preserve the existing completion contract: `normalizeStdout` over the full
  buffered stdout remains the source of truth for
  `AdapterExecutionOutput`. Streaming is additive observability; a stream
  consumer crash or missed event must never change run results.
- Keep `WorkflowRunEvent` and the persisted session record schemas
  backward-compatible (new optional fields only).
- Bound memory and event volume: delta coalescing, a bounded async bridge, a
  per-execution runtime-store ring buffer, and capped assistant tail text.
- Redact sensitive environment values from streamed content with the existing
  `redactAdapterSensitiveText` machinery before anything leaves the adapter.

## Non-Goals

- GraphQL subscriptions, SSE, WebSocket transport, or cursor-based polling
  queries. The deterministic request/response server
  (`DeterministicServerRouteHandler`) stays as-is in Phase 1.
- Streaming for `official/*-sdk` backends (OpenAI/Anthropic/Gemini/Cursor SDK
  adapters use buffered `URLSession` requests; SSE support there is a separate
  effort).
- Interactive mid-run input to the agent (that is the manager control plane's
  job).
- Changing mock-scenario or stdio node executor behavior.
- For the current Phase 1 issue-resolution pass: Claude stream-json migration,
  GraphQL polling, viewer panes, `session logs --follow`, text-mode live lines,
  and unrelated RielaApp UX changes.

## Design

### 1. Rich backend events (RielaCore contract change)

Extend `AdapterBackendEvent` with optional content fields. All new fields are
optional so existing constructors and tests keep compiling.

```swift
public enum AdapterBackendEventChannel: String, Codable, Sendable {
  case lifecycle      // session/thread/turn started/completed
  case assistant      // assistant-visible response text
  case thinking       // reasoning/thinking text
  case tool           // tool call started/completed
  case usage          // token usage snapshots
}

public struct AdapterBackendEvent: Equatable, Sendable {
  public var provider: String
  public var eventType: String            // existing raw type string
  public var channel: AdapterBackendEventChannel?
  public var contentDelta: String?        // incremental text (already-coalesced)
  public var contentSnapshot: String?     // full text when the backend sends snapshots
  public var isDelta: Bool                // true when contentDelta appends to prior events
  public var toolName: String?
  public var usage: JSONObject?           // provider-native usage object
  public var sequence: Int?               // per-execution monotonic index (assigned by runner)
  public var at: Date?
}
```

`LocalAgentCommand` gains a richer classifier alongside the existing one:

```swift
public struct LocalAgentCommand: Sendable {
  ...
  // Existing (kept for compatibility; used as fallback):
  public var backendEventType: @Sendable (String) -> String?
  // New: full classification. When set, wins over backendEventType.
  public var classifyBackendEvent: (@Sendable (String) -> AdapterBackendEvent?)?
}
```

### 2. Per-backend classifiers

Each agent target adds a `classify<Backend>BackendEvent(_ line: String)`
function next to its existing `<backend>BackendEventType`, reusing the same
JSON parsing. Phase 1 implements the codex and cursor classifiers only; the
Claude classifier remains documented here as the Phase 2 contract boundary.

- **codex-agent** (`Sources/CodexAgent/CodexAgentAdapter.swift`)
  - `item.completed` with `item.type == "agent_message"` →
    `channel: .assistant, contentSnapshot: item.text, isDelta: false`.
  - `item.completed` with `item.type == "reasoning"` → `channel: .thinking`.
  - `item.completed` with `item.type == "command_execution" | "tool_call"` →
    `channel: .tool, toolName: ...`.
  - `turn.completed` → `channel: .usage, usage: usage object`.
  - Everything else → `channel: .lifecycle`.
  - Codex does not emit token deltas from `exec --json`; item-level snapshots
    are the granularity we stream. No CLI flag change needed.

- **Deferred claude-code-agent boundary (Phase 2, not in this request)**
  (`Sources/ClaudeCodeAgent/ClaudeCodeAgentAdapter.swift`)
  - Phase 1 intentionally keeps the existing `--output-format text` workflow
    adapter behavior and existing final-response normalization.
  - **Builder change**: `--output-format text` →
    `--output-format stream-json --verbose`, plus
    `--include-partial-messages` gated by a node variable
    (`claudeStreamPartialMessages`, default off — see §6 volume control).
  - New `normalizeClaudeStreamJSONStdout` extracting the final response:
    prefer the `result` field of the terminal `{"type":"result"}` event, fall
    back to concatenated `assistant` message text blocks. Non-JSON stdout is
    returned unchanged (same defensive convention as
    `normalizeCodexExecJSONStdout` / `normalizeCursorStreamJSONStdout`).
  - Classifier: `assistant` message text blocks → `.assistant` snapshot;
    `stream_event` `content_block_delta` (`text_delta` / `thinking_delta`) →
    `.assistant`/`.thinking` delta; `system` subtypes → `.lifecycle`;
    `result.usage` → `.usage`.
  - This also fixes G2: claude executions finally get heartbeats, making
    `workflowAutoImproveBackendSupportsHeartbeat(.claudeCodeAgent)` truthful.
  - Risk: `stream-json` requires `--verbose` in `-p` mode and its `init`
    event is large; the classifier maps it to one `.lifecycle` event and
    never forwards raw payloads.

- **cursor-cli-agent** (`Sources/CursorCLIAgent/CursorCLIAgentAdapter.swift`)
  - `thinking` with `subtype: "delta"` → `.thinking` delta.
  - `assistant` message content text → `.assistant` snapshot (cursor sends
    the full message object; the observed CLI also has
    `session.assistant_message` variants which are handled identically to the
    existing `cursorAssistantText` helper).
  - `result` → `.usage` (usage object) + `.lifecycle`.
  - No CLI flag change needed; deltas already flow.

### 3. Non-blocking event bridge in `LocalAgentCommandAdapter`

Replace the per-line `DispatchSemaphore` + `Task` bridge (G4) with a
buffered `AsyncStream`:

```swift
// In LocalAgentCommandAdapter.execute:
let (eventStream, eventContinuation) = AsyncStream.makeStream(
  of: AdapterBackendEvent.self,
  bufferingPolicy: .bufferingNewest(512)
)
let consumer = Task {
  for await event in eventStream {
    await backendEventHandler(event)   // ordered, off the reader thread
  }
}
// outputEventHandler now only classifies + coalesces + yields. The coalescer
// serializes event absorption and timer callbacks under one lock:
{ outputEvent in
  guard outputEvent.stream == .stdout,
        let event = classify(outputEvent.line) else { return }
  coalescer.absorb(event, yield: eventContinuation.yield)
}
// after runner.run returns (or throws):
coalescer.finish(yield: eventContinuation.yield) // unconditional final drain
eventContinuation.finish()
await consumer.value
```

Properties:

- The pipe-reader thread never blocks on store I/O; classification and regex
  work stay cheap and synchronous.
- Ordering is preserved (single consumer task).
- Backpressure is "drop oldest beyond 512 pending" — acceptable because the
  stream is observability, and the terminal result path does not depend on it.
- The consumer is awaited before `execute` returns, so `step_completed` is
  always emitted after the last backend event for that execution (same
  guarantee as today).

**Delta coalescing** lives in front of the continuation: a small,
synchronized `BackendEventCoalescer` merges consecutive same-channel delta
events and flushes when (a) accumulated delta >= 256 UTF-8 bytes, (b) a timer
reaches 250 ms after the first absorbed delta, or (c) a
different-channel/non-delta event arrives. Absorbing the first pending delta
starts a cancellable timer task; the timer flushes even if no further process
output arrives. Event absorption, timer firing, and completion drain are
linearized by the coalescer's lock, so a pending delta is yielded before a
later non-delta event and can be yielded at most once.

On every success, thrown error, or cancellation exit from `runner.run`, the
adapter cancels the timer, synchronously drains any pending delta, then calls
`eventContinuation.finish()` and awaits the consumer. Cancellation does not
discard an already classified delta. No timer callback may yield after
`finish()`. This unconditional final flush preserves the last partial response
even when it arrives immediately before process exit; the timer-driven flush
makes an isolated delta visible within 250 ms when the child stays alive but
silent. This turns cursor's per-token firehose into ~4 events/second worst
case while keeping codex item-level events untouched. Claude item/message
streaming stays outside Phase 1.

**Redaction**: `contentDelta` / `contentSnapshot` pass through
`redactAdapterSensitiveText(_, additionalSensitiveValues:
sensitiveAdapterEnvironmentValues(command.configuration.environment))` before
yield. Content is also truncated to 16 KiB per event.

### 4. Runner + store: live tail instead of last-event-only

`DeterministicWorkflowRunner.adapterExecutionContext` currently records only
`lastBackendEventAt/Type`. Extend:

- `WorkflowStepBackendEventInput` gains the new optional fields plus
  `sequence` (assigned by the runner from a per-execution counter).
- `WorkflowStepExecution` gains:

  ```swift
  public var backendEventCount: Int?
  public var recentBackendEvents: [WorkflowBackendEventRecord]?  // bounded ring, default cap 100
  public var streamedResponseText: String?  // rolling concat of assistant-channel content, capped 32 KiB (head+tail)
  ```

  `WorkflowBackendEventRecord` is a small Codable struct
  (`sequence`, `at`, `eventType`, `channel`, `content`, `toolName`, `usage`).
  `usage` retains the provider-native usage object for bounded live-tail and
  persisted-session readers; it is optional and does not affect
  `streamedResponseText`.
  The execution-level fields are optional, so persisted session JSON stays
  decodable both directions.
- `InMemoryWorkflowRuntimeStore.recordStepBackendEvent` appends to the ring
  (dropping oldest beyond cap), bumps count, and updates
  `streamedResponseText` for `.assistant` channel events (snapshot replaces;
  delta appends).
- Lifecycle-only events (no content) keep today's cheap path — timestamp +
  type only — so heartbeat cost does not grow.

**Deferred full-fidelity artifact contract**: a later read-surface phase may
append every enriched backend event as one JSONL line to
`<artifacts>/<sessionId>/<executionId>/backend-events.jsonl` when the run has
an artifact root (`--artifact-root` / server artifact layout), size-capped at
8 MiB per execution with a truncation marker. Phase 1 does not write or expose
that artifact; the in-store ring is the only retained live-tail data.

### 5. `WorkflowRunEvent` enrichment (CLI JSONL surface)

`WorkflowRunEvent` gains optional fields mirroring the adapter event:

```swift
public var backendEventChannel: String?
public var backendEventContent: String?     // coalesced delta or snapshot
public var backendEventIsDelta: Bool?
public var backendEventSequence: Int?
public var backendToolName: String?
public var backendEventUsage: JSONObject?  // provider-native usage snapshot
```

Because `WorkflowRunCommand` already forwards every run event to the live
JSONL writer, `riela workflow run ... --output jsonl` immediately streams
agent text with **no CLI changes**:

```jsonc
{"type":"backend_event","backendEventType":"item.completed",
 "backendEventChannel":"assistant",
 "backendEventContent":"Looking at the failing test, the cause is ...",
 "backendEventSequence":7,
 "sessionId":"...","stepId":"main-worker","executionId":"main-worker-attempt-1-exec-1", ...}
```

`session_started` / `step_*` / `session_completed` event shapes are untouched.
Consumers that ignore unknown fields (the documented JSONL contract) are
unaffected.

Usage follows the same Phase 1 path as content: classifier
`AdapterBackendEvent.usage` -> `WorkflowStepBackendEventInput.usage` ->
`WorkflowRunEvent.backendEventUsage` for live JSONL and
`WorkflowBackendEventRecord.usage` in the bounded runtime-store ring. Usage is
not written to the deferred full-fidelity `backend-events.jsonl` artifact in
Phase 1 because that artifact itself remains deferred. Session-store JSON
persists the optional record field through the existing Codable path. A usage
event has no effect on `streamedResponseText`; provider-native keys are kept
without normalization so new provider metrics remain forward compatible.

Text output mode (`--output text`) remains unchanged in Phase 1. A later phase
can add a lightweight live line through the same recorder hook, for example
`[step main-worker] assistant: <first 120 chars...>`.

### 6. Volume and cost controls

- Delta coalescing (§3): ≤ ~4 content events/sec per execution.
- Claude partial-message streaming is deferred with the Phase 2
  `stream-json` migration. When added, `--include-partial-messages` should be
  opt-in per node (`variables.claudeStreamPartialMessages: true`) so default
  granularity stays message-level.
- Node-level opt-out: `variables.streamBackendContent: false` downgrades the
  classifier to type-only events (today's behavior) for that node — useful
  for nodes whose output is sensitive or enormous.
- Telemetry remains content-free. If backend-event log records later add a
  `channel` attribute, streamed content must still never be put into telemetry
  attributes.

### 7. Read surfaces

Phase 1 exposes only the enriched live `WorkflowRunEvent` JSONL stream and the
runtime-store fields needed by future readers. The following surfaces are
deferred so the first implementation slice stays inside adapter, runner/store,
and CLI JSONL boundaries:

- **`riela session progress`** (`SessionCommands.swift`): a later phase can
  make running-execution
  rows add `backendEventCount`, last `channel`, and the tail of
  `streamedResponseText` (last ~200 chars). Gives "what is the agent saying
  right now" from any shell.
- **`riela session logs --follow <session-id>`** (new subcommand, later
  phase): tails `backend-events.jsonl` for the active execution, following
  the same watcher pattern as `CodexRolloutWatcher` (poll + offset), so users
  can attach to an already-running session they didn't start with `--output
  jsonl`.
- **GraphQL** (`RielaGraphQL`): a later phase can add a cursor-paged query to
  `GraphQLRuntimeSnapshotQueryService`:

  ```graphql
  stepBackendEvents(sessionId: ID!, executionId: ID, afterSequence: Int, limit: Int = 100):
    StepBackendEventPage!   # { events: [...], lastSequence, executionStatus }
  ```

  Polling with `afterSequence` gives at-least-once, ordered, duplicate-free
  consumption over plain request/response — no server transport change. The
  page reads from the in-store ring; if `afterSequence` has already been
  evicted from the ring, the response sets `truncated: true` and points at
  the artifact path.
- **RielaApp / RielaViewer**: `WorkflowViewer` snapshot rows already carry
  `lastBackendEventType`; a later phase can extend the snapshot model with
  `streamedResponseTail` and `backendEventCount`, and let the existing
  refresh path (manual refresh button today) render a live "Agent output"
  pane. A timer-based auto-refresh while a session is `running` is a small
  follow-on inside the app layer.

### 8. Testing

- **Unit — classifiers**: fixture lines captured from the real CLIs (the
  verified shapes above become test fixtures) → expected
  `AdapterBackendEvent`s. Include malformed JSON, non-event JSON, unknown
  event types, assistant/thinking/tool/usage/lifecycle records, and final
  stdout normalizer invariants for codex/cursor.
- **Unit — coalescer**: burst of 500 one-token deltas -> bounded flush count,
  byte-exact reassembly, and channel-switch flush. With a controllable clock,
  assert that one isolated delta followed by silence flushes at 250 ms; a
  pending delta flushes before a later non-delta event; success, error, and
  cancellation each perform one final drain before stream completion; and a
  cancelled timer cannot duplicate or reorder the final delta.
- **Unit — Phase 2 Claude normalizer (deferred)**: when
  `normalizeClaudeStreamJSONStdout` is added, it gets the same table-driven
  treatment as the codex/cursor normalizers in `AgentAdapterTests`, including
  the "not stream-json -> return text unchanged" invariant so
  `--output-format` overrides via `claudeAdditionalArgs` don't break the final
  result.
- **Integration — `LocalAgentCommandAdapter`**: scripted
  `LocalAgentProcessEventStreaming` mock runner that replays fixture lines
  with delays; assert event ordering, that the last backend event lands
  before `execute` returns, and that a slow `backendEventHandler` cannot
  stall the (mock) reader. Bridge coverage owns redaction, truncation, and
  `variables.streamBackendContent: false`.
- **Integration — runner/store (Phase 1)**: run a mock-scenario-less fake
  adapter emitting N events; assert ring cap, `backendEventCount`,
  `streamedResponseText` assembly, and enriched live `WorkflowRunEvent` JSONL
  fields, including exact `backendEventUsage` JSONL output and retained
  `WorkflowBackendEventRecord.usage`. Decode an old minimal run event and old
  persisted session with no usage field, then round-trip enriched usage to
  prove additive compatibility. Do not assert `backend-events.jsonl` artifact
  contents in Phase 1.
- **Integration — artifact log (later read-surface phase)**: once
  `backend-events.jsonl` is implemented, assert artifact append ordering, size
  cap/truncation marker behavior, and post-hoc tail/read behavior separately
  from Phase 1 runner/store coverage.
- **CLI e2e (manual/verify skill)**: `riela workflow run
  examples/worker-only-single-step ... --output jsonl` against real codex
  shows `backendEventContent` lines arriving before `step_completed`
  (baseline for this behavior was captured during this design's
  investigation).

## Rollout Plan

1. **Phase 1 — contracts + codex/cursor content** (no CLI flag changes):
   `AdapterBackendEvent` enrichment, `AsyncStream` bridge + coalescer,
   codex/cursor classifiers, `WorkflowRunEvent` fields, store ring +
   `streamedResponseText`, JSONL surface. Ships user-visible streaming for
   two backends immediately.
2. **Phase 2 — claude stream-json migration**: builder flag change +
   `normalizeClaudeStreamJSONStdout` + classifier + heartbeat fix. Isolated
   so a claude CLI output-format regression can be reverted independently.
3. **Phase 3 — read surfaces**: `session progress` enrichment, artifact
   JSONL, GraphQL `stepBackendEvents`, viewer tail pane.
4. **Phase 4 (optional)** — `session logs --follow`, text-mode live lines,
   claude partial-message opt-in docs, SSE/subscription transport
   exploration.

## Compatibility & Risk Notes

- All schema changes are additive-optional; new decoders accept persisted
  sessions and run events written without usage, while compatibility tests
  require old/unknown-field-tolerant consumers to continue accepting enriched
  JSONL and session records. Downgrade readers that reject unknown JSON fields
  are outside the documented compatibility contract.
- The final-response path is untouched in Phase 1 (codex/cursor normalizers
  unchanged); Phase 2's claude normalizer is the only behavior change to
  result extraction and is covered by table-driven tests plus the defensive
  "non-JSON passes through" rule.
- Event flood risk is bounded at three layers: coalescer (rate), stream
  buffer (`bufferingNewest(512)`, drops observability only), store ring
  (memory), artifact cap (disk).
- `codex exec --json` / `cursor-agent stream-json` / `claude stream-json`
  event vocabularies drift with CLI releases; classifiers must treat unknown
  types as `.lifecycle` with the raw type string, never fail, and never gate
  the result path — same resilience posture as the existing
  `is<Backend>JSONEvent` allowlists.
- Streamed content may contain secrets the *agent* printed (not just env
  values). The redaction pass catches configured env values; the node-level
  `streamBackendContent: false` opt-out is the escape hatch for sensitive
  workflows, and artifacts inherit the session store's existing access model.
