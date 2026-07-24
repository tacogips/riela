# Workflow Progress Observability

## Summary

`codex-recent-change-quality-loop-session-336` returned
`maxStepsExceeded(12)` after twelve deterministic step executions. The
underlying workflow was still cycling through review, exit-gate, handoff, and
post-handoff because a mid-severity finding stayed open. The command was run
with `--output json`, so the operator saw no session id, current step, or
step progress until the final failure JSON appeared.

This revision replaces the first draft after a source-level review. The main
corrections relative to the first draft:

- JSONL already emits the session id in its first event
  (`session_started`), so "emit session id early" is largely done; the
  remaining gap is the session store path and scope context, plus the legacy
  `--output json` mode.
- The `running`-after-failure inconsistency is not specific to
  `maxStepsExceeded`. No in-runner failure path except cancellation emits a
  terminal event, and CLI persistence is event-driven, so adapter failures,
  node timeouts, and policy blocks can also leave the persisted record
  non-terminal. The fix must generalize.
- `maxLoopIterations` is not a loop-iteration counter. It is additive slack
  on a single global step budget, which is why `maxLoopIterations: 6`
  allowed only two complete fix cycles for this workflow.
- Making the session terminal on `maxStepsExceeded` silently removes an
  accidental recovery path: today `session resume` of the stuck `running`
  session restarts with a fresh step budget. The design must preserve that
  recoverability explicitly.

This document is a review request for making long workflow progress
observable early, terminal failures inspectable, and step-budget failures
actionable.

## Incident Evidence

Run:

```bash
.build/arm64-apple-macosx/debug/riela workflow run \
  codex-recent-change-quality-loop \
  --variables '{"hours":1,"targetPaths":["Sources/RielaApp/DaemonWorkflowGraphPaneView.swift","Tests/RielaAppSupportTests/RielaAppSettingsSectionLayoutTests.swift"],"instruction":"self review and improve"}' \
  --working-dir <workspace>/riela \
  --output json
```

Final command result:

```json
{
  "error": "maxStepsExceeded(12)",
  "exitCode": 1,
  "persistedSession": true,
  "sessionId": "codex-recent-change-quality-loop-session-336",
  "sessionStore": "<home>/.riela/sessions",
  "status": "failed",
  "target": "codex-recent-change-quality-loop"
}
```

Persisted session progress after the command returned:

```json
{
  "sessionId": "codex-recent-change-quality-loop-session-336",
  "workflowName": "codex-recent-change-quality-loop",
  "status": "running",
  "currentStepId": "step4-post-handoff",
  "executionCount": 12,
  "reviewFindingCount": 1
}
```

Observed step sequence:

| Execution | Step | Result |
|---:|---|---|
| 1 | `riela-manager` | completed |
| 2 | `step1-review` | completed, `needs_fix: true` |
| 3 | `step2-exit-gate` | completed, `decision: delegate` |
| 4 | `step3-handoff` | completed |
| 5 | `step4-post-handoff` | completed |
| 6 | `step1-review` | completed, `needs_fix: true` |
| 7 | `step2-exit-gate` | completed, `decision: delegate` |
| 8 | `step3-handoff` | completed |
| 9 | `step4-post-handoff` | completed |
| 10 | `step1-review` | completed, `needs_fix: true` |
| 11 | `step2-exit-gate` | completed, `decision: delegate` |
| 12 | `step3-handoff` | completed |

The next logical step would have been `step4-post-handoff`, but the runner
hit the twelve-step budget first.

### Budget arithmetic for this workflow

The workflow has six steps (`riela-manager`, `step1-review`,
`step2-exit-gate`, `step3-handoff`, `step4-post-handoff`,
`workflow-output`) and `defaults.maxLoopIterations: 6`. The effective budget
is `steps.count + maxLoopIterations = 12`
(`Sources/RielaCore/DeterministicWorkflowRunner.swift:242`).

One delegation cycle consumes four steps (review, exit-gate, handoff,
post-handoff). A clean exit after N delegation cycles costs
`1 (manager) + 4N (cycles) + 3 (final review, exit-gate, workflow-output)`
steps. Budget 12 therefore allows at most **two** complete fix cycles
(`1 + 8 + 3 = 12`); a third cycle is guaranteed to exhaust the budget, which
is exactly what happened. Supporting the six cycles that
`maxLoopIterations: 6` suggests would require a budget of
`1 + 24 + 3 = 28`.

## Code-Verified Findings

All of the following were verified against the current source.

- **F1 — budget check and default.** The runner throws at
  `DeterministicWorkflowRunner.swift:246-247` at the top of the step loop,
  before the next step executes or records anything. The default budget is
  `maxSteps ?? max(1, workflow.steps.count + maxLoopIterations)` (line 242).
  `--max-steps` exists on `workflow run`
  (`Sources/RielaCLI/ParsedWorkflowOptions.swift:160-162`) with no default
  and no help-text explanation of the computed fallback.
- **F2 — one global counter.** `visitedSteps` is the only budget counter.
  Per-step revisit counts are already tracked in `executionCounts`
  (`DeterministicWorkflowRunner.swift:240,255-256`) but are not used for any
  budget or diagnostic.
- **F3 — failure paths emit no terminal event.** Runner events are emitted
  only at: session start (line 235), step completion (lines 265, 288),
  successful session completion (line 310), resume-terminal short-circuit
  (line 187), and the cancellation finalizer
  (`DeterministicWorkflowRunner+Cancellation.swift:25`). The catch block at
  lines 312-317 handles only `CancellationError`. `publishFailureAndThrow`
  (`DeterministicWorkflowRunner+FailurePublication.swift`) records the failed
  execution in the runtime store and rethrows without emitting any event.
- **F4 — CLI persistence is event-driven.** `workflow run` persists live
  snapshots only from the event handler
  (`Sources/RielaCLI/WorkflowRunCommand.swift:95-113`), triggered by
  `sessionStarted`, `stepStarted`, `silenceWarning`, `stepCompleted`, and
  `sessionCompleted` (`WorkflowRunLivePersistence.swift:138-145`). The error
  path (`renderRunFailure`, `WorkflowRunCommand.swift:614-638`) only reads
  the last persisted snapshot; it never persists. Consequence: for
  `maxStepsExceeded` the last snapshot has `status: running` and
  `currentStepId` pointing at the next intended step; for adapter failures,
  timeouts, and policy blocks the in-memory session is `failed`
  (`RuntimeStore.swift:525-527`) but the last **persisted** snapshot is the
  `stepStarted` one, still `running`. The incident is one instance of a
  general staleness bug.
- **F5 — session model has no failure metadata.** `WorkflowSession`
  (`Sources/RielaCore/RuntimeSession.swift:161-242`) has no `failureReason`,
  `failureKind`, or `failedAt`. `markSessionFailed`
  (`RuntimeStore.swift:550-570`) attaches the reason only to executions that
  are currently `running`; when `maxStepsExceeded` fires between steps there
  is no running execution, so the reason would be recorded nowhere.
- **F6 — resume semantics.** Resume short-circuits when the stored status is
  `completed` or `failed` (`DeterministicWorkflowRunner.swift:178-189`). A
  `running` session resumes from `currentStepId` with a **fresh**
  `visitedSteps` budget. So today, resuming session-336 would actually grant
  twelve more steps — accidental but useful recoverability that a naive
  "persist failed" fix would remove. `session resume` has no `--max-steps`
  flag (`Sources/RielaCLI/SessionCommands.swift:39-65`).
- **F7 — JSONL already leads with the session id.** The first JSONL event is
  `session_started` carrying `workflowId`, `sessionId`, `status`,
  `currentStepId` (`Sources/RielaCore/WorkflowRunEvent.swift`,
  `DeterministicWorkflowRunner.swift:235`). What is missing is the session
  store path and scope; those appear only in the failure result
  (`WorkflowRunFailureResult.sessionStore`). `--output json` is final-only
  by design and already documented as legacy.
- **F8 — discovery is cheap to add.** The CLI session index is SQLite with
  columns `session_id, workflow_name, workflow_id, status, record_json,
  updated_at` and an index on `(updated_at DESC, session_id)`
  (`Sources/RielaCLI/CLIWorkflowSessionStore.swift:235-251`). Only
  `loadAll()` exists (line 184), decoding every record. GraphQL exposes only
  `workflowSession(workflowId, sessionId)`
  (`Sources/RielaGraphQL/GraphQLContracts.swift`); there is no list/latest
  query. No `session list`, `latest`, or `watch` subcommand exists
  (`Sources/RielaCLI/RielaCommand.swift:51-61`).
- **F9 — `workflow usage` exists.** It is a synonym for `workflow inspect`
  (`RielaCommand.swift:482-483`) and shows `maxLoopIterations` but not the
  computed effective step budget.
- **F10 — test gap.** `testMaxLoopIterationsBoundsDeterministicRun`
  (`Tests/RielaCoreTests/DeterministicWorkflowRunnerTests.swift:546-561`)
  asserts only that the error is thrown; it does not assert the resulting
  session state or that a terminal event was emitted.

## Root Causes

### RC1 — Budget semantics do not match loop intent

`maxLoopIterations` reads like "number of loop iterations" but acts as
additive slack on a global step budget (F1, F2). For a four-step cycle, the
packaged default allows two fix cycles, not six. Neither `workflow usage`
nor the failure message explains the effective budget or how to raise it.

### RC2 — Failure termination is invisible to the persisted store

The runner's only failure finalizer is the cancellation path (F3). Every
other thrown error ends the run without a terminal event, and the CLI
persists only on events (F4). The persisted record therefore diverges from
the CLI result: `status: failed` on stdout, `status: running` in the store.
`currentStepId` then reads as "actively executing" when it actually means
"next step that never ran".

### RC3 — Session discovery requires prior knowledge of the session id

`session status/progress` work only with a session id. There is no
list/latest surface in CLI or GraphQL, even though the SQLite index already
has the columns needed to answer "latest session for workflow X" cheaply
(F8). With `--output json` (final-only), a driver that lost the process has
no way to find the session.

### RC4 — Long-run guidance still allows final-only JSON

JSONL is the default and leads with the session id (F7), but the incident
run explicitly passed `--output json`. Skills and package docs must steer
long runs to JSONL, and JSONL should also carry the session store path and
scope so a second terminal can immediately run `session progress`.

## Decisions (answers to the first draft's review questions)

- **JSONL is the only supported machine-readable mode for long runs.**
  `--output json` stays final-only and legacy. **Rejected:**
  `--print-session-id` and `--status-file` — they add new output contracts
  to a mode we are steering people away from, and `session latest` (P0-3)
  plus the JSONL run-context record (P1-6) close the same gap.
- **`currentStepId` keeps "next intended step" semantics.** Disambiguation
  comes from the terminal `failed` status plus a derived
  `lastCompletedStepId` in projections, not from changing the stored field's
  meaning.
- **`maxStepsExceeded` stays recoverable, now explicitly.** After P0-1 the
  session is terminal `failed`, which would block resume (F6). Resume gains
  a narrow exception: sessions whose `failureKind == maxStepsExceeded` may
  be resumed, with an optional `--max-steps` override (P1-5). Other failed
  kinds keep the current terminal short-circuit; `session rerun` remains the
  recovery path for those.
- **No per-package `recommendedMaxSteps` knob.** Prefer fixing the semantics
  and surfacing the computed budget (P1-4). Short term, the
  `codex-recent-change-quality-loop` package should raise
  `maxLoopIterations` to 22 (effective budget 28 = six cycles) or document
  `--max-steps 28` in its usage text.

## Acceptance Traceability

The implementation review for this design is complete only when these Step 1
signals are all represented by code, tests, or an explicit limitation:

| Signal | Design owner |
|---|---|
| Terminal in-runner failures persist as failed sessions and emit terminal `session_completed` events. | P0-1 |
| `failureKind` metadata is stored and surfaced in progress/list/latest/run output where applicable. | P0-1, P0-2, P0-3 |
| `stepBudgetDiagnostic` includes dominant-cycle evidence and projected per-step cap classification. | P1-4 |
| JSONL workflow run output includes `run_context` with session discovery context. | P1-6 |
| Session list/latest discovery works for persisted sessions, including failed `maxStepsExceeded` sessions. | P0-3 |
| Session resume supports `maxStepsExceeded` recovery while preserving terminal short-circuit for other failed kinds. | P1-5 |
| `maxStepsExceeded` resume preserves the persisted `runtimeVariables` unless the caller explicitly overrides variables through supported resume inputs. | P1-5 |
| `workflow inspect`/`usage` surfaces `defaultMaxSteps`. | P1-4 |
| GraphQL contracts expose CLI/runtime-parity session inspection and discovery fields for failure metadata, diagnostics, and compact rows. | P0-2, P0-3 |
| Installed `riela-workflow-run` and `riela-troubleshooting` guidance steers long runs to JSONL and unknown-id triage to `session latest`. | P1-6 |
| `examples/recent-change-quality-loop/workflow.json` yields `defaultMaxSteps: 28`; with six workflow steps this means `maxLoopIterations: 22` under the current additive budget formula. | P1-4, P1-6 |
| Relevant CLI/core/GraphQL tests pass. | Implementation plan phases 2-5 |
| Swift lint and build verification are run or limitations are explicitly reported. | Validation |

## Agent Reference Boundaries

The local files listed by the intake are behavioral and structural references:
`Sources/RielaCore/DeterministicWorkflowRunner.swift`,
`Sources/RielaCLI/SessionCommands.swift`,
`Sources/RielaCLI/CLIWorkflowSessionStore.swift`,
`Sources/RielaCLI/WorkflowRunCommand.swift`, and
`Tests/RielaCLITests/WorkflowCommandSessionDiscoveryTests.swift`.
They are not a license to copy behavior blindly across agents.

Riela workflow progress observability is owned by the workflow runtime,
session store, CLI projections, and GraphQL contracts. Codex-agent and
Cursor-agent process details remain isolated behind their adapter modules.
This design intentionally does not add Cursor-specific session discovery or
resume semantics to the workflow core. Cursor CLI behavior may inspire row
shape, GraphQL parity, and operational vocabulary, but workflow persistence
continues to use `WorkflowSession`, `CLIWorkflowSessionStore`, and workflow
failure kinds as the canonical model.

## Proposed Fixes

### P0-1 — Persist terminal failure for all in-runner failure paths

Generalize the failure finalizer instead of special-casing
`maxStepsExceeded`:

1. Add optional session-level failure metadata to `WorkflowSession`:
   `failureReason: String?`, `failureKind: WorkflowSessionFailureKind?`
   (`maxStepsExceeded | cancelled | adapterFailure | policyBlocked |
   nodeTimeout | internal`), `failedAt: Date?`. Optional +
   `decodeIfPresent` keeps old persisted records decodable. Extend
   `WorkflowSessionFailureInput` and `markSessionFailed`
   (`RuntimeStore.swift:550`) to set them; do not overwrite execution-level
   failure reasons already recorded by `publishFailureAndThrow`.
2. At the budget throw site (`DeterministicWorkflowRunner.swift:246`), build
   a step-budget diagnostic before throwing — `executionCounts`, open
   review-finding count, and the unscheduled `currentStepId` are all in
   scope there (see P1-4 for the payload).
3. In the runner's catch block (lines 312-317), for **any** error: if the
   session exists and is not terminal, call `markSessionFailed` with the
   mapped `failureKind`, then emit `sessionCompleted` (failed, exitCode 1)
   exactly as the cancellation finalizer does today. Cancellation keeps its
   current reason string and maps to `failureKind: cancelled` until the
   sibling cancellation design introduces a first-class `cancelled` status.
   Because `sessionCompleted` triggers CLI live persistence (F4), the store
   converges without CLI changes.

Acceptance criteria:

- After a max-step failure, `session progress` reports `failed` with
  `failureKind: maxStepsExceeded`, the budget, `lastCompletedStepId`
  (derived), and the step that would have run next.
- After an adapter failure / timeout / policy block, the **persisted**
  session is `failed` (regression test that reads the store, not the
  in-memory session).
- JSONL streams end with a `session_completed` event on all failure paths.
- Cancellation behavior is unchanged.
- `testMaxLoopIterationsBoundsDeterministicRun` extended to assert persisted
  state and event emission (F10).

### P0-2 — Surface failure metadata in projections

- `SessionInspectionCommandResult`
  (`Sources/RielaCLI/SessionCommands.swift:90-149`): add `failureReason`,
  `failureKind`, `lastCompletedStepId`, and the budget fields from the
  diagnostic.
- GraphQL `WorkflowSession` type: additive fields, mirrored through
  `GraphQLContractProjector` and `riela graphql session` parity
  (`Sources/RielaCLI/ScopedParityCommands.swift:131-165`).
- `WorkflowRunFailureResult` already carries `sessionId`/`sessionStore`;
  add `failureKind` and the diagnostic summary so the final JSON alone
  answers "stuck or budget-limited".

### P0-3 — Add session discovery commands

```bash
riela session list [--workflow <name>] [--status <status>] [--limit <n>] [--scope ...] [--output ...]
riela session latest --workflow <name> [--scope ...] [--output ...]
```

- Implement as a filtered query on `cli_workflow_sessions` — `WHERE
  workflow_name = ? AND status = ? ORDER BY updated_at DESC LIMIT ?`. The
  columns already exist (F8); add `CREATE INDEX IF NOT EXISTS` on
  `(workflow_name, updated_at DESC)` during store open (write path only).
  Decode `record_json` only for the selected rows. Default `--limit 10`.
- Row shape: `sessionId, workflowName, status, failureKind, currentStepId,
  executionCount, updatedAt, sessionStore`.
- `latest` is `list --limit 1` with a single-object payload.
- v1 resolves one store via the existing `--scope`/`--session-store`
  resolution used by other session commands; a cross-scope merged view is
  out of scope.
- GraphQL parity: add `workflowSessions(workflowName, status, limit)`
  returning the same compact rows, so remote drivers get the same
  discovery surface.

Acceptance criteria:

- `riela session latest --workflow codex-recent-change-quality-loop` returns
  the incident session without prior knowledge of its id.
- Listing does not decode unselected records (bounded cost on stores with
  hundreds of sessions).

### P1-4 — Step-budget diagnostics and semantics

Attach a diagnostic to the budget failure (persisted with the session and
included in `WorkflowRunFailureResult`):

- `stepBudget`, `executionCount`, `maxLoopIterations`, and whether the
  budget came from `--max-steps` or the computed default;
- per-step revisit counts (from `executionCounts`) and the dominant cycle
  when detectable. The persisted shape should be structured, not only a
  display string: `dominantCycleStepIds` plus
  `dominantCycleRepeatCount`, e.g. `step1-review -> step2-exit-gate ->
  step3-handoff -> step4-post-handoff (x3)`;
- projected per-step cap classification fields:
  `perStepRevisitCap` and `projectedCapExceededStepIds`. These indicate
  where a future per-step interpretation of `maxLoopIterations` would have
  fired, without changing enforcement in this release;
- open review-finding count;
- the unscheduled next step;
- a suggested remediation: `session resume <id> --max-steps <n>` with `n`
  sized from the observed cycle length.

Semantics (alternative considered): enforce `maxLoopIterations` as a
per-step revisit cap — fail with `loopIterationsExceeded(stepId)` when any
step's `executionIndex > maxLoopIterations + 1`. This makes the field mean
what it says and localizes the diagnosis for free. It also changes failure
behavior for existing workflows that rely on the additive formula, so:
ship it first as **classification only** inside the diagnostic ("step
`step1-review` executed 3 times; per-step cap would have fired here"), and
revisit enforcement as a follow-up once packages have adjusted.

Additionally, `workflow usage`/`inspect` output gains a computed
`defaultMaxSteps` field so operators can see the effective budget before
running.

### P1-5 — Resume with a budget override

- Allow `session resume` for sessions with `failureKind ==
  maxStepsExceeded` (runner-side relaxation of the terminal check at
  `DeterministicWorkflowRunner.swift:178`, gated on the kind).
- Add `--max-steps <n>` to `SessionResumeOptions` and plumb it into the
  resume request. Without it, resume uses the computed default (which is
  what accidental resume grants today, F6).
- Preserve the persisted session `runtimeVariables` on resume so recovery
  continues the same workflow input and source context; only explicit
  supported resume inputs may replace them.
- All other failed kinds keep the terminal short-circuit; `session rerun
  <id> <step-id>` remains their documented recovery path.

### P1-6 — JSONL run context and guidance

- Immediately after forwarding `session_started`, the CLI event handler
  appends a CLI-level `run_context` JSONL record: `{type: "run_context",
  sessionId, workflowName, sessionStore, scope, artifactRoot?}`. The runner
  does not know the store root, so this stays CLI-side
  (`WorkflowRunCommand.swift:95-113`); no core event change.
- Skills: `riela-workflow-run` and `riela-troubleshooting` guidance should
  match what `riela-package` already says — long runs use `--output jsonl`;
  `--output json` is final-only; start triage with `session progress`,
  escalate to `session status`; once P0-3 lands, start with `session
  latest --workflow ...` when the id is unknown. For this repository, the
  design is satisfied by updating the installed skill guidance at
  `<codex-home>/skills/riela-workflow-run/SKILL.md` and
  `<codex-home>/skills/riela-troubleshooting/SKILL.md`; package-local
  copies remain a follow-up only if a future packaging step requires them.

### P2-7 — Watch/attach: defer to the cancellation/orphan design

`design-cancellation-and-orphan-session-resilience.md` (P5) already designs
`workflow run --detach` plus `session attach`/`session wait`. This document
does not define a competing `session watch`. Requirements contributed from
this incident to that design:

- attach/watch must reuse the compact `session progress` projection, not
  full `session status`;
- store polling at step granularity is sufficient — live persistence writes
  on step boundaries and silence warnings, not on backend deltas (F4);
- terminal output must include the P0-1 failure metadata.

Cleanup of pre-existing stale `running` sessions (including session-336) is
likewise owned by that design's `session reconcile` (P4); this design adds
no separate repair command.

## Implementation Plan

Phases 1-3 are sequential; phase 4 is independent and can proceed in
parallel with 2-3.

1. **Failure metadata schema** — `RuntimeSession.swift` (session fields +
   Codable), `RuntimeStore.swift` (`WorkflowSessionFailureInput`,
   `markSessionFailed`). Tests: decode of legacy record JSON without the new
   fields; `markSessionFailed` with and without a running execution.
2. **Runner terminal finalization + diagnostics** —
   `DeterministicWorkflowRunner.swift` (budget throw site, generalized
   catch), `+Cancellation.swift` (fold into the generalized finalizer),
   event payload for failed `session_completed`. Tests (RielaCoreTests):
   budget failure persists `failed` + kind + diagnostic; adapter-failure
   persisted-store regression; cancellation unchanged; resume of a
   budget-failed session (pre-P1-5 this asserts the terminal short-circuit).
3. **CLI/GraphQL projections** — `SessionCommands.swift`,
   `WorkflowRunCommand.swift` (`renderRunFailure`), `run_context` record,
   `GraphQLContracts.swift` + projector. Tests (RielaCLITests /
   RielaGraphQLTests): progress payload shape after budget failure; JSONL
   stream contains `run_context` and terminal `session_completed`.
4. **Discovery** — `CLIWorkflowSessionStore` filtered query + index
   migration, `session list`/`latest` parsing (`RielaCommand.swift`), help
   text (`RielaCLIApplication.swift`), GraphQL `workflowSessions`. Tests:
   filter/order/limit against a seeded store; parity between CLI and
   GraphQL row shapes.
5. **Resume override** — `SessionResumeOptions.maxSteps`, runner terminal
   check relaxation gated on `failureKind`. Tests: resume succeeds with a
   raised budget; resume of a non-budget failure still short-circuits.
6. **Budget surfacing + package/skills** — `workflow usage`/`inspect`
   `defaultMaxSteps`; raise `codex-recent-change-quality-loop`
   `maxLoopIterations` (package repo); align `riela-workflow-run` /
   `riela-troubleshooting` skill guidance.

### Risks and compatibility

- New session fields are optional and additive: old records decode, old
  readers ignore them. RielaApp and GraphQL consumers compile against the
  same structs in-repo, so additions are caught at build time.
- The generalized catch must not mask the original error: finalization is
  best-effort (`try?`-style, as the cancellation path does) and always
  rethrows.
- Double-finalization guard: if the session is already `failed` (adapter
  path marks it in-memory), only fill session-level `failureKind`/`reason`
  if unset and still emit the terminal event so persistence converges.
- Index migration runs only on writable opens; read-only inspection paths
  must not attempt DDL.
- Mock-scenario fixtures or EXPECTED_RESULTS that assert a stale `running`
  status after failures will need updating (behavioral change is the point
  of P0-1).
- `failureKind: cancelled` is transitional; when the sibling design's
  first-class `cancelled` status lands, migration maps kind to status.

## Boundaries With Related Designs

- `design-cancellation-and-orphan-session-resilience.md` owns: the
  `cancelled` terminal status, PID/heartbeat and orphan reconciliation
  (`session reconcile`), and detach/attach/wait. This design owns: in-process
  failure finalization and `failureKind` metadata, session discovery
  (`list`/`latest`), step-budget semantics and diagnostics, and resume
  budget override. The two must share the failure-metadata schema from
  phase 1.
- Issue #15 (stale `currentStepId` in live persistence) is adjacent; P0-1
  narrows its blast radius but does not claim it.

## Validation

- `swift build` and the targeted test suites per phase
  (`RielaCoreTests.DeterministicWorkflowRunnerTests`,
  `RielaCLITests.WorkflowCommandSessionDiscoveryTests`,
  `RielaCLITests.WorkflowCommandInspectionTests`,
  `RielaCLITests.WorkflowCommandTests`, and
  `RielaGraphQLTests.GraphQLContractsTests`). Broaden to
  `RielaCoreTests`, `RielaCLITests`, and `RielaGraphQLTests` for final
  handoff when runtime permits.
- Manual re-check of the incident shape: run the packaged loop with a mock
  scenario that keeps one finding open, confirm `session progress` reports
  `failed` + diagnostic, then `session resume --max-steps 28` completes.
- `swiftlint`, `git diff --check`, and pre-commit safety checks before
  committing. If any command is unavailable or exposes unrelated pre-existing
  failures, record the command, result, and owner explicitly in the handoff.

## Session Follow, Rollup, and Backend Liveness Extension (2026-07-23)

### Scope and issue reference

This extension is the accepted design for the single `issue-resolution` work
package **“Session observability: progress --follow, parent/child rollup,
backend liveness verdict (one feature)”**. The request came from
`fable-and-improve` through workflow execution
`codex-design-and-implement-review-loop-session-2`; no GitHub repository,
issue number, or issue URL was supplied. It extends the compact progress
projection designed above. It does not reopen the earlier failure-finalization,
discovery, or budget-recovery decisions.

The extension owns three views over one persisted model:

1. periodic progress digests for one live session;
2. a root/child tree for cross-workflow sessions; and
3. an evidence-backed activity verdict for the active CLI-agent backend.

These remain one feature because provenance, follow mode, health, CLI, and
GraphQL all consume the same read-only session-observability service. There is
no feature fan-out. No kill, restart, reconciliation, detach, attach, wait, or
new daemon behavior is introduced.

### Source-verified starting points

- `Sources/RielaCLI/SessionCommands.swift` builds
  `SessionInspectionCommandResult` directly from one
  `WorkflowRuntimePersistenceSnapshot`. It already exposes current step/stage,
  execution count, running backend, last backend event, silence ages,
  `stepBudgetDiagnostic`, and loop evidence, but has no follow loop, rollup, or
  backend-activity verdict.
- `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` opens
  `load` and `loadAll` connections in SQLite read-only mode. Its writable
  `ensureSchema` path uses additive `ALTER TABLE` migrations. The
  `workflow_runtime_snapshots` table has no root or parent session columns.
- `Sources/RielaCore/WorkflowRuntimePersistenceSnapshot.swift` persists a
  `WorkflowSession` JSON blob. `WorkflowSession` in
  `Sources/RielaCore/RuntimeSession.swift` has no cross-workflow provenance or
  live effective-budget field; old JSON is already decoded through optional
  additive fields.
- `Sources/RielaCore/DeterministicWorkflowRunner+CrossWorkflow.swift` passes
  the runtime-only `workflowRunId` to the callee and appends
  `_rielaCrossWorkflow` to the parent only after the child completes. The
  child is therefore not durably discoverable while it is running.
- `Sources/CodexAgent/CodexSessionIndex.swift` and
  `Sources/ClaudeCodeAgent/ClaudeCodeSessionIndex.swift` expose indexed native
  sessions with rollout paths and modification dates. Their home resolvers
  honor `CODEX_HOME` and `CLAUDE_CONFIG_DIR`, respectively, with home-relative
  defaults. The corresponding rollout watchers use the same roots.
- `Sources/AgentRuntimeKit/AgentProcessStateProber.swift` can classify a known
  PID as running, zombie, or missing, but the workflow snapshot does not
  currently persist a backend PID. Process evidence is therefore optional in
  this work package; artifact and stream evidence are the required paths.
- `RielaCore` cannot import `CodexAgent` or `ClaudeCodeAgent` under the SwiftPM
  dependency graph. Provider-neutral contracts belong in `RielaCore`;
  provider-specific probes stay in their adapter modules and are injected by
  an application composition layer.

### Shared read-only projection

Add a provider-neutral session-observability API in `Sources/RielaCore`, with
one service used by CLI and GraphQL. Names may follow repository conventions,
but the public data contract is fixed:

- `SessionProgressDigest`: observation time, session/workflow identifiers,
  `parentSessionId`, `rootSessionId`, status, optional previous status, current
  step and stage, execution count, effective step budget, gate visit counts,
  last backend event type/time/age, and active backend.
- `SessionRollupNode`: one digest plus recursively nested `children`.
- `SessionBackendActivity`: backend, verdict, evidence list, active and stalled
  thresholds, last activity time, and age.
- `SessionObservabilityView`: the requested root node and, for health reads,
  the backend activity assessment. CLI and GraphQL may wrap this contract but
  must not independently recalculate its fields.

All ages are derived from an injected clock at read time. Reads never persist
the observation time, status transitions, liveness result, or access metadata.
Stable structured output uses milliseconds for ages and ISO-8601 UTC dates.

The effective step budget is selected in this order:

1. `stepBudgetDiagnostic.stepBudget`, when a failure diagnostic exists;
2. the new optional `WorkflowSession.effectiveStepBudget`, captured from the
   runner's already-computed budget when the session starts; or
3. `null` for legacy sessions where neither value exists.

The service must not invent a budget from execution count. Gate visit counts
use `loopEvidence.convergence.gateVisitCounts` as the authoritative map; its
keys are stable `gateId` values, not step ids. When convergence evidence is
absent, group `loopEvidence.gates` by `gateId`. When the evidence manifest is
absent, the service may count executions only for gate ids that persisted loop
metadata explicitly maps to step ids; otherwise it returns an empty count set
rather than guessing from step names.

### Persisted parent/child provenance

Add optional, Codable-compatible session fields:

- `parentSessionId`: the immediately dispatching workflow session, or `nil`
  for a top-level run;
- `rootSessionId`: the top-level workflow session shared by the dispatch tree;
  old sessions resolve a missing value to their own `sessionId`; and
- `effectiveStepBudget`: the budget calculated for this run.

`DeterministicWorkflowRunRequest` carries parent/root provenance internally.
The top-level runner sets `rootSessionId` to its generated session id. Before
`dispatchCrossWorkflowCallee` invokes the child runner, it supplies the known
parent session id and inherited root id. The child's initial `session_started`
snapshot therefore includes provenance. This is the earliest durable point at
which a child exists and makes an in-flight child discoverable; discovery must
not wait for the parent's `_rielaCrossWorkflow` completion payload.

The writable SQLite migration adds nullable `parent_session_id` and
`root_session_id` columns plus indexes for parent and root queries. Upsert
writes the columns from session JSON. Migration and backfill occur only on an
existing writer/schema-preparation path. A reader opened against an older
database feature-detects missing columns and returns legacy sessions as
standalone roots; it must not run DDL, open a writable connection, create a
database, or modify file timestamps.

The store adds read-only queries for direct children and a complete rollup.
One rollup refresh should use a short autocommit read on a read-only connection,
selecting the root and indexed descendants, then close the connection before
sleeping. Tree assembly is in memory, orders siblings by `createdAt` then
`sessionId`, tracks visited ids to prevent malformed cycles, and represents a
missing referenced parent as an unattached root rather than failing the whole
read.

`session list` adds `parentSessionId` and `rootSessionId` to structured rows.
Text/table output adds stable parent and root columns without reordering or
removing existing columns.

### `session progress --follow` contract

`riela session progress <id>` remains a one-shot command. Add:

- `--follow`, valid only for `session progress`;
- `--poll-interval <seconds>`, default `2.0`; accepted values are finite and
  between `0.1` and `3600` seconds; and
- `--include-children`, valid for one-shot and follow progress reads.

Each refresh creates a new read-only store connection, reads one coherent
view, renders it, closes the connection, and then waits. No application lock,
write transaction, schema preparation, heartbeat, or observer state is stored
in the session database. A concurrently running writer remains the sole owner
of session mutations.

Text and JSONL emit one digest per refresh, including unchanged refreshes, so
silence ages continue to advance. JSONL emits one complete JSON object per
line; it never opens an array and never rewrites prior output. `--follow
--output json` is rejected with usage guidance to select `jsonl`; text/table
use the text digest. `previousStatus` is `null` on the first observation and is
set from the immediately preceding in-process observation thereafter.

Without `--include-children`, follow exits after emitting the first observation
whose requested session is terminal. With `--include-children`, it exits after
emitting a view in which the requested session and every discovered descendant
are terminal. Today `completed` and `failed` are terminal; a failed session
whose `failureKind` is `cancelled` is also terminal, and a future first-class
`cancelled` status must be handled additively. An already-terminal session
emits exactly once and exits successfully. Read/decode/not-found errors produce
one normal command failure and terminate rather than retrying forever.

### Backend activity verdict

Define the provider-neutral probe protocol and verdict/evidence models in
`RielaCore`. Concrete probes live in:

- `Sources/CodexAgent`: resolve a uniquely correlated Codex native session and
  use its rollout/session artifact modification time;
- `Sources/ClaudeCodeAgent`: use persisted Claude stream-event recency and,
  when uniquely correlated, its native session artifact modification time;
  and
- `Sources/AgentRuntimeKit`: optional process-state evidence for a PID and
  start identity supplied by a future or existing adapter integration.

The probe input includes workflow/session/execution identity, backend,
execution start/update times, persisted last backend event, working directory,
optional native backend session id, and configured thresholds. Add optional
`backendSessionId` and `backendWorkingDirectory` fields to
`WorkflowStepExecution`, and an optional `backendSessionId` to
`AdapterBackendEvent`. The runner copies the node's effective working directory
when it starts an execution. Codex and Claude classifiers populate the event
session id as soon as an existing stream parser identifies the native session;
the runner's existing backend-event receipt path persists it on the running
execution. Correlation uses that id directly. When a provider does not emit an
id, an artifact match must be unique within the active execution time window
and persisted working directory. Ambiguous correlation is `unknown`, never
“latest session wins.” Legacy executions decode both new fields as `nil`.

Home resolution must call `CodexSessionIndex.resolveCodexHome` or
`ClaudeCodeSessionIndex.resolveClaudeCodeHome`, or accept an explicitly
injected root in tests. No absolute user path appears in source. Unreadable or
missing roots, absent artifacts, unsupported backends, ambiguous matches, and
probe errors degrade to `unknown` with a non-secret reason. Evidence may expose
the resolved artifact path in structured local output; text rendering should
home-abbreviate it for readability. Probe code never creates, touches, or
opens artifacts for writing.

Default thresholds are `activeThresholdMs = 30_000` and
`stalledThresholdMs = 180_000`, and both values are included in output.
Classification is deterministic:

- `active`: the newest correlated backend event, artifact modification, or
  positive process-activity evidence is no older than the active threshold;
- `quiet`: correlated evidence exists and is older than the active threshold
  but no older than the stalled threshold, or correlated evidence exists and
  the workflow execution is no longer running;
- `stalled-suspect`: the workflow execution is still running and runtime
  silence exceeds the stalled threshold. For Codex, a matching stale artifact
  or a matched live process plus stale artifact must corroborate the verdict.
  For Claude, a persisted stream event attached to that execution is already
  provider-correlated evidence and is sufficient when its age also exceeds the
  stalled threshold; a uniquely matched stale artifact is an additional path;
  and
- `unknown`: the probe lacks enough unique, readable evidence for the other
  verdicts.

This is evidence, not remediation. “Suspect” intentionally avoids claiming
that a stale artifact proves deadlock. Fixture tests distinguish a healthy
long turn (fresh stream or artifact evidence) from a wedged-looking turn
(running execution plus stale runtime and provider evidence). A merely stale
runtime event with no correlated provider evidence remains `unknown`.

### CLI and GraphQL parity

`SessionInspectionCommand` delegates projection to the shared service.
`session health` retains existing health and silence fields and additively
returns `backendActivity` plus evidence and thresholds. `session progress`
returns the same digest/rollup shape used by follow. `session list` projects
the shared provenance fields.

Add GraphQL fields/queries without renaming or removing existing schema:

- `sessionProgress(sessionId: String!, includeChildren: Boolean = false)`
  returns the shared digest/rollup view;
- `sessionHealth(sessionId: String!)` returns the shared digest plus backend
  activity assessment; and
- existing session discovery rows gain nullable `parentSessionId` and
  `rootSessionId`.

`RielaGraphQL` depends only on the provider-neutral service/protocol. The
application composition layer injects the Codex and Claude probe registry.
Every in-repository production composition path that exposes these GraphQL
queries must register the same concrete probes and root configuration used by
the CLI. The `unknown` default exists only for external/library consumers that
intentionally omit probe registration. Resolver tests compare decoded GraphQL
fields with the result of the shared service for the same fixture and clock,
rather than comparing two independent implementations.

The production composition inventory is explicit:

- `Sources/RielaCLI/SessionCommands.swift` is the production CLI progress and
  health path. The `RielaCLI` target already imports `CodexAgent` and
  `ClaudeCodeAgent`; one CLI-owned composition factory assembles the concrete
  probe registry, configured roots, clock, and read-only store service used by
  both `SessionInspectionCommand` and GraphQL parity commands.
- `Sources/RielaCLI/ScopedParityCommands.swift` is the production
  `riela graphql session` path. Its additive progress and health actions use
  that same CLI-owned composition factory and delegate to
  `GraphQLRuntimeSnapshotQueryService`; they do not build a second probe
  registry or recalculate a verdict.
- `Sources/RielaGraphQL/RielaGraphQL.swift` owns the provider-neutral
  `GraphQLRuntimeSnapshotQueryService`. It accepts the shared observability
  service or probe registry through initialization and has no dependency on
  `CodexAgent` or `ClaudeCodeAgent`. A caller that deliberately omits the
  registry receives `unknown`, as documented by the public initializer.
- `Sources/RielaServer/ServerContracts.swift` and
  `Sources/RielaServer/WorkflowServingController.swift` do **not** currently
  execute runtime-session GraphQL queries: `/graphql` either delegates to the
  note-only document executor or returns the schema/delegation envelope.
  `Sources/RielaCLI/ServeHTTPCommand.swift` therefore exposes no production
  runtime-session query composition to update in this package. If runtime
  session document execution is added there later, its executable composition
  root must inject the same registry; `RielaServer` itself remains
  provider-neutral.
- `Sources/RielaApp/RielaAppWebRouter.swift` likewise forwards `/graphql` to
  the default server adapter and does not install a runtime-session executor.
  RielaApp has no production runtime-session GraphQL composition in this work
  package, so it must not grow an unused probe registry merely to satisfy a
  test. Its existing `/api/v1` session summary is a separate REST projection
  and is not changed by this GraphQL acceptance signal.

This inventory makes the CLI and its GraphQL parity path the two concrete
production consumers in scope. Tests must prove both receive the same registry;
tests that instantiate `GraphQLRuntimeSnapshotQueryService` without a registry
cover only the documented external/library `unknown` fallback.

### Data flow and boundaries

1. The runner creates a session with root/parent provenance and effective
   budget.
2. The existing writer event path persists the snapshot and indexed provenance
   columns.
3. A progress, health, list, or GraphQL reader opens the SQLite database in
   read-only mode and loads the requested snapshot or indexed descendants.
4. The shared service derives digest and rollup fields using an injected clock.
5. Health composition invokes only the probe matching the active backend and
   merges its assessment into the shared view.
6. CLI or GraphQL renders that view without additional business derivation.

Cursor CLI behavior is not a reference input for this work package, so there
is no Cursor behavior mapping. Cursor remains unsupported by the new concrete
liveness probes and reports `unknown`; no Cursor-specific path or process
logic enters `RielaCore`. No external codex-agent reference repository was
provided or consulted. Codex-agent in this design denotes the in-repository
`Sources/CodexAgent` adapter only.

### User-facing documentation contract

Implementation updates both user-facing command-documentation surfaces before
handoff:

- `README.md` gains a compact session-observability section with runnable
  examples for one-shot and followed progress, text and JSONL streaming,
  `--poll-interval`, `--include-children`, parent/root fields in `session list`,
  and `session health`. It states that observers are read-only, follow exits
  after the applicable terminal tree, and unavailable or ambiguous artifacts
  yield `backendActivity: unknown`.
- `Sources/RielaCLI/RielaCLIApplication.swift` command help lists the new flags,
  their validity (`progress` only where applicable), the `2.0` second default
  and accepted interval range, the rejection of `--follow --output json`, and
  the four backend-activity verdicts.

The documentation defines `active`, `quiet`, `stalled-suspect`, and `unknown`
as evidence classifications rather than remediation or a guarantee of
deadlock. It preserves existing command examples and does not document
RielaServer or RielaApp runtime-session GraphQL execution because those
production paths do not exist in this package.

### Acceptance mapping

| Requested signal | Design decision |
|---|---|
| Follow streams text and JSONL and exits on terminal state | Per-refresh output, JSONL-only structured stream, terminal rules, injected clock/sleeper |
| Digest includes step/stage, executions/budget, gate visits, backend event/age, transitions | `SessionProgressDigest` and persisted `effectiveStepBudget` |
| Parent plus in-flight/completed children are visible | Parent/root provenance on the child's first snapshot plus indexed rollup query |
| Session list shows relationships | Additive parent/root fields and text columns |
| Health distinguishes active, quiet, stalled-suspect, unknown | Deterministic two-threshold verdict with runtime and provider evidence |
| Codex and Claude are covered | Provider-specific probes using existing home resolvers, indexes, streams, and injectable fixture roots |
| CLI and GraphQL agree | One `RielaCore` observability service and parity tests using the same fixture/clock |
| Readers do not interfere with a live writer | Read-only, short-lived connections; no DDL, writes, locks, or sleeps while connected |
| Session-command behavior is documented | `README.md` examples and `RielaCLIApplication.swift` help cover follow, rollup/list provenance, and backend-activity semantics |

### Validation and review gates

Required automated verification from the worktree root:

```bash
swift build
swift test --filter RielaCoreTests
swift test --filter RielaCLITests
swift test --filter RielaGraphQLTests
swift test --filter CodexAgentTests
swift test --filter ClaudeCodeAgentTests
rg -n "session progress|include-children|poll-interval|backendActivity|parentSessionId|rootSessionId" README.md Sources/RielaCLI/RielaCLIApplication.swift
git diff --check
```

Targeted tests must cover digest projection with an injected clock; legacy and
new provenance decoding; indexed discovery of a running child; cycle-safe tree
assembly; read-only access to a pre-migration database; concurrent writer and
polling reader; follow output cadence, status transitions, terminal exit, and
invalid intervals; Codex and Claude fresh/stale/missing/ambiguous artifacts;
stalled-suspect versus healthy-long-turn fixtures; unsupported backend
fallback; GraphQL/shared-service equality; shared CLI/GraphQL probe-registry
identity; and command-help parsing for every new option and invalid output
combination. Documentation review must confirm the README examples match the
tested CLI spelling, defaults, terminal behavior, and structured field names.

Live smoke verification must run a small mock-scenario parent/child workflow
and execute:

```bash
.build/debug/riela session progress <session-id> --follow --poll-interval 0.2 --output text
.build/debug/riela session progress <session-id> --follow --poll-interval 0.2 --output jsonl
.build/debug/riela session progress <parent-session-id> --include-children --output json
.build/debug/riela session list --output json
.build/debug/riela session health <session-id> --output json
```

The smoke record must show that follow observed live updates, emitted its
terminal digest, exited, and did not change snapshot content except for writes
made by the workflow writer. Known baseline exclusions are the two
`SourceDeletionReadinessTests` failures, the flaky
`DaemonWorkflowNodePatchTests` event-source-restart test, and the occasionally
flaky agent-VM interleaved-submit test; any other failure is a regression until
explained.

Because this change includes an additive database migration, workflow runner
provenance, external artifact reads, and branch-owned commit/push behavior, the
implementation receives adversarial review even though the requested
`reviewMode` is `standard` and `riskLevel` is `normal`. Review must explicitly
decide: **accept**, **accept with non-blocking findings**, or **request
changes**, and must treat read-path writes, ambiguous backend correlation,
CLI/GraphQL drift, or missing terminal-exit coverage as blocking findings.

### Risks and rollout constraints

- Old stores have no provenance. They remain readable and appear as standalone
  roots; provenance cannot be reconstructed reliably from completed parent
  payloads without false matches.
- A child can be absent for the brief interval before its first persisted
  `session_started` snapshot. No reader-side mutation is allowed to close that
  interval.
- Artifact modification times can be coarse or externally changed. Verdict
  output includes evidence and thresholds, and ambiguous or missing matches
  remain `unknown`.
- Very small polling intervals increase read load. Validation bounds and an
  indexed one-query rollup keep that load finite.
- A parent could become terminal before a child due to failure propagation.
  Include-children follow waits for every discovered descendant so its final
  emitted tree is internally terminal.
- Structured schema additions are optional and additive. Existing commands,
  flags, GraphQL fields, and legacy snapshot decoding remain supported.
