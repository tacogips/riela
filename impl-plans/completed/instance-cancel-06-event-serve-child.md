# instance-cancel-06: Events-serve child — per-session cancel, session-control frames, cron receipt

**planId**: instance-cancel-06-event-serve-child
**dependsOn**: instance-cancel-01-contracts (`OperatorCancellation`, `LiveSessionCancelRegistry`, `WorkflowServeSessionControlFrame`/`Acknowledgement`), instance-cancel-02-runner-reason (`WorkflowRunCommand.operatorCancellationReason`)
**Design Reference**: design-docs/specs/design-instance-cancel.md §2 (event rows), §3 C2 item 1, C3 (child side), C5 (cron), C6
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/instance-cancel-06-event-serve-child.md
**Evidence root**: tmp/instance-cancel/instance-cancel-06-event-serve-child/

## Intent and context

A resident instance's cron and event runs execute in-process inside its child
`riela events serve`, and every one passes through
`DefaultEventLiveServer.runEventWorkflow`
(`Sources/RielaCLI/EventReadOnly.swift:27-48`). This plan:
- makes each run individually cancellable by sessionId through a
  `LiveSessionCancelRegistry`;
- answers `session-cancel` and `session-list` frames on the private channel;
- records a cron receipt `cancelled` for operator cancels.

## Non-goals

- When there is no registry (plain `events serve` without the
  runtime-environment channel), behavior must be byte-identical.
- No change to admission-gate semantics, `cancelRunning`, the queue, or
  shutdown receipts.
- No change to non-cron source error handling; they just see a new error type.
- Do not touch App files.

## File-level changes

- `Sources/RielaCLI/EventLiveServe.swift`:
  - `EventWorkflowRunRequest` gains `var operatorCancellation: OperatorCancellation? = nil`.
    Keep the memberwise call sites compiling: a default value or an explicit
    init.
  - `DefaultEventLiveServer` gains `var sessionCancelRegistry: LiveSessionCancelRegistry?`.
  - At about line 120, when `descriptors` exist, create one registry. Pass it
    to `RuntimeEnvironmentChannel(..., sessionRegistry:)`, and in the server
    copy at about line 140 set `server.sessionCancelRegistry = registry`, next
    to `server.admissionGate`.
  - `CLIEventWorkflowRunner.runWorkflow` (about line 1031): when
    `request.operatorCancellation` is non-nil, set
    `observedCommand.operatorCancellationReason = { [c] in c.failureReason }`.
- `Sources/RielaCLI/EventReadOnly.swift` `runEventWorkflow`: if
  `sessionCancelRegistry == nil`, run the existing code path unchanged.
  Otherwise, after admission succeeds:
  - `registry.beginRun()`; create an `OperatorCancellation`; copy the request
    with `operatorCancellation` and a wrapped `onSessionStarted`. The wrapper
    first calls `registry.register(sessionId:cancellation:cancel:)`, then the
    original observer, and records the sessionId for the unregister.
  - Run the existing body (environment capture plus `workflowRunner.runWorkflow`)
    inside `let child = Task { … }`, which inherits task-locals. Await it
    through `withTaskCancellationHandler { try await child.value } onCancel: { child.cancel() }`,
    so cron `cancelRunning` and shutdown still reach the run.
  - **Handle-before-start race.** `onSessionStarted` can fire before `child`
    is assigned. Register a cancel closure that targets a small lock box
    `TaskHandleBox`. If cancel was requested before the handle was stored,
    the box cancels the task immediately when the handle is stored.
  - In `defer`, or on both exit paths **before** `admissionGate?.release()`:
    unregister the recorded sessionId and call `registry.endRun()`.
  - Error mapping: if the run threw and `cancellation.isRequested`, throw
    `EventOperatorCancelled(sessionId: String?)`, a new
    `struct ... : Error, CustomStringConvertible` with description
    `"operator_cancelled"`, declared in this file. If the run returned a
    result, return it, even if a cancel was requested late.
- `Sources/RielaCLI/RuntimeEnvironmentChannel.swift` (init at about lines
  204-238): add the parameter `sessionRegistry: LiveSessionCancelRegistry? = nil`.
  In the frame loop, **before** the admission decode, call
  `WorkflowServeSessionControlFrame.decodeControlLine(frame)`:
  - `session-cancel` → `registry?.requestCancel(...) ?? .notFound`, reply
    with `cancelAck`;
  - `session-list` → `registry?.liveSnapshot()`, or `([], 0)` without a
    registry, reply with `listAck`.

  Write the reply with the same `output.write(contentsOf: data + [10])` idiom.
  Never await a run inside the loop.
- `Sources/RielaCLI/EventCronOverlapDispatcher.swift`:
  - Add `CronOverlapReason.operatorCancelled(_ bindingId: String, sessionId: String?) -> String`,
    giving `operator-cancelled:<binding>:<sid>`, or `operator-cancelled:<binding>`
    when there is no id.
  - In the `start` task's catch, set
    `operatorCancelled = error is EventOperatorCancelled`.
  - `finish` gains the parameter `operatorCancelled: Bool`. Branch order:
    `result` → `admissionClosed` → `handle.cancelCause` (unchanged wins) →
    `operatorCancelled` (receipt `.cancelled` with the new reason, using
    `handle.sessionId`) → failed.
  - Skip `recordWorkflowDispatchFailure` when `operatorCancelled`. Everything
    else (slot removal, `advanceDeferred`, waking drain and shutdown waiters)
    stays as is.

Pitfalls:
- `withTaskCancellationHandler` must wrap the await of the child, not its
  creation.
- Do not use `Task.detached`: it loses `CLIRuntimeEnvironment.$captured`.
- Release order: unregister and `endRun` before admission `release()`, so a
  reload confirm never counts a finished run.
- `EventCronOverlapDispatcher.swift` is also changed by branch
  fix/manual-overlap-terminal-reserve. Keep the edit to one helper, one
  parameter and one branch.

## Tests: Tests/RielaCLITests/EventOperatorCancelTests.swift (new)

Imitate `Tests/RielaCLITests/EventCronOverlapTests.swift`,
`EventAdmissionGateTests.swift` and `RuntimeEnvironmentChannelTests.swift`,
with a fake `EventWorkflowRunning` that calls `onSessionStarted(id)` and then
awaits cancellation (bounded at 10 s).
- Two concurrent runs s1 and s2 with a registry; `requestCancel(s1)` → s1
  throws `EventOperatorCancelled`, s2 is still running, then s2 completes.
  Afterwards the snapshot is `([], 0)` and admission `running == 0`.
- Cancelling the outer task (simulated `cancelRunning`) → the inner run is
  cancelled and the error is **not** `EventOperatorCancelled`.
- Cancel requested in `onSessionStarted` before the handle is assigned →
  the run is still cancelled (the TaskHandleBox path).
- No registry → `runEventWorkflow` result and error identical to before (a
  run that throws a provider error gives the same error type).
- The fake runner records that `operatorCancellation.failureReason` is
  visible after the request.
- Dispatcher: a run ending in `EventOperatorCancelled` → receipt `cancelled`,
  reason `operator-cancelled:<binding>:<sid>`, no dispatch-failure record, the
  scope is empty, a queued fire (`queue` policy) starts, and under `skip` the
  next fire starts.
- Dispatcher: a run superseded by `cancelRunning` that also reports operator
  cancel → the existing `cancelled` superseded reason wins.
- Channel: a `session-cancel` line for a registered id → ack
  `cancelRequested`; for an unknown id → `notFound`; without a registry →
  `notFound`; `session-list` → ids plus pending; an admission frame still
  handled; an environment frame still handled.

## Verification (arm64 shell; tee to the evidence root)

- `swift build` → exit 0.
- `swift test --filter "EventOperatorCancelTests|EventCronOverlap|EventAdmissionGateTests|RuntimeEnvironmentChannelTests|EventLiveServeCronTests"`
  → exit 0, 0 failures.
- `swiftlint lint` on the changed and new files → no new violations.

## Done criteria

- The tests pass.
- The diff is limited to the 4 sources plus 1 new test.
- The progress log has exit codes and log paths.

## Drift protocol

Re-read before each edit and record pre/post sha256. Stop on unexpected
drift.

## Implementation status

Source wiring and the planned behavioral assertions are present. The aggregate passed 67 tests on the moving shared tree; build and strict selected-file lint passed. See the progress log. Formal review and serial integration remain pending.

## Amendment 2026-11-11 (integration-paths-outside-writePaths, round 1)

Source: integration review comm-000054 (IR-SCOPE-FIXTURE-ROOTS), routed by
dispatch-plans comm-000056 (`amendment_required`). This is a bounded scope
amendment only; there is no design change.

- **Fixture root.** `tmp/instance-control/instance-control-05-child-admission-gate`
  is added to writePaths **and** artifactRoots, for verification only.
  `EventAdmissionGateTests.temporaryRoot()` writes its fixtures there
  (`Tests/RielaCLITests/EventAdmissionGateTests.swift:223`). Do not edit that
  test.
- **Still required.**
  - Compile and run `EventOperatorCancelTests`.
  - Add the missing assertions: reason visibility, late cancel, channel
    fallback, and the cron failure-record, skip and supersede precedence cases.
- **Transient test byproducts.** Some existing suites create
  `tmp/<prefix>-<UUID>` directories and delete them themselves. Those are
  authorized byproducts of verification. Do not edit those tests.
- **Shared build output.** The worktree `.build` written by `swift build` and
  `swift test` from the worktree root is authorized shared build output. It is
  untracked and does not count as a write-scope violation. A private
  `--scratch-path` may be used in addition to the plan commands, never instead
  of them.
- **Dispatch manifest.** `impl-plans/active/instance-cancel-dispatch.json` is
  regenerated by the dispatch flow. Workers never edit it.
