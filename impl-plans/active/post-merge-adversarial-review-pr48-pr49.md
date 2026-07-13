# Post-Merge Adversarial Review PR #48 and PR #49 Implementation Plan

**Status**: Complete
**Design Reference**: design-docs/specs/design-post-merge-adversarial-review-pr48-pr49.md
**Created**: 2026-07-13
**Last Updated**: 2026-07-13

---

## Design Document Reference

**Source**: design-docs/specs/design-post-merge-adversarial-review-pr48-pr49.md

### Summary

Execute one issue-resolution work package for the code merged by PR #48 and
PR #49. The implementation step must adversarially review the accepted scope,
confirm candidate defects through trace evidence or failing tests, apply only
minimal fixes for confirmed defects, document any unfixed confirmed defects as
residual risks, verify with the required Swift commands, and commit locally
without pushing.

### Scope

**Included**: PR #48 loop convergence, loop evidence/stats, workflow history,
sleep-node runtime semantics, and corresponding `Tests/RielaCoreTests`; PR #49
Riela Note storage, dispatch, LibSQL, note GraphQL, note UI view models, and
corresponding note, dispatch, GraphQL, and UI tests.

**Excluded**: Feature fanout, unrelated refactors, behavior changes not tied to
a confirmed finding, documentation churn outside the accepted review package,
and any Codex Agent or Cursor adapter work.

---

## Task Breakdown

### TASK-001: Establish Review Baseline and Safety Snapshot

**Status**: COMPLETED
**Depends On**: accepted Step 3 design
**Write Scope**: no source writes expected; branch/status only

**Deliverables**:
- Confirm the active design reference and implementation plan are the source of
  truth for the work package.
- Capture initial `git status --short`; preserve any pre-existing user changes.
- Create or confirm a local working branch/snapshot before source edits.
- Enumerate reviewed changes with:
  - `git diff a503b16~1..14274b5`
  - `git diff 14274b5..b5808b3`
- Record review notes and command evidence under repository `tmp/` only.

**Checklist**:
- [x] Initial dirty-worktree state recorded
- [x] Local branch/snapshot confirmed
- [x] PR #48 and PR #49 diffs enumerated
- [x] In-scope file list finalized from the accepted design

### TASK-002: Review and Confirm PR #48 Runtime Findings

**Status**: COMPLETED
**Depends On**: TASK-001
**Write Scope**: `Sources/RielaCore`, `Tests/RielaCoreTests`

**Review Targets**:
- `Sources/RielaCore/LoopConvergenceTracker.swift`
- `Sources/RielaCore/LoopEvidence*.swift`
- `Sources/RielaCore/LoopWorkflowStats.swift`
- `Sources/RielaCore/LoopCostAccumulator.swift`
- `Sources/RielaCore/LoopFindingFingerprint.swift`
- `Sources/RielaCore/LoopRegressionVerdict.swift`
- `Sources/RielaCore/LoopSessionOverview.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift`
- `Sources/RielaCore/WorkflowLoopValidation.swift`
- `Sources/RielaCore/SleepNodeExecution.swift`
- `Sources/RielaCore/WorkflowHistoryModels.swift`
- `Sources/RielaCore/WorkflowHistoryCanonicalCoding.swift`
- corresponding tests under `Tests/RielaCoreTests`

**Deliverables**:
- Trace loop convergence off-by-one, stall misclassification, fingerprint
  repeat handling, evidence replay ordering, verdict/stat loss, sleep
  duration/cancellation/resume semantics, and workflow history coding.
- For every candidate issue, either record why behavior is correct or confirm
  it with a failing focused test or concrete code-path trace.
- Do not patch speculative issues.

**Checklist**:
- [x] Loop convergence/stall behavior reviewed
- [x] Evidence projection/replay ordering reviewed
- [x] Regression verdict and stats preservation reviewed
- [x] Sleep-node semantics reviewed
- [x] Workflow history coding reviewed
- [x] Confirmed findings list or zero-finding evidence recorded

### TASK-003: Review and Confirm PR #49 Note Findings

**Status**: COMPLETED
**Depends On**: TASK-001
**Write Scope**: `Sources/RielaNote`, `Sources/RielaNoteDispatch`,
`Sources/RielaNoteLibSQL`, note GraphQL files, `Sources/RielaNoteUI`, and
their corresponding tests

**Review Targets**:
- `Sources/RielaNote`
- `Sources/RielaNoteDispatch`
- `Sources/RielaNoteLibSQL`
- `Sources/RielaGraphQL/NoteGraphQLDocumentExecutor*.swift`
- `Sources/RielaGraphQL/NoteGraphQLDocumentInputs*.swift`
- `Sources/RielaGraphQL/NoteGraphQLDocumentParsing*.swift`
- `Sources/RielaGraphQL/NoteGraphQLContracts.swift`
- `Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift`
- `Sources/RielaNoteUI/RielaNoteLibraryViewModel*.swift`
- `Sources/RielaNoteUI/RielaNoteAgentViewModel.swift`
- `Sources/RielaNoteUI/RielaNoteConfigAgentViewModel.swift`
- corresponding tests under `Tests/RielaNoteTests`,
  `Tests/RielaGraphQLTests`, `Tests/RielaNoteUITests`, and
  `Tests/RielaNoteDispatchTests`

**Deliverables**:
- Trace schema/migration preservation, file reclamation behavior,
  auto-action retry/lease/idempotency, maintenance ticker behavior, GraphQL
  strict argument and projection parsing, and UI async pagination, selection,
  and generation guards.
- For every candidate issue, either record why behavior is correct or confirm
  it with a failing focused test or concrete code-path trace.
- Do not patch speculative issues.

**Checklist**:
- [x] Note schema and migration behavior reviewed
- [x] Auto-action dispatch and ticker behavior reviewed
- [x] GraphQL parsing/execution behavior reviewed
- [x] Note UI async guard behavior reviewed
- [x] Confirmed findings list or zero-finding evidence recorded

### TASK-004: Apply Minimal Fixes and Regression Tests

**Status**: COMPLETED
**Depends On**: TASK-002, TASK-003
**Write Scope**: only files tied to confirmed findings

**Deliverables**:
- For each confirmed finding, apply the smallest behavior-preserving fix in
  the owning module.
- Add or update targeted regression tests next to the relevant existing test
  suites.
- If a confirmed issue cannot be fixed within scope, document it as residual
  risk with exact reason, impact, and verification evidence.
- Keep changes within the review boundaries from the accepted design.

**Checklist**:
- [x] Each confirmed finding mapped to fix or residual risk
- [x] Regression tests added for fixed findings
- [x] No unrelated source changes introduced
- [x] Scratch artifacts remain under `tmp/`

### TASK-005: Verify, Document, and Commit Locally

**Status**: COMPLETED
**Depends On**: TASK-004
**Write Scope**: implementation evidence and local commit metadata only

**Deliverables**:
- Run verification commands in the accepted order.
- Record exact command results and failure modes if any command fails.
- Confirm `git status --short` contains only in-scope source/test/doc changes.
- Create a local branch commit for the completed work package.
- Do not push to origin.

**Checklist**:
- [x] `swift build` completed before tests
- [x] All targeted test filters run
- [x] Final `git status --short` reviewed
- [x] Local commit exists and `git log --oneline -1` captured
- [x] No push performed

---

## Dependencies

| Task | Depends On | Reason |
|------|------------|--------|
| TASK-001 | accepted Step 3 design | Defines source of truth and boundaries |
| TASK-002 | TASK-001 | Needs exact diff and safety baseline |
| TASK-003 | TASK-001 | Needs exact diff and safety baseline |
| TASK-004 | TASK-002, TASK-003 | Fixes only confirmed findings |
| TASK-005 | TASK-004 | Verifies final source state |

## Parallelizable Tasks

| Tasks | Parallelizable | Constraint |
|-------|----------------|------------|
| TASK-002 and TASK-003 | Yes | Review work may proceed in parallel because PR #48 and PR #49 write scopes are disjoint until TASK-004. |
| TASK-004 PR #48 fixes and PR #49 fixes | Conditional | Parallel only when confirmed findings touch disjoint source/test files. Shared package or test manifest changes must be serialized. |
| TASK-005 | No | Verification and commit require a single final worktree state. |

## Verification

Run in order:

```sh
swift build
swift test --filter LoopConvergence
swift test --filter SleepNodeExecution
swift test --filter WorkflowHistory
swift test --filter RielaNoteTests
swift test --filter NoteGraphQL
swift test --filter RielaNoteUITests
git status --short
git log --oneline -1
```

A failed command blocks completion unless the exact command, failure mode, and
residual-risk decision are documented in the implementation result.

## Completion Criteria

- [x] Every confirmed defect or quality issue is fixed or documented as
  residual risk.
- [x] Zero confirmed defects, if applicable, is backed by review evidence.
- [x] `swift build` succeeds.
- [x] Required targeted test filters complete or any failure is explicitly
  documented as accepted residual risk.
- [x] `git status --short` shows only in-scope files changed.
- [x] Local branch commit exists.
- [x] Nothing is pushed to origin.

## Progress Log Expectations

The implementation step must maintain a concise progress log covering:

- review evidence for PR #48 and PR #49;
- confirmed findings, discarded candidates, and residual risks;
- files changed for each fix;
- verification command output summary;
- final branch and commit id.

Use repository `tmp/` for throwaway logs or intermediate evidence. Do not add
scratch files to git.

## Progress Log

- 2026-07-13: Confirmed Step 6 is running in `issue-resolution` mode. Active
  plan and accepted design are aligned: one work package for PR #48 and PR #49,
  no feature fanout, no Codex Agent reference inputs, no Cursor adapter work.
- 2026-07-13: Initial status on branch
  `codex/pr48-pr49-post-merge-review-design` showed pre-existing untracked
  `design-docs/specs/design-post-merge-adversarial-review-pr48-pr49.md` and
  this active plan. Reviewed `git diff a503b16~1..14274b5` and
  `git diff 14274b5..b5808b3`; implementation remained inside the accepted
  Swift source/test scope.
- 2026-07-13: PR #48 review confirmed one sleep-node defect:
  `SleepNodeExecution` converted `durationMs` with unchecked
  `UInt64(durationMs) * 1_000_000`, so extremely large valid JSON integer
  durations could trap before normal timeout/cancellation semantics applied.
  Fixed by clamping millisecond-to-nanosecond conversion and added regression
  coverage in `SleepNodeExecutionTests`.
- 2026-07-13: PR #48 loop convergence, evidence projection/diff, regression
  verdict/stats, and workflow-history canonical coding review found no further
  confirmed defect requiring a code change.
- 2026-07-13: PR #49 review confirmed one auto-action retry defect:
  `retryPendingAutoActionDispatches(limit:)` passed negative limits through to
  SQLite, where `LIMIT -1` means no limit and could dispatch every pending row.
  Fixed by treating negative limits as zero and added regression coverage in
  `AutoActionTests`.
- 2026-07-13: PR #49 note schema/migration, file reclamation, GraphQL
  strict-argument/projection/parsing, maintenance ticker, and Note UI
  generation/pagination guard review found no further confirmed defect
  requiring a code change.
- 2026-07-13: Verification evidence: `swift build` passed;
  `swift test --filter LoopConvergence` passed 10 tests; `swift test --filter
  SleepNodeExecution` passed 6 tests; `swift test --filter WorkflowHistory`
  passed 15 tests; `swift test --filter RielaNoteTests` passed 101 tests.
  `swift test --filter NoteGraphQL` reported all selected tests passed
  (59 tests) but the SwiftPM process did not exit before the command timeout.
  `swift test --filter RielaNoteUITests` reported all selected tests passed
  (166 tests) but the SwiftPM process did not exit before the command timeout.
  Changed-file SwiftLint passed with 0 violations; full-repository SwiftLint
  reached "Done linting" with 14 pre-existing warnings before command timeout.
- 2026-07-13: Final branch status reviewed. Local commit created without
  pushing; commit id recorded in the Step 6 implementation result.

## Addressed Feedback

- Step 3 accepted the design with no findings and no required revisions.
- No Step 5 feedback is present for this implementation-plan creation run.

## Risks

- Some targeted `swift test --filter` commands may still compile broad test
  targets and expose unrelated build failures; record exact failure evidence if
  encountered.
- Persisted workflow history or note schema behavior may require careful
  compatibility reasoning before any fix; do not change compatibility behavior
  without a confirmed defect.
- Local branch commit creation must preserve any pre-existing user work and
  must not push to origin.
