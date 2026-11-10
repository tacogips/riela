# sdwd-05: Wall-clock deadlines for LocalProcess, ACP deadline cancel and file-markdown conversion; timeout docs

**planId**: sdwd-05-wall-clock-adapters
**dependsOn**: sdwd-01-wall-clock-core (`WallClockDeadlineScheduling`, `SystemWallClockDeadlineScheduler`, `wallClockSleep(until:scheduler:)` in RielaCore)
**Design Reference**: design-docs/specs/design-wall-clock-deadlines.md §1, §2, §4 (rows 1, 3, 4 and the audited-unchanged list), §5 (LocalProcessWallDeadlineTests), §6
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/sdwd-05-wall-clock-adapters.md
**Evidence root**: tmp/stale-definition/sdwd-05-wall-clock-adapters/

## Intent and context

This plan fixes the root cause of the ART 3300 s kills.
`Sources/RielaAdapters/LocalProcess.swift`, at about line 857, arms the
process deadline with
`DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: workItem)`.
`DispatchTime` is uptime, and it pauses while the Mac sleeps. The fix is to
schedule at the absolute wall `Date` through the injectable scheduler from
sdwd-01. Two more `Date`-deadline sites move to `wallClockSleep(until:)`,
and the docs state that timeouts are wall-clock.

## Non-goals

- Do not change `scheduleKillIfRunning(after:)` (about line 489-505, the
  1 s SIGTERM to SIGKILL grace).
- Do not change `checkLocalProcessAdmission` or any timeout value or
  default.
- Do not touch `RielaLocalHTTPServer`, `AppleSpeechRecognition`, RielaCore
  (sdwd-01) or any sdwd-02/03/04 file.
- No public API change to `LocalProcessRunning` or the `run` signatures.

## File-level changes

### Sources/RielaAdapters/LocalProcess.swift

- `FoundationLocalProcessRunner` (line 708) gains
  `var deadlineScheduler: any WallClockDeadlineScheduling = SystemWallClockDeadlineScheduler()`.
  Keep the existing public init(s) source-compatible. Add an
  `internal init(deadlineScheduler:)` or settable property for tests;
  RielaAdaptersTests uses `@testable import`.
- In the deadline block at about lines 844-858, replace the
  `delay`/`asyncAfter(deadline:)` pair with
  `deadlineScheduler.schedule(at: deadline, on: DispatchQueue.global(qos: .utility), workItem)`.
  The work item body is unchanged: `markTimedOut`, `closeForFailureOrTimeout`,
  terminate, then `scheduleKillIfRunning(after: 1)`. So is
  `completion.setDeadlineWorkItem(workItem)`. The closure that schedules
  must capture the scheduler value.

### Sources/RielaAdapters/AgentGatewayNodeAdapter.swift (about lines 343-356)

In the ACP deadline cancel task, replace
`if interval > 0 { try? await Task.sleep(for: .seconds(interval)) }`
with `try? await wallClockSleep(until: deadline)`. The guard/expired/cancel
logic after it stays the same. Cancellation of the task still stops it,
because `wallClockSleep` throws `CancellationError` and the `try?` plus the
`Task.isCancelled` guard handle that.

### Sources/RielaCLI/ProductionNodeAdapter+FileMarkdownAddon.swift (about lines 578-590)

In the timer task, replace `try await Task.sleep(for: .seconds(remaining))`
with `try await wallClockSleep(until: deadline)`. Keep the pre-check
(`remaining > 0` else throw) and both error messages verbatim.

### docs/workflows/step-deadline-and-retry.md

Add a short "Timeout clock" section:

- `nodeTimeoutMs`, `timeoutMs` and `deadlineMs` measure elapsed wall-clock
  time, including time the host is asleep. A run on a sleeping Mac can
  time out as soon as the host wakes.
- Wall-clock adjustments (NTP or manual) move the deadline.
- Values and defaults are unchanged.

### Tests/RielaAdaptersTests/LocalProcessWallDeadlineTests.swift (new)

Use a recording fake scheduler that implements
`WallClockDeadlineScheduling` and records `(Date, DispatchWorkItem)`
behind a lock. It does **not** fire on its own. Imitate the process setup
in `Tests/RielaAdaptersTests/LocalProcessAdmissionTests.swift` and
`LocalProcessForegroundLifetimeTests.swift`.

- **`/bin/sleep 30` with `deadline = D = Date() + 3600`**:
  - Poll until one schedule is recorded, bounded at 5 s. Assert the
    recorded date `== D` exactly (absolute, not relative).
  - Then call `perform()` on the recorded item. The `run` throws
    `AdapterExecutionError` with `.timeout` and the message
    `local agent process exceeded deadline and was terminated`, within
    10 s.
  - The process is gone. Imitate the existing group-ownership assertions
    if available; otherwise `kill(pid, 0)` fails.
- **`/bin/echo hi` with `deadline = Date() + 3600`** → it completes
  normally, and the recorded work item `isCancelled == true` after
  completion. This relies on the existing `deadlineWorkItem` cancel path.
  If the implementation does not cancel it, assert at least that firing
  it afterwards does not change the completed result.
- **No deadline (`nil`)** → the scheduler records nothing.
- **Default scheduler type** →
  `FoundationLocalProcessRunner().deadlineScheduler is SystemWallClockDeadlineScheduler`.

## Pitfalls

- Do not recompute a relative `delay` anywhere. That is the bug being
  fixed.
- Keep the ordering of `completion.setDeadlineWorkItem(workItem)` before
  scheduling. A past deadline fires immediately.
- Do not change the shape of `scheduleKillIfRunning`'s `asyncAfter`.
- Process tests must not depend on real deadline timing.

## Acceptance criteria

- [ ] `grep -n "asyncAfter(deadline: .now() + delay" Sources/RielaAdapters/LocalProcess.swift`
      returns exactly one match, inside `scheduleKillIfRunning`.
- [ ] No `Task.sleep` remains in the two modified deadline blocks.
- [ ] All new tests pass. The existing LocalProcess* suites pass.
- [ ] The docs section exists.

## Verification (arm64; logs plus `.exit` under the evidence root)

1. `arch -arm64 /bin/zsh -lc 'swift build > tmp/stale-definition/sdwd-05-wall-clock-adapters/build.log 2>&1; echo $? > tmp/stale-definition/sdwd-05-wall-clock-adapters/build.exit'`
   → 0.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "LocalProcess|AgentGatewayNodeAdapter|FileMarkdown|WallClockDeadline" > tmp/stale-definition/sdwd-05-wall-clock-adapters/test.log 2>&1; echo $? > tmp/stale-definition/sdwd-05-wall-clock-adapters/test.exit'`
   → 0, 0 failures, and the LocalProcessWallDeadlineTests names appear.
3. `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet Sources/RielaAdapters/LocalProcess.swift Sources/RielaAdapters/AgentGatewayNodeAdapter.swift Sources/RielaCLI/ProductionNodeAdapter+FileMarkdownAddon.swift Tests/RielaAdaptersTests/LocalProcessWallDeadlineTests.swift > tmp/stale-definition/sdwd-05-wall-clock-adapters/lint.log 2>&1; echo $? > tmp/stale-definition/sdwd-05-wall-clock-adapters/lint.exit'`
   → 0.

## Concurrency and drift protocol

Re-read each file before editing it and record pre/post sha256. Edit only
the files in writePaths. Log sibling build breaks and re-run.

## Progress log expectations

`impl-plans/progress/sdwd-05-wall-clock-adapters.md` holds the commands,
exit codes, log paths, hashes and the checked acceptance list.
