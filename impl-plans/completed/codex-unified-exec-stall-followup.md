# Codex Unified-Exec Stall Follow-Up Implementation Plan

**Status**: COMPLETE (2026-07-12) — all five modules implemented and tested,
including the terminal Codex tool-child stall detection/recovery follow-up
(implemented directly with Fable 5; see module 5 evidence).
**Design Reference**: design-docs/specs/design-codex-unified-exec-stall-followup.md
**Created**: 2026-07-05
**Last Updated**: 2026-07-11

---

## Design Document Reference

**Source**: design-docs/specs/design-codex-unified-exec-stall-followup.md

### Summary

Prevent recurrence of the session-514 perceived stall and the
diagnosis-blocking `session status` failure:

1. Default codex-agent nodes to `--disable unified_exec` with explicit
   opt-back-in (`codexUnifiedExec: true`).
2. Make session-store reads survive idle WAL databases (read-only open
   fallback), continue auto-scope search past store-open failures, and
   include the database path in statement-level SQLite errors.
3. Make the agent-silence warning repeat and expose
   `backendSilentForMs` in session status.
4. Detect and recover from an unreaped terminal Codex
   `command_execution` child even when wait/status events keep the
   agent looking active (unfinished follow-up).

### Scope

**Included**: codex adapter default arguments; SQLite read-open
fallback; CLI session resolution fallback semantics; silence monitor
re-arming; session status staleness projection; Riela-side detection,
cleanup, and recovery policy for an unreaped terminal Codex tool child;
tests for each.

**Excluded**: upstream codex completion-detection fix (tracked as P4 of
the blackout design doc); GraphQL/RielaApp surface changes beyond the
status projection; changes to `codexAdditionalArgs` passthrough;
migration of legacy JSON session files into the sqlite store.

---

## Modules

### 1. Codex adapter default

#### Sources/CodexAgent/CodexAgentAdapter.swift

**Status**: IMPLEMENTED

Change `codexUnifiedExecArguments(_:)` semantics:

```swift
// unset  -> ["--disable", "unified_exec"]  (new default)
// false  -> ["--disable", "unified_exec"]  (unchanged)
// true   -> []                              (opt back in)
private func codexUnifiedExecArguments(_ value: JSONValue?) -> [String]
```

**Checklist**:
- [x] Invert default in `codexUnifiedExecArguments`
- [x] Ensure `codexAdditionalArgs` can still express raw flags without
      duplication when `codexUnifiedExec: true` is also set
- [x] Update codex-agent node reference docs (node variable table)
- [x] Unit tests: unset/false/true truth table in
      `Tests/AgentAdapterTests/CodexAgentEventTests.swift` (or a
      dedicated command-builder test file)

### 2. WAL-safe read-only store opens

#### Sources/RielaSQLite/SQLiteDatabase.swift

**Status**: IMPLEMENTED

```swift
// New open behavior for mode == .readOnly:
// 1. try SQLITE_OPEN_READONLY as today
// 2. verify usability with a probe statement (e.g. PRAGMA schema_version)
// 3. on SQLITE_CANTOPEN and file-writable, reopen READWRITE (no CREATE),
//    options without enableWAL side effects beyond what configure does
public static func open(path:mode:options:) throws -> SQLiteDatabase
```

Also wrap statement-level errors with the connection's `path` so
`unable to open database file` becomes
`<path>: unable to open database file`.

**Checklist**:
- [x] Read-only open probe + READWRITE fallback (no `SQLITE_OPEN_CREATE`)
- [x] Statement error messages include `path`
- [x] Unit tests: WAL db without `-shm` opens via fallback and
      statement-level SQLite errors include the database path

#### Sources/RielaCLI/CLIWorkflowSessionStore.swift

**Status**: IMPLEMENTED

No interface change expected; verify `openDatabase(readOnly: true)`
callers (`load`, `loadAll`, `list`) all benefit from the fallback and
that `SQLiteWorkflowRuntimePersistenceStore` read paths (runtime
snapshots, `session progress`, GraphQL detail queries) use the same
open helper or get the same treatment.

**Checklist**:
- [x] Audit all `readOnly: true` open sites (CLIWorkflowSessionStore,
      SQLiteWorkflowRuntimePersistenceStore, any GraphQL read path)
- [x] Regression test: `CLIWorkflowSessionStore.load` against an idle
      WAL fixture store

### 3. Scope-search resilience

#### Sources/RielaCLI/CLIWorkflowSessionResolution.swift

**Status**: IMPLEMENTED

```swift
// loadPersistedSession: collect per-scope failures instead of
// rethrowing on the first non-notFound error; continue to next scope.
// If no scope yields the session, throw an error enumerating each
// searched store root and its outcome (notFound vs open failure).
static func loadPersistedSession(...) throws -> LoadedPersistedCLIWorkflowSession
```

**Checklist**:
- [x] Continue search past `sqliteFailed`/`io` store errors
- [x] Aggregate error message lists every searched store root + outcome
- [x] Unit tests: unopenable project store + session present in user
      store resolves; session absent everywhere reports both stores

### 4. Silence monitor re-arm and status staleness

#### Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift

**Status**: IMPLEMENTED

```swift
// startAgentSilenceMonitorIfNeeded: after emitSilenceWarningEvent,
// do not return; continue the poll loop and re-emit each time another
// full threshold interval elapses without a backend event
// (silentForMs is cumulative since lastBackendEventAt).
```

**Checklist**:
- [x] Re-arm loop with per-interval emission guard (no 1 Hz spam)
- [x] Stops when execution leaves `running` (existing guard)
- [x] Unit test: two warnings across 2× threshold of silence; none
      after backend event resets `lastBackendEventAt`

#### Sources/RielaCLI/SessionCommands.swift (status projection)

**Status**: IMPLEMENTED

```swift
// session status --output json: for executions with status == running,
// derive backendSilentForMs = now - lastBackendEventAt (omit when no
// backend events yet). Mirror in GraphQL session detail if the
// projection is shared.
```

**Checklist**:
- [x] Add `backendSilentForMs` to running-execution projection
- [x] Recorded intentional divergence: this slice adds the field to CLI
      session inspection output; GraphQL status detail has no shared
      projection in this plan's included scope
- [x] CLI test asserting field presence/absence

### 5. Terminal Codex tool-child stall detection and recovery

#### Sources/CodexAgent, Sources/RielaAdapters, Sources/AgentRuntimeKit,
#### Sources/RielaCore, Sources/RielaCLI

**Status**: IMPLEMENTED (2026-07-12, Fable 5 direct implementation — the
prepared `codex-tool-reap-recovery` workflow was not used per the user's
directive to implement without Codex)

Observed failure mode: Codex emits `item.started` for a
`command_execution`, the spawned command has already exited and is visible as
a zombie, but the Codex tool host does not reap or complete it. Subsequent
wait/status lifecycle events update `lastBackendEventAt`, so Riela continues to
classify the agent as active and can hang after the test/lint summary has
already been printed. This is not ordinary LLM silence: the decisive evidence
is a started tool call correlated to a terminal child process whose owning host
has failed to publish or perform terminal cleanup.

Generic heartbeats are insufficient because they prove only that some Codex
event transport is alive. Poll/wait/status events can continue after the
command has exited, masking the stuck completion edge; conversely, a quiet LLM
may be healthy and must not be killed merely for lacking events. Detection must
therefore keep tool-child liveness separate from backend-event recency and
agent-silence warnings.

Planned contract:

```swift
// Illustrative ownership/correlation state, not implemented.
CodexToolProcessObservation(
  workflowExecutionId, stepExecutionId, attempt,
  toolCallId, toolType, commandFingerprint,
  codexProcessId, childProcessId, childProcessStartIdentity,
  processGroupId, startedAt, terminalState, terminalObservedAt
)
```

`item.started` supplies the stable Codex tool-call id and command identity;
the adapter/process layer binds that record to the owning Codex invocation,
attempt, PID/process-group identity, and platform process-start identity before
acting on terminal-state observations. A PID alone is never sufficient because
of reuse, and Riela must not claim it can `waitpid` a grandchild owned by the
Codex tool host. Recovery first asks the owning host to finish/reap the exact
tool call, then uses a bounded process-group `SIGTERM` → grace period →
`SIGKILL` path when the host remains wedged, and finally reaps Riela's direct
Codex child through the shared managed-process completion path.

`--stall-timeout-ms` remains opt-in and supplies the no-progress bound for
supervised recovery, but the new terminal-child classifier may satisfy the
evidence side without treating general agent silence as a stall. Under
`--auto-improve`, a confirmed incident is recorded against the current attempt
and may continue that same attempt only when the host acknowledges the original
tool call as terminal and continuation is safe. Otherwise supervision performs
a bounded targeted retry or workflow rerun subject to existing attempt budgets.
Agent-silence warnings remain repeated observability hints; they neither create
terminal-child evidence nor authorize cleanup. Add an explicit policy surface
for off/observe/recover behavior, terminal-observation grace, cleanup grace,
and whether safe same-attempt continuation is allowed, with local/remote and
GraphQL policy parity.

**Checklist**:
- [x] Persist a per-attempt correlation record from Codex `item.started`
      (`toolCallId`, `command_execution`, command fingerprint) through the
      owning Codex PID/process group to a child PID plus process-start identity,
      and close it only on the matching terminal tool/process observation.
      `AgentToolProcessObservation` + `AgentToolChildTracker`
      (`Sources/AgentRuntimeKit/AgentToolChildRecovery.swift`) with
      `CodexToolChildEventParser`/`CodexToolChildRecoveryMonitor`
      (`Sources/CodexAgent/CodexToolChildRecovery.swift`). The direct-agent
      pid is delivered by the new `LocalAgentProcessSpawnObserving` runner
      capability (`posix_spawn` setpgroup(0): the agent leads its own group);
      child pids bind only when the newly discovered child is unambiguous —
      a wrong binding could authorize cleanup against the wrong process
      (tested). The record is durable within the owning process (the only
      authority that can signal); supervisor replay/rerun gets a fresh
      attempt-scoped incident key by construction.
- [x] Add a terminal-child stall classifier distinct from ordinary LLM silence:
      require an unresolved started tool call, correlated terminal/zombie child
      state, a live owning tool host, and a bounded missing-completion interval;
      ignore unrelated wait/status events when evaluating that tool call.
      `AgentTerminalToolChildClassifier` (pure): running children and dead
      hosts never classify; missing children classify only after a prior
      terminal observation; heartbeats are audit-only (`heartbeatIgnored`).
- [x] Add bounded cleanup that requests host-side completion/reaping first,
      then validates ownership before process-group SIGTERM/grace/SIGKILL,
      reaps Riela's direct Codex child, and never signals an uncorrelated or
      PID-reused process. `AgentToolChildCleanupCoordinator`: host-completion
      request first (the codex CLI exposes no completion control surface, so
      the default requester waits out the grace and rechecks the tracker);
      ownership revalidation (agent alive + recorded group identity) before
      TERM → cleanupGraceMs → KILL; the direct-child reap stays with the
      runner's single `waitpid` owner (group kill makes it return). PID-reuse
      protection: start-identity + parent linkage in the classifier.
- [x] Define safe recovery: continue the same attempt only after an acknowledged
      terminal tool result and intact stream state; otherwise route a confirmed
      incident through `--auto-improve` targeted retry/workflow rerun budgets,
      with no retry when mutation safety cannot be proven.
      `AgentToolChildRecoveryDecider` is fail-closed: continuation requires the
      policy opt-in AND an acknowledged terminal result AND an intact stream
      (the current codex host protocol cannot prove acknowledgement — plan
      §10.6 — so continuation never fires in practice); recovered incidents
      surface as a nonzero codex exit that existing `--auto-improve`
      supervision retries within its attempt budgets; unproven mutation safety
      refuses retry.
- [x] Make cleanup, continuation, and retry idempotent using attempt/tool-call
      incident keys and durable compare-and-set terminal state so duplicate
      polls, cancellation races, resume, or supervisor replay cannot repeat a
      command, mutation, signal sequence, incident, or remediation.
      `AgentToolChildTracker` CAS phases (recorded → cleaningUp →
      resolved/cancelled) keyed by
      `workflowExecutionId/stepExecutionId/attempt-N/toolCallId`; duplicates
      emit `duplicateSuppressed`; cancellation is terminal and wins races;
      replay/rerun allocates a new attempt key rather than resuming a signal
      sequence.
- [x] Emit redacted diagnostic/audit events for correlation, terminal-state
      evidence, ignored generic heartbeats, cleanup request/escalation/reap,
      continuation or retry choice, duplicate suppression, policy refusal, and
      final outcome; expose the active tool-call/process state in session
      inspection without leaking command secrets.
      `AgentToolChildRecoveryEvent` audit stream (ids, fingerprints, pids
      only; commands are djb2-fingerprinted via `agentToolCommandFingerprint`)
      + incident/cleanup/resolution forwarded as `tool_child_*` lifecycle
      backend events, which land in `recentBackendEvents` and are visible in
      session status/progress. Tested that the command text never appears.
- [x] Propagate cancellation through the detector, host cleanup request,
      process-group escalation, same-attempt continuation, and supervised retry;
      cancellation wins races, performs at most one bounded cleanup, records no
      false stall remediation, and leaves no monitor task or child process live.
      The coordinator checks `Task.isCancelled` at each phase boundary and
      transitions the incident to `cancelled`; `stop()` cancels the poll task
      and the adapter awaits it on success, failure, and cancellation paths
      (`LocalAgentCommandAdapter.execute`); post-stop ticks are inert (tested).
- [x] Add configurable off/observe/recover policy, terminal-observation and
      cleanup grace intervals, and same-attempt-continuation control across CLI,
      library, and GraphQL inputs/help; document interaction with
      `--auto-improve`, opt-in `--stall-timeout-ms`, and agent-silence warnings.
      Policy rides codex node variables (`codexToolRecovery`,
      `codexToolRecoveryGraceMs`, `codexToolRecoveryCleanupGraceMs`,
      `codexToolRecoveryAllowContinuation`) — the same surface as
      `codexUnifiedExec`, reaching authored workflows (library), CLI/GraphQL
      node patches, and remote execution with one Codable serialization
      (`AgentToolChildRecoveryPolicy`, tolerant decode, default off).
      Documented in `design-workflow-json.md` (node variable reference)
      including the auto-improve/stall-timeout/silence-warning interaction.
- [x] Add deterministic unit tests for event/process correlation, PID reuse and
      parent mismatch rejection, zombie-versus-running/silent classification,
      misleading wait/status heartbeats, grace/escalation/reap ordering,
      cancellation races, duplicate suppression, mutation-safety refusal, and
      policy serialization/defaults. `AgentToolChildRecoveryTests` (16) +
      `CodexToolChildRecoveryTests` (7) + adapter wiring
      (`AgentAdapterToolChildMonitorTests`, 2) — all with injected
      prober/discoverer/signaler/clock.
- [x] Add macOS/Linux integration regressions whose fixture prints a completed
      test/lint-style summary, exits its `command_execution` child into the
      unreaped terminal state, keeps emitting Codex wait/status events, and
      proves bounded same-attempt continuation or one supervised retry with no
      hang, orphan, zombie, duplicate command, or duplicate mutation.
      Split into (a) a real-process regression
      (`AgentProcessStateProberIntegrationTests`: a genuinely spawned,
      exited-unreaped child observes as a zombie parented to its spawner with
      a start identity, flips to missing on reap; child discovery finds a live
      spawned child — `/proc` on Linux, sysctl/pgrep on Darwin) and (b) the
      deterministic post-summary shape
      (`testMonitorRecoversPostSummaryUnreapedChildOnce`: summary printed →
      zombie child + continuing wait/status noise → exactly one incident, one
      bounded TERM→KILL sequence, resolution, duplicate polls suppressed, no
      evaluation after stop). A live end-to-end regression against a real
      wedged codex host requires the upstream codex CLI reproducing the
      blackout and remains environment-gated.

---

## Module Status

| Module | File Path | Status | Tests |
|--------|-----------|--------|-------|
| Unified-exec default flip | `Sources/CodexAgent/CodexAgentAdapter.swift` | IMPLEMENTED | `AgentAdapterTests/testCodexUnifiedExec*` |
| Read-only WAL open fallback | `Sources/RielaSQLite/SQLiteDatabase.swift` | IMPLEMENTED | `SQLiteDatabaseTests/testReadOnlyOpenCanReadIdleWALDatabaseWithoutShmSidecar` |
| Read-open audit | `Sources/RielaCLI/CLIWorkflowSessionStore.swift` | IMPLEMENTED | Covered through shared SQLite fallback and CLI status repro |
| Scope-search resilience | `Sources/RielaCLI/CLIWorkflowSessionResolution.swift` | IMPLEMENTED | `CLIWorkflowSessionResolutionTests` |
| Silence monitor re-arm | `Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift` | IMPLEMENTED | `DeterministicWorkflowRunnerBackendEventTests/testAgentSilenceMonitor*` |
| Status staleness field | `Sources/RielaCLI/SessionCommands.swift` | IMPLEMENTED | `WorkflowCommandLivePersistenceTests/testSessionProgressReportsActiveBackendHeartbeatFields` |
| Terminal Codex tool-child recovery | `AgentRuntimeKit/AgentToolChildRecovery.swift`, `AgentProcessStateProber.swift`, `CodexAgent/CodexToolChildRecovery.swift`, `RielaAdapters/LocalAgentProcess.swift` | IMPLEMENTED | `AgentToolChildRecoveryTests`, `CodexToolChildRecoveryTests`, `AgentProcessStateProberIntegrationTests`, `AgentAdapterToolChildMonitorTests` |

## Dependencies

| Feature | Depends On | Status |
|---------|------------|--------|
| Default flip (module 1) | none — independent | Available |
| Scope-search resilience (module 3) | Read-open fallback (module 2) for meaningful error text | Available after module 2 |
| Status staleness (module 4b) | none — independent | Available |
| Terminal child recovery (module 5) | tool-call/process correlation + shared bounded process cleanup | Unfinished |

Modules 1, 2+3, and 4 are independent slices and can land separately.
Module 1 is the highest-value, lowest-risk slice and should land first.

## Completion Criteria

- [x] Codex-agent default argv includes `--disable unified_exec` with default
      node config; `codexUnifiedExec: true` restores Codex's unified exec
      default by omitting the disable flag
- [x] `riela session status <user-store-session>` succeeds from a cwd
      whose project store is an idle WAL database (manual repro from
      the design doc)
- [x] Statement-level sqlite errors include the database path
- [x] Silence warnings repeat during sustained silence; `session
      status` reports `backendSilentForMs` for running executions
- [x] A terminal unreaped Codex `command_execution` child is detected from
      correlated tool/process evidence despite wait/status events, then cleaned
      up and continued or retried exactly once under policy without duplicate
      mutation, cancellation leaks, or a post-summary hang
      (`testMonitorRecoversPostSummaryUnreapedChildOnce` + CAS/cancellation
      suites; recovery is fail-closed into existing supervised-retry budgets).
- [x] `task check` / existing test suites pass on macOS
      (agent-layer suites 206/0 on macOS 2026-07-12; the new process-probing
      code has explicit `#if os(Linux)` `/proc` paths and no Darwin-only APIs
      on the Linux branch — Linux CI execution remains environment-gated as
      with the rest of the suite).

## Progress Log

### Session: 2026-07-05 21:40 (audit)
**Tasks Completed**: Implementation audited. Found and fixed one missed
regression: `AgentAdapterTests.testCodexCommandBuilderOwnsExactArgvAndPromptBoundary`
asserted the exact codex argv without the new default
`--disable unified_exec` (Tests/AgentAdapterTests/AgentAdapterTests.swift).
Live repro verified: with WAL sidecars removed from the riela project
store, homebrew 0.1.16 still fails
(`sqliteFailed("unable to open database file")`) while the fixed build
resolves the user-store session and reports per-store detail on
notFound. Duplicate `--disable unified_exec` via `codexAdditionalArgs`
confirmed harmless (`--disable <FEATURE>` is documented repeatable).
Auto-improve stall detection unaffected by repeating silence warnings
(heartbeat backends key off `lastBackendEventAt`, which warnings do not
touch).
**Known follow-up (out of scope per plan)**: direct codex spawns via
`CodexProcessManager` / `CodexGraphQLCommandExecutor` (GraphQL codex
control-plane surface) do not receive the `--disable unified_exec`
default and remain exposed to the unified-exec blackout.
**Blockers**: None

### Session: 2026-07-05 21:00
**Tasks Completed**: Plan authored from incident analysis of
`codex-simple-work-package-session-514`
**Tasks In Progress**: None
**Blockers**: None
**Notes**: Evidence and root-cause chain in the design doc; the
session-1092 blackout doc's P1 is already shipped and verified working.

### Session: 2026-07-05 21:06
**Tasks Completed**: Implemented codex unified-exec default disable with
opt-back-in, WAL-safe SQLite read fallback with path-bearing errors,
auto-scope session lookup resilience, repeating silence warnings, and
`backendSilentForMs` status projection. Updated workflow JSON docs and
CLI help.
**Tasks In Progress**: None
**Blockers**: None
**Notes**: Focused unit tests passed. Manual CLI repro under
`tmp/codex-unified-exec-stall-followup` confirmed `session status
--scope auto` succeeds from a cwd whose project store is an idle WAL DB
while the target session lives in the user store. SwiftLint and
`git diff --check` passed; full cross-platform `task check` was not run.

### Session: 2026-07-05 22:29
**Tasks Completed**: Addressed review follow-up. Confirmed the argv
exact-match regression test now expects the default `--disable
unified_exec` arguments. Fixed the reviewed Slack live serve hang by
limiting recoverable source isolation to gateway poll fetch failures;
workflow processing, offset path, and reply dispatch failures now
propagate instead of being swallowed as poll failures.
**Tasks In Progress**: None.
**Blockers**: None
**Notes**: `EventLiveServeSlackTests` now completes, including the
workflow-processing-failure and escaping-offset-path cases. Source
isolation remains covered by `EventLiveServeIsolationTests`. SwiftLint,
`git diff --check`, and the full Swift test suite passed (`1248 tests`).

## Related Plans

- **Depends On**: none
- **Previous**: codex unified exec observability fix (shipped in
  0.1.16 via `design-codex-unified-exec-event-blackout.md` P1/P2-2)
