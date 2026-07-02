# Riela Core / Add-on Layer Review Findings And Improvement Designs

## Summary

This document records a design and implementation review of the non-app parts
of Riela — `RielaCore`, `RielaAdapters`, `RielaAddons`, `RielaEvents`,
`RielaGraphQL`, `RielaServer`, `RielaObservability`, `RielaHook`, the shared
CLI runtime plumbing in `RielaCLI` that backs those layers, and the three
agent adapter packages (`ClaudeCodeAgent`, `CodexAgent`, `CursorCLIAgent`).
`RielaApp` UI code is out of scope.

The review found no correctness catastrophe: the runtime is deterministic,
value-typed, well-tested, and consistently `Sendable`. The dominant problems
are structural: an event contract that grows by optional-field accretion, a
per-event full-snapshot persistence path that turns streaming into O(n²) I/O,
three hand-rolled SQLite layers, ~25k lines of brand-cloned agent adapter
code, ten copies of the same failure-publication block inside the runner, and
an observability exporter that emits a payload no OTLP collector accepts.

Each finding below has a location, an impact statement, and a concrete
improvement design. A prioritized roadmap and migration notes close the
document.

Reviewed at commit `09d8d12` (branch `rielaapp-ux-onboarding-improvements`,
2026-07-02), including the in-flight agent-response-streaming working-tree
changes where they affect the analysis.

## Review Scope And Method

- Read every file in `RielaCore` runtime paths (runner + extensions, stores,
  publication, validation), `RielaAdapters`, `RielaAddons` resolver/manifest,
  `RielaEvents`, `RielaGraphQL`, `RielaServer`, `RielaObservability`,
  `RielaHook`.
- Sampled `RielaCLI` only where it hosts runtime infrastructure used by the
  core loop (`WorkflowRunCommand`, `CLIWorkflowSessionStore`,
  `WorkflowRunLivePersistence`).
- Measured agent-adapter duplication by brand-normalized diff
  (`sed s/ClaudeCode|Codex|CursorCLI/X/` then `diff`).
- Cross-checked findings against the active
  `design-agent-response-streaming.md` spec because streaming multiplies the
  cost of several existing hot paths.

Severity legend: **P1** correctness or scalability defect that will bite as
streaming/scale lands; **P2** structural debt with high ongoing cost; **P3**
polish / hardening.

---

## Findings And Improvement Designs

### F1 (P1) Per-run-event full-snapshot persistence is O(n²) and will collapse under streaming

**Location**: `Sources/RielaCLI/WorkflowRunCommand.swift:95-111`
(`runEventHandler`), `Sources/RielaCLI/CLIWorkflowSessionStore.swift:90-110`
(`save`), `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift:34-42`
(`save(_:in:)` → `replaceMessages`).

**Problem**: the CLI installs a `WorkflowRunEventHandler` that calls
`persistLiveSessionRecordIfPresent` for **every** `WorkflowRunEvent` without
filtering by `event.type`. Each call:

1. loads the full session from the in-memory store (value copy of every
   execution, including `recentBackendEvents` and `streamedResponseText`),
2. lists **all** workflow messages,
3. opens a new SQLite connection, runs `BEGIN IMMEDIATE`,
4. re-runs DDL (`ensureSchema` → `CREATE TABLE IF NOT EXISTS`, `PRAGMA
   table_info`, JSONB probe) inside the transaction,
5. JSON-encodes the entire session,
6. **deletes and re-inserts every message row** (`replaceMessages`),
7. commits and closes the connection.

Today the event volume per step is small. The agent-response-streaming design
(Phase 1, in flight) makes `backend_event` fire per assistant/tool delta —
hundreds to thousands per node. Cost per event is proportional to
session-so-far size, so a long session degrades quadratically, and the write
lock (`BEGIN IMMEDIATE`) is taken at delta frequency against the same file
other processes (`events serve`, `session progress`) read.

**Improvement design**:

1. **Filter by event type at the call site.** Persist full snapshots only on
   `session_started`, `step_started`, `step_completed`, `session_completed`.
   `backend_event` must never trigger snapshot persistence.
2. **Debounce a live-tail flush.** For live visibility of streamed text, add a
   `WorkflowRunLivePersistenceState.scheduleTailFlush(sessionId:)` on the
   existing actor: coalesce to at most one flush per N ms (default 500 ms,
   env-tunable `RIELA_LIVE_PERSIST_INTERVAL_MS`), writing only the *current
   execution's* live-tail columns (see F2's split), not the whole snapshot.
3. **Make message persistence incremental.** `WorkflowMessageRecord` is
   append-only in practice (`createdOrder` is monotonic). Replace
   `replaceMessages` in the live path with
   `appendMessages(after lastPersistedOrder:)`; keep `replaceMessages` only
   for rerun/import flows that legitimately rewrite history. Track
   `lastPersistedOrder` per session in `WorkflowRunLivePersistenceState`.
4. **Hold one connection per run.** Open the SQLite handle once when the run
   starts, enable `PRAGMA journal_mode=WAL` and `PRAGMA busy_timeout=3000`,
   run `ensureSchema` once, and reuse the handle for every flush. Close on
   terminal event. This also removes DDL-inside-transaction (F8).

**Acceptance**: a mock-scenario run emitting 10k backend events must persist
with O(events) total I/O and produce identical final snapshots to today
(existing `RuntimeStoreTests` + a new throughput regression test).

### F2 (P1) Backend-event hot path copies the whole session per delta and re-caps text O(n²)

**Location**: `Sources/RielaCore/RuntimeStore.swift:532-629`
(`recordStepBackendEvent`, `cappedStreamedResponseText`,
`byteBoundPrefix/Suffix`), `Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift:42-76`.

**Problem**: every `AdapterBackendEvent` does
`store.recordStepBackendEvent(...)` followed by `store.loadSession(...)`.
Both operations copy the full `WorkflowSession` value — an array of all
executions, each carrying up to 100 `recentBackendEvents` and a 32 KiB
`streamedResponseText`. On top of that, `cappedStreamedResponseText` walks the
accumulated string character-by-character (`byteBoundPrefix` recounts
`prefix.utf8.count` inside the loop, making a single cap call itself
quadratic) on **every delta**. Combined with F1 this is the single biggest
scalability hazard of the streaming feature.

**Improvement design**:

1. **Split the live tail out of `WorkflowSession`.** Introduce a
   `WorkflowExecutionLiveTail` value (executionId, byte-capped text ring,
   lastEventAt, lastEventType, eventCount, recent events ring) held by the
   store in a separate `[String: WorkflowExecutionLiveTail]` keyed by
   executionId. `recordStepBackendEvent` touches only this small struct.
   `WorkflowStepExecution.streamedResponseText` / `recentBackendEvents` become
   projections filled in when a session is *read*
   (`loadSession(includeLiveTail:)`) or when the execution completes, not
   mutated per delta.
2. **Cap incrementally.** Keep the tail as a `Deque<UInt8>`-style byte buffer
   (or `[UInt8]` with head index) with a running byte count: append the delta
   bytes, drop from the front while over the 32 KiB cap, and materialize a
   `String` lazily only when read (repairing a leading partial UTF-8 sequence
   at that point). Appending becomes O(delta), reading stays O(cap).
3. **Stop reloading the session per delta.** The runner's backend-event
   handler in `DeterministicWorkflowRunner+ExecutionEvents.swift` reloads the
   session only to fill `WorkflowRunEvent.status/currentStepId/
   nodeExecutions`. During a step these are constants; capture them once at
   `recordStepStartedExecution` and reuse. Add a narrow
   `store.recordStepBackendEvent` return type
   (`WorkflowBackendEventReceipt`: sequence + at) so the emit path never sees
   the full session.

### F3 (P1) `WorkflowRunEvent` is a flat bag of 17 optionals — the event contract cannot grow safely

**Location**: `Sources/RielaCore/DeterministicWorkflowRunner.swift:56-125`.

**Problem**: one struct serves five event types, discriminated by a `type`
enum with every payload field optional (`backendEventType`,
`backendEventChannel`, `backendEventContent`, `backendEventIsDelta`,
`backendEventSequence`, `backendToolName`, `backendEventUsage`, `exitCode`,
…). Nothing prevents constructing a `sessionCompleted` event carrying
`backendToolName`, consumers must defensively unwrap everything, and each new
capability (streaming already added seven fields) widens every event. The
same shape is serialized into JSONL artifacts, so the accretion is also a
persisted-format problem.

**Improvement design**: convert to an enum with associated payload structs
while keeping the wire format stable:

```swift
public enum WorkflowRunEvent: Sendable, Equatable {
  case sessionStarted(SessionEnvelope)
  case stepStarted(SessionEnvelope, StepEnvelope)
  case backendEvent(SessionEnvelope, StepEnvelope, BackendEventPayload)
  case stepCompleted(SessionEnvelope, StepEnvelope, StepCompletionPayload)
  case sessionCompleted(SessionEnvelope, SessionCompletionPayload)
}
```

- `SessionEnvelope` = workflowId, sessionId, status, currentStepId.
- Custom `Codable` implementation flattens to the **existing** JSON keys
  (`type` + today's field names), so JSONL artifacts, `--output jsonl`
  consumers, and RielaApp stay byte-compatible. Round-trip tests against the
  current fixtures gate the change.
- Consumers switch exhaustively; adding a payload field to one case no longer
  touches the other four.
- `emitRunEvent`/`telemetryAttributes` in
  `DeterministicWorkflowRunner+Events.swift` become a single
  `switch`, deleting the per-event builder duplication.

### F4 (P1) Ten near-identical failure-publication blocks in the runner, all swallowing publish errors

**Location**: `Sources/RielaCore/DeterministicWorkflowRunner.swift` — repeated
in `executeStdioNodeAndPublish` (×3), `executeAndPublish` (×4),
`executeAddonAndPublish` (×5); each is

```swift
_ = try? await publisher.publishAcceptedOutput(
  WorkflowPublicationRequest(sessionId:…, stepId:…, nodeId:…, attempt:…,
    adapterFailure: adapterFailure, transitions: transitions,
    publishesRootOutput: transitions.isEmpty))
throw adapterFailure
```

**Problem**: (a) copy-paste drift risk — the blocks already diverge subtly
(some pass `backend:`, some pass `adapterOutput:` alongside the failure);
(b) `try?` silently discards publication failures, so a session can end with
an execution stuck in `.running` and no diagnostic anywhere (the store's
failure record is the *only* durable trace of why a step failed); (c) the
publisher *also* re-throws the adapter failure it was given, so error flow is
decided in two layers.

**Improvement design**: introduce one helper on the runner:

```swift
@discardableResult
func publishFailureAndThrow(
  _ failure: AdapterExecutionError,
  step: WorkflowStepRef, sessionId: String, attempt: Int,
  backend: NodeExecutionBackend? = nil,
  adapterOutput: AdapterExecutionOutput? = nil,
  transitions: [WorkflowStepTransition],
  telemetry note: String? = nil
) async throws -> Never
```

- It performs the publication, and when the publication itself fails it
  attaches that as a diagnostic (log via `telemetry.recordLog` with
  `riela.workflow.publish.failure`) instead of discarding it, then throws the
  original failure.
- All ten call sites collapse to one line; `executeAndPublish`'s catch
  ladder shrinks to `catch let e as AdapterExecutionError { try await
  publishFailureAndThrow(e, …) }`.
- Follow-up (same change): `WorkflowPublicationRequest` currently multiplexes
  four mutually exclusive candidate sources (`adapterFailure`,
  `adapterOutput`, `inlineCandidate`, `candidatePath`) validated at runtime
  (`ambiguousCandidateSources`). Model it as
  `enum WorkflowPublicationBody { case failure(AdapterExecutionError,
  adapterOutput: AdapterExecutionOutput?); case adapterOutput(…);
  case inline(JSONObject); case candidatePath(URL, RuntimeCandidatePathReservation);
  case none }` so ambiguity is unrepresentable and
  `runtimeCandidate(from:)`'s manual source counting disappears.

### F5 (P2) Three brand-cloned agent adapter packages (~30k lines) triple every fix

**Location**: `Sources/ClaudeCodeAgent` (25 files / 10.3k lines),
`Sources/CodexAgent` (21 / 8.5k), `Sources/CursorCLIAgent` (24 / 10.7k).

**Problem**: brand-normalized diffs show the packages are structural clones:

| pair | lines | differing lines after renaming |
|---|---|---|
| ClaudeCode vs Codex `ProcessIO` | 190 | 9 |
| ClaudeCode vs Codex `RolloutWatcher` | 137 | 4 |
| Codex vs Cursor `SessionSQLiteIndex` | 73 | 22 |
| Codex vs Cursor `ProcessManager` | ~594 | 55 |
| Codex vs Cursor `AgentAdapter` | ~385 | 318 (genuinely provider-specific) |

The adapter layer itself (`*AgentAdapter.swift`) is legitimately
provider-specific; nearly everything else (process management, pipe IO,
rollout watching, session indexes, operational stores, queue commands, usage
stats, GraphQL command executors) is the same code with renamed types. The
current git status demonstrates the tax: the streaming change touches
`CodexAgentAdapter.swift` *and* `CursorCLIAgentAdapter.swift` with parallel
edits, and every future fix must be triplicated (and can silently miss one
clone — the 9/4/22-line diffs above already contain unintentional drift
candidates).

**Improvement design**: extract a shared `AgentRuntimeKit` target:

1. Move the clone families in dependency order, lowest-risk first:
   `ProcessIO` → `RolloutWatcher` → `SessionSQLiteIndex` →
   `Operations`/`OperationalStores` → `ProcessManager` → `Polling`/`Queue`.
2. Parameterize by a small `AgentProviderDescriptor` value (provider id,
   executable name, rollout file layout, session-dir resolution, env-var
   names) plus narrow protocol hooks where behavior actually differs (the
   22/55 differing lines — e.g., cursor effort resolution, codex queue
   semantics).
3. Each brand package shrinks to: its descriptor, its `AgentAdapter`
   (stdout normalization + backend-event classification, which are genuinely
   different), and re-exports for source compatibility. Public API of the
   three packages is preserved via `public typealias` shims for one release.
4. Gate each extraction with the existing `AgentAdapterTests` +
   `AgentAdapterStreamingTests` running against all three providers
   (parameterized over descriptors), which converts today's copy-paste tests
   into a conformance suite.

This is the highest-leverage maintainability change in the codebase: it
removes ~15–18k duplicated lines and makes "add a fourth agent backend" a
descriptor + one adapter file.

### F6 (P2) Three hand-rolled SQLite stacks with divergent error enums and per-call connections

**Location**: `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`,
`Sources/RielaCore/SQLiteWorkflowMessageLog.swift`,
`Sources/RielaCLI/CLIWorkflowSessionStore.swift` (plus the per-agent
`*SessionSQLiteIndex.swift` clones counted under F5).

**Problem**: each file re-implements `openDatabase`, `execute`, `queryRows`,
`bind`, transient destructor, `sqliteErrorMessage`, ISO8601 formatting, and
JSONB probing, with three different error enums
(`WorkflowRuntimePersistenceStoreError`, `SQLiteWorkflowMessageLogError`,
`CLIWorkflowSessionStoreError`) and three different binding enums. None set
`journal_mode=WAL` or `busy_timeout`, so concurrent access (an `events serve`
process persisting while a user runs `riela session progress`) surfaces as an
opaque `sqliteFailed("database is locked")`. Connections are opened and
closed per operation; `ISO8601DateFormatter` is allocated per row.
`SQLiteWorkflowRuntimePersistenceStore.save(_:in:)` also constructs a
`SQLiteWorkflowMessageLog` with a *path* but then writes through the *foreign
handle* it was passed — the path is dead weight and the coupling is
non-obvious.

**Improvement design**: add a small internal `RielaSQLite` target (no ORM):

```swift
struct SQLiteDatabase {              // owns the handle
  static func open(path:, mode:, options: [.wal, .busyTimeout(3000)]) throws -> SQLiteDatabase
  func transaction<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T
  func execute(_ sql: String, _ bindings: [SQLiteValue]) throws
  func query(_ sql: String, _ bindings: [SQLiteValue]) throws -> [SQLiteRow]
}
enum SQLiteValue { case text(String), int(Int64), null, json(String) }
struct SQLiteError: Error { let code: Int32; let message: String; let sql: String? }
```

- One error type wrapped by each store into its domain error (so public
  error contracts don't change).
- WAL + busy_timeout on by default; JSONB probe done once per open.
- Schema setup expressed as an ordered migration list run once per
  connection, outside caller transactions (fixes DDL-inside-transaction,
  F8).
- The three stores keep their schemas and public APIs; they lose ~600 lines
  of plumbing and gain consistent locking behavior. The F5 extraction reuses
  the same kernel for the agent session indexes.

### F7 (P2) Loop-engineering workflow semantics are hardcoded inside the generic adapter contract layer

**Location**: `Sources/RielaCore/AdapterContracts.swift:233-311`
(`reconcileCompletionReviewRouting`, `isCompletionReviewPayload`,
`expectedGoalCompletionRouting`), and the JSON-extraction heuristics at
`AdapterContracts.swift:327-428`.

**Problem**: `AdapterContracts.swift` is the neutral contract between the
runtime and *any* node backend, yet it contains logic that recognizes the
specific payload vocabulary of the loop-engineering workflows
(`needs_replan`, `needs_work`, `accepted`, `goalAchieved`, `decision`) and
silently rewrites a node's `when` routing map when the payload "looks like" a
completion review. Consequences: (a) any user workflow that happens to use a
`decision` or `goalAchieved` key gets its explicitly-returned routing
overridden by core; (b) the loop-engineering feature can't evolve its
vocabulary without editing the adapter contract file; (c) the behavior is
invisible — no diagnostic is emitted when reconciliation rewrites routing.
Separately, ~100 lines of markdown-fence/balanced-brace JSON extraction
heuristics (`extractJSONObjectCandidateText` et al.) also live here — that is
parsing *policy*, not contract.

**Improvement design**:

1. Move reconciliation into the loop layer: `LoopPolicyEvaluating` (or a new
   `WorkflowRoutingReconciling` hook on `DeterministicWorkflowRunner`,
   defaulting to no-op) applies it only when the step is part of a loop
   policy / the node opts in via payload contract metadata
   (`output.completionReview == true` in `workflow.json`).
2. When reconciliation changes routing, record it: append a diagnostic to the
   step execution (`failureReason` is wrong; add
   `WorkflowStepExecution.notes: [String]?` or a telemetry log
   `riela.workflow.routing.reconciled`) so users can see why a branch fired.
3. Move `parseJSONObjectCandidate` + extraction helpers to a
   `RuntimeOutputExtraction.swift` in RielaCore (same module, separate file,
   clearly named as heuristics) or into `RuntimeOutputValidation.swift`
   which is their only consumer family.

### F8 (P3) Persistence-store hygiene: DDL in transactions, duplicated encoding, formatter allocation

**Location**: `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`.

**Problem** (independent of F6 but fixed by it): `save(_:in:)` runs
`ensureSchema` (DDL + `ALTER TABLE` probe) inside the caller's
`BEGIN IMMEDIATE` transaction; `upsertSnapshot` JSON-encodes `rootOutput` and
`loopEvidence` **twice each** (once per placeholder in the
`CASE WHEN ? IS NULL` binding pattern); `dateString` allocates an
`ISO8601DateFormatter` per call; `loadAll` decodes every session's messages
via a *second* store instance and a fresh connection per session
(`snapshot(from:)` → `SQLiteWorkflowMessageLog(...).listMessages`), making
`loadAll` open N+1 connections.

**Improvement design**: fold into F6's kernel migration — schema as
migrations on open; bind encoded JSON once into a local; make the ISO8601
formatter a `static let`; give `snapshot(from:)` access to the already-open
handle for message loading (`listMessages(in db:)` variant, which
`SQLiteWorkflowMessageLog` already has internally for writes).

### F9 (P2) `maxConcurrency` and fanout/cross-workflow transitions are accepted but not implemented — failures surface only at runtime

**Location**: `Sources/RielaCore/DeterministicWorkflowRunner.swift:9`
(`maxConcurrency` never read), `Sources/RielaCore/RuntimePublication.swift:389-402`
(`unsupportedTransitionReason` — "not supported by the Swift TASK-005
in-memory publisher"), `DeterministicWorkflowRunner+Prompting.swift:168`
("multiple direct transitions are not supported by the Swift TASK-007
sequential runner").

**Problem**: `WorkflowModel` and `DefaultWorkflowValidator` accept fanout,
cross-workflow, and resume-step transitions; the CLI parses and forwards
`--max-concurrency`; the runner threads it into the request — and then the
run **fails mid-session** at the step that first uses the feature, after
earlier steps have already executed (and possibly caused side effects via
agents). The request field silently does nothing. The "TASK-005/TASK-007"
wording in user-facing errors references internal migration task ids that
mean nothing to users.

**Improvement design**:

1. **Preflight, don't discover.** Extend the runner's validation phase
   (`run()` already validates the workflow) with a *capability check*: walk
   reachable steps and reject the run before creating a session when the
   workflow uses transitions the configured publisher/runner cannot execute.
   Message format: `step 'x' uses fanout transitions, which this runner does
   not support yet`. Implement as
   `DeterministicWorkflowRunner.unsupportedFeatures(in: WorkflowDefinition)
   -> [WorkflowRuntimeCapabilityGap]` so `riela workflow validate` can also
   surface it statically.
2. **Remove or implement `maxConcurrency`.** Until parallel fanout exists,
   reject the option at CLI parse time with "reserved for fanout execution;
   not yet supported" instead of accepting and ignoring it. Keep the request
   field (wire compatibility) but document it as reserved.
3. Replace `TASK-00x` strings with feature-named messages; the task ids can
   stay in code comments if useful.

### F10 (P2) Runner step loop does linear scans per iteration and duplicates the routing decision with the store

**Location**: `Sources/RielaCore/DeterministicWorkflowRunner.swift:304-357`,
`Sources/RielaCore/RuntimeStore.swift:676-681`.

**Problem**: each loop iteration does `workflow.steps.first(where:)` and
`nodeRegistry.first(where:)` — O(steps) per transition, O(steps²) per run
with loops; fine at 10 steps, wasteful at 200 with `maxLoopIterations`.
More important: **two places decide the next step** — the runner takes
`publishResult.publishedMessages.first?.toStepId`, while
`InMemoryWorkflowRuntimeStore.appendWorkflowMessages` *also* writes
`session.currentStepId = records.first?.toStepId`. They agree today because
the publisher publishes at most one message, but the moment fanout publishes
several, "first" is an arbitrary and store-dependent choice, and the two
sites can diverge.

**Improvement design**:

1. Build `stepsById: [String: WorkflowStepRef]` and
   `nodesById: [String: WorkflowNodeRegistryRef]` once at the top of `run()`
   (a `WorkflowExecutionPlan` struct; also a natural home for the F9
   capability preflight).
2. Make routing explicit and single-sourced: add
   `WorkflowPublicationResult.nextStepId: String?` computed by the
   *publisher* (which owns transition evaluation) and have the runner consume
   only that; remove the `currentStepId` side-write from
   `appendWorkflowMessages` (the store should record, not route) — the
   publisher already updates the execution and can set `currentStepId`
   explicitly via the existing update input.

### F11 (P2) Observability: exporter payload is not OTLP, spans have fabricated durations, buffers are unbounded, flush is best-effort-invisible

**Location**: `Sources/RielaObservability/RielaObservability.swift:283-380`
(`OTLPRielaTelemetryExporter`, `sendBestEffort`, `OTLPPayload`),
`Sources/RielaCore/DeterministicWorkflowRunner+Events.swift:136-150`.

**Problem**:

1. `OTLPPayload` (`{serviceName, surface, resourceAttributes, records}`) is a
   custom JSON shape POSTed to `/v1/traces|logs|metrics`. Real OTLP/HTTP
   requires the `ExportTraceServiceRequest` JSON mapping
   (`resourceSpans[].scopeSpans[].spans[]` with `traceId`/`spanId`,
   nanosecond epoch strings). Every standard collector will 400 this payload,
   so the "OTel" integration only works against a bespoke receiver — but the
   env vars (`OTEL_EXPORTER_OTLP_ENDPOINT`) advertise standard behavior.
2. Step/run spans are created at completion with `startedAt: Date()` — all
   spans are zero-duration; latency analysis is impossible.
3. The exporter actor accumulates spans/logs/metrics without bound until
   `flush` is called, and `flush` is called only in three CLI paths — a
   long-lived `events serve` process leaks memory at streaming-event rate
   (every backend event records a log line, F1×F11 compounding).
4. `sendBestEffort`'s `catch {}` swallows all errors; the timeout race
   (`group.next()` then `cancelAll`) abandons in-flight sends without any
   counter, so exporting can be 100% broken with zero signal.

**Improvement design**:

1. **Emit real OTLP JSON.** Implement the OTLP/HTTP JSON mapping for the
   three signals (small, dependency-free: ~200 lines of encodable structs),
   generating random `traceId`/`spanId` (`RielaTraceContext` already produces
   hex ids) and honoring the parent context from
   `telemetryChildProcessEnvironment`. Keep the legacy shape behind
   `RIELA_OTEL_LEGACY_PAYLOAD=1` for one release if the bespoke receiver
   exists in the wild.
2. **Real span timing.** `recordStepStartedExecution` already exists — carry
   `execution.createdAt` into the step-completed emission and pass it as
   `startedAt` (add `startedAt` to the event payload in the F3 redesign;
   until then, look it up from `publishResult.stepExecution.createdAt`).
   Same for the run span via `session.createdAt`.
3. **Bound + auto-flush.** Give the exporter a max buffer (e.g., 2 048
   records per signal, drop-oldest with a dropped-count attribute) and a
   periodic flush task (`Task` started on first record, every 10 s) so
   long-lived surfaces don't require call-site discipline.
4. **Surface export failures once.** Keep exports non-blocking, but count
   consecutive failures and emit a single stderr warning (or a
   `riela.telemetry.export.failed` self-log) on first failure and on
   recovery.

### F12 (P2) `LocalAgentProcess` stdin handling can block the calling thread indefinitely or crash on a dead child

**Location**: `Sources/RielaAdapters/LocalAgentProcess.swift:697-699` (stdin
write), whole-file structure (~900 lines of `@unchecked Sendable` lock
choreography).

**Problem**: after spawning, the parent writes the entire prompt with
`inputPipe.fileHandleForWriting.write(Data(stdin.utf8))` **synchronously on
the task thread inside `withCheckedThrowingContinuation`**:

- Prompts larger than the pipe buffer (64 KiB on macOS) block until the child
  drains stdin. A child that doesn't read stdin (crash loop, waiting on
  something else) blocks a Swift-concurrency cooperative thread until the
  deadline fires.
- When the deadline/cancellation path runs, `closeForFailureOrTimeout`
  closes the write handle *while the write may be in progress*, and
  `FileHandle.write` raises an ObjC `NSFileHandleOperationException` on a
  closed/broken pipe — which Swift cannot catch → process crash. Same if the
  child exits before consuming stdin (EPIPE).
- Riela composes prompts from templates + resolved inputs + memory guidance;
  >64 KiB prompts are realistic for loop-engineering workflows.

Secondary: the file implements a five-class manual concurrency machine
(`LockedProcessData`, `LocalProcessPipes`, `LocalProcessCompletion`,
`LocalProcessCancellationState`, `LocalProcessHandle`) that is hard to verify
and duplicated in spirit inside each agent package's `ProcessManager`
(→ F5).

**Improvement design**:

1. **Immediate hardening (small diff)**: move the stdin write onto the same
   utility queue pattern as the readers, writing in chunks via
   `write(fd, …)` (POSIX, returns -1/EPIPE instead of throwing) with `SIGPIPE`
   ignored (`signal(SIGPIPE, SIG_IGN)` process-wide at adapter init, or
   `F_SETNOSIGPIPE` on the descriptor). Treat EPIPE as benign (child chose
   not to read; its exit status will tell the story).
2. **Structural (with F5)**: fold the five helper classes into an
   actor-based `AgentProcessSupervisor` in `AgentRuntimeKit` using
   `posix_spawn` + a single monitor thread per process and async streams for
   output lines; the existing behavior tests
   (`AgentAdapterTests`, `AgentAdapterStreamingTests`) already specify the
   contract (deadline → SIGTERM → 1 s → SIGKILL, group signaling first).

### F13 (P3) `executeWithRetry` in `AdapterUtilities` ignores deadlines

**Location**: `Sources/RielaAdapters/AdapterUtilities.swift:80-103`; contrast
`OfficialSDKAdapters.swift:500-560` which got this right.

**Problem**: the generic retry helper retries `providerError`/`timeout` up to
`maxAttempts` with a sleep, without consulting `context.deadline` — a retry
can start after the node's deadline has passed, and the *timeout* error class
is retried even though a timed-out attempt has already consumed the whole
budget. The official-SDK variant checks `deadlineHasPassed(deadline)`; the
two implementations should not diverge.

**Improvement design**: add `deadline: Date?` to `executeWithRetry`, skip the
retry (rethrow) when `deadline <= now + retryDelay`, and do not retry
`.timeout` when a deadline is set (the deadline *is* the budget). Migrate
`OfficialSDKAdapters` to the shared helper and delete its private copy.

### F14 (P3) GraphQL schema SDL and DTOs are dual-maintained; server "routes" GraphQL by echoing it

**Location**: `Sources/RielaGraphQL/GraphQLContracts.swift:570-688`
(`schemaContract` SDL string), the parallel `GraphQL*DTO` structs in the same
file, `Sources/RielaServer/ServerContracts.swift:168-245`
(`routeGraphQL` returns `delegated: true` + the raw query; operation type by
`hasPrefix`).

**Problem**: the SDL constant and the Swift DTOs describe the same shape with
no mechanical link — adding a field to a DTO silently stales the SDL that
clients introspect. The deterministic server route does not execute
GraphQL — it returns the query back with `delegated: true`, and the actual
execution lives elsewhere (library callers / node integration per
`riela-workflow-reference`). That split is a legitimate design choice for
this codebase, but nothing *validates* an incoming query against the schema
at this boundary, so typos surface only in the downstream executor with
confusing errors, and telemetry classifies operations by string prefix.

**Improvement design** (deliberately minimal — do not adopt a GraphQL server
framework for this):

1. **Single source of truth**: generate `schemaContract` from the DTOs (a
   small build-time or test-time generator walking `Codable` reflection is
   overkill; instead, add a golden test that renders the SDL from a
   hand-written but *centralized* schema model — field name + type table —
   from which both the SDL string and compile-time `CodingKeys` conformance
   checks are asserted). Cheapest robust form: a unit test that parses the
   SDL (regex-level: type → field:type lines) and asserts every DTO
   `CodingKeys` set matches its SDL type exactly. Drift then fails CI.
2. Keep `delegated: true` behavior, but validate the envelope (`query`
   non-empty, named operation exists when `operationName` given) and return
   structured errors; classify operation type from the first
   non-comment token rather than raw `hasPrefix` (a leading comment or
   shorthand-with-directive currently classifies as `unknown`).

### F15 (P3) `HookContext` decoding silently defaults `vendor` to `.codex` and `eventName` to `"unknown"`

**Location**: `Sources/RielaHook/HookContracts.swift` (`init(from:)`).

**Problem**: a hook payload missing `vendor` is attributed to Codex; missing
`eventName` becomes `"unknown"`. Both defaults hide integration bugs
(mis-shaped payloads from a new agent version) as plausible-looking data —
downstream stores then index sessions under the wrong vendor.

**Improvement design**: decode leniently but *tag* the fallback — add
`public var inferredFields: Set<String>` (excluded from encoding when empty)
populated when a default was applied, and have the hook CLI log a one-line
warning when `inferredFields` is non-empty. Alternatively make `vendor`
required and map legacy payloads at the single call site that needs it;
choose based on whether pre-`vendor` payload producers still exist (git
history suggests they do — keep lenient+tagged).

### F16 (P3) `JSONValue` numbers are `Double`-only — 64-bit ids silently lose precision

**Location**: `Sources/RielaCore/JSONValue.swift`.

**Problem**: `case number(Double)` means any integer above 2^53 (Discord/
Telegram snowflake ids, some usage counters) is corrupted on
decode/re-encode. `RielaEvents` ingests exactly such payloads
(`design-chat-sdk-event-sources.md`); today the event sources work around it
by keeping ids as strings, but nothing prevents a mapping from routing a
snowflake through `JSONValue.number`.

**Improvement design**: this is a widely-used contract type, so avoid a
case-shape change. Extend decoding to try `Int64` before `Double` and store
exact integers losslessly: add `case integer(Int64)` with `Codable` emitting
a plain JSON number, and make `number`'s accessors (`asDouble`, equality
against `.number`) interoperate. Sweep pattern matches with the compiler
(exhaustive switches will flag every site — the churn is the point: each site
decides int vs double explicitly). If the sweep is deemed too invasive now,
minimally document the 2^53 limit on the type and add a validation
diagnostic when an event-source mapping routes a >2^53 number.

### F17 (P3) Terminology drift: `sessionId` vs `workflowExecutionId`

**Location**: `WorkflowSession.sessionId` vs
`WorkflowMessageRecord.workflowExecutionId` /
`WorkflowResolvedMessageInput.workflowExecutionId` (same value), GraphQL DTOs
use `sessionId`, the persistence store's primary key column is
`workflow_execution_id`.

**Problem**: the same identifier has two names depending on which struct you
are reading, which forces every new contributor (and every LLM-driven
workflow that inspects runtime artifacts) to learn the equivalence and makes
grep-based tracing unreliable.

**Improvement design**: declare `workflowExecutionId` the canonical term (it
is the persisted column and the more precise name), then converge
opportunistically: new APIs use it exclusively; existing `Codable` keys stay
stable; Swift property renames go through deprecated computed-property
shims (`@available(*, deprecated, renamed:)`). Record the decision in
`design-riela-workflow-internals.md` glossary.

---

## What Was Reviewed And Found Sound

Worth recording so future reviews don't re-litigate:

- **Value-semantics runtime + actor store**: `WorkflowSession` as a pure
  value updated through `InMemoryWorkflowRuntimeStore` (actor) is a clean,
  test-friendly design; the F2 objection is to *payload size on the hot
  path*, not the model.
- **Validation layering** (`WorkflowRawValidation` → node/loop/memory/session
  entry validators, each a separate file with focused tests) is well
  factored.
- **Path-safety discipline**: `isSafeId` checks before any path-derived
  SQLite/file access, staging-directory escape checks in
  `RuntimePublication.finalizeCandidatePathIfNeeded`, and redaction of
  sensitive env values in adapter errors are consistently applied.
- **`WorkflowBranchEvaluator`**: small recursive-descent parser, no regex,
  fails closed on malformed expressions — appropriate.
- **Native add-on gating** (`NativeBundleAddonResolver`): digest-keyed cache,
  builtin-name denial, duplicate-registration denial, capability flags
  (`allowCandidatePayload`, `allowDispatchIntents`) — the security posture is
  deliberate.

## Prioritized Roadmap

Ordering minimizes rebase pain with the in-flight streaming work (F1–F3
should land *with or before* streaming Phase 1 rollout to real workloads).

| phase | items | rationale |
|---|---|---|
| 1 | F1, F2 | Streaming Phase 1 multiplies both; land before enabling streaming on long sessions. Small, contained diffs. |
| 2 | F4, F10, F9 | Runner-internal refactors; F4/F10 shrink the files streaming keeps touching; F9 preflight prevents user-facing mid-run failures. |
| 3 | F3, F11 | Event-contract redesign (wire-compatible) + telemetry correctness; F3 unblocks clean payloads for F11's span timing. |
| 4 | F6, F8 | SQLite kernel; mechanical, high fan-in, best done when phases 1–2 have stabilized call sites. |
| 5 | F5, F12 | AgentRuntimeKit extraction (largest effort, largest payoff); includes the process-supervisor rewrite that fixes F12 structurally (F12's stdin hardening ships earlier, standalone). |
| 6 | F7, F13–F17 | Contract cleanups and polish; safe anytime, batched to avoid churn. |

## Compatibility And Migration Notes

- **Wire formats are frozen**: JSONL run events (F3), persisted snapshot JSON
  (F1/F6), GraphQL SDL field names (F14), and hook payload keys (F15) must
  round-trip byte-identically (modulo added optional fields). Every phase
  gates on golden-file tests against fixtures captured from the current
  implementation *before* refactoring.
- **Public Swift API**: `RielaCore` is consumed by RielaApp and by package
  API users (`riela-workflow-reference`). Renames ship as
  deprecated-typealias shims for one release; removals require a VERSION
  bump note.
- **DB files**: F6 keeps schemas unchanged; WAL mode is a per-connection
  pragma and coexists with old readers (SQLite ≥3.7 required, satisfied
  everywhere Riela runs). The F1 incremental-append path must tolerate
  legacy rows written by `replaceMessages`.

## Testing Strategy

- **Throughput regression** (F1/F2): mock-scenario workflow emitting 10k
  backend events; assert total persisted-write count and wall time bounds,
  and byte-identical final snapshot vs. the pre-change implementation.
- **Event-contract goldens** (F3): encode/decode fixtures for all five event
  types captured from current `--output jsonl` runs.
- **Conformance suite** (F5): parameterize existing adapter tests over
  `AgentProviderDescriptor`; every extracted family keeps its brand tests
  green before the brand copy is deleted.
- **Concurrency** (F6): two-process test (or two connections in-process)
  interleaving live persistence with `loadAll`, asserting no
  `SQLITE_BUSY` surfaces with busy_timeout set.
- **OTLP** (F11): golden OTLP JSON fixtures validated against the OTLP JSON
  schema mapping; zero-duration-span assertion inverted (span duration ==
  execution createdAt→updatedAt).
- **Process robustness** (F12): child that never reads stdin + 256 KiB
  prompt + 1 s deadline must produce a timeout error, not a hang or crash;
  child exiting immediately with unread stdin must not crash the parent.
