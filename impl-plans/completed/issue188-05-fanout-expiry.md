# Issue 188 Plan 05: Fanout dispatch anchor and expiry of unscheduled branches

**Status**: Completed (2026-11-10; accepted by step7 adversarial review comm-000100 and combined-tree integration, issue #188)
**planId**: issue188-05-fanout-expiry
**dependsOn**: issue188-01-core-contract (needs `DeterministicWorkflowRunRequest.runStartedAt`, `retryClock`, `StepRetryDiagnostics`)
**Design Reference**: design-docs/specs/design-step-deadline-and-retry-policy.md §3.1 (anchor, fanout slot wait), §5.3, §10 case 14
**Issue**: tacogips/riela#188
**Created**: 2026-11-10
**Last Updated**: 2026-11-10

## Intent and context

`runFanoutBranches` (`Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift:179-222`) schedules the next branch only after an outcome arrives, so a queued item can wait without limit while every slot is busy. A save job's deadline must cover that wait.

This plan does two things:
1. It anchors every branch at the fanout **dispatch** time, through `branchRequest.runStartedAt`.
2. It adds an expiry timer that resolves unscheduled indices as failed branch records once `dispatchAt + deadlineMs` passes. The timer is active only when the branch entry step authors `deadlineMs`.

## Non-goals

- No change to running branches, slot release, fail-fast semantics or join payload shapes, beyond adding new failure records of the existing shape.
- No supervisor work (plan 04).
- **Cross-workflow fanout** (`directive.workflowId != nil`): no active expiry timer, because the callee is resolved inside each branch and resolving it up-front would change error timing for existing workflows. Those branches still get `runStartedAt = dispatchAt`, so plan 04's dispatch guard fails an expired branch with `attempts=0` when it starts (elapsed accounting). Record this limitation in the progress log.

## File-level changes

### Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift

1. **Dispatch time.** In `dispatchFanout`, before any scheduling, capture `let fanoutDispatchAt = retryClock.now()` once per dispatch and pass it into `runFanoutBranches` and `runFanoutBranch`. Pitfall: in a wave-based dispatch (`wave.selectedIndices`, line ~69), capture it once per `dispatchFanout` call, not once per branch.
2. **Anchor.** In `runFanoutBranch`, after `var branchRequest = DeterministicWorkflowRunRequest(...)` (line ~288) and next to `branchRequest.workflowRunId = ...`, set `branchRequest.runStartedAt = fanoutDispatchAt`.
3. **Expiry timer**, in `runFanoutBranches`, only when `directive.workflowId == nil` and `request.workflow.steps.first { $0.id == directive.targetStepId }?.deadlineMs` is non-nil.
   - `expiresAt = fanoutDispatchAt + deadlineMs`. All pending indices share one dispatch time, so they share one `expiresAt`.
   - Change the group's element type to a small private enum with `branch(FanoutBranchOutcome)` and `expiryTick` cases. Add one timer child, `try await retryClock.sleep(until: expiresAt); return .expiryTick`.
   - On `.expiryTick`: every remaining unscheduled index (from `nextIndex` to the end of `indices`) becomes:
     `FanoutBranchOutcome.failure(index:, item:, sessionId: nil, reason: "branch not started before deadline" + StepRetryDiagnostics.suffix(attempts: 0, stopReason: .stepDeadline, elapsedMs: <now-dispatchAt>, timeoutKind: .stepDeadline, effectOutcome: nil, queueWaitMs: <now-dispatchAt>), cancelled: false)`.
     Then set `nextIndex = indices.count`. Running branches continue.
   - In `scheduleNext()`, check: if the timer is active and `retryClock.now() >= expiresAt`, append the failure outcome above instead of scheduling. This covers a slot that frees at the same instant the deadline passes.
   - When all branches have finished before expiry, cancel the timer child so the group can finish. A `CancellationError` from the timer's own cancellation must be swallowed, **not** propagated as a workflow cancellation. With `fail-fast`, the existing `group.cancelAll()` also cancels the timer, and its cancellation must not be turned into a failure.
   - With no deadline, the group must behave exactly as today. Keeping the enum wrapper is fine, but there must be no timer child and no extra outcomes.
4. Pitfall: `outcomes` must contain exactly one record per selected index. Assert in tests that the join has `indices.count` records with no duplicates.

### Tests/RielaCoreTests/StepDeadlineFanoutExpiryTests.swift (new)

- Imitate `Tests/RielaCoreTests/DeterministicWorkflowRunnerFanoutTests.swift` for the fanout workflow setup and the collect-partial join assertions.
- Use `ManualWorkflowRetryClock` (plan 01) and inject it through `DeterministicWorkflowRunner(retryClock:)`.
- Use a fake add-on resolver whose downstream branch step can be blocked on a gate.

## Invariants

- Fanouts whose entry step has no `deadlineMs` schedule exactly as before: same order, same concurrency, same join content.
- Occupied slots are never released early, and running branches are never cancelled by the expiry timer.
- Join record shape is unchanged. Expired records use the existing `failure(...)` constructor.

## Test cases (situation → expected)

- 14: collect-partial with concurrency 1 and 3 items. The entry step (an add-on) has `deadlineMs:1000`. Branch 0's entry step succeeds, then its next step blocks on a gate.
  - Advance the fake clock to dispatch+1000: items 1 and 2 are recorded as failed with `status:"failed"`, the original `item`, `failureReason` containing `stopReason=step-deadline` and `attempts=0`, and no `sessionId`.
  - Branch-session count is 1, and branch 0 is still running.
  - Release the gate: the join completes with 3 records and branch 0 `completed`.
- **Anchor test (integration-gated; requires issue188-04).** Name it `testBranchEntryDeadlineAnchoredAtFanoutDispatch`.
  - Setup: concurrency 1, 2 items, entry add-on step with `deadlineMs:1000` and **no** `timeoutMs`. Set `defaults.nodeTimeoutMs` to a value at or below 0, or large enough not to bind.
  - Branch 0's second step is gated and released at fake t=dispatchAt+400.
  - Branch 1's fake add-on captures the `context.deadline` it receives.
  - Expect the captured deadline `== dispatchAt + 1000`, **not** `dispatchAt + 400 + 1000`.
  - This observable exists only after plan 04's supervisor passes `min(attemptDeadline, stepDeadline)` as `context.deadline`. If plan 04 has not landed when this worker runs, the test is still written exactly as specified, the progress log records it as `integration-pending`, and the integration filter (which includes `StepDeadlineFanoutExpiryTests`) is the gate. **Do not weaken or skip-flag the assertion.** Do not add runner hooks.
  - All other tests in this file depend only on plans 01 and 05.
- No-deadline control: the same fanout without `deadlineMs` → 3 completed records, identical to the pre-change join (compare to a run of the same fixture without the timer).
- All branches finish before the deadline → the join completes promptly, and no leftover sleeper remains on the fake clock (`waitForSleepers(count:0)` or an equivalent check).
- fail-fast plus deadline → the existing fail-fast behaviour is unchanged, and the timer's cancellation is not reported as a workflow cancellation.

## Verification (each must exit 0)

1. `mkdir -p tmp/issue-188 && arch -arm64 /bin/zsh -lc 'swift test --filter "StepDeadlineFanoutExpiryTests/(?!testBranchEntryDeadlineAnchoredAtFanoutDispatch)" 2>&1 | tee tmp/issue-188/p05-test.log; exit ${pipestatus[1]}'`.
   - Run it 3 times and record each log as `p05-test-run{1,2,3}.log`.
   - If XCTest's filter does not accept the negative lookahead, run the full `StepDeadlineFanoutExpiryTests` class instead. In that case only the anchor test may fail before plan 04 lands; record its failure as `integration-pending`.
   - If plan 04 is already present, the anchor test must pass.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "DeterministicWorkflowRunnerFanoutTests|FanoutResumeTests|FanoutFailedBranchStepOutputsTests|WorkflowFanoutMapReduceTests|WorkflowFanoutObservationBoundTests|FanoutArtifactEvidenceRunnerTests" 2>&1 | tee tmp/issue-188/p05-regression.log; exit ${pipestatus[1]}'` — no fanout regression. `FanoutResumeTests` is the class inside `DeterministicWorkflowRunnerFanoutResumeTests.swift`; check that the log shows it ran.
- The anchor test's final gate is the integration filter run, which must show it passing.
- If a compile error comes only from a sibling plan's writePaths, record it as `sibling-blocked` and re-run later. Never edit sibling files.
3. `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift Tests/RielaCoreTests/StepDeadlineFanoutExpiryTests.swift 2>&1 | tee tmp/issue-188/p05-lint.log; exit ${pipestatus[1]}'`

## Edit safety

- Re-read before each edit, and record pre- and post-edit sha256.
- `DeterministicWorkflowRunner+Fanout.swift` is owned only by this plan.
- On drift, re-apply only the three numbered changes.

## Completion criteria

- [x] Dispatch anchor and expiry timer implemented, scoped to local fanout with an entry `deadlineMs`.
- [x] All non-anchor tests pass in 3 consecutive runs. The anchor test passes, or is logged `integration-pending` when plan 04 is absent, and must pass at integration.
- [x] Verification 1–3 exit 0, with log paths recorded.
- [x] Cross-workflow limitation noted in the progress log.

## Progress Log

### Session: 2026-11-10
**Tasks Completed**: Plan authored (Opus).
**Blockers**: Waits for issue188-01.

### Implementation progress: 2026-11-10

- Captured one retry-clock dispatch instant and passed it into each branch request. Local entry deadlines expire unscheduled indices; running branches are left alone. Timer cancellation is absorbed by the timer child.
- Cross-workflow fanouts do not actively expire queued branches; they receive the dispatch anchor for elapsed accounting when started.
- `StepDeadlineFanoutExpiryTests` covers queued expiry, session count, original items and unique indices, no-deadline join equivalence, timer cleanup and fail-fast. The two-item dispatch-anchor assertion is written without skipping and is integration-pending on plan 04; the fake retry and runtime-store clocks share the same start.
- Final focused runs `tmp/issue-188/issue188-05-fanout-expiry/clock-test-{1,2,3}.log` each passed 3 tests. `clock-regression.log` passed 66 tests including `FanoutResumeTests`. `clock-lint.log` (strict changed-file gate) and `plan-lint.log` exited 0. Earlier build interruptions from concurrent sibling edits and an intermediate test failure remain in the evidence directory; both were rerun successfully. All tests ran on a moving shared tree; serial integration must rerun the union filter, including the anchor test, full build and lint.

### Current implementation verification: 2026-11-10

- Fresh non-anchor runs `current-test-1.log`, `current-test-2.log`, and `current-test-3-retry.log` each passed 3 tests; `current-anchor.log` passed the unskipped dispatch-anchor test. Logs are under `tmp/issue-188/issue188-05-fanout-expiry/`.
- `current-regression.log` passed 66 tests, including `FanoutResumeTests`; `current-strict-lint.log` and `current-plan-lint.log` exited 0. A sibling-owned test temporarily failed compilation in `current-test-3.log`; the sibling correction preceded the successful retry. These runs used the moving shared tree.
- Formal review and serial integration remain downstream; integration must rerun the full build, union filter including the anchor, and lint. Queued cross-workflow branches remain elapsed-accounted only.
