# gcc-01-request-limiter: shared start-slot rate limiter for riela/gmail-collect

```json
{
  "planId": "gcc-01-request-limiter",
  "planPath": "impl-plans/active/gmail-collect-concurrency-01-request-limiter.md",
  "dependsOn": [],
  "wave": "W1",
  "writePaths": [
    "Sources/RielaCLI/GmailCollectionRequestLimiter.swift",
    "Tests/RielaCLITests/GmailCollectionRequestLimiterTests.swift",
    "impl-plans/progress/gcc-01-request-limiter.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

`riela/gmail-collect` (`GmailMailboxCollector.collectScan` in
`Sources/RielaCLI/GmailCollection.swift`) currently spaces provider requests
with a local `read` helper (lines 93-101). That helper keeps a `requests`
counter. It checks the deadline as `deadline - now <= (requests > 0 ? interval : 0)`
and waits a full `interval` before every request except the first.

Plan gcc-02 will run per-thread reads concurrently. Every provider request,
from every worker, must then take a start slot from one shared limiter. The
contract is in design-docs/specs/design-native-source-collection.md, subsection
"Full listing, concurrent thread reads and early-stop reasons", paragraph 3
(decision D4).

This plan adds only that limiter, as a standalone actor with its own unit
tests. gcc-02 consumes it.

## Non-goals

- Do not touch `GmailCollection.swift`, `GmailCollectionCoordinator.swift`,
  `ProductionNodeAdapter+GmailCollect.swift` or `GmailCollectionTests.swift`.
  Those belong to gcc-02.
- Do not touch `GmailMessageBodyCollection.swift`. Message-bodies mode keeps its own sequential spacing.
- No new dependencies. Do not use `Synchronization.Mutex`: the deployment
  target is macOS 14 (`Package.swift` platforms). No generic rate-limiter
  framework, no configuration knobs beyond the ones pinned below.

## Pinned contract (gcc-02 depends on these exact names)

```swift
struct GmailCollectionDeadlineRefusal: Error, Sendable {}

actor GmailCollectionRequestLimiter {
  init(interval: Double, deadline: Date?,
       clock: @escaping @Sendable () -> Date,
       wait: @escaping @Sendable (Double) async throws -> Void)
  /// Counts a request the caller already made (coordinator-read profile) as the first granted slot at clock().
  func recordPrefetchedGrant()
  /// Grants the next start slot or throws GmailCollectionDeadlineRefusal / CancellationError.
  func acquire() async throws
  var grantedCount: Int { get }
}
```

Both types are internal (no `public`). File: `Sources/RielaCLI/GmailCollectionRequestLimiter.swift`.

## Semantics of `acquire()`

1. Call `Task.checkCancellation()` first. A cancelled caller gets `CancellationError` and no slot.
2. Let `now = clock()`. If no slot has been granted yet, `slot = now`.
   Otherwise `slot = max(now, lastSlot + interval)`.
3. If `deadline != nil && slot >= deadline`, throw
   `GmailCollectionDeadlineRefusal()`. Do not change `lastSlot` or
   `grantedCount`, and do not call `wait`.
4. Reserve before suspending: set `lastSlot = slot` and increment
   `grantedCount`. Only after that, if `slot.timeIntervalSince(now) > 0`, call
   `try await wait(slot.timeIntervalSince(now))`, then
   `Task.checkCancellation()`. Reserving before the `await` is what makes actor
   reentrancy safe: a concurrent `acquire` that runs while this one sleeps must
   see the reserved slot and take the next one.
5. Never call `wait` with `0` or a negative value. With `interval == 0`, `wait` is never called.

`recordPrefetchedGrant()` sets `lastSlot = clock()` and increments `grantedCount`. It does no deadline check.

## Patterns to imitate

- Injectable clock/wait closure shapes: `GmailMailboxCollector.clock` and
  `.wait` (GmailCollection.swift:87-88). Keep the same `(Double)` seconds
  parameter, but make the closures `@Sendable`.
- The timeout wording stays in gcc-02. The limiter throws only the dedicated
  refusal error, so callers can tell a deadline stop apart from provider
  errors (including provider `.timeout` errors).
- Test-side shared mutable state goes in a lock-protected
  `final class ...: @unchecked Sendable` with `NSLock`, as in
  `GmailCollectTransport` (Tests/RielaCLITests/GmailCollectionTests.swift:439).
  Test code only; never in production code.

## Pitfalls

- Do not sleep a fixed `interval` the way the old `read` helper did. Sleep only
  `slot - now`. With a frozen test clock, sequential acquires must wait 2.5,
  5.0 and 7.5 (slots t0+2.5, t0+5, t0+7.5), not 2.5 each time.
- Do not check the deadline after the wait in a way that releases the reserved
  slot. Refusal happens only at reservation time (step 3).
- `grantedCount` counts reserved slots. A cancellation during `wait` after
  reservation leaves the count incremented. That is acceptable because
  cancellation propagates and no result is produced. Document this in a
  one-line comment.
- Keep the file small, with no extra public API.

## Tests to add (`Tests/RielaCLITests/GmailCollectionRequestLimiterTests.swift`, class `GmailCollectionRequestLimiterTests`)

The class name contains `GmailCollection`, so `--filter GmailCollection` also runs it.

| Situation | Expected outcome |
| --- | --- |
| First `acquire` with interval 2.5 and no deadline | No `wait` call. `grantedCount == 1`. |
| Frozen clock, interval 2.5, 4 sequential acquires | Recorded waits `[2.5, 5.0, 7.5]`. `grantedCount == 4`. |
| `wait(d)` advances the fake clock by `d`, interval 2.5, 4 sequential acquires | Waits `[2.5, 2.5, 2.5]`. |
| Clock moved 10s past the last slot before the next acquire (interval 2.5) | No wait for that acquire. |
| Frozen clock, interval 1, 8 concurrent acquires in a `withThrowingTaskGroup` | `grantedCount == 8`. Recorded waits sorted equal `[1,2,...,7]` (one acquire has no wait). This proves distinct reserved slots. |
| Interval 0, 5 acquires | `wait` never called. `grantedCount == 5`. |
| Deadline = t0, first acquire at t0 | Throws `GmailCollectionDeadlineRefusal`. `grantedCount == 0`. No wait. |
| Deadline = t0+3, interval 2.5, frozen clock | 1st and 2nd acquires are granted (slot t0+2.5 < t0+3). The 3rd (slot t0+5) throws `GmailCollectionDeadlineRefusal`. `grantedCount == 2`. |
| `recordPrefetchedGrant()` then `acquire()` with interval 2.5 and a frozen clock | `grantedCount == 2`. One wait of 2.5. |
| `acquire()` inside a task cancelled before the call | Throws `CancellationError`. `grantedCount == 0`. |

## Verification (all logs under `tmp/gmail-collect-concurrency/gcc-01/`)

1. `mkdir -p tmp/gmail-collect-concurrency/gcc-01`
2. `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift build > tmp/gmail-collect-concurrency/gcc-01/build.log 2>&1'`
   must exit 0 with no Swift 6 concurrency diagnostics in the new file
   (`grep -n "GmailCollectionRequestLimiter" tmp/gmail-collect-concurrency/gcc-01/build.log`
   shows no `error:` or `warning:`).
3. `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter GmailCollectionRequestLimiterTests > tmp/gmail-collect-concurrency/gcc-01/test.log 2>&1'`
   must exit 0. The log must show all 10 test methods executed with 0 failures.
4. `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swiftlint lint --strict --quiet --no-cache Sources/RielaCLI/GmailCollectionRequestLimiter.swift Tests/RielaCLITests/GmailCollectionRequestLimiterTests.swift > tmp/gmail-collect-concurrency/gcc-01/swiftlint.log 2>&1'`
   must exit 0 with an empty log.
5. `git diff --quiet -- Sources/RielaCLI/GmailCollection.swift Sources/RielaCLI/GmailCollectionCoordinator.swift Sources/RielaCLI/ProductionNodeAdapter+GmailCollect.swift Tests/RielaCLITests/GmailCollectionTests.swift`
   must exit 0. This proves no out-of-scope edits.

## Concurrent-edit hygiene

Before editing each owned file, record its SHA-256, or `absent`, in the
progress log. Read each file fresh before every edit. If an owned file changed
between your read and your write, re-read it and reapply your intent; never
overwrite blindly. Never run git commands that change the index or the
worktree (no checkout, stash, reset or commit).

## Done criteria (mechanically checkable)

- `grep -n "actor GmailCollectionRequestLimiter" Sources/RielaCLI/GmailCollectionRequestLimiter.swift` matches.
- `grep -n "struct GmailCollectionDeadlineRefusal: Error, Sendable" Sources/RielaCLI/GmailCollectionRequestLimiter.swift` matches.
- `grep -n "func acquire() async throws" Sources/RielaCLI/GmailCollectionRequestLimiter.swift` matches.
- `grep -n "func recordPrefetchedGrant()" Sources/RielaCLI/GmailCollectionRequestLimiter.swift` matches.
- `grep -n "unchecked" Sources/RielaCLI/GmailCollectionRequestLimiter.swift` has no matches.
- Verification commands 2-5 each exit 0, with complete logs.
- `impl-plans/progress/gcc-01-request-limiter.md` contains:
  - the changes list;
  - pre/post SHA-256 of the owned files;
  - a verification table with command, exitStatus, testsRun, failureCount and log path.
