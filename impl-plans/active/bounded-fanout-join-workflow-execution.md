# Bounded Fanout Join Workflow Execution Implementation Plan

**Status**: Ready
**Design Reference**: `design-docs/specs/design-bounded-fanout-join-workflow-execution.md`; `design-docs/specs/design-workflow-json.md`
**Created**: 2026-07-16
**Last Updated**: 2026-07-16

---

## Design Document Reference

**Source**: `design-docs/specs/design-bounded-fanout-join-workflow-execution.md`

### Summary

Implement local fanout-transition execution for live Swift workflow runs. The
publisher should emit a fanout dispatch directive for selected fanout
transitions, and `DeterministicWorkflowRunner` should execute branch sub-paths
with bounded concurrency, deterministic input-order aggregation, failure-policy
handling, write-ownership validation, and `runtimeVariables.fanoutJoin`
injection before continuing at the join step.

### Scope

**Included**:

- Runtime fanout directive emission in `InMemoryWorkflowOutputPublisher`.
- Runner-owned local fanout dispatch using structured Swift concurrency.
- JSON Pointer item resolution from the accepted source-step payload.
- Per-item branch request construction with `itemVariable` binding.
- Branch termination before `joinStepId`, ordered aggregation, and join-step
  variable/message injection.
- `fail-fast` cancellation and `collect-all` aggregation semantics.
- `read-only` and `disjoint-paths` write-ownership validation.
- Capability and CLI diagnostics for supported fanout, `run.maxConcurrency`,
  unsupported `isolated-workspace`, and unsupported cross-workflow fanout.
- Focused RielaCore tests, fixture/scenario coverage, and non-fanout regression
  verification.

**Excluded**:

- `isolated-workspace` branch worktree isolation; this remains a specific
  unsupported diagnostic.
- Partial-success joins; `collect-all` records every branch but still fails the
  dispatch when any branch fails.
- Codex-agent or Cursor adapter-specific behavior; no reference input exists
  and the accepted design treats fanout as runtime scheduling.
- Cross-workflow fanout unless implementation proves and tests it in the same
  slice; otherwise it must fail before a partial directive is emitted.

---

## Task Breakdown

### T1. Baseline And Contract Audit

**Status**: NOT_STARTED
**Write Scope**: none, except optional scratch notes under `tmp/bounded-fanout-join-workflow-execution/`
**Depends On**: accepted design

**Deliverables**:

- Confirm current publisher rejection, runner cross-workflow dispatch sites,
  runtime-variable prompt path, capability-gap diagnostics, CLI
  `--max-concurrency` behavior, existing fanout model fields, and current
  affected tests.
- Record any implementation-only discoveries in the progress log before code
  edits.

**Verification**:

- `git status --short`
- `rg -n 'fanout|crossWorkflowDispatch|runtimeVariables|maxConcurrency|unsupportedTransition' Sources/RielaCore Sources/RielaCLI Tests/RielaCoreTests`

### T2. Publisher Directive Surface

**Status**: NOT_STARTED
**Write Scope**: `Sources/RielaCore/RuntimePublication.swift`; focused
`Tests/RielaCoreTests/RuntimePublicationTests.swift`
**Depends On**: T1

**Deliverables**:

- Add `WorkflowFanoutDispatchDirective` parallel to
  `WorkflowCrossWorkflowDispatchDirective`.
- Add `WorkflowPublicationResult.fanoutDispatch`.
- Replace the live fanout unsupported-transition rejection with a helper that
  builds the directive from the accepted source output and selected transition.
- Fail early with a typed diagnostic for unsupported fanout combinations such
  as cross-workflow fanout when not implemented.
- Update runtime publication tests to assert directive emission and no blanket
  fanout unsupported error for supported local fanout.

**Verification**:

- `swift test --filter RuntimePublicationTests`

### T3. Runner Fanout Dispatch Core

**Status**: NOT_STARTED
**Write Scope**:
`Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift`;
`Sources/RielaCore/DeterministicWorkflowRunner.swift`;
focused runner tests under `Tests/RielaCoreTests`
**Depends On**: T1, T2

**Deliverables**:

- Add `dispatchFanout(...)` in a new fanout runner extension.
- Resolve `itemsFrom` with JSON Pointer semantics and fail with an actionable
  error when missing or non-array.
- Compute the effective concurrency bound from transition concurrency, item
  count default, and optional `run.maxConcurrency` cap.
- Run branch sub-paths with structured Swift concurrency and at most the
  effective bound active at once.
- Build branch requests by copying parent run context, binding `itemVariable`,
  isolating branch session/store state, and stopping before executing
  `joinStepId`.
- Aggregate branch records in source item order regardless of completion order.
- Implement `fail-fast` cancellation and `collect-all` aggregation/failure.
- Consume `publishResult.fanoutDispatch` at both existing runner dispatch
  handling sites.

**Verification**:

- `swift test --filter RielaCoreTests`
- Focused tests must prove bounded overlap with a counter, deterministic
  input-order results under out-of-order completion, and fail-fast cancellation.

### T4. Join Injection And Prompt Variable Path

**Status**: NOT_STARTED
**Write Scope**:
`Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift`;
`Sources/RielaCore/DeterministicWorkflowRunner.swift`;
prompt/runtime-variable focused tests under `Tests/RielaCoreTests`
**Depends On**: T3

**Deliverables**:

- Build the `fanoutJoin` object with `fanoutGroupRunId`, group/source/target/join
  identifiers, result order, failure policy, and ordered branch records.
- Append the joined workflow message once for `joinStepId`.
- Merge the same object into effective request variables so
  `runtimeVariables.fanoutJoin` is available through the existing prompt path.
- Continue execution at `joinStepId` after successful fanout completion.

**Verification**:

- A focused test asserts the join step reads `runtimeVariables.fanoutJoin`.
- The new fanout scenario reaches completed/exitCode 0.

### T5. Write Ownership And Capability Diagnostics

**Status**: NOT_STARTED
**Write Scope**:
`Sources/RielaCore/WorkflowRuntimeCapabilityGap.swift`;
`Sources/RielaCLI`;
`Tests/RielaCoreTests/WorkflowRunnerCapabilityPreflightTests.swift`;
CLI/preflight tests if present
**Depends On**: T2, T3

**Deliverables**:

- Validate `read-only` and `disjoint-paths` before launching branch tasks.
- Reject unsafe, empty, absolute, escaping, or overlapping disjoint paths.
- Keep `isolated-workspace` as a specific unsupported capability gap.
- Remove the blanket fanout unsupported gap for supported local fanout.
- Wire `run.maxConcurrency` as a live fanout cap and update CLI help/validation
  text that currently describes it as reserved.
- Preserve unrelated cross-workflow/resume diagnostics.

**Verification**:

- `swift test --filter WorkflowRunnerCapabilityPreflightTests`
- CLI help or validation tests covering `--max-concurrency`, if available.

### T6. Fixtures And End-To-End Workflow Scenarios

**Status**: NOT_STARTED
**Write Scope**:
workflow fixture/scenario files under existing test/example directories;
`Tests/RielaCoreTests`
**Depends On**: T3, T4, T5

**Deliverables**:

- Add a deterministic fanout mock scenario that completes with exitCode 0.
- Add tests for fanoutJoin ordering, out-of-order completion stability,
  bounded concurrency, fail-fast cancellation, collect-all failure aggregation,
  publisher directive emission, and capability preflight behavior.
- Re-run the existing non-fanout
  `codex-design-and-implement-review-loop` mock scenario and preserve
  29 node executions, 28 transitions, and exitCode 0.
- Run a `has_feature_fanout: true` path that reaches
  `step5-feature-plan-join` without `unsupportedTransition`.

**Verification**:

- `riela workflow validate codex-design-and-implement-review-loop`
- New fanout mock-scenario run command added to the progress log when its exact
  fixture path is known.
- Existing non-fanout mock-scenario command added to the progress log when its
  exact fixture path is confirmed.

### T7. Full Verification And Documentation Refresh

**Status**: NOT_STARTED
**Write Scope**:
this plan's progress log; `design-docs/specs/design-workflow-json.md` only if
implementation uncovers a schema clarification needed to stay aligned with the
accepted design
**Depends On**: T2, T3, T4, T5, T6

**Deliverables**:

- Run the full verification set and record exact commands/results.
- Confirm no throwaway artifacts exist outside
  `tmp/bounded-fanout-join-workflow-execution/`.
- Confirm no implementation commits or pushes were made unless explicitly
  requested by a later step.
- Refresh documentation only for factual implementation deltas, not for a new
  design decision.

**Verification**:

- `swift build`
- `swift test`
- SwiftLint command if configured in the repository.
- `git status --short`

---

## Module Status

| Module | File Path | Status | Tests |
|--------|-----------|--------|-------|
| Publisher directive | `Sources/RielaCore/RuntimePublication.swift` | NOT_STARTED | `Tests/RielaCoreTests/RuntimePublicationTests.swift` |
| Runner fanout dispatch | `Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift` | NOT_STARTED | New/focused RielaCore fanout tests |
| Runner dispatch integration | `Sources/RielaCore/DeterministicWorkflowRunner.swift` | NOT_STARTED | New/focused RielaCore fanout tests |
| Runtime variables join injection | `Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift` path audit, runner integration files as needed | NOT_STARTED | Prompt/runtime-variable fanout test |
| Capability gaps | `Sources/RielaCore/WorkflowRuntimeCapabilityGap.swift` | NOT_STARTED | `Tests/RielaCoreTests/WorkflowRunnerCapabilityPreflightTests.swift` |
| CLI concurrency diagnostics | `Sources/RielaCLI` | NOT_STARTED | Existing CLI/preflight tests if available |
| Fanout scenario fixtures | Existing workflow example/test fixture directories | NOT_STARTED | New deterministic scenario test |

## Dependencies

| Feature | Depends On | Status |
|---------|------------|--------|
| This plan | Accepted design review from Step 3 | Available |
| Publisher directive | Existing cross-workflow directive publication pattern | Available |
| Runner fanout dispatch | Existing `run()` recursion and cross-workflow dispatch structure | Available |
| Join prompt injection | Existing runtime-variable prompt merge path | Available |
| Capability downgrade | Supported ownership validation and fanout runtime implementation | Pending implementation |
| End-to-end proof | Publisher, runner, join injection, diagnostics, and fixture coverage | Pending implementation |

## Parallelizable Tasks

- T2 and the read-only portions of T5 may proceed in parallel after T1 because
  the write scopes are disjoint until capability tests are updated.
- T6 fixture drafting may proceed in parallel with T3 after the intended
  fanout contract is confirmed, but fixture execution depends on T3-T5.
- T3 and T4 are not parallelizable because both touch runner state flow and
  join continuation semantics.
- T5 test updates should wait for T2/T3 behavior to stabilize to avoid
  asserting an intermediate capability state.

## Completion Criteria

- [ ] Exactly this focused active implementation plan owns the bounded fanout
      join implementation slice; the older broad fanout-capabilities plan
      remains background roadmap only.
- [ ] `InMemoryWorkflowOutputPublisher` emits
      `WorkflowFanoutDispatchDirective` for supported live local fanout.
- [ ] `DeterministicWorkflowRunner` executes branch sub-paths with true bounded
      concurrency and deterministic input-order aggregation.
- [ ] `runtimeVariables.fanoutJoin` reaches the join step and includes ordered
      branch records plus `fanoutGroupRunId`.
- [ ] `fail-fast`, `collect-all`, `read-only`, `disjoint-paths`, and
      unsupported `isolated-workspace` behavior are tested.
- [ ] Capability preflight and CLI diagnostics no longer report supported
      fanout as unrunnable, while unsupported combinations remain explicit.
- [ ] New fanout scenario completes with exitCode 0.
- [ ] Existing non-fanout mock scenario still reports 29 node executions,
      28 transitions, and exitCode 0.
- [ ] Full build/test/lint and workflow validation commands are recorded in the
      progress log.
- [ ] No scratch artifacts are left outside
      `tmp/bounded-fanout-join-workflow-execution/`.

## Progress Log Expectations

Each implementation session must append a dated progress entry before handoff
that includes:

- Tasks completed and task ids.
- Files changed.
- Verification commands run with pass/fail status.
- Exact fanout and non-fanout scenario commands once fixture paths are known.
- Blockers, if any, tied back to accepted design sections.
- Any intentional divergence from the design, with reason and follow-up owner.

## Progress Log

### Session: 2026-07-16

**Tasks Completed**: Created implementation plan after Step 3 accepted the
design.
**Tasks In Progress**: None.
**Blockers**: None.
**Notes**: Step 3 reported no findings and no Codex-agent references. The plan
traces to `design-bounded-fanout-join-workflow-execution.md` and the fanout
schema clarifications in `design-workflow-json.md`.

## Related Plans

- **Background Roadmap**: `impl-plans/active/workflow-runtime-fanout-capabilities.md`
- **Detailed Progress Tracker**: `impl-plans/progress/plans/bounded-fanout-join-workflow-execution.json`
