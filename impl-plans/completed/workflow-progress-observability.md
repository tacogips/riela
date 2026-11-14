# Workflow Progress Observability Implementation Plan

**Status**: Implemented; completion-audit verified
**Design Reference**: `design-docs/specs/design-workflow-progress-observability.md`
**Workflow Mode**: issue-resolution
**Issue Reference**: none provided in runtimeVariables
**Created**: 2026-07-03
**Last Updated**: 2026-07-03

## Summary

Implement the accepted workflow progress observability design so long-running
workflow failures become terminal, discoverable, and recoverable where the
failure kind permits it. The accepted design is the source of truth.

Primary behavior to deliver:

- Persist terminal in-runner failures as failed sessions and emit terminal
  `session_completed` events.
- Store and surface `failureKind`, failure reason, failed timestamp, and
  budget diagnostics where applicable.
- Emit CLI JSONL `run_context` records with session discovery context.
- Add session `list` and `latest` discovery for persisted sessions.
- Allow `session resume --max-steps` only for `maxStepsExceeded` failures.
- Surface computed `defaultMaxSteps` from `workflow inspect` and
  `workflow usage`.

## Source References

Design references:

- `design-docs/specs/design-workflow-progress-observability.md`

Codex-agent behavioral references from Step 3 intake:

- `design-docs/specs/design-workflow-progress-observability.md`
- `impl-plans/active/workflow-progress-observability.md`
- `examples/recent-change-quality-loop/workflow.json`
- `Sources/RielaCore/RuntimeSession.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift`
- `Sources/RielaCLI/SessionCommands.swift`
- `Sources/RielaCLI/CLIWorkflowSessionStore.swift`
- `Sources/RielaCLI/WorkflowRunCommand.swift`
- `Sources/RielaGraphQL/GraphQLContracts.swift`
- `Tests/RielaCLITests/WorkflowCommandSessionDiscoveryTests.swift`
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerTests.swift`
- `Tests/RielaGraphQLTests/GraphQLContractsTests.swift`

Additional implementation touchpoints expected from the accepted design:

- `Sources/RielaCore/RuntimeSession.swift`
- `Sources/RielaCore/RuntimeStore.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift`
- `Sources/RielaCLI/CLIWorkflowSessionStore.swift`
- `Sources/RielaCLI/WorkflowRunCommand.swift`
- `Sources/RielaCLI/RielaCommand.swift`
- `Sources/RielaCLI/RielaCLIApplication.swift`
- `Sources/RielaCLI/WorkflowCommands.swift`
- `Sources/RielaCLI/WorkflowValidateInspectCommands.swift`
- `Sources/RielaGraphQL/GraphQLContracts.swift`
- `Tests/RielaCLITests/WorkflowCommandSessionDiscoveryTests.swift`
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerTests.swift`
- `Tests/RielaCLITests/WorkflowCommandInspectionTests.swift`
- `Tests/RielaCLITests/WorkflowCommandTests.swift`
- `Tests/RielaGraphQLTests/GraphQLContractsTests.swift`

## Scope

Included:

- Additive runtime session schema fields for failure metadata and step-budget
  diagnostics.
- Runner finalization for all in-runner failure paths, preserving original
  error rethrow behavior.
- CLI and GraphQL projections for failure metadata, diagnostics, and session
  discovery.
- JSONL run-context emission from the CLI, because only the CLI knows session
  store and scope context.
- Resume override for budget-failed sessions only.
- Targeted tests, lint/build verification, and progress-log updates.

Excluded:

- `session watch`, `session attach`, `workflow run --detach`, orphan
  reconciliation, and first-class `cancelled` status; those remain owned by
  `design-cancellation-and-orphan-session-resilience.md`.
- Cursor-agent or Codex-agent specific session discovery semantics. The
  canonical model remains `WorkflowSession`, `CLIWorkflowSessionStore`, and
  workflow failure kinds.
- Full implementation code in this plan.

Intentional divergences accepted by design:

- `--output json` remains final-only and legacy.
- `currentStepId` keeps "next intended step" semantics.
- Per-step revisit caps are diagnostic classification only, not enforcement.
- `maxStepsExceeded` resume is explicitly permitted; other failed kinds remain
  terminal and use rerun paths.

## Task Breakdown

### TASK-001: Failure Metadata Schema

**Status**: COMPLETED
**Deliverables**:

- `Sources/RielaCore/RuntimeSession.swift`
- `Sources/RielaCore/RuntimeStore.swift`
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerTests.swift`

**Work**:

- Add optional `WorkflowSession` metadata:
  `failureReason`, `failureKind`, `failedAt`, and a structured step-budget
  diagnostic.
- Define `WorkflowSessionFailureKind` with at least:
  `maxStepsExceeded`, `cancelled`, `adapterFailure`, `policyBlocked`,
  `nodeTimeout`, and `internal`.
- Extend `WorkflowSessionFailureInput` and `markSessionFailed` so session-level
  metadata is filled without overwriting execution-level failure details already
  recorded by failed step publication.
- Keep old persisted records decodable through optional fields and
  `decodeIfPresent` behavior.

**Completion criteria**:

- Legacy session JSON without new fields decodes.
- `markSessionFailed` records session-level metadata with and without a running
  execution.
- Existing cancellation status behavior remains compatible with the accepted
  transitional `failureKind: cancelled` design.

### TASK-002: Runner Terminal Finalization And Budget Diagnostics

**Status**: COMPLETED
**Depends On**: TASK-001
**Deliverables**:

- `Sources/RielaCore/DeterministicWorkflowRunner.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift`
- Optional local runner helper split files if needed for maintainability
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerTests.swift`

**Work**:

- Build budget diagnostics at the max-step throw site, including step budget,
  execution count, max loop iterations, budget source, per-step revisit counts,
  open review-finding count, unscheduled next step, and suggested remediation.
- Generalize the runner catch/finalization path so all in-runner failures mark
  the session failed, map a `failureKind`, emit failed `session_completed`, and
  rethrow the original error.
- Preserve cancellation behavior while routing it through the same terminal
  event persistence path where practical.
- Guard against double-finalization and treat finalization persistence as
  best-effort so failure handling never masks the original error.

**Completion criteria**:

- Max-step failure persists `status: failed`, `failureKind:
  maxStepsExceeded`, diagnostics, and the unscheduled next step.
- Adapter, timeout, policy, and internal failure paths converge the persisted
  store to failed.
- JSONL streams end with `session_completed` for failure paths.
- Cancellation regression tests continue to pass.

### TASK-003: CLI Failure Projections And JSONL Run Context

**Status**: COMPLETED
**Depends On**: TASK-001, TASK-002
**Deliverables**:

- `Sources/RielaCLI/SessionCommands.swift`
- `Sources/RielaCLI/WorkflowRunCommand.swift`
- CLI result DTOs used by session progress/status and workflow run failure
- `Tests/RielaCLITests/WorkflowCommandTests.swift`

**Work**:

- Surface `failureReason`, `failureKind`, `failedAt`,
  `lastCompletedStepId`, and budget diagnostic fields in session inspection
  output.
- Add `failureKind` and diagnostic summary to `WorkflowRunFailureResult`.
- Emit CLI-owned JSONL `run_context` immediately after the forwarded
  `session_started` event, including `sessionId`, `workflowName`,
  `sessionStore`, `scope`, and `artifactRoot` when available.

**Completion criteria**:

- `session progress` on a failed budget session exposes terminal failure
  metadata and diagnostic details.
- `workflow run --output json` failure result includes enough diagnostic
  summary to distinguish budget exhaustion from a stale running session.
- JSONL output contains both early `run_context` and terminal
  `session_completed`.

### TASK-004: Session Discovery CLI And Store Queries

**Status**: COMPLETED
**Depends On**: TASK-001
**Deliverables**:

- `Sources/RielaCLI/CLIWorkflowSessionStore.swift`
- `Sources/RielaCLI/SessionCommands.swift`
- `Sources/RielaCLI/RielaCommand.swift`
- `Sources/RielaCLI/RielaCLIApplication.swift`
- `Tests/RielaCLITests/WorkflowCommandSessionDiscoveryTests.swift`

**Work**:

- Add filtered store queries over `cli_workflow_sessions` with filters for
  workflow name, status, and limit.
- Add writable-open migration for an index on
  `(workflow_name, updated_at DESC)`.
- Decode only selected rows, not the full store.
- Add `riela session list [--workflow <name>] [--status <status>]
  [--limit <n>] [--scope ...] [--output ...]`.
- Add `riela session latest --workflow <name> [--scope ...] [--output ...]`.
- Use compact row shape:
  `sessionId`, `workflowName`, `status`, `failureKind`, `currentStepId`,
  `executionCount`, `updatedAt`, and `sessionStore`.

**Completion criteria**:

- `session latest --workflow <name>` returns the latest failed
  `maxStepsExceeded` session without prior knowledge of its id.
- `session list` supports workflow, status, and limit filtering in stable
  updated-at descending order.
- Tests prove bounded decoding by querying only selected rows.

### TASK-005: GraphQL Projection Parity

**Status**: COMPLETED
**Depends On**: TASK-001, TASK-004
**Parallelizable With**: TASK-003 after shared DTO names are agreed
**Deliverables**:

- `Sources/RielaGraphQL/GraphQLContracts.swift`
- CLI GraphQL parity command surfaces where they project session fields
- `Tests/RielaGraphQLTests/GraphQLContractsTests.swift`

**Work**:

- Add additive `WorkflowSession` fields for failure metadata and diagnostics.
- Add `workflowSessions(workflowName, status, limit)` returning the compact row
  shape used by CLI discovery.
- Keep `riela graphql session` parity aligned with CLI session inspection
  projections.

**Completion criteria**:

- GraphQL session inspection exposes the same failure metadata as CLI
  inspection.
- GraphQL session discovery returns compact rows compatible with CLI discovery
  tests.

### TASK-006: Resume Budget Override

**Status**: COMPLETED
**Depends On**: TASK-001, TASK-002
**Deliverables**:

- `Sources/RielaCLI/SessionCommands.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner.swift`
- Resume request/options plumbing
- `Tests/RielaCLITests/WorkflowCommandTests.swift`
- `Tests/RielaCLITests/WorkflowCommandSessionDiscoveryTests.swift`
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerTests.swift`

**Work**:

- Add `--max-steps <n>` to `session resume`.
- Pass the override into the resumed deterministic run.
- Relax terminal resume short-circuit only when
  `failureKind == maxStepsExceeded`.
- Preserve terminal short-circuit for all other failed kinds.

**Completion criteria**:

- A budget-failed session resumes successfully with a raised max-step budget.
- A non-budget failed session still rejects resume and points operators toward
  rerun behavior.
- Resume without `--max-steps` keeps the computed default behavior described in
  the accepted design.

### TASK-007: Workflow Inspect And Usage Budget Surfacing

**Status**: COMPLETED
**Depends On**: TASK-002
**Parallelizable With**: TASK-004, TASK-005, TASK-006 after diagnostic model is stable
**Deliverables**:

- `Sources/RielaCLI/WorkflowCommands.swift`
- `Sources/RielaCLI/WorkflowValidateInspectCommands.swift`
- `Tests/RielaCLITests/WorkflowCommandInspectionTests.swift`

**Work**:

- Add computed `defaultMaxSteps` to `workflow inspect` and `workflow usage`
  output.
- Make output explain the effective fallback budget without changing
  `maxLoopIterations` enforcement semantics.

**Completion criteria**:

- Inspect and usage JSON include `defaultMaxSteps`.
- Text output exposes the budget in a concise operator-facing form.
- Existing inspect/usage fixtures are updated intentionally.

### TASK-008: Guidance, Integration Verification, And Progress Logging

**Status**: COMPLETED
**Depends On**: TASK-001 through TASK-007
**Deliverables**:

- Updated plan progress log entries in this file
- Relevant skill/package guidance only where it lives in this repository
- Verification evidence from targeted tests, lint, and build

**Work**:

- Record dated progress entries after each implementation slice.
- Ensure long-run guidance says JSONL is the supported machine-readable mode,
  `--output json` is final-only, and unknown session ids should use
  `session latest --workflow ...` after discovery lands.
- Run focused tests after each slice and full verification before handoff.
- Leave out-of-repository package or skill changes as explicit follow-up
  limitations if they cannot be edited from this repository.

**Completion criteria**:

- Every task has a dated progress entry with files changed, behavior covered,
  tests added, commands run, and remaining limitations.
- Verification commands pass or failures are explicitly documented with
  follow-up owner and scope.

## Dependencies

| Task | Depends On | Reason |
| ---- | ---------- | ------ |
| TASK-001 | Accepted Step 3 design | Runtime schema is the shared foundation. |
| TASK-002 | TASK-001 | Runner finalization persists session-level failure metadata. |
| TASK-003 | TASK-001, TASK-002 | CLI projections need persisted failure metadata and terminal events. |
| TASK-004 | TASK-001 | Discovery rows surface `failureKind` from the session model. |
| TASK-005 | TASK-001, TASK-004 | GraphQL discovery mirrors CLI row shape and session fields. |
| TASK-006 | TASK-001, TASK-002 | Resume gating depends on stored `failureKind` and runner terminal logic. |
| TASK-007 | TASK-002 | Budget surfacing should use the same computed-budget semantics. |
| TASK-008 | TASK-001 through TASK-007 | Final guidance and validation depend on implemented behavior. |

## Parallelization

Safe parallelizable slices:

- TASK-005 can proceed in parallel with TASK-003 after shared DTO names are
  agreed, because GraphQL projection writes are isolated from CLI rendering.
- TASK-007 can proceed in parallel with TASK-004, TASK-005, and TASK-006 after the
  diagnostic model and computed-budget helper are stable, because inspect and
  usage output writes are disjoint from session discovery and GraphQL
  projection files and resume command plumbing.

Not parallelizable:

- TASK-001 and TASK-002 are sequential because the runner needs the schema.
- TASK-003 and TASK-004 both write `SessionCommands.swift`; do not run them in
  parallel unless an implementation lead first splits disjoint helpers.
- TASK-006 must wait for failure-kind persistence and terminal finalization so
  resume gating cannot accidentally reopen unrelated failed sessions.
- TASK-008 is final integration and should run after all behavior slices.

## Verification

Run focused commands as each slice lands:

```bash
swift test --filter RielaCoreTests.DeterministicWorkflowRunnerTests
swift test --filter RielaCLITests.WorkflowCommandSessionDiscoveryTests
swift test --filter RielaCLITests.WorkflowCommandInspectionTests
swift test --filter RielaCLITests.WorkflowCommandTests
swift test --filter RielaGraphQLTests.GraphQLContractsTests
```

Run full handoff checks:

```bash
swift build
swift test --filter RielaCoreTests
swift test --filter RielaCLITests
swift test --filter RielaGraphQLTests
swiftlint
git diff --check
```

Manual incident-shape verification:

```bash
.build/arm64-apple-macosx/debug/riela workflow run <workflow> --variables <mock-open-finding-variables> --working-dir <workspace>/riela --output jsonl
.build/arm64-apple-macosx/debug/riela session latest --workflow <workflow> --output json
.build/arm64-apple-macosx/debug/riela session progress <session-id> --output json
.build/arm64-apple-macosx/debug/riela session resume <session-id> --max-steps 28 --output jsonl
.build/arm64-apple-macosx/debug/riela workflow inspect <workflow> --output json
```

If `swiftlint` is unavailable in the active environment, record that
limitation in the final handoff and run the remaining verification commands.

## Completion Criteria

- Terminal in-runner failures persist as `failed` sessions and emit terminal
  `session_completed` events.
- `failureKind` metadata is stored and surfaced in run failure, session
  progress/status, discovery rows, and GraphQL where applicable.
- JSONL workflow run output includes early CLI `run_context` with session
  discovery context.
- `session list` and `session latest` work for persisted sessions, including
  failed `maxStepsExceeded` sessions.
- `session resume --max-steps` succeeds only for `maxStepsExceeded` failures;
  other failed kinds remain terminal for resume.
- `workflow inspect` and `workflow usage` surface computed `defaultMaxSteps`.
- Targeted CLI, core, and GraphQL tests cover the new behavior.
- Build, lint, and diff checks are run or explicitly reported as unavailable.
- This plan has dated progress entries for each implementation slice.

## Progress Log Expectations

Each implementation session must add a dated entry under the relevant task or
in this section with:

- Tasks completed and tasks still in progress.
- Files changed and behavior delivered.
- Tests added or updated.
- Verification commands run and their pass/fail result.
- Any intentional limitation, out-of-scope follow-up, or accepted divergence
  from the design.

### Session: 2026-07-03

**Tasks Completed**: Created implementation plan from accepted Step 3 design.
**Tasks In Progress**: None.
**Blockers**: None.
**Notes**: Step 3 accepted the design with no findings and no pending
user-decision tracking requirement.

### Session: 2026-07-03 Step 6 Implementation

**Tasks Completed**: TASK-001 through TASK-008.
**Tasks In Progress**: None.
**Files Changed**: Runtime failure metadata and diagnostics in
`Sources/RielaCore/RuntimeSession.swift`, `Sources/RielaCore/RuntimeStore.swift`,
`Sources/RielaCore/DeterministicWorkflowRunner.swift`, and
`Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift`; add-on runner
logic split to `Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift`.
CLI projection, JSONL run-context, discovery, resume override, and inspect budget
surfacing in `Sources/RielaCLI/SessionCommands.swift`,
`Sources/RielaCLI/CLIWorkflowSessionStore.swift`,
`Sources/RielaCLI/WorkflowRunCommand.swift`, `Sources/RielaCLI/WorkflowCommands.swift`,
`Sources/RielaCLI/WorkflowValidateInspectCommands.swift`,
`Sources/RielaCLI/RielaCLIApplication.swift`, `Sources/RielaCLI/RielaCommand.swift`,
and `Sources/RielaCLI/RielaCommand+SessionParsing.swift`. GraphQL discovery and
failure metadata parity in `Sources/RielaGraphQL/GraphQLContracts.swift` and
`Sources/RielaGraphQL/RielaGraphQL.swift`.
**Tests Added Or Updated**:
`Tests/RielaCoreTests/DeterministicWorkflowRunnerTests.swift`,
`Tests/RielaCLITests/WorkflowCommandSessionDiscoveryTests.swift`,
`Tests/RielaCLITests/WorkflowCommandInspectionTests.swift`,
`Tests/RielaCLITests/WorkflowCommandTests.swift`, and
`Tests/RielaGraphQLTests/GraphQLContractsTests.swift`.
**Verification**:
`swift test --filter RielaCoreTests.DeterministicWorkflowRunnerTests`,
`swift test --filter RielaCLITests.WorkflowCommandSessionDiscoveryTests`,
and
`swift test --filter RielaGraphQLTests.GraphQLContractsTests`
passed. `swift build`,
`swift test --filter RielaCLITests`,
`swift test --filter RielaGraphQLTests`,
the Xcode-toolchain `swiftlint` command, and `git diff --check` passed.
`swift test --filter RielaCoreTests`
has one unrelated pre-existing fixture failure:
`SourceDeletionReadinessTests.testFixturesDoNotReferenceRemovedCodexNanoModel`
flags `Tests/RielaAppSupportTests/RielaAppSettingsSectionLayoutTests.swift`.
**Limitations**: Out-of-repository package guidance changes remain follow-up
work; in-repository CLI help and design traceability were updated.

## Completion Audit Task Breakdown

These audit tasks are the actionable plan for the later review/implementation
step after Step 3 accepted the design. Apply only warranted fixes; do not
rework accepted design choices or unrelated implementation.

### AUDIT-001: Terminal Failure Persistence And Failure Kind

**Status**: COMPLETED
**Write Scope**:

- `Sources/RielaCore/RuntimeSession.swift`
- `Sources/RielaCore/RuntimeStore.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift`
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerTests.swift`

**Work**:

- Verify terminal failure metadata is optional, Codable-compatible, and mapped
  for `maxStepsExceeded`, `cancelled`, adapter failures, policy blocks, node
  timeouts, and internal errors.
- Verify every in-runner failure path persists `status: failed`, emits terminal
  `session_completed`, and rethrows the original error.
- Fix only gaps that leave persisted sessions stale or lose failure kind.

**Completion criteria**:

- Budget failures persist `failed` with `failureKind: maxStepsExceeded`.
- Non-budget in-runner failures converge persisted store state to failed.
- Cancellation behavior remains compatible with the accepted transitional
  `failureKind: cancelled` boundary.

### AUDIT-002: Budget Diagnostics And Inspect Surfacing

**Status**: COMPLETED
**Depends On**: AUDIT-001
**Write Scope**:

- `Sources/RielaCore/RuntimeSession.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift`
- `Sources/RielaCLI/SessionCommands.swift`
- `Sources/RielaCLI/WorkflowCommands.swift`
- `Sources/RielaCLI/WorkflowValidateInspectCommands.swift`
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerTests.swift`
- `Tests/RielaCLITests/WorkflowCommandInspectionTests.swift`

**Work**:

- Verify `stepBudgetDiagnostic` includes dominant-cycle evidence, projected
  per-step revisit-cap classification, open review-finding count, unscheduled
  next step, budget source, and remediation.
- Verify `workflow inspect` and `workflow usage` expose computed
  `defaultMaxSteps`.
- Fix only missing fields, projection drift, or misleading diagnostic names.

**Completion criteria**:

- Core tests assert dominant-cycle and projected-cap fields for max-step
  failures.
- Inspect/usage tests assert `defaultMaxSteps`.

### AUDIT-003: CLI Session Discovery, JSONL, And Resume Recovery

**Status**: COMPLETED
**Depends On**: AUDIT-001, AUDIT-002
**Write Scope**:

- `Sources/RielaCLI/CLIWorkflowSessionStore.swift`
- `Sources/RielaCLI/SessionCommands.swift`
- `Sources/RielaCLI/WorkflowRunCommand.swift`
- `Sources/RielaCLI/RielaCommand.swift`
- `Sources/RielaCLI/RielaCommand+SessionParsing.swift`
- `Sources/RielaCLI/RielaCLIApplication.swift`
- `Tests/RielaCLITests/WorkflowCommandSessionDiscoveryTests.swift`
- `Tests/RielaCLITests/WorkflowCommandTests.swift`

**Work**:

- Verify JSONL emits early `run_context` with session discovery context.
- Verify `session list` and `session latest` use bounded filtered store queries
  and return compact rows with failure kind and session store.
- Verify `session resume --max-steps` is allowed only for
  `maxStepsExceeded`; all other failed kinds keep terminal resume
  short-circuit behavior.

**Completion criteria**:

- Unknown-id triage can find the latest session for a workflow.
- Resume tests cover budget failure recovery and non-budget failure rejection.

### AUDIT-004: GraphQL Parity And Guidance

**Status**: COMPLETED
**Depends On**: AUDIT-001, AUDIT-003
**Parallelizable With**: AUDIT-002 after diagnostic field names are stable
**Write Scope**:

- `Sources/RielaGraphQL/GraphQLContracts.swift`
- `Sources/RielaGraphQL/RielaGraphQL.swift`
- `<codex-home>/skills/riela-workflow-run/SKILL.md`
- `<codex-home>/skills/riela-troubleshooting/SKILL.md`
- `Tests/RielaGraphQLTests/GraphQLContractsTests.swift`

**Work**:

- Verify GraphQL session fields and `workflowSessions` discovery match CLI
  projection semantics.
- Verify installed guidance steers long runs to JSONL and unknown-id triage to
  `session latest --workflow`.
- Fix only parity or guidance drift against the accepted design.

**Completion criteria**:

- GraphQL contract tests cover failure metadata and diagnostic field parity.
- Installed guidance explicitly mentions JSONL, compact progress, and latest
  session discovery.

### AUDIT-005: Final Verification And Diff Check

**Status**: COMPLETED
**Depends On**: AUDIT-001 through AUDIT-004
**Work**:

- Run targeted core, CLI, and GraphQL tests before broad suites.
- Run `swift build`, `swiftlint`, and `git diff --check`.
- Record unrelated pre-existing failures separately from this feature.

**Completion criteria**:

- Verification commands pass, or each limitation is explicitly attributed with
  command output and owner.
- Plan progress log is updated with files changed, tests run, and remaining
  limitations.

### Session: 2026-07-03 Completion Audit Follow-Up

**Tasks Completed**: Closed remaining P1-4 and P1-6 audit gaps.
**Tasks In Progress**: None.
**Files Changed**: Added diagnostic cycle/classification fields in
`Sources/RielaCore/RuntimeSession.swift`, populated them from ordered execution
history in `Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift`,
surfaced them in `Sources/RielaCLI/SessionCommands.swift`, and added GraphQL
schema coverage in `Sources/RielaGraphQL/GraphQLContracts.swift`.
**External Skill Guidance Updated**:
`<codex-home>/skills/riela-workflow-run/SKILL.md` and
`<codex-home>/skills/riela-troubleshooting/SKILL.md` now steer unknown
session-id triage through `session latest --workflow`, compact
`session progress`, and JSONL for long runs.
**Tests Added Or Updated**:
`Tests/RielaCoreTests/DeterministicWorkflowRunnerTests.swift` now asserts
dominant-cycle and projected revisit-cap diagnostics for max-step failures.
`Tests/RielaGraphQLTests/GraphQLContractsTests.swift` now keeps the GraphQL
`StepBudgetDiagnostic` field set in sync with encoded DTOs.
**Verification So Far**:
`swift build`,
`swift test --filter RielaCoreTests.DeterministicWorkflowRunnerTests/testMaxLoopIterationsBoundsDeterministicRun`,
`swift test --filter RielaGraphQLTests`,
and `git diff --check` passed before the final broadened verification pass.
**Limitations**: The Riela review workflow implemented and accepted Step 6, but
its `step6-implement-self-review` adapter failed before returning review output;
a targeted rerun of that step failed the same way.

### Session: 2026-07-03 Step 6 Completion Audit Verification

**Tasks Completed**: AUDIT-001 through AUDIT-005 reviewed and verified against
the accepted design after the completion-audit fixes.
**Tasks In Progress**: None.
**Files Changed**: Updated this active implementation plan to mark completion
audit tasks verified. No additional source changes were warranted by this pass.
**Review Coverage**: Confirmed terminal failure persistence, `failureKind`
metadata, dominant-cycle and projected-cap budget diagnostics, JSONL
`run_context`, session list/latest discovery, max-steps resume recovery,
workflow inspect/usage `defaultMaxSteps`, GraphQL parity, and installed
`riela-workflow-run` / `riela-troubleshooting` guidance.
**Verification**:
`swift test --filter RielaCoreTests.DeterministicWorkflowRunnerTests`
passed.
`swift test --filter RielaCLITests.WorkflowCommandSessionDiscoveryTests`
passed.
`swift test --filter RielaCLITests.WorkflowCommandTests`
passed, including the `WorkflowCommandInspectionTests.swift` extension tests.
`swift test --filter RielaCLITests`
passed.
`swift test --filter RielaGraphQLTests.GraphQLContractsTests`
passed.
`swift test --filter RielaGraphQLTests`
passed.
`swift build`
passed.
`xcrun swiftlint`
passed.
`git diff --check` passed.
`swift test --filter RielaCoreTests`
still has the unrelated pre-existing
`SourceDeletionReadinessTests.testFixturesDoNotReferenceRemovedCodexNanoModel`
fixture failure for
`Tests/RielaAppSupportTests/RielaAppSettingsSectionLayoutTests.swift`.
**Limitations**: No new limitations for workflow progress observability.

### Session: 2026-07-03 Step 6 Self-Review Revision

**Tasks Completed**: Addressed the mid-severity Step 6 self-review finding for
TASK-006 non-budget failed session resume behavior.
**Tasks In Progress**: None.
**Files Changed**: `Sources/RielaCLI/SessionCommands.swift` now rejects resume
for failed sessions unless `failureKind == maxStepsExceeded`, returning explicit
rerun and progress-inspection guidance instead of rendering a misleading
successful resume. `Tests/RielaCLITests/WorkflowCommandSessionDiscoveryTests.swift`
adds JSON-output regression coverage for `adapterFailure` resume rejection.
**Verification**:
`swift test --filter RielaCLITests.WorkflowCommandSessionDiscoveryTests`
passed.
`swift build`
passed.
`xcrun swiftlint`
passed.
`git diff --check` passed.
**Limitations**: The broader
`swift test --filter RielaCLITests`
run passed the new `WorkflowCommandSessionDiscoveryTests` coverage but exited
with signal 6 in existing
`WorkflowCommandTests.testAutoImproveCancellationPreservesPriorIncidentAndRemediation`
due to an uncaught `NSFileHandleOperationException` bad file descriptor from
`Sources/RielaAdapters/LocalAgentProcess.swift`. The broader
`swift test --filter RielaCoreTests`
suite still has the unrelated pre-existing
`SourceDeletionReadinessTests.testFixturesDoNotReferenceRemovedCodexNanoModel`
fixture failure noted by the previous review.

### Session: 2026-07-03 Step 6 Test Integrity Revision

**Tasks Completed**: Addressed the mid-severity Step 6 test-integrity finding
for TASK-006 raised-budget resume coverage.
**Tasks In Progress**: None.
**Files Changed**:
`Tests/RielaCLITests/WorkflowCommandSessionDiscoveryTests.swift` now adds
end-to-end JSON-output CLI coverage for a two-step workflow that fails with
`workflow run --max-steps 1` and completes through
`session resume --max-steps 2`.
**Completion Criteria Updated**: TASK-006 now lists
`Tests/RielaCLITests/WorkflowCommandSessionDiscoveryTests.swift` as a test
deliverable because it owns the user-visible session discovery/resume CLI
regressions.
**Verification**:
`swift test --filter RielaCLITests.WorkflowCommandSessionDiscoveryTests`
passed, including
`testSessionResumeCompletesBudgetFailedSessionWithRaisedMaxSteps`.
**Limitations**: No new limitations for workflow progress observability.

### Session: 2026-07-03 Step 7 Review Revision

**Tasks Completed**: Addressed the mid-severity Step 7 review finding for
failed `session resume` persistence after `runner.run` throws.
**Tasks In Progress**: None.
**Files Changed**:
`Sources/RielaCLI/SessionCommands.swift` now persists the mutated runtime
snapshot for failed resume attempts with the same store root, resolution,
workflow name, and mock scenario metadata used by the success path, while
preserving the original runner error returned to the operator.
`Tests/RielaCLITests/WorkflowCommandSessionDiscoveryTests.swift` now verifies a
`maxStepsExceeded` session can resume, fail again, and have `session progress`
and `session latest` report the new persisted terminal failure metadata.
**Completion Criteria Updated**: TASK-006 coverage now includes failed
raised-budget resume persistence in addition to raised-budget success and
non-budget failure rejection.
**Verification**:
`swift test --filter RielaCLITests.WorkflowCommandSessionDiscoveryTests`
passed, including the failed-resume persistence regression coverage.
`swift build`
passed.
`xcrun swiftlint`
passed.
`git diff --check` passed.
**Limitations**: No new limitations for workflow progress observability.

### Session: 2026-07-03 Step 7 Adversarial Review Revision

**Tasks Completed**: Addressed the mid-severity Step 7 adversarial-review
finding that budget-failed `session resume --max-steps` could restart remaining
steps without the original runtime variables.
**Tasks In Progress**: None.
**Files Changed**:
`Sources/RielaCLI/CLIWorkflowSessionStore.swift` now persists optional
`runtimeVariables` on CLI session records while preserving compatibility with
older records that lack the field.
`Sources/RielaCLI/WorkflowRunCommand.swift`,
`Sources/RielaCLI/ScopedParityCommands.swift`, and
`Sources/RielaCLI/WorkflowPackageParityCommands.swift` now save the run
variables into persisted session metadata.
`Sources/RielaCLI/RielaCommand+SessionParsing.swift` and
`Sources/RielaCLI/SessionCommands.swift` now carry an explicit
`session resume --variables` override and otherwise restore the persisted
runtime variables for resume and rerun execution, including failed-resume
snapshot persistence.
`Tests/RielaCLITests/WorkflowCommandSessionDiscoveryTests.swift` now verifies
a max-step-failed CLI session persists `workflowInput` variables and only
successfully resumes when the command-node invocation still receives those
variables.
**Completion Criteria Updated**: TASK-006 coverage now includes runtime input
preservation across raised-budget resume recovery and explicit resume-variable
override plumbing.
**Verification**:
`swift test --filter RielaCLITests.WorkflowCommandSessionDiscoveryTests`
passed, including the runtime-variable preservation regression.
`swift build`
passed.
`xcrun swiftlint`
passed.
`git diff --check` passed.
**Limitations**: No new limitations for workflow progress observability.

### Session: 2026-07-03 Completion Audit Revision

**Tasks Completed**: Addressed the remaining P1-6 package-budget guidance gap
from the design document by raising the bundled `recent-change-quality-loop`
workflow to the six-cycle effective budget described in the incident analysis.
**Tasks In Progress**: None.
**Files Changed**:
`examples/recent-change-quality-loop/workflow.json` now sets
`defaults.maxLoopIterations` to `22`, producing `defaultMaxSteps: 28` for the
six delegation cycles described in
`design-docs/specs/design-workflow-progress-observability.md`.
**Completion Criteria Updated**: TASK-007 completion now includes the bundled
recent-change quality-loop budget alignment, not only installed skill guidance.
**Verification**:
`./.build/arm64-apple-macosx/debug/riela workflow validate recent-change-quality-loop --workflow-definition-dir ./examples --output json`
passed with `valid: true`.
`./.build/arm64-apple-macosx/debug/riela workflow inspect recent-change-quality-loop --workflow-definition-dir ./examples --output json`
reported `defaultMaxSteps: 28` and `maxLoopIterations: 22`.
`./.build/arm64-apple-macosx/debug/riela workflow usage recent-change-quality-loop --workflow-definition-dir ./examples --output text`
reported `defaultMaxSteps: 28`.
`./.build/arm64-apple-macosx/debug/riela workflow run recent-change-quality-loop --workflow-definition-dir ./examples --mock-scenario ./examples/recent-change-quality-loop/mock-scenario.json --output json`
completed with `nodeExecutions: 8` and `exitCode: 0`.
`./.build/arm64-apple-macosx/debug/riela workflow run recent-change-quality-loop --workflow-definition-dir ./examples --mock-scenario ./examples/recent-change-quality-loop/mock-scenario.json --max-steps 1 --output jsonl`
emitted early `run_context`, terminal `session_completed`, and final
`failureKind: maxStepsExceeded` with `stepBudgetDiagnostic`.
`./.build/arm64-apple-macosx/debug/riela session latest --workflow recent-change-quality-loop --session-store .riela/sessions --output json`
returned the failed max-step session without prior id knowledge.
`./.build/arm64-apple-macosx/debug/riela session progress recent-change-quality-loop-session-1091 --session-store .riela/sessions --output json`
reported `failed`, `failureKind: maxStepsExceeded`, `lastCompletedStepId:
riela-manager`, and the persisted budget diagnostic.
`./.build/arm64-apple-macosx/debug/riela session resume recent-change-quality-loop-session-1091 --session-store .riela/sessions --workflow-definition-dir ./examples --mock-scenario ./examples/recent-change-quality-loop/mock-scenario.json --max-steps 28 --output json`
completed with `status: completed`.
`swift build`
passed.
`xcrun swiftlint`
passed.
`git diff --check` passed.
**Limitations**: No new limitations for workflow progress observability.

### Session: 2026-07-03 Riela Review Fixes

**Tasks Completed**: Ran `codex-adversarial-implementation-review-loop` over
the final implementation. The review found two medium issues, both fixed:
stale session-level failure metadata after a resumed budget failure encounters a
new pre-step failure, and buffered JSONL failure output missing prior progress
records for in-process CLI callers.
**Tasks In Progress**: None.
**Files Changed**:
`Sources/RielaCore/RuntimeStore.swift` now overwrites session-level
`failureReason`, `failureKind`, `failedAt`, and `stepBudgetDiagnostic` with
the current terminal failure input.
`Sources/RielaCLI/WorkflowRunCommand.swift` now keeps the JSONL recorder
available through catch handling and appends final failure JSON to buffered or
immediate JSONL output.
`Tests/RielaCoreTests/DeterministicWorkflowRunnerTests.swift` covers stale
metadata replacement on resumed pre-step failure.
`Tests/RielaCLITests/WorkflowCommandTests.swift` covers buffered JSONL failure
output preserving `session_started`, `run_context`, and terminal
`session_completed`.
**Completion Criteria Updated**: Final Riela review is accepted for the two
blocking findings, with no high or medium findings remaining.
**Verification**:
`swift test --filter RielaCoreTests.DeterministicWorkflowRunnerTests/testResumePreStepFailureOverwritesPreviousBudgetFailureMetadata`
passed.
`swift test --filter RielaCLITests.WorkflowCommandTests/testWorkflowRunJSONLFailureIncludesBufferedProgressRecords`
passed.
`swift test --filter RielaCoreTests.DeterministicWorkflowRunnerTests` passed
with 32 tests.
`swift test --filter RielaCLITests.WorkflowCommandTests` passed with 95 tests.
`swift test --filter RielaCLITests.WorkflowCommandSessionDiscoveryTests`
passed with 4 tests.
`swift test --filter RielaGraphQLTests` passed with 11 tests.
`swift build` passed.
`xcrun swiftlint` passed with 0 violations.
`git diff --check` passed.
Real CLI JSONL max-steps failure smoke passed, preserving progress records and
final `failureKind: maxStepsExceeded`.
`codex-adversarial-implementation-review-loop-session-419` completed with
`status: accepted` and no high or medium findings.
**Limitations**: The final Riela review was scoped to the two medium findings
after a broader design-and-implementation workflow stalled at step6. Earlier
design and plan review steps in that stalled workflow had no findings.

## Risks

- Failure finalization must never mask the original thrown error.
- Double-finalization must not overwrite more specific execution-level failure
  details.
- Read-only session inspection paths must not attempt SQLite DDL for the new
  index.
- Optional schema additions must remain compatible with older persisted
  records.
- Existing fixtures that asserted stale `running` sessions after failures must
  be intentionally updated.
- Transitional `failureKind: cancelled` must stay compatible with the sibling
  cancellation/orphan design.
