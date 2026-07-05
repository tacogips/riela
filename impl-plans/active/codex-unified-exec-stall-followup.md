# Codex Unified-Exec Stall Follow-Up Implementation Plan

**Status**: Implemented
**Design Reference**: design-docs/specs/design-codex-unified-exec-stall-followup.md
**Created**: 2026-07-05
**Last Updated**: 2026-07-05

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

### Scope

**Included**: codex adapter default arguments; SQLite read-open
fallback; CLI session resolution fallback semantics; silence monitor
re-arming; session status staleness projection; tests for each.

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

## Dependencies

| Feature | Depends On | Status |
|---------|------------|--------|
| Default flip (module 1) | none — independent | Available |
| Scope-search resilience (module 3) | Read-open fallback (module 2) for meaningful error text | Available after module 2 |
| Status staleness (module 4b) | none — independent | Available |

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
- [ ] `task check` / existing test suites pass on macOS and Linux
      (SQLite fallback path uses no Darwin-only APIs)

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
