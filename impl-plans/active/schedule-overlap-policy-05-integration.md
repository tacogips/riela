# Schedule Overlap Policy 05: Integration Verification and Index Implementation Plan

**planId**: `overlap-05-integration`
**Status**: Ready for implementation (wave 3, serial reconciliation)
**Workflow Mode**: issue-resolution
**Issue Reference**: none (no issueUrl or issueNumber). The intake came from
workflowInput.requestedBehavior via comm-008602 and comm-008603.
workflowExecutionId: `opus-luna-design-and-implement-review-loop-session-471`.
**Design Reference**: `design-docs/specs/design-scheduled-overlap-policy.md`
(accepted by Step 3, comm-008607): §5 (diagnostic texts), §14 (verification)
and §12 (docs).
**dependsOn**: none remaining in this checkpoint. overlap-01 to overlap-04 are
already accepted and committed: overlap-01/02/03 in `cd109008`, the
pre-existing CLI surface parity fix in `42b81cd4`, and overlap-04 in `3cd0c117`
(accepted by the session-472 integration review). They are listed under
`acceptedDependencies` in the dispatch manifest, so this plan runs against the
combined tree at HEAD.
**Branch**: `feat/schedule-overlap-policy`. Make no commits, run no git write
commands.
**Progress log**: `impl-plans/progress/overlap-05-integration.md`
**Evidence dir**: `tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/`

## Intent and Context

Wave 2 plans verified their slices while other plans were still editing the
same targets. This plan runs once, after all of them, and does three things:

1. Re-verifies the combined tree: one build, the union of the focused suites,
   lint, and an SDL drift check.
2. Runs the CLI smoke checks from design §14 against the built `riela` binary.
3. Adds the shared index entry for the feature to `impl-plans/README.md`. Only
   this serial plan edits that shared index.

## Non-Goals

- Do not edit any `Sources/` or `Tests/` file. If a combined check fails,
  record the failing command, the log path and the failing test names in
  the progress log, and report them. Repairs go back to the owning plan
  through the review loop.
- Do not run the full `swift test`. It is not a gate.
- Do not commit, push, archive plans, or move them to `completed/`.

## Tasks

### T1. Combined build and focused suites

Run V1-V3 below.

### T2. SDL drift check

Run V4. Re-running the generator must produce no diff in
`Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift`.

### T3. CLI smoke checks

All fixtures go under `tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/fixtures/`.
Each output goes to its own log.

- **S1 events, unknown value.**
  1. Copy `examples/event-sources/.riela-events` to `fixtures/events-bad`.
  2. Add `"overlapPolicy": "bogus"` to
     `bindings/cron-to-arithmetic.json`.
  3. Run `.build/debug/riela events validate --event-root <abs path>`.
  4. Expect `status=failed`, and output containing
     `overlapPolicy must be one of skip, cancelRunning, queue, concurrent; got 'bogus'`.
- **S2 events, no field.**
  1. Copy the unmodified events root to `fixtures/events-ok`.
  2. Run `events validate`.
  3. Expect `status=ok`, and a record
     `binding=cron-to-arithmetic overlapPolicy=inherit`.
- **S3 workflow, unknown value.**
  1. Copy `examples/first-four-arithmetic-pipeline` to
     `fixtures/workflows/first-four-arithmetic-pipeline`.
  2. Add `"triggerDefaults": {"overlapPolicy": "bogus"}` to its
     `workflow.json`.
  3. Run `.build/debug/riela workflow validate first-four-arithmetic-pipeline --workflow-definition-dir <abs fixtures/workflows>`.
  4. Expect a non-zero exit and a diagnostic at
     `workflow.triggerDefaults.overlapPolicy` with the message
     `must be one of skip, cancelRunning, queue, concurrent`.

  If `--workflow-definition-dir` expects the bundle directory itself rather
  than its parent, retry with the bundle path, and record which form worked.
- **S4 workflow inspect.** Use a valid fixture with
  `"triggerDefaults": {"overlapPolicy": "queue", "maxQueuedRuns": 2}`. Run
  `workflow inspect ... --output text`. Expect a line
  `triggerDefaults: overlapPolicy=queue maxQueuedRuns=2`.

Run every binary invocation as
`arch -arm64 /bin/zsh -lc '<cmd>' > <log> 2>&1`. Record its exit status.

### T4. Index entry

Add a short paragraph to the Active Plans section of `impl-plans/README.md`.
It must name the feature, the design path, the five plan paths, and the
dispatch manifest
`impl-plans/active/schedule-overlap-policy-20261021-session-471-dispatch.json`.
Before editing, read the file fresh and record its hash. Edit only that
paragraph.

## Verification

```text
V0: mkdir -p tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/fixtures
V1: arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v1-build.log 2>&1
V2: arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "EventOverlapPolicyTests|EventOverlapContractValidationTests|RoutineStoreTests|EventRoutineBindingTests|EventDryRunTests|WorkflowLoopValidationTests"' > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v2-core-events.log 2>&1
V3: arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "EventCronOverlapTests|EventLiveServe|EventReadOnlyPolicyTests|OverlapPolicyInspectionTests|RoutineCommandTests|RoutineGraphQLTests|RoutineAddonTests|SurfaceParity|WorkflowCommandLivePersistenceEventTests"' > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v3-cli-graphql.log 2>&1
V4: git hash-object Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v4-sdl-hash-before.txt && scripts/surface-parity/generate-sdl.sh > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v4-sdl.log 2>&1 && git hash-object Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v4-sdl-hash-after.txt && cmp tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v4-sdl-hash-before.txt tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v4-sdl-hash-after.txt
V5: arch -arm64 /bin/zsh -lc 'git diff --name-only -z 3e6d4adf HEAD -- "*.swift" | xargs -0 swiftlint lint --strict' > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v5-lint.log 2>&1
V6: smoke checks S1-S4 (logs: tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/s1.log … s4.log)
V7: git diff --check > tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/v7-diff-check.log 2>&1
```

V4 note: when this plan runs, the regenerated SDL is still uncommitted
working-tree content, so `git diff --exit-code` against HEAD would be
non-zero because of `overlap-04`'s regeneration. V4 therefore hashes the
file before and after re-running the generator and requires the hashes to
be equal. Record both hashes.

Expected results:

- V1: exit 0.
- V2 and V3: exit 0, `testsRun > 0`, 0 failures.
- V4: the generator exits 0, and the SDL file hash is unchanged by the
  re-run.
- V5: exit 0. If baseline violations exist in untouched files, record them
  separately from the touched-file results.
- V6: the expectations listed in T3.
- V7: exit 0.

For each command, record an integer `exitStatus`, `testsRun`, `failureCount`
and `logPath`.

## Acceptance Criteria

1. V1-V7 records are in the progress log, with integer fields and log paths.
2. S1-S4 outputs contain the exact expected strings. Paste them into the
   progress log.
3. `grep -n "schedule-overlap-policy" impl-plans/README.md` matches.
4. No file outside `impl-plans/README.md`, the progress log and
   `tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration/` was modified by this plan.
   Check with `git status --short` before and after, and record both.

## Progress Log Expectations

`impl-plans/progress/overlap-05-integration.md` must contain:

- a task checklist;
- the V1-V7 records;
- the S1-S4 evidence excerpts;
- the README pre and post hashes;
- a list of failures handed back to owning plans, empty if none;
- residual notes. They must not start with a severity word.

## Operator amendment (2026-10-22, before rerun session-473 → next)

- V5 is now selected-file SwiftLint over every Swift file changed since `main` @ `3e6d4adf` (33 files, all from overlap-01..04 and the parity fix). The operator ran it on HEAD `a13864ed`: exit 0, no diagnostics.
- Repo-wide `swiftlint lint --strict` exits 2 with 30 diagnostics. All of them are in files this feature does not touch (for example EventLiveServe+FileChange.swift, DeterministicWorkflowRunner+History.swift and Apple*AddonTests). They also exist on `main`. Record them as inherited baseline only; they do not gate this plan.
- Do NOT create mirror/export trees (e.g. a `lint-baseline/` checkout) under `tmp/schedule-overlap-policy-20261021-session-471/overlap-05-integration`. The fanout source snapshot is capped at 512 entries, and the previous attempt failed at 513 because of one. Keep evidence to flat log/JSON files.
- The uncommitted `impl-plans/README.md` index entry and `impl-plans/progress/overlap-05-integration.md` come from the previous attempt (S1-S4 smoke checks passed). Re-verify them and reuse them instead of starting over.

