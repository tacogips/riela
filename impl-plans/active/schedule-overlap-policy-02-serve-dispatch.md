# Schedule Overlap Policy 02: Non-Blocking Cron Dispatch Implementation Plan

**planId**: `overlap-02-serve-dispatch`
**Status**: Ready for implementation (wave 2)
**Workflow Mode**: issue-resolution
**Issue Reference**: none (no issueUrl or issueNumber). The intake came from
workflowInput.requestedBehavior via comm-008602 and comm-008603.
workflowExecutionId: `opus-luna-design-and-implement-review-loop-session-471`.
**Design Reference**: `design-docs/specs/design-scheduled-overlap-policy.md`
(accepted by Step 3, comm-008607): §3, §4.3 (resolution at startup), §6.1-6.8,
§7.1-7.3 (receipts, reasons, serve record), §8, §11, §14.
**dependsOn**: `overlap-01-contracts`
**Branch**: `feat/schedule-overlap-policy`. Make no commits, run no git write
commands.
**Progress log**: `impl-plans/progress/overlap-02-serve-dispatch.md`
**Evidence dir**: `tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/`

## Intent and Context

`riela events serve` now awaits every cron run inline:
`EventLiveServe.swift` l.215-240 calls `dispatchCronTick`, which awaits
`runEventWorkflow` (`EventLiveServe+Cron.swift:65`). One long run blocks every
other source.

This plan:

1. Makes cron runs tracked, unstructured tasks owned by a new
   `CronOverlapDispatcher` actor, keyed by `bindingId`.
2. Applies the effective overlap policy per binding.
3. Writes one receipt per (tick, binding) and records reasons.
4. Makes `--limit` drain and makes signal/error shutdown cancel.
5. Injects a clock.
6. Surfaces session ids before completion through a callback seam in
   `WorkflowRunCommand`.

Contracts from `overlap-01-contracts` that you consume and must not redefine:

- `EventOverlapPolicy`, `EventOverlapPolicySource`, `EventOverlapSettings`,
  `EffectiveEventOverlapPolicy`, `EventOverlapPolicyError`,
  `resolveEventOverlapPolicy(binding:workflow:)` (in RielaCore);
- `EventBindingContract.overlapSettings` (in RielaEvents);
- the new optional `PersistedEventReceipt` fields: `bindingId`,
  `overlapPolicy`, `overlapPolicySource`, `cancelledSessionIds`,
  `coalescedTickCount` (in `Sources/RielaCLI/EventReadOnly.swift`);
- `WorkflowDefinition.triggerDefaults`.

## Non-Goals

- Do not change webhooky, file-change, telegram, discord, slack or matrix
  dispatch. They stay inline. Do not edit `EventLiveServe+Webhooky.swift`,
  `EventLiveServe+FileChange.swift` or the chat files.
- Add no new session status. A cancelled run is
  `status: failed, failureKind: cancelled`, produced by the existing runner.
- Do not persist the queue. Add no user-configurable settle timeout. Add no new
  CLI flags.
- Do not edit `ScopedParityCommands*.swift`, `WorkflowValidateInspectCommands.swift`
  (owned by `overlap-03`), any routine or GraphQL files (owned by `overlap-04`),
  or `EventReadOnly.swift` (owned by `overlap-01`).
- Do not switch event runs to `.jsonl` output. Do not allocate session ids
  anywhere. Only observe them.
- Add no extra process-kill logic. Cancellation is `Task.cancel()` only.

## File-Level Changes

### 1. `Sources/RielaCLI/EventServeClock.swift` (new)

- `protocol EventServeClock: Sendable { func now() -> Date; func sleep(for duration: Duration) async throws }`
- `struct SystemEventServeClock: EventServeClock`. It uses `Date()` and
  `Task.sleep(for:)`.

### 2. `Sources/RielaCLI/WorkflowRunCommand.swift`

- Add `var sessionStartedObserver: (@Sendable (String) -> Void)?`, next to
  `afterTerminalPersistence` (around l.22).
- In `runEventHandler` (around l.131-176), call
  `sessionStartedObserver?(event.sessionId)` when
  `event.type == .sessionStarted && event.workflowId == persistenceBundle.workflow.workflowId`.
- **Pitfall (design §6.5):** put this check **outside and before**
  `if let jsonlRecorder { ... }` (l.165). `jsonlRecorder` is nil for `.json`
  output (l.51), and `CLIEventWorkflowRunner` uses `.json`. A copy placed
  inside that block never fires.
- Make no other change.

### 3. `Sources/RielaCLI/EventLiveServe.swift`

- `EventWorkflowRunRequest`: add `var onSessionStarted: (@Sendable (String) -> Void)? = nil`.
- `CLIEventWorkflowRunner.runWorkflow`: copy `command`, set
  `sessionStartedObserver = request.onSessionStarted`, then run. Keep
  `output: .json`.
- `DefaultEventLiveServer`: add these stored properties and init parameters,
  each with a default so all existing call sites compile:
  - `clock: any EventServeClock = SystemEventServeClock()`
  - `triggerDefaultsResolver: (any EventWorkflowTriggerDefaultsResolving)? = nil`
  - `cancelSettleTimeout: Duration = .seconds(30)`
- New protocol, in this file or the dispatcher file:

  ```swift
  protocol EventWorkflowTriggerDefaultsResolving: Sendable { func triggerDefaults(workflowName: String, parsed: ParsedParityOptions) throws -> EventOverlapSettings? }
  ```

  - `CLIWorkflowTriggerDefaultsResolver` resolves through
    `WorkflowRunCommand().resolver.resolve(WorkflowResolutionOptions(workflowName:scope:workflowDefinitionDir:workingDirectory:))`.
    Use the same inputs `CLIEventWorkflowRunner` uses (l.812-819) and return
    `bundle.workflow.triggerDefaults`.
  - Effective resolver selection in `servePrepared`:
    1. the injected `triggerDefaultsResolver`, if set;
    2. otherwise `CLIWorkflowTriggerDefaultsResolver`, only when
       `workflowRunner is CLIEventWorkflowRunner`. Mirror l.90;
    3. otherwise no workflow layer (nil).

    This keeps unit tests from touching real registries.
- `servePrepared`:
  - **Startup resolution:** for each enabled binding whose `sourceId` is a
    cron source id and that has a `workflowName`:
    - If `binding.overlapSettings?.overlapPolicy` is nil, ask the resolver.
      A resolver error means no workflow layer, and the binding's entry gets
      `"diagnostic": "overlap_policy_workflow_unresolved"`.
    - Call `resolveEventOverlapPolicy`. If it throws (an invalid binding
      value), call `writeServeRecord(status: "failed", detail: message)` and
      throw `CLIUsageError(message)`. This is fail-closed, the same as the
      file-change source errors at l.141-147.
    - Write `overlapPolicies` to the serve record as JSON. Shape per
      binding:
      `{ "<bindingId>": { "policy": "...", "source": "...", "maxQueuedRuns"?: n, "maxConcurrentRuns"?: n, "diagnostic"?: "..." } }`.
  - Create one `CronOverlapDispatcher` per `servePrepared` call.
  - Replace `Date()` at l.167/216 with `clock.now()`. Replace the idle
    `Task.sleep` at l.318 with
    `clock.sleep(for: webhookySources.isEmpty ? .seconds(1) : .milliseconds(200))`.
  - **Cron loop:**
    1. Compute `let ticks = source.dueTicks(after: lastCheckedAt, until: now)`.
    2. Call `dispatchCronTick` for each tick in ascending order, passing
       `isLatestDueTick` and `coalescedTickCount: ticks.count - 1`.
    3. Sum the returned counts into `processedEvents`.
    4. Run the limit check after each tick.
  - **`--limit` paths:** before every `return liveReady(...)` at a limit
    check, and before the final return after the `repeat` loop, run
    `await dispatcher.drain()` and then `recordEventsServeCompletion`. There
    are several early returns, one per source loop. Do not miss any. A small
    local helper is fine.
  - **Signal/error path:**
    - Wrap the `repeat` loop in `do { } catch { }`.
    - In the catch, run
      `await Task { await dispatcher.shutdownCancelling() }.value`. The
      unstructured task keeps the shutdown from inheriting the cancelled
      state. This is the pattern in
      `DeterministicWorkflowRunner+Cancellation.swift:16-29`.
    - Then rethrow.
  - Keep the webhooky task cancellation `defer` as is.
- `writeServeRecord`:
  - Serialize the whole read-modify-write behind a process-wide
    `static let serveRecordLock = NSLock()`.
  - Add a parameter `overlapPolicies: JSONObject? = nil`. When non-nil, write
    it under the key `overlapPolicies`.
  - All other behavior is unchanged.

### 4. `Sources/RielaCLI/EventLiveServe+Cron.swift`

- Replace `CronScheduleSource.dueTick(after:until:) -> Date?` with
  `dueTicks(after:until:) -> [Date]`. It returns every matching second in
  `(after, until]`, ascending, with the same lower bound
  (`maximumCatchUpSeconds`). Remove `dueTick`; it has no other callers.
- New signature:

  ```swift
  func dispatchCronTick(source: CronScheduleSource, scheduledAt: Date, firedAt: Date, config: EventLiveConfig, eventRoot: URL, parsed: ParsedParityOptions, dispatcher: CronOverlapDispatcher, isLatestDueTick: Bool = true, coalescedTickCount: Int = 0) async throws -> Int
  ```

  - Build the envelope, dry run, and read-only path exactly as today. The
    read-only receipt is written per due tick (design §7.1, D14).
  - For each trigger with a `workflowName`:
    1. Look up `dispatcher.effectivePolicy(bindingId:)`. If the policy is not
       `.concurrent` and `!isLatestDueTick`, continue: the tick is not
       submitted and is covered by `coalescedTickCount` on the latest tick.
    2. Run the routine gate as today. A gate skip writes the serve record as
       today and is not counted.
    3. Submit a `CronOverlapFire`, setting `coalescedTickCount` to 0 for
       `.concurrent` and to the argument value otherwise.
  - Return 1 if any binding was submitted, else 0.
  - Remove the inline `runEventWorkflow` call and the inline
    `recordRunCompletion` call from this function. Both move to the
    dispatcher.
- Make `routineDispatchGate(routineId:storeRoot:parsed:)` internal instead
  of private, so the dispatcher can re-check before deferred starts.

### 5. `Sources/RielaCLI/EventCronOverlapDispatcher.swift` (new)

Pin this shape. Tests call these members.

```swift
struct CronOverlapFire: Sendable { var bindingId: String; var sourceId: String; var workflowName: String; var runtimeVariables: JSONObject; var envelope: ExternalEventEnvelope; var scheduledAt: Date; var firedAt: Date; var routineId: String?; var routineStoreRoot: String?; var coalescedTickCount: Int }
enum CronOverlapSubmitOutcome: Equatable, Sendable { case started, queued(position: Int), skipped(reason: String), cancelPending }
actor CronOverlapDispatcher {
  init(server: DefaultEventLiveServer, eventRoot: URL, parsed: ParsedParityOptions, policies: [String: EffectiveEventOverlapPolicy], clock: any EventServeClock, cancelSettleTimeout: Duration)
  nonisolated func effectivePolicy(bindingId: String) -> EffectiveEventOverlapPolicy   // default .skip/.default when absent
  @discardableResult func submit(_ fire: CronOverlapFire) -> CronOverlapSubmitOutcome   // never awaits a run
  func drain() async
  func shutdownCancelling() async
  func runningSessionIds(bindingId: String) -> [String?]   // test/inspection helper
}
```

Behavior, following design §6.4 exactly. Per-scope state:

- `running: [RunHandle]`. Each handle holds `receiptId`, the `Task`,
  `sessionId: String?`, `fire`, and `cancelRequested`.
- `queue: [CronOverlapFire]`.
- `pendingAfterCancel: CronOverlapFire?`.
- `settleGeneration: Int`, incremented every time `pendingAfterCancel` is set
  or cleared. It guards against stale timeout tokens (see `cancelRunning`).

Starting a run:

1. Write the receipt with status `dispatched`.
2. Create `Task { await server.runEventWorkflow(EventWorkflowRunRequest(..., onSessionStarted: { id in Task { await self.recordSessionStarted(receiptId:, sessionId: id) } })) }`.
3. The task's completion calls back into the actor:
   `finish(receiptId:result:)`.

`finish(receiptId:result:)`:

- **On success:** receipt `completed`, with `workflowExecutionId` set to
  `result.session.sessionId`. If `routineId` is set, call
  `try? RoutineStore(...).recordRunCompletion(routineId:, at: fire.firedAt)`.
  Use the same store resolution as `routineDispatchGate`.
  Also keep today's serve-record write from `EventLiveServe+Cron.swift:85-90`:
  `server.writeServeRecord(status: "ready", pollingTarget: sourceId, lastWorkflowName: workflowName)`.
- **On throw:**
  - If `cancelRequested` is set: receipt `cancelled`, reason
    `overlap-cancelled:<bindingId>:<supersedingReceiptId>`.
  - Otherwise: receipt `failed` and call `server.recordWorkflowDispatchFailure`
    with `sourceKind: "cron"`.
  - In both cases the run is not counted for the routine.
- **Afterwards:** remove the handle. Then, in this order:
  1. **Event-driven settle:** if the scope has a `pendingAfterCancel` and no
     remaining running handle has `cancelRequested`, the cancellation has
     settled. Take the pending fire (clear it, bump `settleGeneration`),
     re-check the routine gate, and start it with the
     `overlap-cancel-running` receipt data.
  2. Otherwise, if `queue` is non-empty and nothing else is pending,
     dequeue the head, re-check the routine gate, and start it.
  3. Resume the drain and shutdown waiters (see the continuation rules
     under Pitfalls).

`submit`, by policy, when something is running or pending:

- **`skip`:** receipt `skipped`, reason
  `overlap-skip:<bindingId>:<oldest running sessionId ?? "pending">`.
- **`concurrent`:** start if `maxConcurrentRuns == nil || running.count < cap`.
  Otherwise receipt `skipped`, reason
  `overlap-concurrency-cap:<bindingId>:<cap>`.
- **`queue`:** if `queue.count < maxQueuedRuns`, append. The receipt is
  `queued` with reason `overlap-queued:<bindingId>:<1-based position>`.
  Otherwise receipt `skipped`, reason
  `overlap-queue-full:<bindingId>:<max>`.
- **`cancelRunning`:**
  1. Set `cancelRequested` on all running handles and call `task.cancel()`.
  2. If a `pendingAfterCancel` already exists, write it as `skipped` with
     `overlap-superseded:<bindingId>` and replace it.
  3. Store the fire as `pendingAfterCancel` and bump `settleGeneration`.
     Capture `let token = settleGeneration` and the cancelled handles'
     observed session ids.
  4. Start a separate unstructured **timeout Task**:
     `try? await clock.sleep(for: cancelSettleTimeout)`, then
     `await self.settleTimedOut(bindingId:, generation: token)`.

     **Do not use `withTaskGroup` to race "all finished" against the sleep.**
     A task group always waits for every child. A run that ignores
     cancellation would keep the group from returning, so the timeout outcome
     would never be recorded and the test would hang.

  Outcomes:

  - **Settled.** The event-driven path in `finish` starts the pending fire.
    Its receipt gets `cancelledSessionIds`, the observed ids of the cancelled
    handles, and reason
    `overlap-cancel-running:<bindingId>:<first cancelled sessionId ?? "pending">`.
    The settle bumps `settleGeneration`, so the later timeout token is stale.
  - **`settleTimedOut(bindingId:generation:)`.** If `generation` differs from
    the scope's current `settleGeneration`, or `pendingAfterCancel` is nil,
    return without doing anything: the fire already started, or was
    superseded or discarded. Otherwise clear the pending fire, bump the
    generation, and record it `skipped` with
    `overlap-cancel-timeout:<bindingId>:<sid ?? "pending">`. Start no run.
    The unsettled handles stay tracked and are recorded by `finish` when
    they end. That later `finish` must not start anything for this cleared
    pending fire.
  - **Superseded.** Step 2 replaces the pending fire and bumps the
    generation, so the older timeout token becomes a no-op.

Recording rules:

- Every non-start outcome (`skipped`, any overflow, cancel-timeout,
  superseded) also calls `server.writeServeRecord(status: "ready", pollingTarget: sourceId, lastIgnoredReason: reason)`
  and records the telemetry log `riela.events.cron.overlap`, with attributes
  `binding.id`, `overlap.policy` and `overlap.reason`.

Receipts:

- Location: `<eventRoot>/receipts/<receiptId>.json`.
- `receiptId = "event-cron-" + sha256 hex(sourceId + "\u{0}" + envelope.eventId + "\u{0}" + bindingId)`.
  Imitate `EventReadOnly.swift:52-54`, which uses Crypto `SHA256`.
- Encoder: ISO8601 dates, `[.prettyPrinted, .sortedKeys]`, atomic write,
  `0o600` permissions, `0o700` for the directory. Imitate
  `EventReadOnly.swift:55-78`.
- Every write fills:
  - `bindingId`;
  - `overlapPolicy` (`policy.rawValue`);
  - `overlapPolicySource` (`source.rawValue`);
  - `coalescedTickCount`, omitted (nil) when 0;
  - `workflowName`, `envelope`, `eventId` and `sourceId`;
  - `updatedAt = clock.now()`.
- Only the actor writes receipts.

`recordSessionStarted(receiptId:sessionId:)`:

- Sets the handle's `sessionId`.
- Rewrites the receipt's `workflowExecutionId`.
- Ignores the call if the handle has already finished.

`drain()`:

- Loop until `running`, `queue` and `pendingAfterCancel` are all empty for
  every scope.
- Do not start new submits. The serve loop has stopped polling.
- Queued and pending fires still run (design §6.7). The settle path in
  `finish` or `settleTimedOut` resolves the pending fire, and `finish`
  dequeues the queue.
- Await with stored continuations that `finish` and `settleTimedOut` resume.
  **Actor reentrancy:** re-check the state after every resume.

`shutdownCancelling()`:

1. Write every queued fire and the pending fire as `discarded` with
   `overlap-shutdown-discarded:<bindingId>`.
2. Clear them, and bump every scope's `settleGeneration` so that
   outstanding timeout tokens become no-ops.
3. Cancel all running handles.
4. Wait for them, bounded: register one stored shutdown continuation and
   start a timeout Task (`try? await clock.sleep(for: cancelSettleTimeout)`,
   then `await self.shutdownWaitTimedOut(token:)`). The continuation is
   resumed by whichever comes first:
   - `finish` observing that no running handles remain;
   - the timeout call, using a token check like the settle path.

   Each path removes the continuation from state before resuming it, so it
   is never resumed twice. A handle that never finishes must not block the
   return. **Do not** wait with a task group or by awaiting `task.value`.
5. Return. Handles still running stay tracked. Their late `finish` calls
   record receipts but start nothing, because the queue and pending fire
   were cleared.

Deferred-start routine re-check, before starting a queued or pending fire
that has a `routineId`:

- Call `server.routineDispatchGate`.
- If it returns a `skipReason`, write the receipt as `skipped` with that
  reason and consider the next queued fire.

### 6. Tests

#### `Tests/RielaCLITests/EventCronOverlapTests.swift` (new, class `EventCronOverlapTests`)

Test helpers, defined in this file:

- **`ManualEventServeClock` (actor-backed).** `now()` returns the virtual time.
  - `sleep(for:)` registers a waiter `{deadline, continuation}` and suspends
    until `advance(by:)` moves the virtual time to or past the deadline.
  - It is **cancellation-aware**: wrap it in `withTaskCancellationHandler`.
    On cancellation, remove the waiter and resume it once with
    `CancellationError`. The handler runs outside the actor, so hop in with
    a `Task` keyed by the waiter id.
  - `advance(by:)` resumes the due waiters in ascending deadline order and
    removes each one before resuming it.
  - Auto-advance mode, for driving the serve loop: `sleep` advances the
    virtual time to its own deadline, fires any earlier-due waiters first in
    deadline order, then returns after `await Task.yield()`. Never wake a
    later-deadline waiter before an earlier one.
- **`ControllableEventWorkflowRunner` (actor).**
  - Each `runWorkflow` call records the request, calls
    `request.onSessionStarted?("session-<n>")`, and then suspends on a
    per-call continuation.
  - The continuation is wrapped in `withTaskCancellationHandler`, so
    cancellation resumes it with `CancellationError`. A configurable mode
    ignores cancellation, for the timeout test.
  - Expose `release(index:)`, `failNext`, `requestCount`, `cancelledIndices`.
  - Build the `WorkflowRunResult` the way `FakeEventWorkflowRunner` does
    (`Tests/RielaCLITests/EventLiveServeTestSupport.swift:205`).
- No `Thread.sleep` and no fixed `Task.sleep`. Wait on conditions with a
  bounded `Task.yield()` loop that has an iteration cap.

Cases, each `situation -> expected outcome`. Drive the dispatcher directly
unless the case says serve. "Release" means the controllable runner lets the
run finish.

- **Rule for every case that asserts a session id in a reason** (skip,
  cancelRunning, timeout, superseded): before the overlapping submit, wait
  with a bounded yield loop until `runningSessionIds(bindingId:)` contains a
  non-nil id. `onSessionStarted` reaches the actor through a `Task` hop, so
  without this wait the reason could end in `pending`.
- **skip:** run 1 in flight, submit again → `.skipped`. The receipt has
  status `skipped` and reason `overlap-skip:b:session-1`, and `serve-record.json`
  `lastIgnoredReason` equals that reason. Release run 1, submit again →
  `.started`.
- **skip before session start:** the runner delays `onSessionStarted`. The
  second submit's reason ends in `:pending`.
- **concurrent, cap 2:** three submits → two started, then `.skipped` with
  `overlap-concurrency-cap:b:2`. Each started run has its own receipt.
- **concurrent, no cap:** three submits → three started.
- **queue, max 1:** run in flight, submit 2 → `.queued(position: 1)`, submit 3 → skipped
  `overlap-queue-full:b:1`. Release run 1 → run 2 starts (requestCount == 2), and the
  FIFO order matches the scheduledAt order.
- **cancelRunning:**
  - Run 1 in flight, submit 2 → `.cancelPending`. Run 1's task is cancelled;
    its receipt is `cancelled` with reason `overlap-cancelled:b:<receipt2>`.
  - Run 2 then starts; its receipt has `cancelledSessionIds == ["session-1"]`
    and reason `overlap-cancel-running:b:session-1`.
  - Routine `runCount` is unchanged by run 1.
- **cancelRunning timeout:** the runner ignores cancellation. Advance the
  manual clock by 30s → the pending fire's receipt is `skipped` with
  `overlap-cancel-timeout:b:session-1`, and no second run starts.
  - This must complete without releasing run 1, which proves that the
    timeout is not blocked by an unsettled run.
  - Then release run 1 → its receipt is recorded and still no second run
    starts, because the stale token and the cleared pending fire start
    nothing.
- **cancelRunning settles before the timeout:** run 1 honors cancellation →
  run 2 starts without advancing the clock. A later `advance(by: 30s)`
  changes nothing: the token is stale and no extra receipt is written.
- **cancelRunning superseded:** with a pending fire waiting, submit again →
  the older pending fire's receipt reads `overlap-superseded:b`.
- **drain:** a queue entry is waiting and `drain()` is called → the queued
  run starts. `drain` returns only after all runs finish. Release the runs
  from a separate task.
- **shutdownCancelling:** one running and one queued → the queued receipt is
  `discarded` with `overlap-shutdown-discarded:b`, the running task is
  cancelled, and the function returns.
- **shutdownCancelling with an unsettled run:** the runner ignores
  cancellation. Call `shutdownCancelling()` from a child task, then advance
  the clock by 30s → it returns while run 1 is still unreleased.
- **routine accounting:** use a temp `RoutineStore` with an active routine.
  - concurrent, two runs complete → `runCount == 2`;
  - a skipped fire → no increment;
  - a failed run → no increment;
  - routine disabled while a fire is queued → that fire's receipt is
    `skipped` with `routine-disabled:<id>`, and no run starts.
- **dueTicks:**
  - `*/30` schedule, window of 95s → three ascending dates;
  - an empty window → `[]`;
  - a window larger than 3600s → bounded by `maximumCatchUpSeconds`.
- **serve, coalescing:** use `DefaultEventLiveServer(workflowRunner:clock:)`
  with a manual clock and `--limit`.
  - A cron binding with `overlapPolicy: "concurrent"` and three due ticks in
    one iteration → three submits.
  - A `skip` binding → one submit, whose receipt has `coalescedTickCount == 2`.
- **serve, non-blocking (acceptance):** cron source A is bound to a blocking
  run (skip); cron source B is bound to a fast run. Under the auto-advance
  clock, B's request count reaches at least 2 while A's run is still
  unreleased. Then release A, and serve returns `processedEvents` equal to
  the limit.
- **serve, non-blocking with file-change:** same as above with a file-change
  source. A file written after start is dispatched while A blocks. Imitate
  `EventLiveServeFileChangeTests` for the setup.
- **serve, non-blocking with webhooky:** same with a webhooky fake streamer.
  Imitate `EventLiveServeWebhookyTests` for the streamer injection.
- **serve, invalid binding value:** `overlapPolicy: "bogus"` on a cron
  binding in config → serve throws with the unknown-value message, and the
  serve record status is `failed`.
- **serve, startup resolution:** a fake `EventWorkflowTriggerDefaultsResolving`
  returns `queue` → the serve record's `overlapPolicies.<id>.source == "workflow"`.
  When the resolver throws → `"diagnostic": "overlap_policy_workflow_unresolved"`
  and policy `skip`.
- **session seam unit test:** a `WorkflowRunCommand` running a mock-scenario
  workflow with `output: .json` and `sessionStartedObserver` set → the
  observer is called exactly once with the returned session's id. Use
  `--mock-scenario` and temp `--session-store` and `--artifact-root`, like
  `Tests/RielaCLITests/WorkflowMutableRegistryTests.swift:340-350`, which uses
  `CLIEventWorkflowRunner` with a mock scenario.

#### Real-runner cancel test (design §14), `testCancelRunningWithRealRunnerRecordsRuntimeSessionId`

Setup:

- Author a temp workflow bundle with one command node. The shell script
  writes `$$` to `pid` in a temp dir and then `exec /bin/sleep 30`. Copy the
  bundle layout from an existing CLI test that authors a workflow under
  `--workflow-definition-dir`; `grep -rn "workflow-definition-dir" Tests/RielaCLITests`
  finds them.
- Use temp `--session-store` and `--artifact-root`. Never use `~/.riela`.
- Use the real `CLIEventWorkflowRunner` and a dispatcher with the
  `cancelRunning` policy.

Steps:

1. Submit fire 1.
2. Wait, with a bounded poll in 20ms steps like
   `DistributedProcessCancellationTests.swift:46-50`, until
   `runningSessionIds(bindingId:)` contains a non-nil id and the pid file
   exists.
3. Submit fire 2.

Assertions:

- fire 2's receipt `cancelledSessionIds == [that id]`, and its reason is
  `overlap-cancel-running:<b>:<that id>`, not `pending`;
- the runtime session with that id has `failureKind == .cancelled`. Load it
  from the temp session store;
- `kill(pid, 0) == -1` and `errno == ESRCH`, checked within a bounded poll.

Release or cancel fire 2, then call `shutdownCancelling()` for cleanup.

#### `Tests/RielaCLITests/EventLiveServeCronTests.swift` (update)

- Replace `testDueTickCoalescesMissedTicksIntoLatestMatch` with an equivalent
  `dueTicks` test.
- `testRoutineGateSkipsDisabledRoutineAndCountsActiveRun` and
  `testReadOnlyCron...`:
  - pass a dispatcher created for the test;
  - after the dispatched submit, `await dispatcher.drain()` before asserting
    `runCount == 1`;
  - the skipped-gate expectation of 0 stays.
- `testCronServeFiresTickAndRunsBoundWorkflow` and
  `testCronServeSurvivesWorkflowRunFailure` must pass unchanged, because
  `--limit 1` drains. Do not weaken their assertions.

## Invariants

- The serve loop never awaits a cron run, except in `drain()` and
  `shutdownCancelling()`.
- Every accepted fire ends in exactly one terminal receipt status:
  `completed`, `failed`, `cancelled`, `skipped` or `discarded`.
- Session ids come only from runtime events, through `onSessionStarted` or
  the result. The dispatcher never invents ids, except the literal
  placeholder `pending`.
- `processedEvents` changes only on the serve-loop task.
- Non-cron dispatch behavior and the existing tests for it are unchanged.
- Configs without overlap fields behave as `skip`.

## Pitfalls to Avoid

- Actor reentrancy: state can change across any `await` inside the actor.
  Re-validate before acting after an await.
- Do not `await task.value` inside `submit`.
- Run tasks are unstructured, so they are not cancelled when the serve task
  is cancelled. `shutdownCancelling` must cancel them explicitly.
- Shutdown must run in `Task { }.value`. A pre-cancelled task would skip the
  settle wait.
- `writeServeRecord` is now called from many tasks. Without the lock, updates
  are lost.
- Every `return liveReady` limit path must call `drain()` first.
- **Stored continuations** (drain waiters, the shutdown waiter, and the
  manual clock's sleep waiters) must each be resumed **exactly once**.
  - Always remove a continuation from state before resuming it.
  - Guard timeout callbacks with the generation or token check.
  - Resuming twice crashes; never resuming hangs.
- **Never race with a task group** against a child that waits for a run.
  Any child that does not respond to cancellation makes the group wait for
  it. Use the event-driven settle and the generation-guarded timeout Tasks
  described above.

## Execution Protocol (shared working directory)

- **Before each edit:** read the file fresh and record `git hash-object` before
  and after. If drift appears, re-read the file and reapply your intent;
  never overwrite blindly.
- **Write scope:** edit only this plan's `writePaths`.
- **Concurrent plans:** `overlap-03-inspection` and
  `overlap-04-routine-surfaces` edit other files in the same targets at the
  same time.
- **Build failures in files you do not own:** wait, re-run the build up to
  three times, then record the failure in the progress log. Do not edit those
  files.
- **Scratch files:** only under `tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/`.
- **Git:** run no git write commands.

## Verification

```text
V0: mkdir -p tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch
V1: arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/v1-build.log 2>&1
V2: arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "EventCronOverlapTests|EventLiveServeCronTests"' > tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/v2-overlap.log 2>&1
V3: arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "EventLiveServeTests|EventLiveServeFileChangeTests|EventLiveServeWebhookyTests|EventLiveServeSlackTests|EventLiveServeMatrixTests|EventLiveServeIsolationTests|EventReadOnlyPolicyTests|WorkflowCommandLivePersistenceEventTests"' > tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/v3-regression.log 2>&1
V4: arch -arm64 /bin/zsh -lc 'swiftlint lint --strict Sources/RielaCLI/EventServeClock.swift Sources/RielaCLI/EventCronOverlapDispatcher.swift Sources/RielaCLI/EventLiveServe.swift Sources/RielaCLI/EventLiveServe+Cron.swift Sources/RielaCLI/WorkflowRunCommand.swift Tests/RielaCLITests/EventCronOverlapTests.swift Tests/RielaCLITests/EventLiveServeCronTests.swift' > tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/v4-lint.log 2>&1
```

Expected results:

- V1: exit 0.
- V2: exit 0, `testsRun > 0`, 0 failures. The log lists the real-runner
  cancel test as passed.
- V3: exit 0, `testsRun > 0`, 0 failures.
- V4: exit 0.

For each command, record an integer `exitStatus`, `testsRun`, `failureCount`
and the full `logPath`.

## Acceptance Criteria (mechanically checkable)

1. `grep -n "sessionStartedObserver" Sources/RielaCLI/WorkflowRunCommand.swift`
   shows the call site on a line before `if let jsonlRecorder`.
2. `grep -n "func dueTick(" Sources/RielaCLI` finds nothing, and
   `grep -n "func dueTicks" Sources/RielaCLI/EventLiveServe+Cron.swift` matches.
3. `grep -n "runEventWorkflow" Sources/RielaCLI/EventLiveServe+Cron.swift` finds
   nothing. The run moved to the dispatcher.
4. `grep -n "serveRecordLock" Sources/RielaCLI/EventLiveServe.swift` matches.
5. V1-V4 pass, with the records in the progress log.

## Progress Log Expectations

`impl-plans/progress/overlap-02-serve-dispatch.md` must contain:

- a task checklist;
- a table of pre and post hashes;
- the list of `return liveReady` sites converted to drain;
- the V1-V4 records;
- notes on any peer-plan build interference;
- residual notes. Residual-risk text must not start with a severity word.
