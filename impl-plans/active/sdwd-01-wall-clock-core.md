# sdwd-01: Wall-clock deadline primitive (RielaCore) + step supervisor clock + distributed worker timeout

**planId**: sdwd-01-wall-clock-core
**dependsOn**: none (wave 1)
**Design Reference**: design-docs/specs/design-wall-clock-deadlines.md §2, §3, §4 (rows 2 and 5), §5; design-docs/specs/design-step-deadline-and-retry-policy.md §5.4
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/sdwd-01-wall-clock-core.md (this worker edits only this log)
**Evidence root**: tmp/stale-definition/sdwd-01-wall-clock-core/

## Intent and context

ART outage, 2026-11-10. Node and step budgets are `Date` deadlines, but some
timers that enforce them run on a relative or uptime clock. The rule
(design §2) is that every timer enforcing a node or step `Date` deadline
fires at that wall-clock `Date`. Host sleep counts toward the budget.

This plan adds the one shared primitive in RielaCore and moves two RielaCore
sites onto it:

- `SystemWorkflowRetryClock.sleep(until:)`, which drives the step
  supervisor's `deadlineMs` and per-attempt expiry, the backstops, the
  fanout expiry and backoff
- the timeout race in `DistributedWorkerNodeExecutor`

Plan sdwd-05 (wave 2) moves the RielaAdapters and RielaCLI sites, including
LocalProcess, onto the same primitive. **The primitive signatures below are
the contract sdwd-05 depends on. Do not rename them.**

## Non-goals

- Do not change any timeout value, default, precedence or clamping.
- Do not touch `WorkflowRuntimeClock`, `SleepNodeExecution`, polling loops,
  `RielaLocalHTTPServer`, `AppleSpeechRecognition`, or any file in
  RielaAdapters or RielaCLI (sdwd-05 owns those).
- Do not change the `WorkflowRetryClock` protocol or the test fake
  `Tests/RielaCoreTests/ManualWorkflowRetryClock.swift`.

## File-level changes

### Sources/RielaCore/WallClockDeadline.swift (new)

The contract, which must match exactly:

```swift
public protocol WallClockDeadlineScheduling: Sendable {
  func now() -> Date
  func schedule(at deadline: Date, on queue: DispatchQueue, _ work: DispatchWorkItem)
}
public struct SystemWallClockDeadlineScheduler: WallClockDeadlineScheduling { public init() }
public func dispatchWallTime(for date: Date) -> DispatchWallTime
public func wallClockSleep(until deadline: Date,
  scheduler: any WallClockDeadlineScheduling = SystemWallClockDeadlineScheduler()) async throws
```

- **`dispatchWallTime(for:)`** builds a `timespec` from
  `date.timeIntervalSince1970`:
  - `tv_sec` is the floor.
  - `tv_nsec` is the fractional part × 1e9, clamped to `0..<1_000_000_000`.
  - Negative or pre-epoch values are clamped to 0.

  It returns `DispatchWallTime(timespec:)`. Keep it pure, so tests can
  assert on it.
- **`SystemWallClockDeadlineScheduler.schedule`** calls
  `queue.asyncAfter(wallDeadline: dispatchWallTime(for: deadline), execute: work)`.
  A deadline in the past fires immediately; dispatch handles that.
- **`wallClockSleep(until:scheduler:)`**:
  1. `try Task.checkCancellation()` first.
  2. If `deadline <= scheduler.now()`, return immediately.
  3. Otherwise use `withTaskCancellationHandler` around
     `withCheckedThrowingContinuation`. Create a `DispatchWorkItem` that
     resumes the continuation and schedule it on `DispatchQueue.global(qos: .utility)`.
  4. On cancellation, cancel the work item and resume with
     `CancellationError()`.
  5. Resume **exactly once**. Guard with a small lock-protected state (an
     `NSLock` plus a flag in a `final class … @unchecked Sendable` box) so
     a fire and a cancel that race cannot double-resume.

  For the lock-box style, imitate
  `Sources/RielaAdapters/LocalProcess.swift` (`lock.lock()` /
  `defer`-style guarded state).

### Sources/RielaCore/WorkflowStepRetryPolicy.swift

`SystemWorkflowRetryClock.sleep(until:)`: replace the `Task.sleep(for:)` body
with `try await wallClockSleep(until: until)`. Leave `now()` as `Date()`.
Nothing else in the file changes.

### Sources/RielaCore/DistributedWorkerNodeExecutor.swift (about lines 62-75)

Compute `let deadline = Date().addingTimeInterval(request.timeoutSeconds)`
once. Pass that same `deadline` into the execute context, which today
computes its own `Date().addingTimeInterval`. Replace the timer task's
`Task.sleep(for: .seconds(request.timeoutSeconds))` with
`try await wallClockSleep(until: deadline)`. Keep the thrown error text
exactly: `AdapterExecutionError(.timeout, "worker execution deadline exceeded")`.
The task-group structure and `defer { group.cancelAll() }` stay unchanged.

### Tests/RielaCoreTests/WallClockDeadlineTests.swift (new)

Write a fake scheduler, `RecordingWallClockScheduler`: a lock-protected
`now` plus a recorded `[(Date, DispatchWorkItem)]`, and a `fire(index)`
that calls `work.perform()`. Keep it local to this test file. Cases:

- `dispatchWallTime(for: Date(timeIntervalSince1970: 1_700_000_000.25))`
  → equals `DispatchWallTime(timespec: timespec(tv_sec: 1_700_000_000, tv_nsec: 250_000_000))`.
  Compare the `rawValue`. If that is not accessible, compare against a
  value built the same way.
- `Date(timeIntervalSince1970: 0)` and a negative interval → no crash,
  clamped.
- `wallClockSleep(until: now + 3600, scheduler: fake)` → it records
  exactly one schedule whose date `==` the deadline (absolute, not
  relative). The sleep does not return until `fire(0)`, and returns after
  it.
- Cancel the sleeping task → it throws `CancellationError` and the
  recorded work item `isCancelled == true`.
- `wallClockSleep(until: Date.distantPast)` with the system scheduler →
  returns without scheduling.
- A pre-cancelled task → throws `CancellationError` before scheduling
  (fake records 0).
- `SystemWorkflowRetryClock().sleep(until: Date().addingTimeInterval(-1))`
  → returns immediately. A cancelled `SystemWorkflowRetryClock().sleep(until: now + 3600)`
  → throws `CancellationError` within 2 s.

No test may sleep for real longer than 2 s.

## Pitfalls

- Do not use `DispatchTime` / `.now() + delay` anywhere in the new code.
  That is the bug.
- Do not convert the deadline to a relative delay before scheduling. The
  scheduler must receive the absolute `Date`.
- A double resume of a checked continuation crashes. The once-guard is
  mandatory.
- Do not add the primitive to an existing file. sdwd-05 imports it from
  `RielaCore` by these exact names.

## Invariants

- Existing step deadline, retry and fanout suites pass unchanged. They use
  `ManualWorkflowRetryClock`, not the system clock.
- Public API additions only. No existing signature changes.

## Acceptance criteria

- [ ] `Sources/RielaCore/WallClockDeadline.swift` exists with exactly the
      contract signatures above.
- [ ] `grep -n "Task.sleep" Sources/RielaCore/WorkflowStepRetryPolicy.swift Sources/RielaCore/DistributedWorkerNodeExecutor.swift`
      returns no deadline-enforcing match.
- [ ] All `WallClockDeadlineTests` cases are present and pass.
- [ ] The existing `StepRetry*` and `StepDeadline*` suites pass.

## Verification (arm64 shell; write the logs under the evidence root)

1. `arch -arm64 /bin/zsh -lc 'swift build > tmp/stale-definition/sdwd-01-wall-clock-core/build.log 2>&1; echo $? > tmp/stale-definition/sdwd-01-wall-clock-core/build.exit'`
   → exit 0.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "WallClockDeadlineTests|StepRetry|StepDeadline" > tmp/stale-definition/sdwd-01-wall-clock-core/test.log 2>&1; echo $? > tmp/stale-definition/sdwd-01-wall-clock-core/test.exit'`
   → exit 0, 0 failures, and the WallClockDeadlineTests case names appear
   in the log.
3. `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet Sources/RielaCore/WallClockDeadline.swift Sources/RielaCore/WorkflowStepRetryPolicy.swift Sources/RielaCore/DistributedWorkerNodeExecutor.swift Tests/RielaCoreTests/WallClockDeadlineTests.swift > tmp/stale-definition/sdwd-01-wall-clock-core/lint.log 2>&1; echo $? > tmp/stale-definition/sdwd-01-wall-clock-core/lint.exit'`
   → exit 0.

A build failure in a file owned by a sibling wave-1 plan (sdwd-02) is not
yours to fix. Record it with the log path, wait for that plan, and re-run.

## Concurrency and drift protocol

Re-read each file immediately before editing it. Record its sha256 before
and after the edit in the progress log. If a file changed since your read
and the change is not yours, stop editing that file and record the drift.
Edit only the files in writePaths.

## Progress log expectations

`impl-plans/progress/sdwd-01-wall-clock-core.md` holds, for each
verification command, the command, its exit code and its log path; the
pre/post hashes; and a checked acceptance list.
