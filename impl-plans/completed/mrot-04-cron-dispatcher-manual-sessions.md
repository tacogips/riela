# mrot-04: Cron overlap dispatcher honors live manual sessions

**planId**: mrot-04-cron-dispatcher-manual-sessions
**dependsOn**: mrot-02-live-root-session-probe (wave 2)
**Design Reference**: design-docs/specs/design-manual-run-overlap-and-terminal-reserve.md §3.2 (including "FIFO under external blocking (queued-idle state)"), §3.6, §6 (dispatcher row, DR-001 interleaving); baseline design-docs/specs/design-scheduled-overlap-policy.md §6.4 and §6.7
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/mrot-04-cron-dispatcher-manual-sessions.md
**Evidence root**: tmp/manual-overlap-terminal-reserve/mrot-04/

## Intent and context

`CronOverlapDispatcher` (`Sources/RielaCLI/EventCronOverlapDispatcher.swift`)
only sees runs it started itself. A manual App run
(`hourly-refresh-session-249`) did not block cron ticks 250 and 252. With
this plan, a live **manual** root session of the binding's workflow in the
serve's session store counts as running, but only when the binding's scope
has no in-process run. Cron-vs-cron behavior must not change.

## Non-goals

- Do not change the reason formats, receipt shapes, `CronOverlapReason`
  strings, routine-gate logic, admission-gate accounting semantics, shutdown,
  or abandoned-receipt reconciliation.
- Do not cancel any session owned by another process.
- No new timers or leases. Do not edit `LiveRootSessionProbe.swift`
  (mrot-02), App files, docs, or `Tests/RielaCLITests/EventCronOverlapTests.swift`.

## File-level changes

### Sources/RielaCLI/EventCronOverlapDispatcher.swift

- Add an internal seam in this file:
  `protocol ExternalRunProbing: Sendable { func liveManualSessionIds(workflowId: String) throws -> [String] }`.
  The default struct `StoreExternalRunProbe(sessionStoreRoot:)` calls
  `LiveRootSessionProbe.liveRootSessions` and returns the ids with
  `isManual == true`, oldest first.
- `init` gains two trailing parameters with defaults:
  `externalProbe: (any ExternalRunProbing)? = nil` and
  `bindingWorkflowIds: [String: String] = [:]`. With `nil` or no entry for a
  binding, there is no probe. That is today's behavior, so every existing
  test constructs the dispatcher unchanged.
- Private helper `externalBlockers(bindingId:) -> [String]`. It probes when
  both a probe and a workflow id exist. On a thrown error it returns `[]`
  (fail-open) and emits telemetry with reason
  `overlap-external-probe-failed:<bindingId>` through the existing
  `emitOverlapTelemetry` or `overlapTelemetryLog` path.
- **Idle shortcut** in `submitReserved`: change the condition to
  `scope.running.isEmpty && scope.pendingAfterCancel == nil && scope.queue.isEmpty`.
  When it holds, compute `E = externalBlockers`. If `E` is empty, start the
  fire as today. If `E` is non-empty, apply the policy table below.
- **Policy with `E` non-empty and scope idle:**
  - `skip`: `recordNonStart(... .skipped, reason: CronOverlapReason.skip(bindingId, runningSessionId: E[0]))`.
  - `cancelRunning`: the same skip. Never call cancel, never set
    `pendingAfterCancel`, never start a settle timer.
  - `queue`: the existing queue-append branch (cap, `overlap-queued` receipt,
    `overlap-queue-full`).
  - `concurrent`: start if `cap == nil || running.count + E.count < cap`,
    otherwise `concurrencyCap`.
- **concurrent with in-process runs:** the cap check uses
  `running.count + E.count` when a probe exists for the binding.
- **`advanceExternallyBlocked(bindingId:)`** (actor-isolated, synchronous,
  no `await` between the probe and the start):
  - It acts only in the queued-idle state
    (`running.isEmpty && pendingAfterCancel == nil && !queue.isEmpty`).
  - If `externalBlockers` is non-empty, it returns.
  - Otherwise it runs the existing queue branch of `advanceDeferred`: FIFO
    dequeue, `skipDeferredIfRoutineInactive` (with `releaseQueuedReservation`
    for gated heads), then `start`.
  - `advanceDeferred` is `async` today because it recurses with `await`.
    Either factor out a synchronous queue-advance helper that both use, or
    make sure nothing between the probe and `start` suspends. **A suspension
    there reopens the DR-001 race.**
  - The `advanceDeferred` call in `finish` must also not start the head while
    `E` is non-empty. Apply the same probe check in its queue branch, so the
    head stays queued and the state becomes queued-idle.
- Call `advanceExternallyBlocked(fire.bindingId)` at the **top of
  `submitReserved`**, before any policy logic. Its admission-gate reservation
  bookkeeping must stay as it is: the started head keeps its reservation, and
  `noteQueued(-1)` only happens for non-started heads.
- New internal method `advanceAllExternallyBlocked()`. It iterates the scopes
  in queued-idle state, in sorted bindingId order for determinism, calling
  `advanceExternallyBlocked`.
- `isDrained` already treats a non-empty queue as not drained. Keep it that
  way.

### Sources/RielaCLI/EventLiveServe.swift

- At dispatcher construction (around line 233), pass:
  - `externalProbe`: `StoreExternalRunProbe` built on the serve's effective
    session store root. Use `parsed.sessionStore` when set. When it is nil,
    resolve the default exactly the way `riela workflow run` resolves a nil
    `sessionStore` (find the existing resolver used by `WorkflowRunCommand`
    or `CLIWorkflowSessionStore`; do not invent a new path). If it cannot be
    resolved, pass `nil`.
  - `bindingWorkflowIds`: for each enabled cron binding, the resolved
    `workflowId`. Get it in `resolveCronOverlapPolicies` (around line 429)
    using the same resolver that loads `triggerDefaults`. Add a method to
    `EventWorkflowTriggerDefaultsResolving`:
    `func workflowId(workflowName: String, parsed: ParsedParityOptions) throws -> String?`,
    with a **protocol-extension default returning nil**, so existing test
    fakes still compile. Implement it in the default resolver (around line
    1001) from `resolver.resolve(options).workflow.workflowId`. If resolution
    fails, omit the entry (no probe).
  - Add a `DefaultEventLiveServer` stored property
    `externalRunProbeOverride: (any ExternalRunProbing)?`, default nil, as the
    test seam. Imitate the `triggerDefaultsResolver` property and init
    parameter.
- In the serve `repeat` loop, call `await dispatcher.advanceAllExternallyBlocked()`
  once per iteration, before the idle `clock.sleep` (around line 372). The
  `--limit` drain (`drainHonoringCancellation`, around line 388) must also
  call it on each wait cycle so that queued-idle work can finish. Use the
  serve clock, with no wall-clock sleeps in tests.

## Tests: Tests/RielaCLITests/EventCronOverlapManualSessionTests.swift (new)

Use a fake `ExternalRunProbing` whose returned ids the test can mutate, and
the fake runner, manual clock and receipt reading helpers from
`EventCronOverlapTests.swift` (copy any private helpers; do not edit that
file).

- `skip`, idle, `E = ["manual-1"]` → receipt `skipped` with reason
  `overlap-skip:<b>:manual-1`, and the runner is not invoked.
- `cancelRunning`, idle, `E` non-empty → the same `overlap-skip`, with no
  cancel and no pending fire.
- `concurrent` cap 1 with `E` non-empty → `overlap-concurrency-cap:<b>:1`.
  With no cap → started.
- `queue` with `E` non-empty → `A` queued. Clear `E`, call
  `advanceAllExternallyBlocked` → `A` starts.
- **DR-001:** `queue maxQueuedRuns 1`, `E` non-empty → submit `A` →
  `queued`. Clear `E`. Submit `B` without any loop re-probe → `A` is
  `dispatched` and started first, and `B` gets `overlap-queued:<b>:1`.
  Variant: with `E` still non-empty, submit `B` → `overlap-queue-full:<b>:1`
  and `A` is still the head.
- Routine variant: `A` queued with its routine deactivated, `E` cleared →
  `A` is `skipped` with the gate reason, and `B` follows the existing outcome.
- Admission accounting: with a test `EventAdmissionGate`, after everything
  drains the queued count is 0.
- In-process run plus `E` non-empty, `skip` → the reason names the
  **in-process** session (cron-vs-cron is unchanged).
- Probe throws → the fire starts (fail-open) and telemetry is recorded.
- No probe configured (`nil`) → behavior is identical to today
  (smoke-test skip and queue).

## Invariants

- `Tests/RielaCLITests/EventCronOverlapTests.swift` passes unmodified.
- No `await` between the probe result and `start` inside
  `advanceExternallyBlocked`.

## Verification

- `/usr/bin/arch -arm64 /bin/zsh -lc 'swift build --target RielaCLI'`: exit 0.
- `/usr/bin/arch -arm64 /bin/zsh -lc 'swift test --filter EventCronOverlap'`: all pass (old and new suites).
- `/usr/bin/arch -arm64 /bin/zsh -lc 'swift test --filter EventLiveServe'`: all pass, or report "no tests matched" with evidence.
- `/usr/bin/arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaCLI/EventCronOverlapDispatcher.swift Sources/RielaCLI/EventLiveServe.swift Tests/RielaCLITests/EventCronOverlapManualSessionTests.swift'`: clean.

Record each command's exit status and log path, plus fresh-read pre and post
hashes. Stop on drift.

## Done when

- [x] Seam, idle shortcut, policy table, queued-idle advancement, and the
      submit, loop and drain hooks are implemented.
- [x] All test bullets green, and the old suite green.
- [x] Progress log complete.
