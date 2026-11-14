# Issue 188 Plan 04: Step supervisor (deadline, retry loop, dispatch guard, diagnostics)

**Status**: Completed (2026-11-10; amended in blocked-wave-scope-or-contract round 1, see the Amendment section; accepted by step7 adversarial review comm-000101 and combined-tree integration, issue #188)
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

- [x] Supervised path implemented per the ordering above.
- [x] All 18 test cases pass in 3 consecutive runs.
- [x] Verification 1–3 exit 0, with log paths recorded.
- [x] Only writePaths and this plan file are changed.

## Amendment 2026-11-10 (blocked-wave-scope-or-contract, round 1)

Source: `checkpointAmendment` (round 0 → this is amendment round 1 of max 2), summary `tmp/opus-terra-waves/opus-terra-design-and-implement-review-loop-session-3/wave-001/wave-summary.json`. Blocker: the runtime store drops the metadata of the design §7 `riela.step.*` events (`WorkflowFailureDiagnostics.retainedEventMetadata`, `Sources/RielaCore/WorkflowFailureDiagnostics.swift:178`) and ignores every backend event once an execution is terminal (`InMemoryWorkflowRuntimeStore.recordStepBackendEventReceiptLocked`, `Sources/RielaCore/RuntimeStore.swift:681`). That makes test cases 2, 4 and 14 (`testRetryAfterRaisesBackoffAndRecordsAttempts`, `testCancellationDuringBackoffStopsWithoutAnotherDispatch`, `testSuccessfulEffectIsPublishedAfterSlowPublicationCrossesDeadline`) unpassable. Evidence: `tmp/issue-188/issue188-04-step-supervisor/cont1-test-attempt2.log` (exit 1, 20 tests, 3 failures).

This amendment is additive. It does not redesign: design §7 already requires these events to be runtime-store-owned evidence, and design §5.1/§7 already require `exceededAfterSuccess` after a published success. No other plan is changed.

### Decision A: authorized extra write paths (plan 04 only, exact files)
- `Sources/RielaCore/WorkflowFailureDiagnostics.swift`: bounded retention of step-retry event metadata.
- `Sources/RielaCore/RuntimeStore.swift`: one post-terminal event, limited to `riela.step.deadline.exceededAfterSuccess`.
- `Tests/RielaCoreTests/StepRetryEventRetentionTests.swift` (new): in-memory store tests.
- `Tests/RielaCLITests/StepRetryEventSQLitePersistenceTests.swift` (new): SQLite fail-closed store round-trip test.

No other plan in issue 188 owns these files. Plans 01, 02, 03, 05 and 06 are accepted and must not be touched. `Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift`, `Sources/RielaCore/RuntimeSession.swift`, `Sources/RielaCore/RuntimeStorePublicationTransactions.swift`, `Tests/RielaCoreTests/RuntimeStoreTests.swift` and `Tests/RielaAdaptersTests/CommandFailureDiagnosticsCaptureTests.swift` stay **read-only**. The fail-closed store needs no change, because its `recordStepBackendEventReceipt` already calls `persist(sessionId:)` after the backing in-memory call.

### Decision B: additive contract for metadata retention (`WorkflowFailureDiagnostics.swift`)
- Keep the `command_failure_diagnostics` branch of `retainedEventMetadata(eventType:metadata:)` byte-identical: same shape checks, same `eventMetadataByteLimit`.
- Add one dispatch at the top. If `eventType` is one of the three step-retry event types, return `retainedStepRetryEventMetadata(eventType:metadata:)`, a new `private static` function in the same file. Every other event type still returns nil.
- Add `public static let stepRetryEventTypes: Set<String> = ["riela.step.attempt.finished", "riela.step.retry.stopped", "riela.step.deadline.exceededAfterSuccess"]` and `public static let stepRetryEventMetadataByteLimit = 1_024`.
- Value rules apply to every key. Use a closed, typed allowlist; drop the whole object (return nil) on any violation. Never strip only the offending key.
  - Duration and count integers must be `.integer`; `.double` and `.string` are rejected. Range is `0...1_000_000_000_000`, and `attempt`/`attempts`/`maxAttempts` use `0...1_000`.
  - Booleans must be `.bool`.
  - Strings must be members of the closed sets below, built from the existing raw values. Do not hand-copy strings that already exist as enum raw values.
- `riela.step.attempt.finished`.
  - Required keys: `attempt` and `outcome`.
  - Allowed integer keys: `attempt`, `maxAttempts`, `attemptDurationMs`, `elapsedMs`, `budgetRemainingMs`, `queueWaitMs`, `recordStartedDurationMs`, `retryAfterMs`, `nextDelayMs`.
  - Allowed `.bool` key: `retryable`.
  - Allowed string keys and their values:
    - `outcome` ∈ {`succeeded`, `failed`};
    - `errorCode` ∈ `AdapterExecutionErrorCode` raw values;
    - `effectOutcome` ∈ `AdapterEffectOutcome` raw values;
    - `timeoutKind` ∈ `StepTimeoutKind` raw values;
    - `timeoutSource` ∈ {`adapter`, `runner-backstop`}.
- `riela.step.retry.stopped`.
  - Required keys: `attempts` and `stopReason`.
  - Allowed keys: `attempts` (integer), `elapsedMs` (integer), and `stopReason` ∈ `StepRetryStopReason` raw values (`succeeded` and `cancelled` are already cases).
- `riela.step.deadline.exceededAfterSuccess`.
  - nil metadata stays nil.
  - Otherwise the allowed keys are `elapsedMs` and `overrunMs` (integers), and none is required.
- After validation, encode with `JSONEncoder` and reject anything over `stepRetryEventMetadataByteLimit` bytes.
- Pitfalls:
  - Do not loosen the command-diagnostics rules.
  - Do not accept free strings: the adapter error *message* must never enter metadata.
  - Do not add session or execution ids.
  - Do not change `eventMetadata(exitCode:diagnostics:)`.
- Supervisor alignment (own file, `DeterministicWorkflowRunner+StepSupervisor.swift`): every metadata object it emits must satisfy these rules. In particular, `attempt.finished` must always carry `attempt` and `outcome`, including the success and runner-backstop paths. The supervisor may add `elapsedMs`/`overrunMs` to `exceededAfterSuccess`; it is not required to.

### Decision C: safe terminal-event mechanism (`RuntimeStore.swift`)
In `InMemoryWorkflowRuntimeStore.recordStepBackendEventReceiptLocked`, replace only the early return of the `guard execution.status == .running` branch, as follows:
- **Append once after a completed step.** Append exactly once when all three hold:
  - `input.eventType == "riela.step.deadline.exceededAfterSuccess"`;
  - the stored execution's `status == .completed`;
  - the stored execution's `recentBackendEvents` has no event of that type yet.
  
  Append it **directly to the stored terminal execution** (`sessions[sessionId].executions[index]`):
  - Use `sequence = (execution.backendEventCount ?? 0) + 1` and `at = input.at ?? clock.now()`.
  - The record's `channel`, `toolName` and `usage` come from the input. Its metadata is `WorkflowFailureDiagnostics.retainedEventMetadata(...)`, and its content is `contentSnapshot ?? contentDelta`, exactly as in `appendRecentBackendEvent`.
  - Keep the same 100-event bound.
  - Update only `backendEventCount`, `lastBackendEventAt` and `lastBackendEventType` (if that field exists on `WorkflowStepExecution`; mirror what `WorkflowExecutionLiveTail.applying(to:)` sets).
  - Write the session back to `sessions`, then return the new receipt.
- **Ignore everything else.** Any other event type, any repeat, or a non-`.completed` terminal or suspended status gets today's behaviour: no mutation, return the existing receipt.
- **Invariants:**
  - Never change the execution's `status`, `completedAt`, `updatedAt`, `output`, `failureReason` or attempt, or any message, publication or session status.
  - Never create or recreate an `executionLiveTails` entry for a terminal execution, so `executionLiveTailCountForTesting()` is unchanged.
  - Never append `attempt.finished` or `retry.stopped` after terminal status. The supervisor already emits those before publication.
  - `recordStepBackendEvent` (non-receipt) shares this function and must return the updated stored execution.
- Persistence: `FailClosedSQLiteWorkflowRuntimeStore.recordStepBackendEventReceipt` already persists the session snapshot after the backing call, and SQLite stores the execution as JSON bytes. So the appended event and its metadata reach SQLite with no wrapper change.
- Rejected alternative: a new `WorkflowRuntimeStore` protocol method. It would force edits to the fail-closed store and three test-only conformances (`WorkflowStepFailurePolicyTests.swift:SessionStatusRecordingStore`, `DefaultLoopGuardTests.swift:NonTransactionalWorkflowRuntimeStore`, `RuntimeStoreTests.swift:StaticWorkflowRuntimeStore`) for no gain.

### Decision D: added tests (situation → expected)
`Tests/RielaCoreTests/StepRetryEventRetentionTests.swift`. Use `@testable import RielaCore` and imitate `RuntimeStoreTests.testCommandFailureDiagnosticsMetadataIsDroppedUnlessItHasTheReceiptShape`.
1. A valid `attempt.finished` carrying every allowed key → the stored metadata equals the input.
2. A valid `retry.stopped` for each `StepRetryStopReason` case → retained.
3. Invalid variants, each causing metadata nil while the event itself is still recorded (count +1):
   - an unknown key;
   - `attempt` given as `.string`;
   - a `.double` duration;
   - a negative or above-range integer;
   - `stopReason:"bogus"`;
   - a missing `outcome`;
   - a missing `stopReason`;
   - `timeoutSource:"worker"`.

   Also add a separate positive check: a maximal valid `attempt.finished` (every allowed key at its maximum range value) is retained. That proves the 1024-byte guard never rejects valid output; the guard itself is defensive only.
4. `retainedEventMetadata(eventType:"other", …)` → nil. The `command_failure_diagnostics` receipt shape is still retained.
5. Complete an execution (`updateStepExecution(... status: .completed ...)`), then record `exceededAfterSuccess` with `{elapsedMs, overrunMs}` → `loadSession` shows:
   - the event, with metadata, last in `recentBackendEvents`;
   - `backendEventCount` +1;
   - status, `completedAt`, `updatedAt` and output unchanged;
   - `executionLiveTailCountForTesting() == 0`.
6. Record the same event again → no duplicate; the receipt sequence is unchanged.
7. After completion, record `riela.step.retry.stopped` or an assistant delta → ignored, with the event count unchanged.
8. A `.failed` execution receiving `exceededAfterSuccess` → ignored.

`Tests/RielaCLITests/StepRetryEventSQLitePersistenceTests.swift`. Imitate `SessionReconcileCommandTests.testCancelledSessionRunsTerminalPersistenceHookOnce`: `makeRielaCLITestTemporaryDirectory`, `FailClosedSQLiteWorkflowRuntimeStore(backing:rootDirectory: canonicalRuntimeStoreRoot(...))`, and reload via `SQLiteWorkflowRuntimePersistenceStore(rootDirectory:).load(sessionId:)`.
9. Create a session, record a running execution, record `retry.stopped{attempts:1, stopReason:"succeeded", elapsedMs:5}`, complete the execution, record `exceededAfterSuccess` → in the reloaded SQLite session, the execution holds both events with metadata retained, and its status is `.completed`.

### Decision E: amended verification (each must exit 0; logs under `tmp/issue-188/`)
1. Run three focused passes, each also required to include the new store tests:
   ```
   arch -arm64 /bin/zsh -lc 'swift test --filter "StepRetryPolicyTests|StepRetryEventRetentionTests|StepRetryEventSQLitePersistenceTests" 2>&1 | tee tmp/issue-188/p04-test-run{1,2,3}.log; exit ${pipestatus[1]}'
   ```
   Run them as three separate commands with `run1`, `run2` and `run3`.
2. Run a regression pass covering the old filter plus the store and diagnostics guards:
   ```
   arch -arm64 /bin/zsh -lc 'swift test --filter "RunnerFailurePolicyTests|RunnerNonTerminalStepFailureTests|DeterministicWorkflowRunnerFanoutTests|FanoutFailedBranchStepOutputsTests|RuntimeStoreTests|CommandFailureDiagnosticsCaptureTests|CommandFailureDiagnosticsExportTests|SessionReconcileCommandTests" 2>&1 | tee tmp/issue-188/p04-regression.log; exit ${pipestatus[1]}'
   ```
3. Lint the plan-owned Swift files:
   ```
   arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCore/DeterministicWorkflowRunner+StepSupervisor.swift Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift Sources/RielaCore/WorkflowFailureDiagnostics.swift Sources/RielaCore/RuntimeStore.swift Tests/RielaCoreTests/StepRetryPolicyTests.swift Tests/RielaCoreTests/StepRetryEventRetentionTests.swift Tests/RielaCLITests/StepRetryEventSQLitePersistenceTests.swift 2>&1 | tee tmp/issue-188/p04-lint.log; exit ${pipestatus[1]}'
   ```
   `RuntimeStore.swift` is long. If lint reports a violation in it, first check whether the violation pre-exists. Run `git show HEAD:Sources/RielaCore/RuntimeStore.swift > tmp/issue-188/p04-runtimestore-head.swift`, then lint that copy into `tmp/issue-188/p04-runtimestore-head-lint.log`. Do not use git stash.
   - A violation that is present at HEAD is recorded as pre-existing.
   - A violation that is new must be fixed by keeping the added helper small and in the same file.
   - Never disable rules.
- Do not weaken or delete the three failing assertions in `StepRetryPolicyTests.swift`. They must pass as written, or be strengthened.

### Completion criteria added by this amendment
- [x] Decision B, C and D implemented; only plan-04 writePaths changed. Record pre/post sha256 for each of the four newly authorized files.
- [x] Amended verification 1–3 exit 0 with log paths recorded in the progress log.
- [x] `git diff -- Sources/RielaCore/WorkflowFailureDiagnostics.swift` shows the `command_failure_diagnostics` branch unchanged.

## Progress Log

### Session: 2026-11-10
**Tasks Completed**: Plan authored (Opus).
**Blockers**: Waits for issue188-01.

### Implementation continuation
- Added the ready-at calculation and exposed existing add-on helpers for reuse; the supervised execution path, timer race, retry loop, diagnostics, and publication are still outstanding.
- Added nine initial behavioral test methods. The remaining cases include non-cooperative execution and projection, timed retry and cancellation, stale timers, fanout, and slow publication.
- Partial test evidence: `tmp/issue-188/issue188-04-step-supervisor/partial-test.log`. All completion criteria above remain open; run the three focused passes, regression, and strict changed-file lint after implementation is complete.
- Partial focused run after correcting a helper compile error: `partial-test-2.log`, exit 1, 9 tests and 11 failures (1 unexpected); the supervised path is not wired. The earlier compile failure is retained in `partial-test.log`.
- Strict changed-file lint: `partial-lint.log`, exit 0, using `changed-swift.nul`. These checks do not satisfy the required final-source gates.

### Implementation continuation: supervisor draft
- Wired the authored-policy path to an unstructured supervisor with ready-at accounting, retry classification, cancellation, separate step/attempt timers and stale timer disarm; legacy path remains unchanged. Added non-cooperative attempt and cancellation tests.
- Focused draft run `tmp/issue-188/issue188-04-step-supervisor/p04-test-run1.log` passed 11 tests before subsequent lint-only refactoring; current source requires a fresh rerun. Strict selected-file lint passed in `p04-strict-lint-3.log`.
- Work remains: complete the full 18 design cases, attempt/backstop and publication diagnostics and telemetry, audit dispatch/expiry races and success timing, run all three focused passes and regression on final source, and resolve any failures. The implementation is not ready for review or integration.
- Current-source `p04-current.log` passed 11 tests, and `p04-regression.log` passed 31 tests. These do not satisfy the three 18-case focused runs. Strict changed-file lint passed on the same Swift sources.
- Self-check finding: the child currently awaits the success attempt event before settling the supervisor, so a delayed event receipt can allow the backstop to win after an adapter success. Settle successful effects before awaiting diagnostics and verify the slow-store case. Backstop attempt events and required detailed metadata/telemetry also remain incomplete.

### Continuation 1: runtime-store ownership blocker
- Settled successful adapter output before awaiting diagnostic events; added backstop attempt metadata, dispatch guard, cancellation elapsed time and publication duration telemetry. Expanded deterministic coverage to 20 methods, including stale timers, blocked projection, fanout and slow publication.
- `tmp/issue-188/issue188-04-step-supervisor/cont1-test-attempt2.log`: exit 1, 20 tests, 3 failures. `cont1-strict-lint.log`: exit 0. Earlier compile failure and hashes remain in the evidence directory.
- Required diagnostics cannot be retained with the present scope: `Sources/RielaCore/WorkflowFailureDiagnostics.swift:178` strips metadata from these event types; `Sources/RielaCore/RuntimeStore.swift:681` ignores events once an execution is terminal, including `riela.step.deadline.exceededAfterSuccess`. These files are outside plan 04 writePaths/sharedPaths. A checkpoint amendment or owner-assigned repair must authorize bounded metadata retention and a safe terminal-event mechanism, with tests across affected stores. Then rerun all three focused passes, regression and lint. Do not weaken assertions or claim completion.

### Amendment implementation
- Implemented bounded typed retry-event retention and once-only terminal success-deadline event persistence, with in-memory and SQLite coverage. The command diagnostics branch is unchanged.
- Focused runs `tmp/issue-188/issue188-04-step-supervisor/redispatch-test{2,3,4}.log`: each exit 0, 23 tests, 0 failures. Regression `redispatch-regression.log`: exit 0, 75 tests, 0 failures. Plan and strict selected-file lint `redispatch-plan-lint.log` and `redispatch-strict-lint.log`: exit 0. These ran on the shared tree; serial integration must rerun combined gates.
- Source identity and per-edit intent/hash evidence are under `tmp/issue-188/issue188-04-step-supervisor/`. Formal integrity and adversarial review, integration, commit and push remain downstream.
