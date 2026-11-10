# Issue 188 Plan 04: Step supervisor (deadline, retry loop, dispatch guard, diagnostics)

**Status**: Ready
**planId**: issue188-04-step-supervisor
**dependsOn**: issue188-01-core-contract
**Design Reference**: design-docs/specs/design-step-deadline-and-retry-policy.md §3.1, §3.2, §3.3, §4, §5.1, §5.2, §5.4, §7, §10
**Issue**: tacogips/riela#188
**Created**: 2026-11-10
**Last Updated**: 2026-11-10

## Intent and context

Today `executeAddonAndPublish` (`Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift:5-153`) runs these steps once, in order:
1. attachment projection (lines 18–24);
2. `recordStepStartedExecution` (line 32);
3. `executePlacedAddon` with `deadline(for:)` (lines 76–83);
4. publish.

The runner never enforces the deadline. This plan adds a **supervised path** for a step that authors `deadlineMs` or `retry`, implementing the accepted design. A step authoring neither keeps today's code byte-for-byte.

## Non-goals

- No fanout changes. Plan 05 handles the expiry of unscheduled branches and sets `runStartedAt` for branches.
- No Notion parsing (plan 03).
- No validation (plan 02).
- No stdio or agent steps; the supervised path is only in the add-on executor.
- No change to the semantics of `publishFailureAndThrow`, `publishAdvisoryFailure`, `RuntimePublication.swift` or advisory routing.
- No change to `deadline(for:)` in `DeterministicWorkflowRunner+Prompting.swift`.
- Do not refactor `RielaAdapters.executeWithRetry`.

## File-level changes

### Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift
- At the top of `executeAddonAndPublish`, add: `if step.deadlineMs != nil || step.retry != nil { return try await executeSupervisedAddonAndPublish(...same args...) }`.
- Nothing else in this file changes.
- `retryPredecessorExecutionIds` and `projectedAddonAttachments` are currently `private`. Change them to `fileprivate`→internal **only if** the new file needs them, and call them without changing their behaviour.

### Sources/RielaCore/DeterministicWorkflowRunner+StepSupervisor.swift (new)

The function is `func executeSupervisedAddonAndPublish(addon:session:sessionId:workflow:step:resolvedInputPayload:transitions:request:executionIndex:) async throws -> WorkflowPublicationResult`.

**Ordering, as in design §5.1:**

1. **readyAt.**
   - `runStartedAt = request.runStartedAt ?? retryClock.now()`.
   - `inputReadyAt` comes from `store.listMessages(for: sessionId, toStepId: step.id)`. Take the record whose `communicationId` equals `resolvedInputPayload["_rielaInput"]["latest"]["communicationId"]`, and use its `createdAt`. If there is no match, use the max `createdAt` of the returned records. If there are no records, use nil.
   - `readyAt = max(inputReadyAt ?? runStartedAt, runStartedAt)`.
   - `stepDeadline = readyAt + deadlineMs`. `retry` requires `deadlineMs` (plan 02). If `deadlineMs` is nil only because validation was bypassed, treat it as no step deadline but still bound attempts by `maxAttempts`.
2. **Dispatch guard #1.** If `now >= stepDeadline`:
   - call `recordStepStartedExecution`;
   - publish the failure `AdapterExecutionError(.timeout, "<addon> step deadline exceeded before dispatch" + suffix(attempts:0, stopReason:.stepDeadline, timeoutKind:.stepDeadline, queueWaitMs:...))`;
   - make no adapter call (design case 9a).
3. `recordStepStartedExecution`, the same arguments as Addons.swift lines 32–43. It is not supervised. Measure its duration as `recordStartedDurationMs`.
4. **Supervised region.** Start an unstructured child `Task` that runs, in order:
   1. projection, via the same `projectedAddonAttachments` call;
   2. building `WorkflowAddonExecutionInput`, identical to lines 44–75, with the same `operationExecutionId` for every attempt;
   3. the attempt loop.
5. **The supervisor.** Implement it with `withCheckedThrowingContinuation` plus a lock-protected once-flag. It resumes on the **first** of:
   - the region's final result;
   - the step-deadline timer: a `Task` running `retryClock.sleep(until: stepDeadline + backstopGraceMs)`;
   - the current attempt's backstop timer at `min(attemptDeadline, stepDeadline) + backstopGraceMs`, for the **current** attempt only. Its lifecycle:
     - The region reports `attemptStarted(attempt:attemptDeadline:)` and `attemptEnded(attempt:)` through lock-protected callbacks. Report the end on success, on a thrown error, and before any backoff sleep.
     - On `attemptStarted`, the supervisor **cancels any previous attempt timer**. It then arms a new one tagged with the attempt number and sets `inFlightAttempt = attempt`.
     - On `attemptEnded`, it cancels that timer and sets `inFlightAttempt = nil`.
     - When a timer fires, under the lock: if its tag differs from `inFlightAttempt`, or no attempt is in flight, the fire is **stale and ignored**. It does not expire the step. Only a matching fire acts as the runner backstop.
     - The step-deadline timer is separate and stays armed for the whole region.
     - Pitfall: arming on start alone, without disarm or replace, lets an attempt-1 timer fire during backoff or attempt 2 and turns a retryable step into a `runner-backstop`/`unknown` failure (test 18);
   - parent cancellation, through `withTaskCancellationHandler`.

   On a timer or a cancellation:
   - set the shared `expired` flag (a lock-protected box captured by the child);
   - cancel the child and all timers;
   - **do not await the child.**

   **Never use `withThrowingTaskGroup` for this race.** A task group awaits its children, so a non-cooperative projection or adapter would hang the step. That is the exact bug this design fixes.
6. **Attempt loop**, inside the child:
   - **Dispatch guard**, immediately before each `executePlacedAddon`: `!expired && !Task.isCancelled && now < stepDeadline && now < attemptDeadline`. If it fails, end with `stopReason=.stepDeadline` and make no call.
   - `attemptDeadline = min(now + effectiveTimeoutMs, stepDeadline)`, where `effectiveTimeoutMs = request.timeoutMs ?? step.timeoutMs ?? request.defaultTimeoutMs ?? request.workflow.defaults.nodeTimeoutMs`. That is the same precedence as `deadline(for:)`. If it is `<= 0`, use `stepDeadline`.
   - Pass `attemptDeadline` as `AdapterExecutionContext.deadline`. Build the context with the existing `adapterExecutionContext(deadline:workflowId:step:execution:eventContext:handler:)`.
   - **Success** → return the output to the supervisor.
   - **`CancellationError`** / `isWorkflowRunCancellation` → rethrow.
   - **`AdapterExecutionError`** → decide, in this order:
     1. `effectOutcome == .unknown` → stop `.outcomeUnknown`;
     2. `isRetryable != true` → `.nonRetryable`;
     3. `attempt >= maxAttempts` → `.retryExhausted`. Without `retry`, `maxAttempts` is 1;
     4. otherwise compute `delay = StepRetryBackoff.delayMs(...)`. If `retryAfter` is set, `delay = max(delay, retryAfterMs)`. If `retryAfterMs > effectiveMaxDelayMs` → stop `.retryAfterExceedsMaxDelay`;
     5. if `now + delay >= stepDeadline` → stop `.deadlineExhausted` **without sleeping**;
     6. otherwise `try await retryClock.sleep(until: now + delay)` and loop.
   - Any other error → wrap it exactly as today (`.providerError`, `String(describing:)`), which makes it non-retryable.
7. **Outcome handling by the supervisor.**
   - **Success received before expiry** → publish through the existing `publisher.publishAcceptedOutput(...)` block, copied from Addons.swift lines 124–152, including `checkpointNestedEffectCompletion`. If `now > stepDeadline` after publication, record the backend event `riela.step.deadline.exceededAfterSuccess`.
   - **Child failure** → append `StepRetryDiagnostics.suffix(...)` to the error's `message`, keeping code, isRetryable and effectOutcome. Then follow the same branch as Addons.swift lines 84–100: advisory → `publishAdvisoryFailure`, otherwise `publishFailureAndThrow`.
   - **Backstop or step-deadline expiry while an attempt is in flight** → `AdapterExecutionError(.timeout, "<addon> exceeded its step deadline" or "...attempt timeout", effectOutcome: .unknown, isRetryable: false)` with suffix `timeoutKind`. Record `timeoutSource=runner-backstop` on the attempt event.
   - **Expiry during projection or backoff** → `.timeout`, `timeoutKind=.stepDeadline`, `effectOutcome` nil. `attempts` is the number of attempts finished so far.
   - **Cancellation** → record a `riela.step.retry.stopped` event with `stopReason=cancelled`, then rethrow the `CancellationError`. The existing cancellation path finalises the execution, so do **not** publish success.
   - **A late child result after expiry** is ignored. The once-flag guarantees this. The child never calls publisher methods.
8. **Diagnostics** (design §7).
   - Use `store.recordStepBackendEventReceipt(WorkflowStepBackendEventInput(...))`, imitating `DeterministicWorkflowRunner+ExecutionEvents.swift:adapterExecutionContext`, so the runtime store owns the records. Then forward to `request.eventHandler`, also as that function does.
   - Event `riela.step.attempt.finished` metadata: `attempt`, `maxAttempts`, `attemptDurationMs`, `outcome`, `errorCode`, `retryable`, `effectOutcome`, `timeoutKind`, `timeoutSource`, `retryAfterMs`, `nextDelayMs`, `elapsedMs`, `budgetRemainingMs`, and on attempt 1 also `queueWaitMs` and `recordStartedDurationMs`.
   - Event `riela.step.retry.stopped`: `attempts`, `stopReason`, `elapsedMs`.
   - After publication, emit telemetry log `riela.step.publication.duration` with `durationMs` and `exceededDeadline`, imitating the `telemetry.recordLog` call in `DeterministicWorkflowRunner+Addons.swift:reportSkippedAddonFinalization`. Check the telemetry redactor allowlist in `Sources/RielaObservability` and use allowlisted attribute keys, or accept their redaction; never put session ids in new keys.

### Tests/RielaCoreTests/StepRetryPolicyTests.swift (new)

- Use `ManualWorkflowRetryClock` from plan 01 (`Tests/RielaCoreTests/ManualWorkflowRetryClock.swift`). Do not edit it; if it is missing a capability, report that in the progress log.
- Imitate the runner construction in `Tests/RielaCoreTests/WorkflowStepFailurePolicyTests.swift:RunnerFailurePolicyTests` (`runner(...)`, `request(...)` helpers), but with an add-on node and a scripted `WorkflowAddonResolving` fake. The fake returns or throws a scripted sequence per call, counts calls, and can block, either cooperatively on the fake clock or non-cooperatively on a semaphore-like gate that ignores cancellation.
- Use an in-memory store whose `WorkflowRuntimeClock` reads the same fake time, so message `createdAt` and `retryClock.now()` agree.
- For projection tests, inject a blocking fake `WorkflowAddonAttachmentProjecting` through the runner's `attachmentProjector` init param.

## Invariants

- No `deadlineMs`/`retry` → the identical code path runs: one call, `deadline(for:)`, no supervisor, and today's projection order (design §10 case 10).
- The supervisor is the only publisher. At most one outcome is published per step dispatch.
- `operationExecutionId` and `executionIdentity` are the same across attempts. There is one step execution record per dispatch.
- No real sleeps in tests. Every wait goes through the fake clock (`waitForSleepers` and `advance`).

## Test cases (situation → expected)

1. A non-cooperative adapter blocks forever with `deadlineMs:1000` → after `advance` past 1000+5000 the step fails with `.timeout`, `effectOutcome=unknown`, and calls=1. The test returns while the adapter is still blocked.
2. 429 retryable (`retryAfter` 3 s) then success, `retry{maxAttempts:3, initialDelayMs:1000}` → calls=2, the sleep target is now+3000, the step is completed, and there are two `attempt.finished` events plus a stopped event with `succeeded`.
3. Retryable failures where the next delay crosses `stepDeadline` → `deadline-exhausted`, and no sleeper is registered.
4. Cancel the parent task while in backoff → the execution is not completed, the stopped event says `cancelled`, and `CancellationError` propagates.
5. An error with `effectOutcome=.unknown` and `isRetryable=true` → calls=1 and `outcome-unknown` (the generic path for design case 6).
6. `isRetryable=false` (permanent) → calls=1 and `non-retryable` (design case 7).
7. `retryAfter` 120 s with `maxDelayMs` 60000 → calls=1 and `retry-after-exceeds-max-delay` (design case 8).
8. Retryable on every call with `maxAttempts:3` → calls=3 and `retry-exhausted`. The failure message ends with `[rielaRetry attempts=3 stopReason=retry-exhausted ...]`.
9. A cooperative slow add-on (json-route stand-in) sleeping on the fake clock past the deadline → `timeoutKind=step-deadline`, not completed.
10. 9a: advance the fake clock past `readyAt+deadlineMs` before the step dispatches. For example, a previous step's input message `createdAt` is old and `runStartedAt` is older too → fails with `attempts=0`, calls=0, `queueWaitMs` present.
11. 12: a projector blocks forever and ignores cancellation → a `step-deadline` failure is published at 1000+5000, and the projector is never released.
12. 13: same as 11, then release the projector after expiry → adapter calls stay 0, and the published failed record is unchanged (re-load the session and compare).
13. 15: collect-partial fanout whose branch has a save step (`failurePolicy` omitted, `deadlineMs`, adapter throws `effectOutcome=.unknown`) then a downstream step → the join record has `status:"failed"`, contains the item, and its `failureReason` contains `[rielaRetry`. The downstream step never ran. Control: the same branch with `failurePolicy:"advisory"` → `completed`, today's behaviour.
14. 16a: success returned before expiry while the publication store write is slow (a store wrapper delays `publishAcceptedOutput` past the deadline using the fake clock) → completed, and the `exceededAfterSuccess` event is present.
15. 16b: success returned after the backstop → discarded, and the recorded failure has `effectOutcome=unknown`.
16. Backward compatibility: a step with no new fields → adapter `context.deadline` equals today's `deadline(for:)` value (±1 ms), calls=1, and no `riela.step.*` events.
17. A resumed or new run anchors `readyAt` at the new `runStartedAt` even when the message `createdAt` is old.
18. **Stale backstop ignored.** Settings: `retry{maxAttempts:3, initialDelayMs:8000, maxDelayMs:8000}`, `timeoutMs:2000`, `deadlineMs:600000`.
    - Attempt 1 throws retryable at t+1 s, so the attempt-1 backstop instant is t+0+2000+5000 = t+7 s.
    - Backoff of 8 s, so attempt 2 starts at t+9 s.
    - Attempt 2 is cooperative on the fake clock and succeeds at its start+1.5 s.
    - Advance the fake clock step by step across t+7 s during backoff, then through attempt 2.
    - Expect: completed, calls=2, no `timeoutSource=runner-backstop` in any `attempt.finished` event, and no step-deadline failure.

## Verification (each must exit 0)

1. `mkdir -p tmp/issue-188 && arch -arm64 /bin/zsh -lc 'swift test --filter StepRetryPolicyTests 2>&1 | tee tmp/issue-188/p04-test.log; exit ${pipestatus[1]}'` — every case passes. Run it 3 times and record all 3 log paths (`p04-test-run{1,2,3}.log`) to show determinism.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "RunnerFailurePolicyTests|RunnerNonTerminalStepFailureTests|DeterministicWorkflowRunnerFanoutTests|FanoutFailedBranchStepOutputsTests" 2>&1 | tee tmp/issue-188/p04-regression.log; exit ${pipestatus[1]}'` — no regression.

If a compile error comes only from a sibling plan's writePaths (plans 03 and 05 in the same wave), record it as `sibling-blocked` and re-run after the sibling finishes. Never edit sibling files.
3. `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCore/DeterministicWorkflowRunner+StepSupervisor.swift Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift Tests/RielaCoreTests/StepRetryPolicyTests.swift 2>&1 | tee tmp/issue-188/p04-lint.log; exit ${pipestatus[1]}'`. If file or function length rules trip, split helpers into the same new file. Do not disable rules.

## Edit safety

- Re-read before each edit, and record pre- and post-edit sha256.
- `DeterministicWorkflowRunner+Addons.swift` is owned only by this plan. `DeterministicWorkflowRunner.swift` (plan 01) and `DeterministicWorkflowRunner+Fanout.swift` (plan 05) are read-only here.

## Completion criteria

- [ ] Supervised path implemented per the ordering above.
- [ ] All 18 test cases pass in 3 consecutive runs.
- [ ] Verification 1–3 exit 0, with log paths recorded.
- [ ] Only writePaths and this plan file are changed.

## Progress Log

### Session: 2026-11-10
**Tasks Completed**: Plan authored (Opus).
**Blockers**: Waits for issue188-01.
