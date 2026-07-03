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

### F1/F2 issue-resolution slice (2026-07-02)

The first implementation slice for the issue "Improve runtime hot paths from
core/add-on review findings" deliberately lands only the compatibility-safe
part of F1 and the narrow F2 reduction that follows from it. The slice is a
runtime hot-path guard, not the full live-tail storage redesign described
above.

**Behavior boundary**:

1. `WorkflowRunCommand` must continue to forward every `WorkflowRunEvent` to
   streamed JSONL output, including every `backend_event`, with the existing
   flattened wire keys and optional streaming fields intact.
2. Full live-snapshot persistence is restricted to lifecycle events that are
   expected to change user-visible session state:
   `session_started`, `step_started`, `step_completed`, and
   `session_completed`.
3. `backend_event` is explicitly non-persisting in the live snapshot path.
   This removes the per-delta CLI persistence work that made F1 quadratic
   under streaming while leaving the event stream itself unchanged.
4. Final persisted snapshots remain produced through the existing completion
   path. The slice must not drop final `recentBackendEvents`,
   `streamedResponseText`, status, message, or node-execution data from the
   stored session record.
5. `RuntimeStore` public session projections and `WorkflowRunEvent` JSON
   encoding remain compatible.
6. A follow-up F2 hot-path refinement keeps the existing `streamedResponseText`
   projection but avoids reconstructing an already capped assistant transcript
   from scratch for each delta. Once the 32 KiB head+tail projection is at the
   cap, appends preserve the stored head and recompute the suffix from only the
   stored tail plus the new delta. This keeps the public head+tail behavior
   intact while bounding per-delta text work after the cap is reached.
7. The in-memory runtime store now keeps backend live-tail fields in an
   internal execution-live-tail table keyed by `executionId` instead of
   mutating the stored `WorkflowSession.executions` array on every
   `backend_event`. `loadSession`, `latestSession`, and returned executions
   project those fields back into the existing public `WorkflowStepExecution`
   shape, preserving API and JSON compatibility while moving the hot-path
   writes toward the F2 live-tail split.
8. Live snapshot persistence now tracks the highest successfully persisted
   `WorkflowMessageRecord.createdOrder` per session in
   `WorkflowRunLivePersistenceState`. Lifecycle-event live saves update the
   session snapshot while upserting only message rows after that watermark;
   terminal/final saves keep the full replace path for compatibility with
   flows that rewrite history.
9. `WorkflowRunLivePersistenceState` now keeps one writable SQLite connection
   for the run's configured session store. The connection prepares CLI/runtime
   schemas once, then lifecycle-event live saves reuse it for the shared
   session/runtime transaction. Final saves still use the normal completion
   path.
10. The backend-event hot path now has a lightweight
    `WorkflowBackendEventReceipt` containing only `executionId`, sequence, and
    timestamp. `InMemoryWorkflowRuntimeStore` returns this receipt directly
    from its live-tail table, and `DeterministicWorkflowRunner` uses it to
    emit `backend_event` records without asking the store for a projected
    `WorkflowStepExecution` on each delta. The legacy
    `recordStepBackendEvent` projection remains available for compatibility.

**Data flow after this slice**:

1. The runner records backend-event data in `RuntimeStore` as it does today.
2. The runner emits a `WorkflowRunEvent(type: .backendEvent, ...)`.
3. The runner enriches the event from `WorkflowBackendEventReceipt` rather
   than a full projected execution.
4. The CLI JSONL recorder writes that event to the live stream.
5. The live-persistence filter rejects the event for full snapshot writes.
6. The next lifecycle event persists the session snapshot with whatever
   backend-event live-tail state the store currently exposes and upserts only
   message rows not previously persisted by a successful live save.
7. Those lifecycle live saves reuse the run's live persistence SQLite
   connection rather than opening a fresh handle each time.
8. The terminal final-save path persists the canonical final snapshot through
   the existing full replace path.

**Validation**:

- Add a focused CLI regression that proves a `backend_event` emission reaches
  JSONL handling but does not call the live full-snapshot persistence path.
- `WorkflowCommandLivePersistenceEventTests.testBackendRunEventBurstDoesNotTriggerLiveSnapshotPersistence`
  covers a 10k `backend_event` burst, proving every event still reaches JSONL
  while live snapshot persistence triggers zero times.
- Keep lifecycle coverage for `session_started`, `step_started`,
  `step_completed`, and `session_completed` triggering live persistence.
- Run `swift test --filter WorkflowCommandLivePersistenceTests`.
- Run `swift test --filter RuntimeStoreTests`.
- Run `swiftlint lint` when SwiftLint is available in the environment.
- `RuntimeStoreTests.testRecordStepBackendEventAppendsDeltasToCappedStreamedResponseText`
  covers the capped-transcript delta append path, preserving the original head,
  retaining the newest tail, and keeping the 32 KiB projection bound.
- `RuntimeStoreTests.testBackendLiveTailProjectsAfterStepCompletionAndLatestSessionLookup`
  covers the internal live-tail projection after terminal step updates and
  through `latestSession(workflowId:)`, preventing projected backend fields
  from being lost outside the hot path.
- `RuntimeStoreTests.testRecordStepBackendEventReceiptAvoidsReturningProjectedExecutionPayload`
  covers the lightweight receipt path and verifies public session reads still
  project the live-tail fields for callers that need them.
- `SQLiteWorkflowMessageLogTests.testSQLiteRuntimePersistenceCanAppendMessagesWithoutReplacingExistingRows`
  covers the live-style snapshot save that upserts new message rows without
  deleting previously persisted rows.
- `SQLiteWorkflowMessageLogTests.testWorkflowMessageLogUpsertRefreshesPayloadIndexRows`
  covers payload-index replacement for upserted message rows.
- `WorkflowCommandLivePersistenceEventTests.testLivePersistenceStateTracksOnlySuccessfullyPersistedMessages`
  covers the per-session live-persistence message watermark and proves failed
  live saves do not advance it.
- `WorkflowCommandLivePersistenceEventTests.testLivePersistenceStateReusesConnectionAcrossSnapshotSaves`
  covers two live saves through one configured session store and proves the
  actor opens only one SQLite connection while preserving incremental message
  persistence.

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

### F3 issue-resolution slice (2026-07-02)

`WorkflowRunEvent` has been converted from a mutable flat struct into an
associated-value enum while preserving the existing flattened JSON contract.
The public `WorkflowRunEventType` raw values and legacy
`WorkflowRunEvent(type:workflowId:sessionId:...)` initializer remain available
for compatibility with existing emitters and tests.

**Behavior boundary**:

1. Encoding and decoding continue to use the same top-level keys:
   `type`, `workflowId`, `sessionId`, `status`, `currentStepId`, step fields,
   backend-event fields, completion fields, `nodeExecutions`, and
   `transitions`.
2. Existing read sites can still use `event.type`, `event.workflowId`,
   `event.backendEventType`, `event.nodeExecutions`, and the other previous
   field names through read-only computed properties.
3. The enum cases now separate session, step, backend-event, step-completion,
   and session-completion payloads so unrelated fields are no longer retained
   on the wrong event type.
4. Mutable field assignment on `WorkflowRunEvent` is intentionally not
   preserved. Tests and callers should construct the intended event case or use
   the compatibility initializer.
5. No wire migration is required for persisted JSONL output or existing
   `backend_event` consumers.

**Validation**:

- `DeterministicWorkflowRunnerBackendEventTests` covers legacy backend-event
  JSON decoding, enriched backend-event encoding, enum payload extraction, and
  irrelevant-field dropping for a session event.
- `WorkflowCommandLivePersistenceEventTests` confirms the CLI live persistence
  filter and JSONL recorder still work through the compatibility properties.

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

### F4 issue-resolution slice (2026-07-02)

The runner failure-publication duplication has been reduced and
`WorkflowPublicationRequest` now uses a single `WorkflowPublicationBody` enum
for mutually exclusive publication inputs. The implementation adds
`DeterministicWorkflowRunner.publishFailureAndThrow(...)` in a focused
extension file, routes the stdio, agent, and add-on failure paths through it,
and removes the runtime candidate-source counting that previously allowed
ambiguous request construction.

**Behavior boundary**:

1. The helper publishes the failed execution with the same `sessionId`,
   `stepId`, `nodeId`, attempt, backend, adapter output, transitions, and
   root-output flag values that the previous inline blocks used.
2. The expected `AdapterExecutionError` rethrow from
   `InMemoryWorkflowOutputPublisher` is treated as the successful failure
   publication path. It is not logged as a publication error.
3. If publication itself fails with another error, the helper records
   `riela.workflow.publish.failure` telemetry with bounded identifying
   attributes, then throws the original adapter failure or the original
   non-adapter error exactly as the old call site did.
4. Cancellation remains outside this helper and still bypasses failure
   publication so interrupted runs keep the existing cancellation handling.
5. `WorkflowPublicationBody` models failure, adapter output, inline candidate,
   candidate path, and no-output cases directly. A request can no longer carry
   both `adapterOutput` and `candidatePath`, or a candidate path without its
   reservation.
6. Candidate-path finalization is now keyed off the `.candidatePath` body case,
   so staging cleanup remains coupled to the only case that owns a reservation.

**Validation**:

- `swift test --filter RunnerFailurePublicationTests`
  proves a publication failure is no longer invisible and that the original
  adapter failure still wins error flow.
- `swift test --filter RuntimePublicationTests` covers every publication body
  case, including failure bodies carrying adapter-output metadata.
- `swift test --filter RuntimeOutputCandidateTests` preserves candidate path
  reservation mismatch rejection.
- Existing runner failure tests continue to prove adapter failures record
  failed executions without messages through the default publisher.

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

**Issue resolution slice (2026-07-02)**:

- Added a shared `AgentRuntimeKit` target and moved the duplicated
  `ProcessIO` mechanics into `AgentProcessOutputBuffers` and
  `AgentManagedProcess`.
- Moved the duplicated `RolloutWatcher` mechanics into
  `AgentRolloutWatcher`, centralizing watched-file offsets, session-directory
  discovery, rollout-file recursion, unreadable-file errors, truncation
  handling, and complete/trailing line parsing.
- `CodexAgent`, `ClaudeCodeAgent`, and `CursorCLIAgent` now depend on
  `AgentRuntimeKit`. Their `*ProcessIO.swift` files retain provider-local
  wrapper names (`ProcessOutputBuffers`, `Managed*Process`) but only provide
  the provider-specific rollout parser and execution-result factory.
- Their `*RolloutWatcher.swift` files now retain provider-local public event
  types and `sessionsWatchDir(...)` APIs while delegating generic file watching
  and event discovery to `AgentRolloutWatcher`.
- Moved the duplicated `SessionSQLiteIndex` raw SQLite reading and row
  normalization into `AgentSessionSQLiteSupport` and
  `AgentSessionSQLiteRecord` in `AgentRuntimeKit`. The provider
  `*SessionSQLiteIndex.swift` files now only open provider-specific state paths,
  apply provider query/filter/sort types, and map normalized records into
  provider session/source/git models.
- Moved the duplicated operational JSON file-store and ISO8601 "now" helper
  into `AgentJSONFileStore` and `agentRuntimeISO8601Now()` in
  `AgentRuntimeKit`. Provider names (`CodexJSONStore`,
  `ClaudeCodeJSONStore`, `CursorCLIJSONStore`, and the local timestamp helper
  functions) remain as source-compatible shims.
- Moved the duplicated process stream cursor and completion-wait cache into
  `AgentRolloutLineStream` and `AgentProcessCompletion` in
  `AgentRuntimeKit`. Provider names (`CodexRolloutLineStream`,
  `ClaudeCodeRolloutLineStream`, `CursorCLIRolloutLineStream`, and the
  matching `*ProcessCompletion` names) remain as source-compatible aliases.
- Moved the duplicated live execution stream result wrapper into
  `AgentExecStreamResult<RolloutLine>` in `AgentRuntimeKit`. Provider names
  (`CodexExecStreamResult`, `ClaudeCodeExecStreamResult`, and
  `CursorCLIExecStreamResult`) remain as source-compatible aliases while the
  wait/collect behavior is implemented once.
- Moved the duplicated process public contract types into
  `AgentProcessStatus`, `AgentProcessRecord`, and `AgentProcessExecution` in
  `AgentRuntimeKit`. Provider names (`CodexProcessRecord`,
  `ClaudeCodeProcessExecution`, `CursorCLIProcessStatus`, etc.) remain as
  source-compatible aliases while process-manager internals now share the same
  status vocabulary and record/execution shape.
- Moved duplicated process-manager registry bookkeeping into
  `AgentProcessRegistry<Managed>` in `AgentRuntimeKit`, including virtual PID
  allocation for injected executors, list/get ordering, kill/write-input state
  transitions, kill-all marking, pruning, finish/exit-code updates, and managed
  process removal.
- Moved duplicated managed-process launch plumbing into
  `AgentManagedProcessLauncher` in `AgentRuntimeKit`, including `/usr/bin/env`
  process construction, cwd/environment assignment, pipe wiring, start-drain
  sequencing, optional initial stdin write/close, running-record creation, and
  failed-start record/managed-result creation.
- Moved the remaining process-manager supervisor flow into
  `AgentProcessSupervisor<Managed>` in `AgentRuntimeKit`, including injected
  executor record lifecycle, run/start/stream orchestration, kill/write/list
  facades, managed-process completion cleanup, and stream wrapping. Provider
  managers now primarily map provider options into command arguments,
  environment, cwd, and provider-specific managed-process factories.
- Moved duplicated running-session state handling into
  `AgentRunningSessionState<RolloutLine>` in `AgentRuntimeKit`, including
  thread-safe session-id refresh, live message merging, resume backfill,
  stable line deduplication hooks, stream chunking hooks, completion caching,
  cancellation, and terminal result metadata. Provider running-session classes
  now retain only read-only session API shape, provider-specific session-id
  extraction, and result type mapping.
- Live stdout/stderr draining, stdout line buffering, partial-line handling,
  blocking `nextLine`, failed-start closed streams, process termination,
  waiting, and execution collection now have one implementation instead of
  three brand-cloned copies.
- This is intentionally a staged F5 extraction. The larger `AgentRuntimeKit`
  plan still needs follow-up slices for the higher-level operational store
  repositories and process-manager/provider descriptor consolidation.

**Validation**:

- `AgentRuntimeKitTests` covers parsed stdout buffering, trailing-line parsing,
  timeout behavior, failed managed-process execution, managed-process launcher
  stdin handoff, and failed-start launch records.
- `AgentRolloutWatcherTests` covers complete/trailing rollout-line parsing,
  recursive rollout-file discovery, close semantics, and new-session events in
  the shared watcher.
- `AgentSessionSQLiteSupportTests` covers opening the shared `threads`
  database, rejecting incomplete rows, parsing date formats, normalizing
  optional fields, fallback titles, unknown CLI versions, and git metadata.
- `AgentOperationalSupportTests` covers default loading, atomic directory
  creation, pretty sorted JSON saves, and reloads through `AgentJSONFileStore`.
- `AgentProcessStreamsTests` covers stream cursor advancement, snapshots,
  cached process completion waits, and shared live execution stream-result
  wait/collect behavior.
- `AgentProcessContractsTests` covers the shared process status, record, and
  execution contracts used by all three provider aliases.
- `AgentProcessRegistryTests` covers shared virtual process creation,
  input tracking, finish/exit-code updates, managed-process lookup for
  termination, kill-all marking, and pruning.
- `AgentProcessSupervisorTests` covers injected-executor run lifecycle and
  stream wrapping through the shared supervisor.
- `AgentRunningSessionStateTests` covers shared running-session live message
  merging, session-id refresh, resume backfill, terminal result metadata, and
  cancellation result behavior.
- `CodexAgentCompatibilityTests.testProcessManagerStreamReturnsBeforeCompletionAndYieldsLiveLines`
  covers the Codex wrapper through a real process-backed live stream.
- `ClaudeCodeAgentCompatibilityTests.testProcessManagerStreamReturnsBeforeCompletionAndYieldsLiveLines`
  covers the Claude wrapper through a real process-backed live stream.
- `CursorCLIAgentCompatibilityTests.testProcessManagerStreamReturnsBeforeCompletionAndYieldsLiveLines`
  covers the Cursor wrapper through a real process-backed live stream.
- `CodexAgentSessionIndexCompatibilityTests.testRolloutWatcherEmitsCompleteLines`,
  `ClaudeCodeSessionIndexCompatibilityTests.testRolloutWatcherEmitsCompleteLines`,
  and `CursorCLISessionIndexCompatibilityTests.testRolloutWatcherEmitsCompleteLines`
  cover provider wrapper event mapping and provider-specific session watch
  roots.
- `CodexAgentSessionIndexCompatibilityTests.testSessionIndexMergesSQLiteAndRolloutsWithRolloutMetadataPrecedence`,
  `ClaudeCodeSessionIndexCompatibilityTests.testSessionIndexUsesRolloutMetadataBeforeStaleSQLiteRows`,
  and `CursorCLISessionIndexCompatibilityTests.testSessionIndexUsesRolloutMetadataBeforeStaleSQLiteRows`
  cover provider-specific session mapping and SQLite/rollout precedence after
  the shared session-index reader extraction.
- `CodexAgentCompatibilityTests.testPersistentQueueAndBookmarkRepositoriesMirrorReferenceConfigFiles`,
  `ClaudeCodeAgentCompatibilityTests.testTokenPersistenceUsesLegacyCcaTokensAndSha256Hashes`,
  and `CursorCLIAgentCompatibilityTests.testTokenPersistenceUsesLegacyCursorTokensAndSha256Hashes`
  cover provider persistence through the public JSON-store shims.
- `CodexAgentCompatibilityTests.testProcessManagerRunAgentAndOperationalStores`,
  `ClaudeCodeAgentCompatibilityTests.testProcessManagerExecutesInjectedRunnerAndRecordsLifecycle`,
  and `CursorCLIAgentCompatibilityTests.testProcessManagerExecutesInjectedRunnerAndRecordsLifecycle`
  cover provider process lifecycle behavior through the public process
  record/execution aliases.

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

**Issue resolution (2026-07-02)**:

- Added a shared `RielaSQLite` target with `SQLiteDatabase`, `SQLiteValue`,
  `SQLiteRow`, and `SQLiteError`. The kernel owns connection lifetime,
  centralizes execute/query/bind/transaction behavior, applies
  `journal_mode=WAL` and `busy_timeout=3000` for writable opens, and probes
  JSONB support on open.
- `SQLiteWorkflowRuntimePersistenceStore`, `SQLiteWorkflowMessageLog`, and
  `CLIWorkflowSessionStore` now use `RielaSQLite` for open/query/execute/bind
  plumbing. Each store still maps kernel errors into its existing domain error
  enum, preserving call-site error handling.
- The CLI combined session/runtime save path still uses one shared database
  object and one transaction, so the prior atomicity between the CLI session
  record, runtime snapshot, and message log is preserved without passing raw
  SQLite handles across store-local helper stacks.
- The prior F8 hygiene slice remains intact: schema preparation still runs
  before caller transactions, runtime snapshot hydration still reuses the
  already-open database object for message loading, and JSONB payloads are
  still encoded once before binding.

**Validation**:

- `SQLiteDatabaseTests` covers WAL mode, busy timeout, JSONB probing,
  execute/query bindings, and rollback behavior in the shared kernel.
- `SQLiteWorkflowMessageLogTests` covers runtime/message-log persistence,
  JSONB payload storage, migration of the runtime snapshot table, and load-all
  message hydration through the shared database object.
- `WorkflowCommandLivePersistenceTests` covers the CLI shared transaction path
  after `CLIWorkflowSessionStore` moved to `RielaSQLite`.

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

**Issue resolution (2026-07-02)**:

- Generic `normalizeOutputContractEnvelope` no longer applies loop-completion
  routing by default. It accepts an explicit `OutputContractRoutingReconciler`
  hook and otherwise preserves the adapter-returned `when` map exactly.
- Loop-specific `goalAchieved`/`decision` routing now lives in
  `LoopCompletionReviewRouting.swift`, outside `AdapterContracts.swift`.
- `DeterministicWorkflowRunner` supplies that reconciler only for workflow loop
  gate steps (`workflow.loop` plus `step.loop.gateId` or `step.loop.role ==
  "gate"`), so ordinary user workflows that happen to return `decision` or
  `goalAchieved` are no longer silently rewritten.
- `WorkflowAcceptedOutputMetadata.routingDiagnostics` records reconciliation
  notes on accepted outputs and decodes older snapshots with an empty list.
- JSON object extraction heuristics moved to `RuntimeOutputExtraction.swift`,
  leaving `AdapterContracts.swift` focused on neutral adapter contract types
  and envelope normalization.

**Validation**:

- `AdapterUtilitiesTests.testOutputContractEnvelopeDoesNotApplyLoopRoutingByDefault`
  covers the neutral adapter contract boundary.
- `AdapterUtilitiesTests.testLoopCompletionReviewReconcilerCanBeAppliedExplicitly`
  covers explicit loop routing reconciliation and diagnostics.
- `RuntimePublicationTests.testPublicationRecordsExplicitLoopRoutingReconciliationDiagnostic`
  covers persisted accepted-output diagnostics.
- `WorkflowRunnerLoopPolicyTests.testLoopGateStepReconcilesCompletionReviewRouting`
  covers runner opt-in only on loop gate steps.

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

**Issue resolution (2026-07-02)**:

- Runtime persistence schema setup now runs through `prepareSchema(in:)` before
  the store-owned `BEGIN IMMEDIATE` transaction. The CLI combined
  session/runtime save path also prepares both CLI and runtime schemas before
  starting its shared transaction.
- `save(_:in:)` now assumes schema has been prepared by the caller and no
  longer performs runtime DDL inside a caller transaction.
- Snapshot upsert encodes `rootOutput` and `loopEvidence` once each and binds
  the resulting optional JSON text directly through `jsonb(?)`.
- Runtime `load`/`loadAll` pass the already-open SQLite handle into
  `SQLiteWorkflowMessageLog.listMessages(..., in:)`, removing the per-session
  message-log store/open path for runtime snapshot hydration.
- Runtime/message-log date rendering now uses a shared locked ISO8601 formatter
  wrapper instead of allocating `ISO8601DateFormatter` for every row.

**Validation**:

- `SQLiteWorkflowMessageLogTests.testSQLiteRuntimePersistenceRoundTripsLoopEvidenceAndMigratesExistingDatabase`
  covers schema migration and JSONB loop-evidence persistence.
- `SQLiteWorkflowMessageLogTests.testSQLiteRuntimePersistenceLoadAllReturnsMessagesFromRuntimeDatabase`
  covers `loadAll` snapshot hydration with per-session messages from the
  runtime database handle.
- `WorkflowCommandLivePersistenceTests` covers the CLI shared transaction path
  that persists both session records and runtime snapshots.

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

### F9 issue-resolution slice (2026-07-02)

The first F9 implementation slice adds a shared runtime capability check and
uses it before a deterministic run creates a session. The slice also exposes
the same capability gaps through `workflow validate` diagnostics and stops
accepting `--max-concurrency` as a silently ignored run option.

**Behavior boundary**:

1. `DeterministicWorkflowRunner.unsupportedFeatures(in:maxConcurrency:)`
   returns `WorkflowRuntimeCapabilityGap` values with stable diagnostic paths
   and user-facing feature messages.
2. Runner preflight now rejects reserved `maxConcurrency` and unconditional
   reachable fanout, cross-workflow-without-resume, and resume-without-
   cross-workflow transitions before session creation.
3. Conditional fanout/cross-workflow branches remain allowed at static
   preflight so existing workflows with inactive feature branches can still run.
   If such a branch becomes publishable, the runtime fallback still fails
   closed, now without internal `TASK-00x` wording.
4. `workflow validate` appends capability-gap diagnostics so unsupported
   runner features can be detected without starting a run.
5. CLI parsing rejects `--max-concurrency` with a reserved-for-fanout message.
   The DTO/request field remains for wire compatibility, but local CLI users
   can no longer pass a value that would be ignored.

**Validation**:

- `WorkflowRunnerCapabilityPreflightTests` covers unsupported transition and
  `maxConcurrency` preflight before session creation.
- `WorkflowCommandTests.testWorkflowValidateReportsRuntimeCapabilityGaps`
  covers static validate diagnostics for fanout.
- `CommandParsingTests` covers reserved `--max-concurrency` rejection.
- Publisher and command-node fallback tests retain fail-closed behavior with
  feature-named messages instead of task ids.

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

### F10 issue-resolution slice (2026-07-02)

The first F10 implementation slice removes the duplicate route decision from
the deterministic runner and in-memory runtime store.

**Behavior boundary**:

1. `WorkflowExecutionPlan` builds step and registry-node lookup maps once for
   a run, and `DeterministicWorkflowRunner.run` uses those maps instead of
   repeated linear `first(where:)` scans.
2. `WorkflowPublicationResult.nextStepId` is now the route result consumed by
   the runner. It is computed by `InMemoryWorkflowOutputPublisher`, next to
   transition evaluation.
3. `InMemoryWorkflowRuntimeStore.appendWorkflowMessages` no longer mutates
   `session.currentStepId`; appending messages records delivery only.
4. `WorkflowStepExecutionUpdateInput.currentStepId` lets the publisher
   explicitly advance the session route after messages are successfully
   appended.

**Validation**:

- `RuntimeStoreTests` now asserts direct message append preserves the
  session's current step.
- `RuntimePublicationTests` now asserts publication returns `nextStepId` and
  updates the session current step through the publisher-owned route.

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

### F11 issue-resolution slice (2026-07-02)

The first F11 implementation slice replaces the default custom telemetry
payload with OTLP/HTTP JSON, makes workflow spans use real runtime timestamps,
and bounds exporter memory.

**Behavior boundary**:

1. `OTLPRielaTelemetryExporter` now emits standard OTLP JSON roots:
   `resourceSpans`, `resourceLogs`, and `resourceMetrics` for the three
   signal endpoints. The previous custom `{serviceName, surface, records}`
   envelope remains available only behind `RIELA_OTEL_LEGACY_PAYLOAD=1`.
2. Exported resources include `service.name`, `riela.surface`, configured
   resource attributes, and dropped-record counters when buffers overflow.
3. Trace exports honor an incoming `traceparent` from
   `RielaTelemetryConfiguration.fromEnvironment`, using its trace id and
   parent span id while generating a fresh span id per exported span.
4. Exporter buffers are capped by `maxBufferRecords` (default 2,048,
   overridable by `RIELA_OTEL_MAX_BUFFER_RECORDS`) and drop oldest records
   with counters rather than growing without bound.
5. An auto-flush task starts on first buffered record and flushes every 10
   seconds by default; tests can disable it by passing `autoFlushInterval: nil`.
6. Export failures are no longer silent: non-2xx responses, URLSession errors,
   and timeout races increment a consecutive-failure counter and emit a single
   stderr warning on first failure, plus a recovery warning after success.
7. Workflow step spans use `WorkflowStepExecution.createdAt/updatedAt`, and
   workflow run spans use `WorkflowSession.createdAt/updatedAt`; completion
   span durations are no longer fabricated from a completion-time `Date()`.

**Validation**:

- `WorkflowObservabilityTests` now checks standard OTLP payload roots,
  redaction, resource attributes, parent trace propagation, bounded buffers,
  dropped-record counters, timeout behavior, and workflow span timing.
- Existing server/events telemetry call sites continue compiling against the
  same `RielaTelemetry` protocol and `RielaTelemetrySpan` model.

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

### F12 issue-resolution slice (2026-07-02)

The first F12 implementation slice lands the immediate stdin hardening without
changing the public `LocalAgentProcessRunning` API or the process supervision
state machine.

**Behavior boundary**:

1. `FoundationLocalAgentProcessRunner` no longer writes the complete stdin
   prompt synchronously on the task thread. It dispatches a utility-queue
   `LocalProcessStdinWriter` after spawn setup completes.
2. The writer uses POSIX `write(2)` in bounded chunks and closes the stdin
   descriptor when it finishes, preserving EOF behavior for children that read
   from stdin.
3. `SIGPIPE` is suppressed for stdin writes (`F_SETNOSIGPIPE` on Darwin,
   `SIG_IGN` elsewhere), so a child that exits or closes stdin cannot crash
   the parent process through `NSFileHandleOperationException` or SIGPIPE.
4. `EINTR` is retried, while `EPIPE` and `EBADF` are treated as benign
   terminal write outcomes. The child process exit status remains the
   authority for adapter success or failure.
5. Timeout and cancellation still close process pipes and terminate the
   process group through the existing `LocalProcessCancellationState` and
   `LocalProcessHandle` flow. The structural actor-based process supervisor
   remains deferred to the F5/AgentRuntimeKit extraction.

**Validation**:

- `AgentAdapterTests.testFoundationRunnerWritesLargeStdinInChunks` verifies a
  prompt larger than the usual pipe buffer is delivered to a stdin-reading
  child.
- `AgentAdapterTests.testFoundationRunnerTreatsClosedStdinPipeAsBenign`
  verifies a large prompt sent to an immediately exiting child does not block,
  throw, or crash.

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

**Issue resolution**:

- `executeWithRetry` now accepts an optional deadline and injected clock,
  normalizes terminal failures through the supplied normalizer, refuses to retry
  `.timeout` when a deadline is present, and skips provider retries that cannot
  complete their retry delay before the deadline.
- `OfficialSDKAdapters` now delegates retry decisions to the shared helper while
  retaining `runWithDeadline` to cap each individual SDK attempt.

**Validation**:

- `AdapterUtilitiesTests` covers deadline-aware provider retry, deadline-based
  retry suppression, timeout suppression when a deadline exists, and preserved
  timeout retry behavior without a deadline.
- `OfficialSDKAdapterTests.testOfficialSDKAdapterSkipsRetryWhenDeadlineCannotCoverDelay`
  verifies the migrated SDK path does not start a retry that would exceed the
  node deadline and still redacts provider failure text.

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

**Issue resolution**:

- `DeterministicServerRouteHandler` now rejects non-string `operationName`
  values and rejects a supplied operation name that is absent from the parsed
  query's named operations.
- GraphQL envelope failures still expose the existing top-level `error`, and
  now also include a GraphQL-shaped `graphql.errors[].message` payload.
- GraphQL telemetry operation-type classification now tokenizes the query and
  skips whitespace, commas, comments, and string literals before reading the
  operation token, so leading comments no longer hide mutations/subscriptions.
- `GraphQLContractsTests` now parses the SDL type/input field sets and compares
  them with field keys emitted by the corresponding Swift DTO/request types, so
  schema/DTO drift fails in CI.

**Validation**:

- `GraphQLContractsTests.testSchemaContractFieldSetsMatchEncodedDTOs` covers the
  SDL/DTO drift guard for the runtime GraphQL DTOs and input request models.
- `ServerContractsTests.testGraphQLRouteRejectsMissingAndNonObjectBodies`
  covers bad `operationName` shapes and missing named operations.
- `ServerContractsTests.testGraphQLRouteRecordsRedactedTelemetryWithoutQueriesVariablesOrHeaders`
  covers comment-prefixed mutation classification without leaking query,
  variables, or headers into telemetry.

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

**Issue resolution**:

- `HookContext` now carries `inferredFields: Set<String>`, populated with
  `vendor` and/or `eventName` when decode falls back to `.codex` or
  `"unknown"`.
- `HookContext.encode(to:)` omits `inferredFields` when empty and emits a
  deterministic sorted array when fallback provenance exists.
- The hook CLI path now appends a one-line stderr warning when a parsed hook
  context contains inferred fields, while preserving existing stdout rendering.

**Validation**:

- `HookContractsTests.testHookContextDecodesPreTask006MinimalShapeWithDefaults`
  covers legacy decode compatibility and inferred-field round-trip encoding.
- `HookContractsTests.testHookContextOmitsInferredFieldsWhenExplicit` covers
  explicit vendor/event contexts omitting the field from encoded JSON.

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

**Issue resolution**:

- `JSONValue` now includes `case integer(Int64)`, decodes `Int64` before
  `Double`, and re-encodes integers as plain JSON numbers so 64-bit event ids
  can round-trip without `Double` precision loss.
- `JSONValue.asInt64` and `JSONValue.asDouble` expose explicit numeric access
  at call sites, and equality between `.integer` and `.number` only
  interoperates when the integer is exactly representable as a `Double`.
- Exhaustive switch sites now make an explicit integer decision: template and
  event rendering print exact integers, Foundation bridging uses `Int64`,
  text extractors continue treating integers as non-text, and memory/SQLite
  compatibility paths convert to existing numeric representations at their
  current boundaries.

**Validation**:

- `JSONValueTests.testDecodesAndReencodesLargeIntegersLosslessly` covers
  lossless `Int64.max` JSON decode/re-encode.
- `JSONValueTests.testIntegerAndNumberEqualityOnlyInteroperatesWhenExactlyRepresentable`
  covers the `.integer`/`.number` compatibility boundary.
- `EventInputNormalizationTests` verifies event dry-run input normalization
  continues compiling and running through integer-aware template handling.

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

**Issue resolution (2026-07-02)**:

- `WorkflowSession.workflowExecutionId` now aliases the existing `sessionId`
  storage without changing persisted `Codable` keys.
- `GraphQLWorkflowSessionDTO` and the SDL expose `workflowExecutionId` while
  preserving the legacy `sessionId` field for clients.
- `GraphQLInspectSessionRequest`/`GraphQLContinueSessionRequest` expose
  Swift-side `workflowExecutionId` aliases without changing input wire shapes.
- `design-riela-workflow-internals.md` records `workflowExecutionId` as the
  canonical runtime identity term and documents `sessionId` as compatibility
  spelling.

**Validation**:

- `RuntimeSessionTests.testWorkflowSessionWorkflowExecutionIdAliasesSessionId`
  covers the core model alias.
- `GraphQLContractsTests.testProjectsRuntimeSessionAndMessagesIntoStableDTOs`
  covers output projection parity between `sessionId` and
  `workflowExecutionId`.
- `GraphQLContractsTests.testLegacyGraphQLSessionRequestsExposeWorkflowExecutionIdAliasWithoutWireDrift`
  covers request aliases and unchanged input encoding.
- `GraphQLContractsTests.testSchemaContractFieldSetsMatchEncodedDTOs` keeps the
  GraphQL SDL and DTO field sets in sync.

---

## Re-Review After Remediation (commit `dcb16c6`, 2026-07-02 second pass)

A second review pass was performed against the remediation commit
`dcb16c6` ("Address runtime review findings"). Build is clean and the full
suite (940 tests) passes. This section records the verification status of
F1–F17 and the new findings (R1–R7) discovered in the remediation code
itself. R1 is a behavioral regression introduced by the F16 fix and should
be treated as the top follow-up priority.

### Verification status of F1–F17

| finding | status | notes |
|---|---|---|
| F1 | resolved (slice) | `backend_event` no longer persists; lifecycle-only snapshot saves; per-run connection reuse (`WorkflowRunLivePersistenceConnection`); incremental message append via `lastPersistedMessageOrderBySessionId`. Debounced live-tail flush intentionally deferred (documented in slice). |
| F2 | resolved (slice) | Live tail moved to store-internal `executionLiveTails` keyed by executionId; receipt path (`recordStepBackendEventReceipt`) avoids per-delta session copies; capping now preserves the stored head and reworks only tail+delta. Residuals: R3 (tail-table growth), R7 (per-delta cost is O(cap), not O(delta)). |
| F3 | resolved | `WorkflowRunEvent` is now an enum with `SessionEnvelope`/`StepEnvelope`/payload structs; custom Codable keeps the flat wire keys; accessor shims preserve source compatibility. |
| F4 | resolved | `publishFailureAndThrow` used at all 14 sites; zero `try? await publisher` remain in the runner; publish failures logged via `riela.workflow.publish.failure`; `WorkflowPublicationBody` enum makes candidate sources mutually exclusive. |
| F5 | partially resolved | `AgentRuntimeKit` extracted; ProcessIO 190→74, RolloutWatcher 137→55, ProcessManager 594→301 lines per brand. Remaining clones: see R5. |
| F6 | resolved | `RielaSQLite` kernel with WAL + busy_timeout 3 s adopted by all three stores; single error type; JSONB probe per open. |
| F7 | resolved | Reconciliation moved to `LoopCompletionReviewRouting.swift`, applied only when `workflow.loop != nil` and the step is a gate; rewrites recorded in `WorkflowAcceptedOutputMetadata.routingDiagnostics` (wire-compatible optional key); extraction heuristics moved to `RuntimeOutputExtraction.swift`. |
| F8 | resolved | Cached ISO8601 formatter (`LockedISO8601DateFormatter`); JSON encoded once per bind; schema prepared once per connection. |
| F9 | mostly resolved | `unsupportedFeatures` preflight in `run()` and `workflow validate`; `maxConcurrency` rejected as a capability gap; `TASK-00x` strings removed. Residual: R4 (labeled transitions skipped by preflight). |
| F10 | resolved | `WorkflowExecutionPlan` dictionaries; `nextStepId` computed by the publisher only; `appendWorkflowMessages` no longer writes `currentStepId`. New risk introduced by the dictionaries: R2. |
| F11 | resolved | Real OTLP JSON (`resourceSpans[].scopeSpans[].spans[]` with trace/span ids honoring propagated parent context); span timing from `execution.createdAt` / `session.createdAt`; buffers bounded (2 048, env-tunable) with dropped counts; 10 s auto-flush; one-shot failure warning + recovery notice on stderr. |
| F12 | resolved (hardening) | Chunked POSIX `write` on a utility queue, `F_SETNOSIGPIPE`/`SIG_IGN`, EPIPE treated as benign. Structural supervisor rewrite still pending with F5 phase 5 (expected). |
| F13 | resolved | `executeWithRetry` takes `deadline`; retry skipped when the budget cannot fit another attempt; `OfficialSDKAdapters` delegates to the shared helper. |
| F14 | resolved | `testSchemaContractFieldSetsMatchEncodedDTOs` gates SDL↔DTO drift; operation type parsed from the first non-comment token. |
| F15 | resolved | Lenient decode now tags `inferredFields`; hook CLI prints a warning when non-empty. |
| F16 | resolved with regression | `.integer(Int64)` added with cross-case equality and `asDouble`/`asInt64`; switch-based sites compiler-forced to handle it. Guard-case sites silently missed — see R1. |
| F17 | resolved (decision) | Canonical-term decision recorded in `design-riela-workflow-internals.md` glossary. |

### R1 (P1) `.integer` decode regression: guard-case `.number` parsers silently drop integral JSON numbers

**Location**:
`Sources/CodexAgent/CodexAgentProcess.swift:494` (`numberValue`),
`Sources/ClaudeCodeAgent/ClaudeCodeAgentProcess.swift:445` (`numberValue`),
`Sources/CursorCLIAgent/CursorCLIAgentProcess.swift:506` (`numberValue`),
`Sources/CodexAgent/CodexFileChanges.swift:449` (`numberValue`, feeding
`codexJSONInt` at :456).

**Problem**: the F16 change makes `JSONDecoder` produce `.integer` for every
integral JSON number — including `1.0` (verified: `1`, `1.0`, and
`9007199254740993` all decode as `.integer`; only true fractions decode as
`.number`). Exhaustive `switch` statements were compiler-forced to add the
new case, but `guard case let .number(value) = value` compiles unchanged and
now returns `nil` for what used to match. The four helpers above are exactly
such sites, and they parse **decoded** JSON (rollout files, session files,
`--variables` JSON), so the regression is real:

1. `ExecCommandEnd` normalization in all three agent processes computes
   `isError: exitCode.map { $0 != 0 } ?? false` — with `exit_code: 1`
   decoding as `.integer(1)`, `numberValue` returns `nil` and a **failing
   command is reported as `isError: false`** in `tool.result` events.
2. `CodexFileChanges.isSuccessfulToolResult` checks
   `numberValue(payload["exit_code"])` before falling back to `status` —
   a failed command with `exit_code: 1` and no `status` field is now
   classified successful, so its file changes are wrongly indexed.
3. `codexJSONInt` backs the Codex GraphQL executor's integer variables
   (`limit`, `offset`, `from`, `to`, `maxConcurrent`, `resultExitCode`,
   `nthMessage`). Variables supplied as JSON via `--variables` decode as
   `.integer` and are **silently ignored**, falling back to defaults.

The inconsistency is the F5 clone-drift failure mode in action: the sibling
helpers `claudeCodeNumberValue` (`ClaudeCodeFileChanges.swift:388`) and
`cursorOperationNumberValue` (`CursorCLIQueueCommands.swift:440`) *were*
fixed to handle both cases, so Claude/Cursor file-change filtering is
correct while their `AgentProcess` normalizers and everything Codex-side is
not.

**Why tests missed it**: every fixture constructs payloads with
`.number(0)` / `.number(1)` enum literals (e.g.
`Tests/CodexAgentTests/CodexAgentCompatibilityTests.swift:142,682`) instead
of decoding JSON text, so the production decode representation (`.integer`)
is never exercised.

**Improvement design**:

1. Replace the four guard-case helpers with `value?.asDouble` (the accessor
   added by F16 exists precisely for this). Prefer deleting the local
   helpers; if kept for call-site clarity, implement them as
   `value?.asDouble`.
2. Add one shared `jsonInt(_: JSONValue?) -> Int?` in `AgentRuntimeKit`
   (via `asInt64`) and migrate `codexJSONInt` / `claudeCodeIntValue` /
   cursor equivalents to it, removing three near-copies.
3. Sweep guard: `grep -rn 'case let \.number' Sources --include='*.swift'`
   must only hit sites that also handle `.integer` (or that operate on
   non-RielaCore JSON types such as `MemoryJSONValue`). Encode this as a CI
   lint or a unit test over the known helper functions.
4. Fixture realism: route agent-package test fixtures through
   `JSONDecoder().decode(JSONValue.self, from:)` (a tiny
   `jsonFixture(_: String)` helper) so decode-representation changes are
   caught. At minimum add regressions: `ExecCommandEnd` with
   `{"exit_code": 1}` JSON text must yield `isError: true`; a Codex GraphQL
   call with `--variables '{"limit": 3}'` must honor the limit.

### R2 (P2) `WorkflowExecutionPlan` and preflight trap on duplicate step/node ids from programmatic workflows

**Location**: `Sources/RielaCore/WorkflowExecutionPlan.swift:6-7`,
`Sources/RielaCore/WorkflowRuntimeCapabilityGap.swift:59` — all three use
`Dictionary(uniqueKeysWithValues:)`, which **fatalErrors** on duplicate keys.

**Problem**: duplicate step/node id detection lives only in the authored-JSON
validator (`validateTypedAuthoredWorkflow`,
`WorkflowValidation.swift:186,229`). `DefaultWorkflowValidator.validate` —
the check the runner performs at the top of `run()` — does not flag
duplicates. A `WorkflowDefinition` constructed programmatically through the
library API (the `riela-workflow-reference` integration path) with a
duplicated step id previously ran with first-match semantics
(`first(where:)`); it now crashes the host process before any
`DeterministicWorkflowRunnerError` can be thrown. `unsupportedFeatures`'s
`reachableSteps` traps the same way, and it is also called from
`workflow validate`.

**Improvement design**: add duplicate step-id and node-id error diagnostics
to `DefaultWorkflowValidator.validate` (cheap set pass, mirroring the
authored validator), and build the dictionaries with
`Dictionary(_, uniquingKeysWith: { first, _ in first })` as defense in depth
so no input can trap the runtime. One unit test each for the runner and
`unsupportedFeatures` with a duplicated id.

### R3 (P2) `executionLiveTails` grows without bound in long-lived stores

**Location**: `Sources/RielaCore/RuntimeStore.swift:415,595-603,783`.

**Problem**: entries are inserted per execution (backend events, and
`detachingBackendLiveTails` during `seedSession`) and never removed — the
table has no `removeValue` call. The tail must outlive the execution today
because `updateStepExecution` strips tail fields from the stored session
(`withoutBackendLiveTail`) and every read re-projects them. For the CLI's
per-run store this is bounded; for a long-lived
`InMemoryWorkflowRuntimeStore` (serve/app surfaces, or any embedder that
seeds many sessions) it accumulates up to 32 KiB text + 100 event records
per execution forever.

**Improvement design**: on terminal `updateStepExecution` (`completed`,
`failed`, `skipped`), fold the live tail *into* the stored execution (the
inverse of today: apply `projectBackendLiveTail` before storing) and delete
the `executionLiveTails` entry; `markSessionFailed` does the same for the
executions it fails. Reads of running executions keep the projection path;
completed executions carry their own tail. This also removes the subtle
invariant that final-snapshot fidelity depends on the side table surviving
until persistence runs.

### R4 (P3) Capability preflight skips labeled transitions — labeled fanout/cross-workflow still fail mid-run

**Location**: `Sources/RielaCore/WorkflowRuntimeCapabilityGap.swift:33-35`
(`if let label = transition.label, !label.isEmpty { continue }`).

**Problem**: the preflight ignores transitions with a non-empty label,
presumably to avoid rejecting workflows whose unsupported branch may never
fire. But the publisher's `unsupportedTransitionReason` evaluates
*publishable* transitions after label evaluation, so a labeled fanout or
cross-workflow transition whose condition fires still fails the session
mid-run — the exact failure mode F9 set out to eliminate, now limited to
the conditional case.

**Improvement design**: flag labeled unsupported transitions as
`severity: .warning` in `workflow validate` output ("branch 'x' uses
fanout, which will fail at runtime if selected") while keeping the hard
preflight error for unconditional ones. Alternatively (stricter, simpler):
treat any reachable unsupported transition as an error regardless of label
— a workflow whose branch can never fire should not declare it.

### R5 (P3) Remaining agent-package duplication after the AgentRuntimeKit extraction

**Measurements** (brand-normalized diff, post-`dcb16c6`):

| pair | lines | differing |
|---|---|---|
| Codex vs Cursor `UsageStats` | 564 each | 12 |
| Codex vs Cursor `SessionSQLiteIndex` | 59 each | 22 |
| ClaudeCode vs Codex `ProcessIO` (residual wrapper) | 74/77 | 9 |
| Codex vs Cursor `ProcessManager` (residual wrapper) | 301/287 | 30 |

`UsageStats` is now the largest near-identical clone (564 lines × 3 brands,
~12 differing lines). `Operations`, `OperationalStores`, and the GraphQL
command executors have genuinely diverged per provider and are reasonable
to leave. Also noted: `AgentRuntimeKit` declares no dependency on
`RielaSQLite` (`Package.swift:55`), so the per-agent `SessionSQLiteIndex`
files keep their own SQLite plumbing.

**Improvement design**: extract `UsageStats` into `AgentRuntimeKit`
parameterized by the provider descriptor (the differing lines are naming
and paths), and let `AgentRuntimeKit` depend on `RielaSQLite` so the
session-index plumbing collapses too. Keep the residual thin wrappers —
they are the intended shape.

### R6 (P3) `JSONValue` round-trip canonicalizes `1.0` to `1`

**Location**: `Sources/RielaCore/JSONValue.swift` decode order (Int64 tried
before Double).

**Problem**: `{"v": 1.0}` decodes as `.integer(1)` and re-encodes as `1`.
Numerically equal, and cross-case `==` handles comparison, but byte-level
golden-file comparisons or external consumers diffing re-encoded JSON will
see representation churn on integral doubles.

**Improvement design**: document the canonicalization as intended behavior
in the type's doc comment and in the compatibility notes (recorded here);
ensure golden tests compare decoded values, not bytes. No code change
recommended — preserving `1.0` would require a dedicated case and is not
worth the churn.

### R7 (P3) Post-cap streamed-text appends are O(cap) per delta, not O(delta)

**Location**: `Sources/RielaCore/RuntimeStore.swift:663-678`
(`cappedStreamedResponseText(appending:to:)`).

**Problem** (residual of F2, acknowledged trade-off): once at the 32 KiB
cap, each delta re-walks the stored 16 KiB prefix (`byteBoundPrefix`) and
re-derives the suffix from tail+delta — bounded (~48 KiB character walk per
delta) but repeated for every delta. The F2 design's byte-ring
representation (amortized O(delta) append, lazy String materialization)
remains the target if streaming profiles show this path hot; not urgent
since the work is strictly bounded.

### Follow-up priority

R1 first (correctness regression, small diff), then R2 (crash vector for
library consumers) and R3 (leak in long-lived surfaces). R4–R7 are
batchable with the existing phase 5/6 work.

### Final remediation audit (2026-07-03)

The current worktree was rechecked against R1–R7 after the follow-up fixes.

| finding | status | evidence |
|---|---|---|
| R1 | resolved | Agent process/file-change helpers now use `JSONValue.asDouble` / `asInt64`; decoded integral `ExecCommandEnd` tests pass for Codex, Claude Code, and Cursor CLI; Codex GraphQL `--variables '{"limit":3}'` honors the integer. A source sweep for `case let .number` leaves only sites that also handle `.integer` first or operate on `MemoryJSONValue`. |
| R2 | resolved | `DefaultWorkflowValidator` rejects duplicate programmatic step/node ids, and `WorkflowExecutionPlan` / `unsupportedFeatures` build lookup dictionaries with first-value uniquing instead of `Dictionary(uniqueKeysWithValues:)` traps. |
| R3 | resolved | Terminal `updateStepExecution` and `markSessionFailed` fold live-tail state back into stored executions and remove the `executionLiveTails` entry; `RuntimeStoreTests` assert the testing count returns to zero. |
| R4 | resolved | Labeled unsupported transitions are reported as warning capability gaps instead of being skipped, while unconditional unsupported transitions remain hard preflight errors. |
| R5 | resolved (slice) | `AgentUsageStats` moved into `AgentRuntimeKit`, shrinking each provider `*UsageStats.swift` wrapper to 40 lines while preserving public provider type names and functions. `AgentRuntimeKit` now depends on `RielaSQLite`, and `AgentSessionSQLiteSupport` uses `SQLiteDatabase` instead of invoking `/usr/bin/sqlite3`. |
| R6 | resolved (documentation) | `JSONValue` documents that integral decoded numbers canonicalize to `.integer`, so `1.0` may re-encode as `1`; no code change was recommended by the finding. |
| R7 | resolved (bounded hot path) | Running backend live tails now store streamed assistant text in an internal byte head/tail buffer. Once capped, appends update only the suffix bytes plus the new delta and materialize the public `String` lazily on projection, preserving the public 32 KiB head+tail behavior. |

During full-suite verification, `BackendEventCoalescer` was also adjusted so
fast synthetic Cursor thinking streams are not split by the time threshold
before the byte threshold is exercised.

Validation run after this audit:

- `swift build`
- `swift test --filter 'AgentUsageStatsTests|RuntimeStoreTests|CodexAgentCompatibilityUsageStatsTests|AgentSessionSQLiteSupportTests|CodexAgentSessionIndexCompatibilityTests|ClaudeCodeSessionIndexCompatibilityTests|CursorCLISessionIndexCompatibilityTests'`
- `swift test --filter 'CodexAgentCompatibilityTests/testDecodedIntegralExecCommandEndReportsErrors|ClaudeCodeAgentCompatibilityTests/testDecodedIntegralExecCommandEndReportsErrors|CursorCLIAgentCompatibilityTests/testDecodedIntegralExecCommandEndReportsErrors|CodexAgentCompatibilityTests/testGraphQLVariablesFileChangesAndTranscriptSearchBudgets|WorkflowRunnerCapabilityPreflightTests|WorkflowModelTests/testDefaultWorkflowValidatorRejectsDuplicateProgrammaticStepAndNodeIds|JSONValueTests'`
- `/usr/bin/xcrun swiftlint`
- `swift test --filter 'AgentAdapterTests/testCursorThinkingDeltasAreCoalescedBeforeBackendEventHandler'`
- `swift test --filter 'AgentAdapterTests/testFoundationRunnerDrainsLargeOutput'`
- `swift test` (964 tests, 0 failures)

---

## Third-Pass Review (commits `aa1830a`, `fe76f60`, `2892a02`, 2026-07-03)

An independent third review pass verified the R1–R7 remediation commits.
Build is clean and the full suite (964 tests) passes. All seven findings are
confirmed fixed as claimed by the audit table above — spot checks below —
but the remediation introduced one behavioral regression (S1) and left one
narrow residual of R3 (S2). S1 should be fixed before streaming ships to
interactive consumers.

### Independent verification of R1–R7 (confirmed)

- **R1**: all four flagged helpers now delegate to `asDouble`/`asInt64`;
  the repo-wide sweep for `case let .number` leaves only exhaustive
  switches that handle `.integer` and helpers typed against RielaMemory's
  `MemoryJSONValue` (a different enum without an `.integer` case — correctly
  out of scope). New decode-path tests (`decodedJSONObject` helper,
  `testDecodedIntegralExecCommandEndReportsErrors` ×3 providers, GraphQL
  `--variables '{"limit":3}'` assertion) close the fixture-realism gap.
- **R2**: `DefaultWorkflowValidator` gained `validateUniqueIds` for both
  collections; all three dictionary builds use first-value uniquing.
- **R3**: terminal `updateStepExecution` and `markSessionFailed` fold the
  tail into the stored execution and `removeValue` the side-table entry;
  tests assert the count drains to zero. Residual: S2.
- **R4**: labeled unsupported transitions produce `.warning` gaps; the
  runner throws only on `.error` severity, `workflow validate` surfaces
  both.
- **R5**: `AgentUsageStats` (612 lines) extracted to `AgentRuntimeKit`;
  per-provider wrappers are 40 lines each. `AgentRuntimeKit` now depends on
  `RielaSQLite` and `AgentSessionSQLiteSupport` uses `SQLiteDatabase`
  (replacing the previous `/usr/bin/sqlite3` process spawning — a bonus
  robustness fix). Remaining `SessionSQLiteIndex` clones are 59 lines each;
  acceptable.
- **R6**: canonicalization documented on the type.
- **R7**: `StreamedResponseTextBuffer` keeps head/tail as byte arrays with
  an uncapped fast path; post-cap appends touch only `suffixBytes` plus the
  delta and repair UTF-8 continuation bytes on lazy materialization.
  (`removeFirst(_:)` on the suffix array is O(suffixCap) worst case per
  flush, but the suffix is ≤16 KiB and deltas arrive pre-coalesced — within
  the "bounded" intent of R7.)

### S1 (P2) `BackendEventCoalescer` time threshold raised 0.25 s → 2.0 s to stabilize a test — an 8× live-latency regression that contradicts the streaming spec

**Location**: `Sources/RielaAdapters/LocalAgentProcess.swift:909`
(`timeThreshold: TimeInterval = 2.0`, changed in `2892a02`);
spec contract at `design-agent-response-streaming.md` §3 ("flushes when …
(b) **250 ms** elapsed since first absorbed delta", "§6 … ≤ ~4 content
events/sec").

**Problem**: the third-pass audit note in this document admits the change
was made so "fast synthetic Cursor thinking streams are not split by the
time threshold" in
`testCursorThinkingDeltasAreCoalescedBeforeBackendEventHandler` (the test
feeds 300 one-byte deltas and asserts exactly 2 events — byte-threshold
splits only). Changing the production constant to make a timing-sensitive
test deterministic:

1. **Regresses live streaming latency**: content trickling slower than
   256 bytes per window now surfaces up to 2 s late (the flush check runs
   only when the next delta arrives, so a slow token stream is paced at the
   threshold). The entire point of the streaming feature is sub-second
   visibility of agent output.
2. **Silently diverges from the design spec**, which still promises 250 ms
   / ~4 events/sec in two places. Nobody reading the spec will predict 2 s
   behavior.
3. Leaves the test still timing-dependent in principle — a sufficiently
   slow CI machine could still cross 2 s mid-burst.

**Improvement design**: make the threshold injectable —
`BackendEventCoalescer(byteThreshold: Int = 256, timeThreshold: TimeInterval = 0.25)`
— restore the production default to 0.25 s, and have the streaming tests
construct the adapter with a large (or infinite) time threshold, or inject
a fixed clock, so the test asserts byte-threshold behavior without touching
the shipped constant. Update the spec if a different production value is
ever chosen deliberately.

### S2 (P3) R3 residual: seeded terminal executions still park live tails in the side table forever

**Location**: `Sources/RielaCore/RuntimeStore.swift:729-739`
(`detachingBackendLiveTails`), called from `seedSession` at :431.

**Problem**: `detachingBackendLiveTails` moves tail fields into
`executionLiveTails` for **every** seeded execution regardless of status.
The R3 cleanup (`finalizeBackendLiveTail`) runs only inside
`updateStepExecution`/`markSessionFailed`, which are never called again for
an already-terminal execution — so seeded completed/failed executions with
`streamedResponseText` occupy the side table for the store's lifetime. The
CLI seeds *all* persisted sessions at every run
(`seedRuntimeStoreFromPersistedCLIState` → `loadAll()`), so the table holds
one entry per historical streamed execution, up to ~32 KiB each. Bounded
per process for the CLI, unbounded accumulation only for embedders that
seed repeatedly; either way the entries are pure dead weight.

**Improvement design**: in `detachingBackendLiveTails`, detach only
executions with `status == .running`; terminal executions keep their tail
fields inline (the projection path already returns executions without a
side-table entry unchanged, so reads are identical). One-line status guard
plus a seeding test asserting `executionLiveTailCountForTesting() == 0`
after seeding a completed session.

### S3 (P3) Streamed-text byte cap duplicated as a magic number

**Location**: `Sources/RielaCore/RuntimeStore.swift` — the store's
`streamedResponseTextByteCap` property, the `32 * 1024` literal in
`WorkflowExecutionLiveTail.init(execution:)`, and the `byteCap: 32 * 1024`
at the projection site (`applying(to:)` path, :810).

**Problem**: three copies of the constant; if the cap is ever tuned, the
buffer init and projection will silently disagree with the store property
(e.g., re-capping seeded text at a stale size).

**Improvement design**: single
`enum WorkflowStreamedResponseText { static let byteCap = 32 * 1024 }` (or
a static on `StreamedResponseTextBuffer`) referenced from all three sites.

### Third-pass conclusion

The R1 correctness regression, the R2 crash vector, and the R3 leak are
genuinely fixed with regression tests. The follow-up implementation below
also closes S1-S3.

### Third-pass follow-up implementation (2026-07-03)

- **S1 resolved**: `LocalAgentCommandAdapter` now exposes an injectable
  backend-event coalescing time threshold with a production default of
  `0.25` seconds. The byte-threshold coalescing test injects `2.0` seconds,
  and a new streaming test verifies the production default splits delayed
  Cursor thinking deltas at the 250 ms latency target.
- **S2 resolved**: `detachingBackendLiveTails` now detaches only running
  executions. Terminal seeded executions keep their live-tail fields inline,
  and the new seed-session regression test verifies only the running
  execution occupies the side table.
- **S3 resolved**: streamed response text capping now uses the single
  `WorkflowStreamedResponseText.byteCap` constant across live-tail updates,
  seeding, and projection.

Validation after the follow-up:

- `swift test --filter AgentAdapterTests`
- `swift test --filter RuntimeStoreTests`
- `xcrun swiftlint` (Xcode toolchain, 0 violations)
- `swift test` (966 tests, 0 failures)

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
