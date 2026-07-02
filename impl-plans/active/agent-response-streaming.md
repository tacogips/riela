# Agent Response Streaming Implementation Plan

**Status**: Implemented
**Design Reference**: `design-docs/specs/design-agent-response-streaming.md`
**Created**: 2026-07-02
**Last Updated**: 2026-07-02
**Workflow Mode**: issue-resolution
**Issue Reference**: none-provided

---

## Design Document Reference

**Source**: `design-docs/specs/design-agent-response-streaming.md`

### Summary

Implement Phase 1 agent response streaming for CLI agent backends. The scope is
limited to additive backend-event contracts, codex/cursor content
classification, a non-blocking local process bridge, enriched live
`WorkflowRunEvent` JSONL, runtime-store live-tail fields, and focused tests.

### Scope

**Included**:

- Add optional backend-event content fields to RielaCore adapter and run-event
  contracts.
- Add codex-agent and cursor-cli-agent classifiers that expose assistant,
  thinking, tool, usage, and lifecycle channels from existing JSON line output.
- Replace the blocking per-line local process event bridge with an ordered,
  buffered async bridge and bounded delta coalescing.
- Persist bounded live-tail metadata in the runtime store:
  `backendEventCount`, `recentBackendEvents`, and `streamedResponseText`.
- Enrich the existing live `riela workflow run --output jsonl`
  `backend_event` records.
- Preserve final response extraction through the existing buffered stdout
  normalizers.
- Add focused unit and integration tests for classifiers, coalescing, bridge
  ordering, store state, and JSONL enrichment.

**Excluded**:

- Claude `stream-json` migration and `normalizeClaudeStreamJSONStdout`.
- GraphQL polling APIs and viewer/RielaApp panes.
- `riela session logs --follow`.
- Text-mode live response lines.
- Full-fidelity `backend-events.jsonl` artifact reads or tailing.
- Unrelated RielaApp UX changes.

---

## Referenced Behavior And Accepted Divergences

- Codex reference:
  `Sources/CodexAgent/CodexAgentAdapter.swift` and the design's verified
  `codex exec --json -` behavior are authoritative for Phase 1. The
  implementation streams item-level snapshots from `item.completed` events,
  not token deltas, because codex exec JSON does not emit token deltas.
- Cursor reference:
  `Sources/CursorCLIAgent/CursorCLIAgentAdapter.swift` and the design's
  verified `cursor-agent --print --output-format stream-json` behavior are
  authoritative for Phase 1. The implementation streams thinking deltas and
  assistant snapshots from existing stream-json output without changing CLI
  flags.
- Intentional backend divergence:
  codex streams item snapshots while cursor streams coalesced deltas where the
  CLI provides deltas. Both are normalized into the same optional
  `AdapterBackendEvent` and `WorkflowRunEvent` fields.
- Compatibility boundary:
  existing `backendEventType` classifiers remain as fallback behavior, and
  existing session/run event decoders must keep accepting older records.

---

## Tasks And Deliverables

### 1. Core Event Contracts

**Status**: COMPLETED

**Write Scope**:

- `Sources/RielaCore/AdapterContracts.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+Events.swift`
- Codable tests under `Tests/RielaCoreTests/`

**Deliverables**:

- `AdapterBackendEventChannel` with open, documented channel cases for
  lifecycle, assistant, thinking, tool, and usage.
- Additive optional fields on `AdapterBackendEvent`: channel, content delta,
  content snapshot, delta marker, tool name, usage object, sequence, and
  timestamp.
- Additive optional fields on `WorkflowRunEvent`: backend event channel,
  content, delta marker, sequence, and tool name.
- Defaulted initializers and Codable behavior that preserve existing call
  sites and old persisted data.

**Verification**:

- Unit tests prove old minimal `backend_event` JSON decodes.
- Unit tests prove enriched `backend_event` JSON encodes expected field names.

### 2. Codex And Cursor Classifiers

**Status**: COMPLETED

**Write Scope**:

- `Sources/CodexAgent/CodexAgentAdapter.swift`
- `Sources/CursorCLIAgent/CursorCLIAgentAdapter.swift`
- `Tests/AgentAdapterTests/`

**Deliverables**:

- Add `classifyCodexBackendEvent(_:)` beside the existing codex event-type
  helper.
- Map codex `agent_message`, `reasoning`, tool/command execution, usage, and
  lifecycle records to enriched backend events.
- Add `classifyCursorBackendEvent(_:)` beside the existing cursor event-type
  helper.
- Map cursor thinking deltas, assistant message snapshots, result/usage, and
  lifecycle records to enriched backend events.
- Keep unknown or malformed lines non-fatal, preserving the final result path.
- Return extracted event metadata and raw content only; redaction, truncation,
  node-level content opt-out, buffering, and coalescing happen in the local
  process bridge where command configuration and environment are available.

**Verification**:

- Fixture-line tests for codex assistant, reasoning, tool, usage, lifecycle,
  unknown events, and malformed JSON.
- Fixture-line tests for cursor thinking delta, assistant snapshot, result
  usage, lifecycle, unknown events, and malformed JSON.

### 3. Non-Blocking Local Process Bridge

**Status**: COMPLETED

**Write Scope**:

- `Sources/RielaAdapters/LocalAgentProcess.swift`
- `Tests/AgentAdapterTests/`

**Deliverables**:

- Add `LocalAgentCommand.classifyBackendEvent` as an optional richer classifier
  that wins over `backendEventType`.
- Replace the `DispatchSemaphore` per-line bridge with an ordered
  `AsyncStream<AdapterBackendEvent>` consumer.
- Add bounded buffering with newest-event retention so reader threads never
  block on runtime-store I/O.
- Add `BackendEventCoalescer` for consecutive same-channel deltas, flushing on
  byte threshold, elapsed time threshold, and channel/type switch.
- Apply content truncation and sensitive-value redaction inside
  `LocalAgentCommandAdapter` before yielding events, using
  `redactAdapterSensitiveText(_, additionalSensitiveValues:
  sensitiveAdapterEnvironmentValues(command.configuration.environment))`.
- Implement node-level `variables.streamBackendContent: false` as the Phase 1
  opt-out: classifiers may still produce type/lifecycle events, but assistant,
  thinking, tool, and usage content fields must be stripped before events leave
  the adapter boundary.
- Ensure the consumer is finished and awaited before `execute` returns, so the
  last backend event still precedes `step_completed`.

**Verification**:

- Mock process runner tests assert output-line replay order, slow backend event
  handler isolation, coalescer flush behavior, and completion ordering.
- Bridge tests assert sensitive environment values are redacted, huge content
  is truncated to the accepted cap, and
  `variables.streamBackendContent: false` emits type-only events with no
  content fields while preserving heartbeat/event-type behavior.

### 4. Runner And Runtime Store Live Tail

**Status**: COMPLETED

**Write Scope**:

- `Sources/RielaCore/DeterministicWorkflowRunner.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift`
- `Sources/RielaCore/RuntimeSession.swift`
- `Sources/RielaCore/RuntimeStore.swift`
- `Tests/RielaCoreTests/`

**Deliverables**:

- Assign per-step-execution monotonic backend event sequence numbers in the
  runner.
- Extend `WorkflowStepBackendEventInput` and store recording to carry enriched
  fields.
- Add `WorkflowBackendEventRecord` and optional `WorkflowStepExecution`
  live-tail fields: `backendEventCount`, `recentBackendEvents`, and
  `streamedResponseText`.
- Keep lifecycle-only events on the cheap timestamp/type path while still
  updating count and last event metadata as required by the design.
- Bound `recentBackendEvents` and cap assistant `streamedResponseText`.

**Verification**:

- Store tests assert ring cap, count increments, assistant snapshot replacement,
  assistant delta append, lifecycle-only compatibility, and old session JSON
  decoding.

### 5. Live JSONL Enrichment

**Status**: COMPLETED

**Write Scope**:

- `Sources/RielaCore/DeterministicWorkflowRunner+Events.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift`
- CLI JSONL assertions in `Tests/RielaCoreTests/` or `Tests/RielaCLITests/`

**Deliverables**:

- Include enriched backend event fields in emitted `WorkflowRunEvent` values.
- Preserve the existing event type and `backendEventType` fields.
- Confirm `riela workflow run --output jsonl` gains content through the
  existing recorder without a new CLI flag or text renderer change.

**Verification**:

- Runner or CLI tests assert `backendEventContent`, channel, sequence, and
  delta marker appear before `step_completed` in captured JSONL events.

### 6. Focused Regression And Compatibility Pass

**Status**: COMPLETED

**Write Scope**:

- Test-only changes unless earlier tasks expose a contract bug.

**Deliverables**:

- Explicit `swift build` typecheck/build verification for the changed package.
- Focused Swift test set for changed modules.
- Compatibility coverage for old event/session records and unchanged final
  response extraction.
- A manual verification recipe for real codex/cursor runs when local CLIs are
  available.

**Verification**:

- `swift build`
- `swift test --filter AgentAdapterTests`
- `swift test --filter DeterministicWorkflowRunnerBackendEventTests`
- `swift test --filter RuntimeStoreTests`
- `swift test --filter WorkflowObservabilityTests`
- Optional manual: `riela workflow run <codex-or-cursor-fixture-workflow> --output jsonl`
  and confirm enriched `backend_event` lines arrive before `step_completed`.

---

## Dependencies

| Task | Depends On | Reason |
| ---- | ---------- | ------ |
| Core Event Contracts | Accepted design doc | Defines additive public event schema. |
| Codex And Cursor Classifiers | Core Event Contracts | Classifiers produce enriched `AdapterBackendEvent` values. |
| Non-Blocking Local Process Bridge | Core Event Contracts | Bridge transports enriched events and coalesces deltas. |
| Runner And Runtime Store Live Tail | Core Event Contracts | Store input and run events depend on event field shape. |
| Live JSONL Enrichment | Runner And Runtime Store Live Tail | JSONL events need runner-assigned sequence and enriched input. |
| Regression And Compatibility Pass | Tasks 1-5 | Final tests must cover integrated behavior. |

## Parallelizable Tasks

- Task 2 codex classifier work and cursor classifier work are parallelizable
  with each other because write scopes are disjoint except for shared test
  support coordination.
- Task 2 classifier work can proceed in parallel with Task 4 runtime-store
  model work after Task 1 contract names are settled.
- Task 3 bridge work can proceed in parallel with Task 4 runtime-store work
  after Task 1 contract names are settled.
- Task 5 is not parallelizable with Task 4 because it depends on runner
  sequence assignment and enriched store/run-event input.

## Completion Criteria

- [x] Phase 1 scope from the accepted design is implemented and no excluded
  read-surface or Claude migration work is included.
- [x] Existing backend event behavior remains source-compatible through
  `backendEventType` fallback and optional Codable fields.
- [x] Codex assistant snapshots and cursor thinking/assistant content appear
  as enriched live `backend_event` JSONL records.
- [x] Runtime sessions expose bounded `recentBackendEvents`,
  `backendEventCount`, and `streamedResponseText` without breaking old session
  data.
- [x] Slow backend event handling no longer blocks stdout pipe reading.
- [x] Final adapter outputs still come from existing full-stdout normalizers.
- [x] Focused Swift tests pass for adapters, runner backend events, runtime
  store, and observability/event encoding.

## Progress Log Expectations

- Implementation sessions should append a dated entry before handoff with:
  completed tasks, in-progress tasks, changed files, verification commands,
  failures or skipped checks, and residual risks.
- If scope is deferred, name the deferred item and tie it to the design's
  Phase 2 or Phase 3 boundary.
- Do not record scratch paths outside `tmp/`; any ad-hoc evidence should live
  under `tmp/agent-response-streaming/` and remain uncommitted.

## Progress Log

### Session: 2026-07-02

**Tasks Completed**: Created implementation plan from accepted Step 3 design.
Revised after Step 4 self-review feedback to move redaction/truncation and
content opt-out expectations into the local process bridge work, keep
classifier tests focused on extraction/mapping, and add explicit `swift build`
verification.

**Tasks In Progress**: None.

**Blockers**: None.

**Notes**: Step 3 accepted the design with no findings or revision requests.
This plan is intentionally limited to Phase 1 implementation and verification.

### Session: 2026-07-02 Step 6 Implementation

**Tasks Completed**: Implemented Phase 1 backend response streaming contracts,
codex/cursor classifiers, non-blocking local-process event bridge, bounded
runtime-store live tail fields, enriched live `WorkflowRunEvent` JSONL fields,
and focused regression tests. Split new streaming adapter tests into
`Tests/AgentAdapterTests/AgentAdapterStreamingTests.swift` so
`AgentAdapterAdditionalTests.swift` remains under the 1000-line Swift file
threshold.

**Changed Files**:

- `Sources/RielaCore/AdapterContracts.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+Events.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift`
- `Sources/RielaCore/RuntimeSession.swift`
- `Sources/RielaCore/RuntimeStore.swift`
- `Sources/RielaAdapters/LocalAgentProcess.swift`
- `Sources/CodexAgent/CodexAgentAdapter.swift`
- `Sources/CursorCLIAgent/CursorCLIAgentAdapter.swift`
- `Tests/AgentAdapterTests/AgentAdapterAdditionalTests.swift`
- `Tests/AgentAdapterTests/AgentAdapterStreamingTests.swift`
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerBackendEventTests.swift`
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerTestSupport.swift`
- `Tests/RielaCoreTests/RuntimeStoreTests.swift`

**Verification Commands**:

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build` - passed.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AgentAdapterTests` - passed.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter DeterministicWorkflowRunnerBackendEventTests` - passed.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RuntimeStoreTests` - passed.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowObservabilityTests` - passed.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RuntimeSessionTests` - passed.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint` - passed with 0 violations.
- `git diff --check` - passed.

**Tasks In Progress**: None.

**Deferred By Scope**: Claude `stream-json` migration, GraphQL polling/viewer
read surfaces, `session logs --follow`, text-mode live lines, full-fidelity
`backend-events.jsonl` reads/tailing, and unrelated RielaApp UX changes remain
outside Phase 1 by accepted design.

**Blockers**: None.

## Risks

- CLI JSON event vocabularies may drift; classifiers must map unknown events to
  lifecycle or ignore malformed lines without failing execution.
- Streaming content may include secrets printed by an agent; redaction of known
  sensitive environment values and node-level opt-out must be preserved.
- Cursor delta volume can overwhelm stores if coalescing or buffering is
  bypassed.
- Additive Codable fields must remain optional so old sessions and existing
  clients keep working.
- Existing worktree changes in implementation files should be treated as
  user/runtime work and reconciled rather than reverted by later steps.
