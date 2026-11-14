# Session Follow, Rollup, and Backend Liveness Implementation Plan

**Status**: Implementation and required verification complete
**Workflow Mode**: `issue-resolution`
**Issue Reference**: workflow input from `fable-and-improve`; workflow execution
`codex-design-and-implement-review-loop-session-2`; no repository, issue number,
or issue URL supplied
**Design Reference**:
`design-docs/specs/design-workflow-progress-observability.md#session-follow-rollup-and-backend-liveness-extension-2026-07-23`
**Accepted Design Review**: `comm-000009`, decision `accept`, no findings
**Codex-Agent References**: none external; `Sources/CodexAgent` is an
in-repository implementation target, not a reference repository
**Created**: 2026-07-23
**Last Updated**: 2026-07-24

## Summary

Implement one cohesive session-observability feature with no feature fan-out:

- read-only `session progress --follow` text and JSONL digests with a validated
  polling interval and terminal exit;
- persisted cross-workflow parent/root provenance, indexed descendant reads,
  progress trees, and session-list relationship fields; and
- evidence-backed `active`, `quiet`, `stalled-suspect`, or `unknown` backend
  activity for Codex and Claude Code.

CLI and GraphQL must consume the same provider-neutral RielaCore projection and
health service. Existing commands, flags, schema fields, and legacy snapshots
remain compatible. Observer paths must never create, migrate, lock, touch, or
write the session store or provider artifacts.

## Source of Truth and Boundaries

The accepted extension in
`design-docs/specs/design-workflow-progress-observability.md` is authoritative.
Earlier sections of that document describe already-completed failure,
discovery, and budget work and are context rather than reopened scope.

Included:

- `WorkflowSession` parent/root provenance and effective-budget persistence.
- `WorkflowStepExecution` backend correlation metadata.
- Additive SQLite provenance columns and indexed, read-only descendant queries.
- Shared digest, rollup, terminal-state, and backend-activity contracts in
  RielaCore.
- Codex artifact-freshness and Claude stream/artifact probes using existing
  home resolvers and injectable roots.
- CLI progress follow/rollup, session-list provenance, and health activity.
- Additive GraphQL progress, rollup, health, and discovery provenance fields.
- Deterministic unit, parity, concurrency/read-only, and live smoke coverage.
- README and CLI-help documentation.

Excluded:

- Kill, restart, reconciliation, detach, attach, wait, remediation, or a new
  daemon.
- Reconstructing provenance for legacy sessions.
- RielaServer or RielaApp runtime-session GraphQL composition, because those
  production execution paths do not currently exist.
- Cursor-specific liveness logic. Cursor remains behind its adapter boundary
  and produces `unknown` through the provider-neutral fallback.
- Optional PID/process evidence unless existing, uniquely correlated adapter
  metadata makes it available without broadening the accepted scope.

Intentional reference boundaries:

- No external Codex-agent repository or Codex-reference behavior was supplied.
- Use concrete local seams in `Sources/CodexAgent`,
  `Sources/ClaudeCodeAgent`, and `Sources/AgentRuntimeKit`; do not copy provider
  behavior into RielaCore.
- Do not add Cursor session discovery, artifact matching, or process logic.

## Task Breakdown

### T1. Baseline and Contract Audit

**Status**: COMPLETED
**Write Scope**: none, except scratch evidence under
`tmp/session-follow-rollup-backend-liveness/`
**Depends On**: accepted Step 3 design review

**Deliverables**:

- Confirm branch, dirty-worktree ownership, current session CLI parsing and
  rendering, runtime snapshot persistence, cross-workflow dispatch, event
  capture, Codex/Claude session indexes, and GraphQL parity composition.
- Record any source drift that changes file placement but not accepted behavior
  in this plan's progress log before implementation edits.
- Confirm there is no unresolved user decision requiring a
  `design-docs/user-qa/` entry.

**Verification**:

- `git status --short --branch`
- `rg -n "SessionInspectionCommand|CLIWorkflowSessionStore|SQLiteWorkflowRuntimePersistenceStore|dispatchCrossWorkflowCallee|AdapterBackendEvent|GraphQLRuntimeSnapshotQueryService" Sources Tests`
- `rg -n "resolveCodexHome|resolveClaudeCodeHome|AgentProcessStateProber" Sources/CodexAgent Sources/ClaudeCodeAgent Sources/AgentRuntimeKit`

### T2. Provider-Neutral Models and Additive Persistence Fields

**Status**: COMPLETED
**Write Scope**:
`Sources/RielaCore/RuntimeSession.swift`,
`Sources/RielaCore/AdapterContracts.swift`, new RielaCore observability model
files, and focused new model tests under `Tests/RielaCoreTests/`
**Depends On**: T1

**Deliverables**:

- Add optional `parentSessionId`, `rootSessionId`, and
  `effectiveStepBudget` session fields with legacy-safe Codable behavior.
- Add optional `backendSessionId` and `backendWorkingDirectory` execution
  fields and optional `backendSessionId` backend-event metadata.
- Define stable provider-neutral DTOs for `SessionProgressDigest`,
  `SessionRollupNode`, `SessionBackendActivity`, evidence, thresholds, verdict,
  and `SessionObservabilityView`.
- Define the backend probe and registry interfaces without importing CodexAgent
  or ClaudeCodeAgent.
- Keep structured ages in milliseconds, timestamps in ISO-8601 UTC, and verdict
  raw values compatible with the accepted CLI/GraphQL contract.

**Completion Criteria**:

- Old session/execution JSON without new fields decodes unchanged.
- New fields round-trip without changing existing encoded fields.
- Unsupported or absent probe registration has an explicit `unknown` result.

**Verification**:

- Focused new RielaCore model/Codable tests.
- `swift test --filter RielaCoreTests`

### T3. Runner Provenance and Backend Correlation Writer Path

**Status**: COMPLETED
**Write Scope**:
`Sources/RielaCore/DeterministicWorkflowRunner.swift`,
`Sources/RielaCore/DeterministicWorkflowRunner+Lifecycle.swift`,
`Sources/RielaCore/DeterministicWorkflowRunner+CrossWorkflow.swift`,
`Sources/RielaCore/DeterministicWorkflowRunner+Events.swift`, provider event
classification in `Sources/CodexAgent/` and `Sources/ClaudeCodeAgent/`, and
dedicated runner/event tests
**Depends On**: T2

**Deliverables**:

- Carry parent/root provenance on internal run requests; assign a top-level
  root id and pass parent/root ids before invoking a cross-workflow child.
- Persist the runner's computed effective step budget on the session before the
  initial live snapshot.
- Capture the effective node working directory when an execution starts.
- Emit and persist the uniquely identified native backend session id as soon as
  the existing Codex or Claude stream parser resolves it.
- Ensure the child's first persisted `session_started` snapshot contains
  provenance so in-flight discovery does not depend on the parent's completion
  payload.
- Preserve existing workflow execution, failure, cancellation, resume, and
  `_rielaCrossWorkflow` completion behavior.

**Completion Criteria**:

- Top-level sessions resolve to their own root id; nested children retain the
  immediate parent and inherited root.
- An in-flight child snapshot contains provenance before parent completion.
- Backend executions persist the canonical absolute effective working
  directory for explicit, relative, and inherited process-directory cases.
- Backend id and working-directory metadata persist only through the existing
  session writer path.

**Verification**:

- Focused RielaCore cross-workflow lifecycle and backend-event tests.
- Focused CodexAgent and ClaudeCodeAgent event-classification tests.

### T4. SQLite Provenance Migration and Read-Only Rollup Queries

**Status**: COMPLETED
**Write Scope**:
`Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` and a dedicated
`Tests/RielaCoreTests/SessionObservabilityPersistenceTests.swift` or equivalent
focused test file
**Depends On**: T2

**Deliverables**:

- Add nullable `parent_session_id` and `root_session_id` columns and indexes on
  the existing writable schema-preparation path only.
- Populate indexed provenance during snapshot upsert.
- Feature-detect older schemas on read-only connections without DDL, writable
  fallback, file creation, or timestamp mutation.
- Add bounded direct-child and root-descendant queries using short-lived,
  read-only connections and indexed predicates.
- Assemble trees deterministically by `createdAt`, then `sessionId`; prevent
  malformed cycles and tolerate missing parents as unattached roots.
- Keep one refresh coherent and release its database connection before any
  follow sleep.

**Completion Criteria**:

- Running and completed children are discoverable through indexed reads.
- A pre-migration database remains readable and is byte/timestamp unchanged by
  inspection.
- Missing/cyclic provenance cannot hang or fail the full rollup.
- A polling reader coexists with a concurrent writer without taking an
  application lock or issuing writes.

**Verification**:

- Focused migration, legacy-read, descendant, cycle, and concurrent-reader
  tests.
- `swift test --filter RielaCoreTests`

### T5. Shared Digest, Rollup, and Health Service

**Status**: COMPLETED
**Write Scope**: new provider-neutral observability service/projector files in
`Sources/RielaCore/` and dedicated service tests under `Tests/RielaCoreTests/`
**Depends On**: T2, T4

**Deliverables**:

- Project current step/stage, execution count, effective budget, active
  backend, last backend event and age, provenance, status, and optional previous
  status from one injected observation time.
- Select budget from `stepBudgetDiagnostic.stepBudget`, then persisted
  `effectiveStepBudget`, else `nil`.
- Derive gate visits from
  `loopEvidence.convergence.gateVisitCounts`; use documented gate-id fallbacks
  only and never infer gates from step names.
- Build recursive rollups from the store's indexed descendants.
- Centralize terminal-state rules used by one-shot, follow, CLI, and GraphQL:
  `completed` and `failed` are terminal, transitional
  `failureKind: cancelled` remains terminal, and a future first-class
  `cancelled` status is handled additively.
- Invoke only the active backend's registered probe and merge its evidence,
  thresholds, timestamp, age, and verdict into the shared view.
- Keep observation transitions in memory; never persist polling state.

**Completion Criteria**:

- Projection is deterministic under an injected clock.
- CLI and GraphQL can consume the same DTO without duplicating field
  calculations.
- Legacy budgets/provenance and unsupported backends degrade to nullable fields
  or `unknown`, not guessed values.

**Verification**:

- Focused projection, gate-count, rollup, status-transition, terminal-state,
  and fake-probe tests.
- `swift test --filter RielaCoreTests`

### T6. Codex and Claude Backend Activity Probes

**Status**: COMPLETED
**Write Scope**: new probe files in `Sources/CodexAgent/` and
`Sources/ClaudeCodeAgent/`; focused new tests in `Tests/CodexAgentTests/` and
`Tests/ClaudeCodeAgentTests/`
**Depends On**: T3, T5

**Deliverables**:

- Resolve roots through `CodexSessionIndex.resolveCodexHome` and
  `ClaudeCodeSessionIndex.resolveClaudeCodeHome`, with injectable fixture roots.
- Prefer direct native session-id correlation; otherwise require one unique
  time-window and working-directory match. Never select the latest artifact by
  convenience.
- Use correlated Codex artifact modification freshness and correlated Claude
  stream-event recency, with artifact freshness as an additional Claude path.
- Implement deterministic defaults of 30,000 ms active and 180,000 ms stalled,
  returning evidence and thresholds with every classified result.
- Require provider-correlated stale evidence before `stalled-suspect`; stale
  runtime evidence alone remains `unknown`.
- Treat missing/unreadable roots, ambiguous matches, absent artifacts,
  unsupported backends, and probe errors as non-secret `unknown` evidence.
- Open provider artifacts read-only and never create or touch them.
- Allow structured local evidence to identify the correlated artifact while
  keeping evidence non-secret; leave user-facing home abbreviation to the CLI
  renderer.

**Completion Criteria**:

- Fixtures distinguish fresh healthy long turns from wedged-looking stale
  executions for both required providers.
- Ambiguous, missing, unreadable, and non-regular artifacts return `unknown`.
- Correlated artifacts are opened read-only and freshness comes from their
  current filesystem modification date, never only cached index metadata.
- Terminal executions with correlated evidence classify `quiet` as designed.

**Verification**:

- `swift test --filter CodexAgentTests`
- `swift test --filter ClaudeCodeAgentTests`

### T7. CLI Follow, Rollup, List, and Health Surfaces

**Status**: COMPLETED
**Write Scope**:
`Sources/RielaCLI/SessionCommands.swift`,
`Sources/RielaCLI/SessionCommandModels.swift`,
`Sources/RielaCLI/RielaCommand+SessionParsing.swift`,
`Sources/RielaCLI/RielaCLIApplication.swift`, optional focused new CLI helper
files, and dedicated `Tests/RielaCLITests/` files
**Depends On**: T4, T5

**Deliverables**:

- Add `--follow`, `--poll-interval`, and `--include-children` with the accepted
  command-validity and finite `0.1...3600` second validation; default to 2.0
  seconds.
- Inject clock and sleeper seams so cadence and terminal exit are tested without
  wall-clock delays.
- Open a fresh read-only view per tick, emit every refresh, close before sleep,
  and stop after the requested session or discovered tree is terminal.
- Emit text and one-object-per-line JSONL digests; reject
  `--follow --output json` with usage guidance.
- Set `previousStatus` from the immediately prior in-process observation and
  emit an already-terminal session exactly once.
- Render one-shot and follow trees for `--include-children`.
- Add parent/root fields to structured `session list` rows and append stable
  text columns without removing existing columns.
- Add the shared `backendActivity` object/evidence to health while preserving
  existing health and silence fields.
- Home-abbreviate artifact paths in text output while preserving the structured
  local evidence contract.
- Fail not-found/read/decode errors once rather than retrying forever.

**Completion Criteria**:

- Follow works against a concurrently written store and exits successfully on
  terminal state.
- Text and JSONL include every required digest field and status transition.
- One-shot and follow child trees show running and completed descendants.
- Reader-only invocations cannot create or migrate a missing/legacy store.

**Verification**:

- Focused CLI parsing, rendering, cadence, transition, terminal-exit,
  invalid-output, provenance-list, and concurrent-read tests.
- `swift test --filter RielaCLITests`

### T8. Additive GraphQL Observability Queries

**Status**: COMPLETED
**Write Scope**:
`Sources/RielaGraphQL/GraphQLContracts.swift`,
`Sources/RielaGraphQL/RielaGraphQL.swift`, and
`Tests/RielaGraphQLTests/GraphQLContractsTests.swift` or a dedicated new test
file
**Depends On**: T5

**Deliverables**:

- Add `sessionProgress(sessionId:, includeChildren:)` backed by the shared
  digest/rollup service.
- Add `sessionHealth(sessionId:)` backed by the shared digest and activity
  assessment.
- Add nullable parent/root fields to existing discovery rows.
- Preserve all existing names and fields; keep RielaGraphQL provider-neutral.
- Document and test the initializer behavior that produces `unknown` when an
  external/library consumer omits probe registration.
- Compare decoded GraphQL output directly with the shared service result for
  the same fixture and clock.

**Completion Criteria**:

- GraphQL values equal shared-service values rather than independent
  recalculations.
- Existing GraphQL session queries remain source- and schema-compatible.

**Verification**:

- `swift test --filter RielaGraphQLTests`

### T9. Production Probe Composition and CLI/GraphQL Parity

**Status**: COMPLETED
**Write Scope**: a CLI-owned composition factory, targeted integration in
`Sources/RielaCLI/SessionCommands.swift` and
`Sources/RielaCLI/ScopedParityCommands.swift`, plus CLI and GraphQL parity tests
**Depends On**: T6, T7, T8

**Deliverables**:

- Build one CLI-owned production factory for store service, clock, Codex probe,
  Claude probe, configured roots, and registry.
- Use the same factory for production CLI progress/health and
  `riela graphql session` parity actions.
- Delegate GraphQL parity through `GraphQLRuntimeSnapshotQueryService`; do not
  create a second registry or recompute verdicts.
- Prove both production consumers receive equivalent registry configuration.
- Leave RielaServer and RielaApp unchanged; record their accepted non-runtime
  GraphQL boundary in tests or progress evidence rather than adding unused
  composition.

**Completion Criteria**:

- CLI and GraphQL return equal rollup and health data for the same store,
  fixture roots, and clock.
- Codex and Claude production probes are registered on both in-scope paths.
- Cursor and deliberately unregistered external consumers return `unknown`.

**Verification**:

- Focused CLI/GraphQL parity and production-factory tests.
- `swift test --filter RielaCLITests`
- `swift test --filter RielaGraphQLTests`

### T10. Documentation, Smoke Verification, and Final Handoff

**Status**: COMPLETED
**Write Scope**: `README.md`,
`Sources/RielaCLI/RielaCLIApplication.swift`, and this plan's progress log;
no unrelated documentation
**Depends On**: T2 through T9

**Deliverables**:

- Add runnable README examples for one-shot/follow progress, text/JSONL,
  interval validation, children, list provenance, and health verdicts.
- Document read-only observers, terminal-tree exit, verdict semantics, and
  `unknown` fallback without claiming deadlock certainty.
- Ensure CLI help matches tested flag spelling, default/range, valid command
  scope, output rejection, and verdict raw values.
- Run the accepted parent/child live smoke and record exact commands, outputs,
  store path, terminal exit, and read-only evidence.
- Run build, required suites, lint if configured, diff checks, and pre-commit
  safety checks before any later commit step.
- Keep all scratch logs/fixtures under
  `tmp/session-follow-rollup-backend-liveness/` and remove them when done.

**Verification**:

- `swift build`
- `swift test --filter RielaCoreTests`
- `swift test --filter RielaCLITests`
- `swift test --filter RielaGraphQLTests`
- `swift test --filter CodexAgentTests`
- `swift test --filter ClaudeCodeAgentTests`
- `rg -n "session progress|include-children|poll-interval|backendActivity|parentSessionId|rootSessionId" README.md Sources/RielaCLI/RielaCLIApplication.swift`
- `xcrun swiftlint --quiet` when SwiftLint is available; otherwise record the
  command as an explicit verification limitation
- `git diff --check`
- `git status --short --branch`

Live smoke commands after a deterministic parent/child fixture is running:

- `.build/debug/riela session progress <session-id> --follow --poll-interval 0.2 --output text`
- `.build/debug/riela session progress <session-id> --follow --poll-interval 0.2 --output jsonl`
- `.build/debug/riela session progress <parent-session-id> --include-children --output json`
- `.build/debug/riela session list --output json`
- `.build/debug/riela session health <session-id> --output json`

## Dependencies

| Dependency | Required By | State |
|---|---|---|
| Accepted design review `comm-000009` | Entire plan | Available |
| Existing optional Codable migration pattern | T2 | Available |
| Existing cross-workflow runner and event writer path | T3 | Available |
| SQLite writable schema preparation and read-only opens | T4 | Available |
| Persisted loop evidence and step-budget diagnostic | T5 | Available |
| `CodexSessionIndex` and `ClaudeCodeSessionIndex` roots/indexes | T6 | Available |
| Shared service contract | T5-T9 | Available |
| Concrete provider probes | T9 | Available |
| CLI and GraphQL provider-neutral surfaces | T9 | Available |

## Parallelizable Tasks

- T3 and T4 may run in parallel after T2. Their implementation and dedicated
  test files are disjoint: runner/provider event writer paths versus the SQLite
  store/query path.
- T6, T7, and T8 may run in parallel after T5 and their own listed
  prerequisites. Their write scopes are disjoint: provider modules and provider
  tests, CLI command files and CLI tests, and RielaGraphQL files and GraphQL
  tests.
- T9 is not parallelizable with T7 or T8 because it integrates their production
  composition points.
- T10 waits for all implementation tasks so documentation and verification
  reflect the final behavior.

## Completion Criteria

- [x] The work remains exactly one feature/work package and
      `has_feature_fanout` is false.
- [x] `session progress --follow` emits periodic text and JSONL digests, shows
      required progress/evidence fields, and exits after the applicable terminal
      session/tree.
- [x] Follow and one-shot rollups use strictly read-only, short-lived store
      connections and coexist with a live writer.
- [x] Observability runtime-store and CLI session-resolution opens use
      `SQLiteOpenMode.strictReadOnlyWithImmutableFallback`; checkpointed stores
      without a WAL use SQLite immutable read-only mode, live WAL stores use
      strict read-only mode, neither path retries with `SQLITE_OPEN_READWRITE`,
      and unrelated legacy readers retain their compatibility fallback.
- [x] Health assesses only the active execution for nonterminal sessions and
      does not report a completed backend as quiet while a non-backend step is
      running.
- [x] A resumed session persists the newly enforced effective step budget in
      both started-execution and pre-execution-failure snapshots.
- [x] Backend events persist through the live writer path with bounded
      coalescing; a newly resolved native backend session id bypasses the
      throttle and is readable from SQLite before step completion.
- [x] Resume and rerun install the same live-persistence handler as fresh runs;
      a concurrent follow observes a resumed session transition from running to
      terminal instead of exiting on the previous terminal snapshot.
- [x] Each one-shot progress or health response is rendered from one coherent
      snapshot/service observation even when a writer advances during the read.
- [x] Parent/root provenance is written on the child's first snapshot and
      indexed discovery includes in-flight children.
- [x] Root-tree reads decode at most 1,000 snapshots per refresh and expose
      truncation plus the applied limit through the shared CLI/GraphQL view.
- [x] Include-children follow never returns terminal success from a truncated
      rollup; it emits the partial terminal-looking refresh and fails explicitly
      because omitted descendant state cannot be proven terminal.
- [x] Native backend ids use targeted strict-read-only SQLite queries; fallback
      artifact correlation is limited to 200 launch-window candidates and
      fails closed when truncated.
- [x] Claude fallback correlation covers both dated rollout storage and the
      execution working directory's legacy `projects/**/*.jsonl` storage
      without scanning unrelated project histories.
- [x] `session list` exposes parent/root relationships additively.
- [x] Codex and Claude activity probes classify fresh healthy and stale
      wedged-looking fixtures, degrade ambiguous/missing cases to `unknown`, and
      never hardcode user paths.
- [x] Codex and Claude health probes use strict read-only provider-state SQLite
      opens, fail closed without a compatibility read-write retry, and preserve
      provider database bytes, timestamps, and absent WAL/SHM sidecars.
- [x] CLI and GraphQL consume the same projection/activity service and parity
      tests prove equal results.
- [x] Existing command flags and GraphQL fields remain compatible.
- [x] Legacy snapshots and pre-migration stores remain readable without
      reader-side mutation.
- [x] README and CLI help match the tested behavior.
- [x] `swift build` and affected required test suites pass after the ordered
      backend-session-id persistence revision, excluding only the
      documented baseline failures: two `SourceDeletionReadinessTests`, the
      flaky `DaemonWorkflowNodePatchTests` event-source-restart test, and the
      occasionally flaky agent-VM interleaved-submit test.
- [x] Live smoke evidence records terminal follow exit, child-tree discovery,
      health output, and read-only behavior.
- [x] The Step 6 test-integrity rerun independently covers every progress
      digest field, production text/JSONL follow emission, one-shot/follow
      child trees, terminal-tree exit, quiet/evidence/threshold health output,
      first-snapshot provenance, held-writer read overlap, additive GraphQL
      schema field sets, and CLI/GraphQL production parity.
- [x] No unrelated files or scratch artifacts outside `tmp/` are modified.

## Progress Log Expectations

After each implementation session, append a dated entry containing:

- tasks completed and tasks still in progress;
- exact files changed and ownership of any pre-existing dirty files;
- exact verification commands, exit status, test counts, and relevant output;
- review findings addressed, including severity and originating workflow step;
- known baseline failures versus new regressions;
- limitations, residual risks, and the next dependency-unblocked task.

Update each task status and completion checkbox only when its stated evidence
exists. Do not mark the plan complete on partial suite success. If later review
returns a high or mid finding, record it here, reopen the owning task, implement
the fix, and add the regression command before returning for review.

## Progress Log

### 2026-07-23 — Step 4 Plan Creation

- Created this active plan from the accepted design extension.
- Preserved workflow mode, issue reference, empty external Codex-agent
  references, accepted review `comm-000009`, required verification, baseline
  exclusions, and residual risks.
- No implementation code was written and no user decision remains open.

### 2026-07-23 — Step 6 Implementation

- Completed T1-T9. Added the provider-neutral digest/rollup/activity service,
  legacy-safe provenance and backend-correlation fields, writer-owned child
  provenance, additive indexed SQLite migration, read-only rollup loading,
  Codex/Claude probes, CLI follow/tree/list/health surfaces, typed additive
  GraphQL contracts, shared production composition, focused tests, README, and
  CLI help. T10 remains in progress only for the all-five-suite gate and a
  fresh live parent/child smoke; the implementation itself is complete.
- Source files changed are limited to `README.md`, `Sources/RielaCore/`,
  `Sources/RielaCLI/`, `Sources/RielaGraphQL/`, `Sources/CodexAgent/`,
  `Sources/ClaudeCodeAgent/`, and their matching test targets. The pre-existing
  modified accepted design and untracked active plan remain workflow-owned.
- Addressed the accepted Step 3 mid findings by routing both CLI and scoped
  GraphQL parity through `SessionObservabilityComposition`, and by documenting
  follow, rollup, list provenance, and backend activity semantics.
- `swift build` passed. `swift test --filter RielaCoreTests` executed 458 tests
  with only the two documented `SourceDeletionReadinessTests` baseline
  failures. The focused final command
  `swift test --filter 'GraphQLContractsTests|SessionObservability|BackendActivityProbeTests|testLiveDispatchRunsCallee'`
  passed 29 tests with zero failures. A broader provider/GraphQL run executed
  142 tests and exposed two GraphQL schema-fixture drift assertions; both were
  fixed and `GraphQLContractsTests` then passed all 16 tests.
- `xcrun swiftlint --quiet` passed with only five unrelated baseline warnings;
  `git diff --check` and the README/help contract search passed.
- Live smoke created terminal `greeting-shell-session-617`; text and JSONL
  follow each emitted once and exited, health returned structured `unknown`
  evidence for a session with no backend, and a read-only include-children
  query succeeded against the concurrently written current workflow session.
  A fresh post-change parent/child live session was not started because it
  would invoke an external coding workflow; in-flight child discovery and
  first-snapshot provenance are instead covered by deterministic tests.
- Residual risks remain the accepted legacy-session boundary, child visibility
  only after its first snapshot, coarse/external artifact mtimes, and
  fail-closed ambiguity. The local command harness also keeps unrelated live
  workflow descendants attached to its process group, so some otherwise
  successful commands report wrapper timeouts after their success output.

### 2026-07-23 — Step 6 Rerun After Self-Review

- Reopened and completed T10 after addressing every Step 6 self-review mid
  finding from `comm-000014`.
- Restored session-list text compatibility by appending `parentSessionId` and
  `rootSessionId` after all legacy columns, with a regression assertion in
  `Tests/RielaCLITests/WorkflowCommandSessionDiscoveryTests.swift`.
- Bounded Codex and Claude fallback artifact correlation to the execution
  launch window (60 seconds before/after persisted execution creation), added
  unique/ambiguous/out-of-window fixtures for both providers, and preserved
  fail-closed `unknown`.
- Enriched Claude stream events with a native `backendSessionId` when
  `session_id` or `sessionId` is present at the event root or payload, and
  verified the existing backend-event writer receives it.
- Added deterministic cycle, pre-migration read-only/no-DDL, concurrent
  writer-reader, follow transition/cadence, invalid poll interval, and
  production probe-registry coverage.
- Focused regression command
  `swift test --skip-build --filter 'SessionObservability|BackendActivityProbeTests|testAgentAdaptersReportBackendEventsFromStreamJSONStdout|testSessionListTextAppendsProvenanceAfterLegacyColumns'`
  passed 22 tests.
- `swift build` passed. Full suite evidence: `swift test --skip-build --filter
  RielaCoreTests` executed 462 tests with only the two documented
  `SourceDeletionReadinessTests` failures; `swift test --skip-build --filter
  RielaCLITests` passed 618; `swift test --skip-build --filter
  RielaGraphQLTests` passed 72; `swift test --skip-build --filter
  CodexAgentTests` passed 42; and `swift test --skip-build --filter
  ClaudeCodeAgentTests` passed 30.
- Fresh deterministic live cross-workflow smoke used a temporary three-second
  callee fixture and `workflow-call-live-echo-session-1` in
  `tmp/session-observability-inflight/store`. A concurrent one-shot
  `session progress --include-children --output json` observed both parent and
  child as `running`. `.build/debug/riela session progress
  workflow-call-live-echo-session-1 --include-children --follow
  --poll-interval 0.1 --output jsonl` emitted 29 records from
  parent/child `running` through parent/child `completed`, then exited. Child
  `workflow-call-live-echo-callee-session-2` carried the expected parent/root
  provenance. `session list --output text` preserved legacy column order and
  appended both provenance columns; `session health --output json` returned
  structured `unknown` evidence because the command workflow has no backend
  execution.
- `xcrun swiftlint --quiet` reported only the five unrelated baseline
  warnings. Final diff/status checks remain the handoff gate; no commit or push
  was performed.

### 2026-07-23 — Step 6 Second Self-Review Reopen

- Reopened T3 and T10 for the two mid findings in `comm-000016`.
- Codex fresh-session publication must become ordered and complete before the
  adapter returns; Claude native-session parsing must be reachable from its
  actual production command stream while preserving normalized user output.
- Required regression evidence is an adapter-through-runner/store assertion
  for Codex fresh/resumed native session ids and Claude production-stream native
  session ids, followed by affected suites, build, lint, and diff checks.

### 2026-07-23 — Step 6 Second Self-Review Completion

- Completed T3 and T10. Codex fresh IDs now travel through the ordered,
  drained `LocalAgentCommandAdapter` backend-event bridge; resumed IDs remain
  explicitly awaited before process execution. Claude production execution now
  requests `stream-json`, normalizes the final `result` back to the prior user
  output contract, and publishes native IDs through the same ordered bridge.
- Added `Tests/AgentAdapterTests/BackendSessionIdPersistenceTests.swift` to run
  both production adapters through `DeterministicWorkflowRunner` and
  `InMemoryWorkflowRuntimeStore`. It proves completed Codex fresh/resumed
  executions both persist `codex-native-1`, completed Claude execution persists
  `claude-native-1`, Claude normalized output remains `done`, and command shape
  contains `--output-format stream-json`.
- `swift test --filter
  'testCodexRunnerPersistsFreshAndResumedBackendSessionIdsBeforeCompletion|testClaudeProductionStreamCommandPersistsNativeSessionIdAndNormalizesResult|testAgentAdaptersReportBackendEventsFromStreamJSONStdout|testClaudeCommandBuilderOwnsPrintModeArgvAndAttachmentPrompt'`
  passed 4 tests with zero failures.
- `swift test --skip-build --filter AgentAdapterTests` passed 134 tests with
  zero failures. `swift test --skip-build --filter
  'CodexAgentTests|ClaudeCodeAgentTests'` passed 72 tests with zero failures.
- `swift build` completed successfully. `xcrun swiftlint --quiet` introduced no
  warnings; the five documented unrelated baseline warnings remain.
  `git diff --check` passed. No commit or push was performed.

### 2026-07-23 — Step 6 Test-Integrity Revision Completion

- Reopened and completed the test evidence for T3, T5, T6, T7, T8, and T9 in
  response to `comm-000019`. No production behavior was weakened and no test,
  fixture, suite, or coverage threshold was deleted or skipped.
- Addressed `test-integrity-001` by asserting every digest field in RielaCore;
  adding one-shot parent/child text and JSON coverage; and exercising the
  production follow record writer in text mode across running-to-terminal
  parent/child transitions. The sleeper asserts that the first record is
  emitted before polling continues.
- Addressed `test-integrity-002` with terminal `quiet` fixtures for both Codex
  and Claude, including evidence kind/path, timestamps, ages, and active/stalled
  thresholds; CLI text/JSON health rendering; and GraphQL health parity.
- Addressed `test-integrity-003` with a gated cross-workflow adapter test that
  inspects the child's first live snapshot before callee completion, plus a
  SQLite test that holds a writer transaction open while the read-only rollup
  query completes.
- Addressed `test-integrity-004` with independent Codable/schema field-set
  assertions for all new observability types and production CLI-versus-scoped
  GraphQL progress/health parity against one persisted fixture. That test
  exposed missing typed parser cases for the already implemented
  `session-progress` and `session-health` scoped actions; both are now accepted
  in `Sources/RielaCLI/RielaClientFamilyArguments.swift`.
- Addressed low finding `test-integrity-005` by retaining system/result native
  session assertions and restoring Claude assistant-event forwarding coverage
  in `Tests/AgentAdapterTests/AgentAdapterAdditionalTests.swift`.
- Focused regression command covering observability, both probes, first-live
  child provenance, GraphQL contracts/parity, and adapter stream forwarding
  passed 46 tests. `swift test --skip-build --filter AgentAdapterTests` passed
  134 tests; `swift test --skip-build --filter CodexAgentTests` passed 43;
  `swift test --skip-build --filter ClaudeCodeAgentTests` passed 31;
  `swift test --skip-build --filter RielaCLITests` passed 622; and the final
  `swift test --skip-build --filter RielaGraphQLTests` passed 74.
- `swift test --skip-build --filter RielaCoreTests` executed 464 tests with
  only the two documented `SourceDeletionReadinessTests` baseline failures.
  `swift build` passed. SwiftLint passed with only the five unrelated baseline
  warnings after splitting the new schema assertion into a focused extension.
  `git diff --check` and final branch/status inspection passed. No commit or
  push was performed.

### 2026-07-23 — Step 6 Strict Read-Only Revision Completion

- Addressed mid finding `self-review-006` from `comm-000021`. Added
  `SQLiteOpenMode.strictReadOnly`, which performs only
  `SQLITE_OPEN_READONLY` plus the usability probe and never enters the existing
  compatibility fallback to `SQLITE_OPEN_READWRITE`.
- Routed every `SQLiteWorkflowRuntimePersistenceStore` read through strict
  mode. Added an opt-in strict path to `CLIWorkflowSessionStore` and
  `CLIWorkflowSessionResolution`; `SessionInspectionCommand` now uses it before
  progress, follow, or health constructs the runtime-store reader. Existing
  non-observability callers retain the compatibility read behavior.
- Added three forced idle-WAL/no-sidecar regressions in
  `Tests/RielaSQLiteTests/SQLiteDatabaseTests.swift`,
  `Tests/RielaCoreTests/SessionObservabilityTests.swift`, and
  `Tests/RielaCLITests/SessionObservabilityCommandTests.swift`. They prove the
  strict database open, rollup reader, and production CLI resolution fail
  closed without recreating WAL/SHM sidecars or changing the database
  modification timestamp. The focused command passed 3 tests; the combined
  observability/SQLite command passed 26.
- Full verification after the revision: `RielaSQLiteTests` passed 7,
  `RielaCLITests` passed 623, and `RielaGraphQLTests` passed 74.
  `RielaCoreTests` executed 465 tests with only the two documented
  `SourceDeletionReadinessTests` baseline failures. `swift build` passed and
  SwiftLint reported only the five unrelated baseline warnings.
- Addressed low finding `self-review-007` by replacing the stale
  remaining-check statement above. Final `git diff --check` and branch/status
  inspection passed after this progress entry; no commit or push was
  performed.

### 2026-07-23 — Step 7 Review Revision Completion

- Addressed all three mid findings from `comm-000025`.
- Health now selects a running execution for every nonterminal session and
  returns `unknown` when that execution has no backend. Completed backend
  fallback remains limited to terminal sessions. Added
  `testHealthDoesNotFallBackToCompletedBackendWhileNonBackendStepIsRunning`.
- Threaded the computed effective step budget through
  `WorkflowStepExecutionRecordInput`; the writer now replaces a resumed
  session's previous budget when its resumed execution starts. Extended
  `testResumeAllowsBudgetFailedSessionWithRaisedBudget` to prove a changed
  budget persists.
- Restored the compatibility `SQLiteOpenMode.readOnly` path for existing
  `SQLiteWorkflowRuntimePersistenceStore` reads. Added
  `loadStrictReadOnly(sessionId:)` for progress and health, retained strict
  rollup reads, and limited strict CLI session resolution to progress and
  health. Added store- and CLI-level idle-WAL regressions proving observability
  fails closed while existing status/snapshot reads remain available.
- The focused four-test regression command passed with zero failures.
  `RielaCLITests` passed 623 tests and `RielaGraphQLTests` passed 74 tests.
  `RielaCoreTests` completed 467 tests with only the two documented
  `SourceDeletionReadinessTests` failures; the explicit baseline exclusion run
  completed 458 tests with zero failures. Both RielaCore SwiftPM wrappers
  remained attached after their completed test summaries and were terminated
  by the command timeout, matching the previously documented local harness
  behavior.
- `swift build` passed. SwiftLint reported only the five unrelated baseline
  warnings. Final `git diff --check` and branch/status inspection passed after
  this progress-log update; no commit or push was performed.

### 2026-07-23 — Step 6 Pre-Execution Resume-Budget Revision

- Addressed the remaining mid finding from `comm-000027`. The runner now carries
  its enforced step budget into failure finalization, and
  `WorkflowSessionFailureInput` applies it through the existing writer-owned
  session update. A resumed run therefore cannot retain its old budget when
  input resolution or another pre-execution operation fails.
- Extended
  `testResumePreStepFailureOverwritesPreviousBudgetFailureMetadata` to prove
  both the cancelled failure snapshot and subsequent terminal resume retain
  the newly enforced budget.
- The focused two-test regression passed with zero failures. The post-change
  `RielaCoreTests` run excluding the two documented
  `SourceDeletionReadinessTests` executed 458 tests with zero failures.
- `swift build` emitted `Build complete!`; its local SwiftPM wrapper remained
  attached after completion and reached the command timeout. SwiftLint exited
  zero with only the five unrelated documented warnings.
- `git diff --check` passed, and branch/status output confirmed
  `feat/session-observability` with no commit or push. The combined status
  wrapper remained attached after emitting its complete output. No TypeScript,
  workflow-definition, package, dependency, commit, or push change was made.

### 2026-07-23 — Step 7 Live-Observation Revision Completion

- Reopened and completed T3, T5, T7, and T10 for all three mid findings in
  `comm-000031`.
- T3/T7: backend run events now participate in live persistence through a
  one-second coalescing policy. The first event and any newly resolved native
  backend session id persist immediately; repeated burst events are bounded.
  `WorkflowRunEvent` carries the native id so the CLI writer can make that
  decision without reading mutable runner state.
- T7: fresh, resume, and rerun commands now share the same event-driven
  persistence helper. The resume regression blocks a real command after the
  session becomes running, starts production follow against SQLite, then proves
  the emitted transition ends at completed.
- T5/T7: the shared service now returns a
  `SessionObservabilityObservation` containing both its source snapshot and
  projected view. One-shot progress and health render only that observation;
  an injected interleaving regression advances SQLite during the service read
  and proves the response remains internally coherent.
- Split session discovery into
  `Sources/RielaCLI/SessionDiscoveryCommand.swift` and live resume/rerun
  composition into `Sources/RielaCLI/SessionCommandLivePersistence.swift`;
  `SessionCommands.swift` remains below 1,000 lines. No TypeScript, dependency,
  workflow-definition, package, commit, or push change was made.
- Final focused verification executed 17 tests with zero failures:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowCommandLivePersistenceEventTests|testOneShotProgressUsesOneCoherentSnapshotWhenWriterAdvancesDuringRead|testSessionResumeCompletesBudgetFailedSessionWithRaisedMaxSteps|DeterministicWorkflowRunnerBackendEventTests'`.
  The SwiftPM wrapper remained attached after its successful summary and was
  terminated by the command timeout.
- Full affected-suite verification passed: RielaCoreTests excluding the two
  documented `SourceDeletionReadinessTests` executed 458 tests with zero
  failures; RielaCLITests executed 625 tests with zero failures; and
  RielaGraphQLTests executed 74 tests with zero failures. Local SwiftPM
  wrappers remained attached after emitting their completed summaries.
- `swift build` emitted `Build complete! (4.08s)`. SwiftLint emitted only the
  five documented unrelated baseline warnings after the new code was
  lint-clean. `git diff --check` passed. Branch inspection confirmed
  `feat/session-observability`; no commit or push was performed.

### 2026-07-23 — Step 7 Artifact-Correlation Revision Completion

- Reopened and completed T3, T6, and T10 for all three mid findings in
  `comm-000035`.
- T6: Codex and Claude probes now require a correlated rollout to be a regular
  file that can be opened read-only. They derive freshness from the file's
  current modification date and preserve a non-secret diagnostic path when a
  SQLite-index-only rollout is missing or invalid.
- T3: every backend execution now persists the same canonical absolute working
  directory used by adapter launch semantics. An omitted directory resolves to
  the process working directory, and a relative directory resolves against it.
  Fallback probe fixtures correlate a unique artifact without a native session
  id using that inherited value.
- New focused regression verification executed seven tests with zero failures;
  both complete backend-probe classes then executed 12 tests with zero
  failures. RielaCoreTests excluding the two documented
  `SourceDeletionReadinessTests` executed 459 tests with zero failures. The
  focused CLI/GraphQL observability parity run executed 14 tests with zero
  failures. The full ClaudeCodeAgentTests suite executed 33 tests with zero
  failures, and the separately completed CodexAgentTests suite executed 45
  tests with zero failures; local wrappers remained attached after their
  successful summaries.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
  completed successfully in 1.24 seconds. SwiftLint exited zero with only the
  five documented unrelated baseline warnings. No TypeScript, dependency,
  workflow-definition, package, commit, or push change was made.

### 2026-07-23 — Step 7 Adversarial Read-Only Revision Completion

- Reopened and completed T6 and T10 for the mid and low findings in
  `comm-000040`.
- Provider session-index APIs now retain compatibility read behavior by
  default, while Codex and Claude health probes explicitly select
  `SQLiteOpenMode.strictReadOnly`. A strict-open failure returns `unknown`
  without retrying read-write.
- New clean-WAL/no-sidecar regressions prove both provider health probes leave
  the SQLite database bytes and modification timestamp unchanged and do not
  recreate `-wal` or `-shm` sidecars. The three focused adversarial regressions
  passed with zero failures.
- Probe exceptions now produce the stable non-secret diagnostic
  `backend activity probe failed`; the throwing-probe regression proves a
  secret-bearing error description is not surfaced. README now qualifies that
  a missing artifact yields `unknown` only when no other sufficient correlated
  evidence exists.
- Full affected-suite verification passed: AgentRuntimeKitTests executed 43
  tests, CodexAgentTests 46, ClaudeCodeAgentTests 34, RielaCoreTests excluding
  the two documented `SourceDeletionReadinessTests` 460, RielaCLITests 625, and
  RielaGraphQLTests 74, all with zero failures. The CLI wrapper remained
  attached after its successful summary and reached the command timeout.
- `swift build` completed successfully. SwiftLint exited zero with only the
  five documented unrelated warnings, and `git diff --check` passed. No
  TypeScript, dependency, workflow-definition, package, commit, or push change
  was made.

### 2026-07-23 — Step 7 Adversarial Runtime Revision Completion

- Reopened and completed T7 and T10 for both mid findings in `comm-000045`.
- Claude stream-JSON commands now own exactly one mandatory `--verbose` flag
  across the production adapter and process command builders. User-supplied
  duplicates are removed without changing non-stream fork behavior. Production
  adapter, process-builder, and runner/store regressions assert the valid
  command shape.
- Added `SQLiteOpenMode.strictReadOnlyWithImmutableFallback` for session
  observers only. A checkpointed database with no `-wal` file opens through
  SQLite `mode=ro&immutable=1`; a live database with a WAL remains on strict
  `SQLITE_OPEN_READONLY`. Provider health probes retain fail-closed
  `strictReadOnly`, and compatibility readers retain their existing behavior.
- SQLite, RielaCore rollup, and production CLI regressions prove sidecar-free
  progress, health, and already-terminal follow succeed while database bytes
  and timestamps remain unchanged and WAL/SHM sidecars remain absent.
- Added the previously residual default-cadence regression, which omits
  `--poll-interval` and asserts the documented `2.0` second sleeper value.
- Focused adversarial regressions passed: 10 tests, zero failures. The affected
  `RielaSQLiteTests|AgentAdapterTests|ClaudeCodeAgentTests` selection passed 176
  tests, and the observability/probe selection passed 41 tests, all with zero
  failures.
- `swift build` and `git diff --check` passed. SwiftLint reported only the five
  documented unrelated baseline warnings; its wrapper remained attached after
  emitting the complete warning set.
- No TypeScript, dependency, workflow-definition, package, commit, or push
  change was made.

### 2026-07-23 — Step 7 Adversarial Bounded-Read Revision Completion

- Reopened and completed T4, T5, T6, T8, T9, and T10 for both mid findings in
  `comm-000050`.
- Rollup reads now use a deterministic 1,000-snapshot limit-plus-one query that
  always orders the requested session first. The shared view reports
  `rollupTruncated` and `rollupSnapshotLimit`; one-shot/follow text, JSON, and
  GraphQL expose the same additive truncation contract.
- Codex and Claude probes no longer call the full-history merged session index.
  Native ids use a targeted strict-read-only SQLite `WHERE id = ?` query.
  Fallback correlation queries only the execution working directory and launch
  window, inspects at most 200 date-scoped rollout candidates, and fails closed
  to `unknown` when the candidate cap is exceeded.
- Scale regressions cover bounded rollup decoding, explicit truncation,
  201-artifact fallback overflow, and targeted native-id lookup with 250
  unrelated SQLite records and 251 unrelated rollout files for each provider.
- Focused verification executed 63 tests with zero failures, including all
  observability, CLI, GraphQL contract, Codex-probe, and Claude-probe tests.
- `swift build` emitted `Build complete!`; its local wrapper remained attached
  until the command timeout. SwiftLint exited zero with only the five
  documented unrelated baseline warnings. Final `git diff --check` and branch
  inspection passed; no commit or push was performed.

### 2026-07-24 — Step 7 Claude Project-Artifact Revision Completion

- Reopened and completed T6 and T10 for the mid finding in `comm-000054`.
- Claude fallback correlation now checks the execution working directory's
  bounded legacy `projects/<encoded-cwd>/**/*.jsonl` storage in addition to
  dated rollouts. A persisted native session id uses direct project-artifact
  paths; the no-id path enumerates only that project directory and shares the
  existing 200-candidate fail-closed limit.
- Added
  `testFallbackCorrelationIncludesLegacyProjectArtifacts`. With no provider
  state database, it proves a fresh project artifact reports `active` with
  either stale stream evidence or no stream evidence, direct native-id lookup
  works, evidence identifies the artifact, and stale correlated evidence
  reports `stalled-suspect`.
  `testLegacyProjectFallbackCandidateLimitFailsClosed` proves the project
  fallback stops and returns `unknown` after the shared candidate cap.
- The fresh, post-build focused gate
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --skip-build --filter 'ClaudeCodeBackendActivityProbeTests|SessionObservabilityCommandTests|SessionObservabilityGraphQLTests'`
  executed 26 tests with zero failures. A complete
  `ClaudeCodeAgentTests` attempt remained attached without a summary and was
  terminated after the command timeout; the affected probe class itself
  executed all 11 tests successfully.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
  completed successfully in 1.33 seconds. SwiftLint emitted only the five
  documented unrelated baseline warnings.
  `git diff --check` passed. No commit or push was performed.

### 2026-07-24 — Step 7 Truncated-Terminal Revision Completion

- Reopened and completed T7 and T10 for the mid and low findings in
  `comm-000058`.
- Include-children follow now treats a truncated terminal-looking rollup as
  incomplete evidence: it emits the bounded refresh, returns a nonzero result,
  and reports that terminal state cannot be confirmed instead of claiming
  successful tree completion.
- Added
  `testFollowFailsInsteadOfClaimingTerminalWhenChildRollupIsTruncated`. Its
  fixture keeps the parent and visible child terminal while a running child is
  omitted from a limit-two page; the regression proves follow emits once,
  does not sleep, reports `rollupTruncated`, and fails explicitly.
- The focused regression passed, and the complete
  `SessionObservabilityCommandTests` class executed 13 tests with zero
  failures.
- The complete current `ClaudeCodeAgentTests` suite executed 38 tests with zero
  failures, closing the prior wrapper-without-summary verification gap.
- A post-revision full `RielaCLITests` attempt remained attached without a
  filtered summary and was terminated at the 120-second wrapper timeout. The
  complete affected `SessionObservabilityCommandTests` class passed all 13
  tests, and the earlier complete RielaCLITests gate remains 625 tests with zero
  failures.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
  emitted `Build complete! (1.22s)` before its local wrapper timeout. SwiftLint
  exited zero with only the five documented unrelated baseline warnings.
- README now documents the explicit nonzero result for a truncated
  terminal-looking follow refresh. Final diff/status checks passed; no commit
  or push was performed.

## Risks

- Legacy sessions cannot safely recover missing provenance and remain
  standalone.
- A child is undiscoverable until its first writer-owned `session_started`
  snapshot persists.
- Artifact timestamps may be coarse or externally modified; verdicts must show
  evidence and remain suspect/unknown rather than claim deadlock.
- Ambiguous backend correlation can create false liveness claims unless it
  fails closed to `unknown`.
- Reader-side SQLite feature detection can accidentally trigger DDL or file
  creation if it reuses writable setup paths.
- A parent may become terminal before a child; include-children follow must wait
  for all discovered descendants.
- Very small polling intervals increase read load; validation and indexed
  queries bound the cost.
- Production CLI and GraphQL composition can drift if separate registries are
  constructed.
- Future RielaServer runtime-session GraphQL execution must explicitly receive
  the shared registry; it is not part of this work package.
