# Wall-clock deadlines for node and step timeouts

Status: proposed 2026-11-11. This is the second root cause of the ART
outage of 2026-11-10. The first is source drift, covered in
`design-workflow-definition-store.md` §4.1. Related:
`design-step-deadline-and-retry-policy.md` §5.4.

## 1. Problem

The runtime expresses a node or step budget as a `Date` deadline. That
covers `nodeTimeoutMs`, `timeoutMs`, `deadlineMs` and the per-attempt
deadline in `DeterministicWorkflowRunner+StepSupervisor.swift`
(`attemptDeadline`), and the timeout given to `LocalProcess.run(...,
deadline:)`. Admission checks compare that `Date` with `Date()`, which is
wall-clock time.

The timer that terminates a running local process is armed differently:
`DispatchQueue.asyncAfter(deadline: .now() + deadline.timeIntervalSinceNow)`
in `Sources/RielaAdapters/LocalProcess.swift`, in the deadline work item
next to `completion.setDeadlineWorkItem`. `DispatchTime` is the uptime
clock, and it stops while the Mac sleeps. A 3300 s limit therefore allowed
1.2-2.7 h of wall time on a host that slept. It started killing runs at
exactly 3300 s once the host stayed awake.

## 2. Rule

A timer that enforces a node or step budget fires at the budget's wall-clock
`Date`. A timeout means elapsed real time, including time the host is
asleep. A wall-clock adjustment (NTP or manual) moves the firing time. This
matches the `Date` comparisons the runtime already uses for admission and
`deadlineMs`. Timeout values, defaults, precedence and clamping do not
change.

## 3. Primitive (RielaCore)

The new file `Sources/RielaCore/WallClockDeadline.swift` adds one small
injectable seam:

- `protocol WallClockDeadlineScheduling: Sendable` with `now() -> Date`
  and `schedule(at: Date, on: DispatchQueue, _ work: DispatchWorkItem)`.
- `SystemWallClockDeadlineScheduler` uses `Date()`, and
  `queue.asyncAfter(wallDeadline: DispatchWallTime(date), execute: work)`.
  `DispatchWallTime(date)` is built from a `timespec` of
  `date.timeIntervalSince1970`. A pure, unit-tested conversion function
  does this. A date in the past fires immediately.
- `func wallClockSleep(until: Date, scheduler: any WallClockDeadlineScheduling)
  async throws` is a checked continuation resumed by a scheduled work item.
  A cancellation handler cancels the work item and throws
  `CancellationError`. If the task is already cancelled, it throws before
  scheduling.

Nothing else is added: no clock framework and no change to
`WorkflowRuntimeClock`.

## 4. Sites

**Changed.** These sites enforce a node or step `Date` deadline:

| Site | Today | Change |
| --- | --- | --- |
| `LocalProcess.swift` deadline work item (`completion.markTimedOut`, terminate, schedule kill) | `asyncAfter(deadline: .now() + delay)` (uptime) | `scheduler.schedule(at: deadline, ...)`. `FoundationLocalProcessRunner` gains an internal initializer parameter `deadlineScheduler` that defaults to the system scheduler. The public API does not change |
| `SystemWorkflowRetryClock.sleep(until:)` (`WorkflowStepRetryPolicy.swift`): the step supervisor's `deadlineMs` and per-attempt expiry, the backstops, the fanout expiry timer and backoff | `Task.sleep(for: until.timeIntervalSinceNow)` | `wallClockSleep(until:)` with the system scheduler. `now()` stays `Date()`. Test fakes of `WorkflowRetryClock` do not change |
| `AgentGatewayNodeAdapter` ACP deadline cancel task | `Task.sleep(for: deadline.timeIntervalSinceNow)` | `wallClockSleep(until: deadline)` |
| `ProductionNodeAdapter+FileMarkdownAddon.swift` conversion deadline race | `Task.sleep(for: remaining)` | `wallClockSleep(until: deadline)` |
| `DistributedWorkerNodeExecutor` execution timeout race | `Task.sleep(for: timeoutSeconds)` and a separate `Date().addingTimeInterval` | compute one `deadline` `Date`, pass it to the context, and race `wallClockSleep(until: deadline)` |

The last four are relative `Task.sleep(for:)` calls on Swift's default
continuous clock, so they may already count sleep. They change anyway, so
that every node or step `Date` deadline fires through one primitive and one
time base. Then no deadline depends on how a runtime maps its clocks, and
the behavior can be tested with the injectable scheduler.

**Audited, unchanged.** These are not node or step budgets:

- the `LocalProcess.scheduleKillIfRunning(after:)` 1 s SIGTERM to SIGKILL
  escalation grace
- `RielaLocalHTTPServer` `requestReadTimeout`, a connection I/O guard
- the `AppleSpeechRecognition` recognizer timeout, an STT stage I/O guard
- polling and backoff intervals that use `Task.sleep(nanoseconds:)` or
  `Task.sleep(for:)` without a `Date` budget (event serve clocks,
  specialist and service loops, retention scheduler)
- `SleepNodeExecution`, an authored sleep duration and not a deadline

## 5. Tests (deterministic, no real long sleeps)

- **`WallClockDeadlineTests` (RielaCoreTests).**
  - The `Date` to `DispatchWallTime`/`timespec` conversion for fixed dates,
    including fractional seconds and a date in the past.
  - `wallClockSleep(until:)` with a fake scheduler returns when the
    recorded work item is fired.
  - It throws `CancellationError` and cancels the work item when its task
    is cancelled.
  - It returns at once for a past date with the system scheduler.
- **`LocalProcessWallDeadlineTests` (RielaAdaptersTests).** A recording
  fake scheduler is injected into `FoundationLocalProcessRunner`. The test
  runs `/bin/sleep 30` with `deadline = D`.
  - The scheduler receives exactly `D` (an absolute `Date`, not a relative
    delay).
  - Firing the recorded work item makes the run fail with
    `AdapterExecutionError(.timeout, "local agent process exceeded deadline
    and was terminated")`, and the process group is reclaimed.
  - A run that exits before the deadline cancels the work item.
  - The existing `LocalProcessAdmissionTests`, `LocalProcessGroupOwnershipTests`
    and `LocalProcessForegroundLifetimeTests` pass unchanged.
- **Step supervisor.** The existing fake-clock suites (step deadline,
  retry and fanout expiry) pass unchanged. One system-clock test checks
  that `SystemWorkflowRetryClock().sleep(until: past)` returns at once and
  that cancellation throws.
- No test sleeps the host. Behavior across host sleep follows from
  `DispatchWallTime` semantics and is documented, not exercised.

Command:
`arch -arm64 /bin/zsh -lc 'swift build && swift test --filter "WallClockDeadline|LocalProcess|StepSupervisor|StepDeadline|StepRetry" && swiftlint lint --strict --quiet <changed files>'`

## 6. Docs

- `docs/workflows/step-deadline-and-retry.md` gains a "Timeout clock"
  paragraph. `nodeTimeoutMs`, `timeoutMs` and `deadlineMs` are elapsed
  wall-clock time, including host sleep. A run of a sleeping Mac can time
  out the moment the host wakes.
- `docs/workflow-definition-store.md` describes the §4.1 auto-sync and
  drift warnings, with the remediation commands.
- The repository has no root CHANGELOG or release-notes file, so there are
  no release-notes edits.
