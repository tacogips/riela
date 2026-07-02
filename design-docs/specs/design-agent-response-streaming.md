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

This document designs response streaming: surfacing agent output content
(assistant text, thinking, tool activity, usage) incrementally while a node
executes, end to end from the child process pipe to the CLI JSONL stream, the
runtime store, session artifacts, and the GraphQL/viewer surfaces.

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

### Gaps this design closes

- G1. Backend events carry no content — only a type string.
- G2. `claude-code-agent` emits zero backend events (text output format), so
  it has no heartbeat either, despite
  `workflowAutoImproveBackendSupportsHeartbeat` claiming heartbeat support
  for it.
- G3. The runtime store keeps only the *last* event type/timestamp; there is
  no live tail for `session progress`, the viewer, or GraphQL.
- G4. The per-event bridge in `LocalAgentCommandAdapter.outputEventHandler`
  blocks the pipe-reader thread with a `DispatchSemaphore` around an async
  store write for *every* line. Acceptable at 4 events/run; hostile at
  token-delta rates (cursor emits dozens of events per second).
- G5. No content-bearing streaming surface exists for library/GraphQL/app
  consumers; RielaApp shows only `lastBackendEventType`.

## Goals

- Stream agent response content (assistant text, thinking, tool activity,
  usage, lifecycle) per executing node, live, for all three CLI agent
  backends.
- Preserve the existing completion contract: `normalizeStdout` over the full
  buffered stdout remains the source of truth for
  `AdapterExecutionOutput`. Streaming is additive observability; a stream
  consumer crash or missed event must never change run results.
- Keep `WorkflowRunEvent` and the persisted session record schemas
  backward-compatible (new optional fields only).
- Bound memory and event volume: delta coalescing, per-execution ring buffer,
  size-capped artifact log.
- Redact sensitive environment values from streamed content with the existing
  `redactAdapterSensitiveText` machinery before anything leaves the adapter.

## Non-Goals

- Real GraphQL subscriptions / SSE / WebSocket transport. The deterministic
  request/response server (`DeterministicServerRouteHandler`) stays as-is; we
  add a cursor-based polling query instead. Push transport can layer on later.
- Streaming for `official/*-sdk` backends (OpenAI/Anthropic/Gemini/Cursor SDK
  adapters use buffered `URLSession` requests; SSE support there is a separate
  effort).
- Interactive mid-run input to the agent (that is the manager control plane's
  job).
- Changing mock-scenario or stdio node executor behavior.

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
JSON parsing:

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

- **claude-code-agent** (`Sources/ClaudeCodeAgent/ClaudeCodeAgentAdapter.swift`)
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
// outputEventHandler now only classifies + coalesces + yields:
{ outputEvent in
  guard outputEvent.stream == .stdout,
        let event = classify(outputEvent.line) else { return }
  eventContinuation.yield(coalescer.absorb(event) /* may return nil */)
}
// after runner.run returns (or throws):
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

**Delta coalescing** lives in front of the continuation: a small
`BackendEventCoalescer` merges consecutive same-channel delta events and
flushes when (a) accumulated delta ≥ 256 UTF-8 bytes, (b) 250 ms elapsed since
first absorbed delta, or (c) a different-channel/non-delta event arrives.
This turns cursor's per-token firehose into ~4 events/second worst case while
keeping codex/claude item-level events untouched.

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
  (`sequence`, `at`, `eventType`, `channel`, `content`, `toolName`).
  All optional → persisted session JSON stays decodable both directions.
- `InMemoryWorkflowRuntimeStore.recordStepBackendEvent` appends to the ring
  (dropping oldest beyond cap), bumps count, and updates
  `streamedResponseText` for `.assistant` channel events (snapshot replaces;
  delta appends).
- Lifecycle-only events (no content) keep today's cheap path — timestamp +
  type only — so heartbeat cost does not grow.

**Full-fidelity artifact**: when the run has an artifact root
(`--artifact-root` / server artifact layout), the runner appends every
enriched backend event as one JSONL line to
`<artifacts>/<sessionId>/<executionId>/backend-events.jsonl`, size-capped at
8 MiB per execution (stop writing + record a truncation marker line). The
in-store ring is for live UIs; the artifact is for post-hoc debugging and
`riela-troubleshooting` flows.

### 5. `WorkflowRunEvent` enrichment (CLI JSONL surface)

`WorkflowRunEvent` gains optional fields mirroring the adapter event:

```swift
public var backendEventChannel: String?
public var backendEventContent: String?     // coalesced delta or snapshot
public var backendEventIsDelta: Bool?
public var backendEventSequence: Int?
public var backendToolName: String?
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

Text output mode (`--output text`) additionally gains a lightweight live
line — `[step main-worker] assistant: <first 120 chars…>` — written through
the same recorder hook; this is a small, isolated change in the text renderer
and can ship in a later phase.

### 6. Volume and cost controls

- Delta coalescing (§3): ≤ ~4 content events/sec per execution.
- `--include-partial-messages` for claude is **opt-in** per node
  (`variables.claudeStreamPartialMessages: true`); default granularity is
  message-level `assistant` events, which are cheap and still much better
  than today's nothing.
- Node-level opt-out: `variables.streamBackendContent: false` downgrades the
  classifier to type-only events (today's behavior) for that node — useful
  for nodes whose output is sensitive or enormous.
- Telemetry: `riela.workflow.backend.event` log records gain a `channel`
  attribute; content is **never** put into telemetry attributes.

### 7. Read surfaces

- **`riela session progress`** (`SessionCommands.swift`): running-execution
  rows add `backendEventCount`, last `channel`, and the tail of
  `streamedResponseText` (last ~200 chars). Gives "what is the agent saying
  right now" from any shell.
- **`riela session logs --follow <session-id>`** (new subcommand, later
  phase): tails `backend-events.jsonl` for the active execution, following
  the same watcher pattern as `CodexRolloutWatcher` (poll + offset), so users
  can attach to an already-running session they didn't start with `--output
  jsonl`.
- **GraphQL** (`RielaGraphQL`): add a cursor-paged query to
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
  `lastBackendEventType`; extend the snapshot model with
  `streamedResponseTail` and `backendEventCount`, and let the existing
  refresh path (manual refresh button today) render a live "Agent output"
  pane. A timer-based auto-refresh while a session is `running` is a small
  follow-on inside the app layer.

### 8. Testing

- **Unit — classifiers**: fixture lines captured from the real CLIs (the
  verified shapes above become test fixtures) → expected
  `AdapterBackendEvent`s. Include malformed JSON, non-event JSON, huge lines
  (truncation), and lines containing a sensitive env value (redaction).
- **Unit — coalescer**: burst of 500 one-token deltas → bounded flush count,
  byte-exact reassembly, channel-switch flush.
- **Unit — normalizers**: new `normalizeClaudeStreamJSONStdout` gets the same
  table-driven treatment as the codex/cursor normalizers in
  `AgentAdapterTests`, including the "not stream-json → return text
  unchanged" invariant so `--output-format` overrides via
  `claudeAdditionalArgs` don't break the final result.
- **Integration — `LocalAgentCommandAdapter`**: scripted
  `LocalAgentProcessEventStreaming` mock runner that replays fixture lines
  with delays; assert event ordering, that the last backend event lands
  before `execute` returns, and that a slow `backendEventHandler` cannot
  stall the (mock) reader.
- **Integration — runner/store**: run a mock-scenario-less fake adapter
  emitting N events; assert ring cap, `backendEventCount`,
  `streamedResponseText` assembly, and JSONL artifact contents.
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

- All schema changes are additive-optional; persisted sessions written by old
  binaries decode in new binaries and vice versa.
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
