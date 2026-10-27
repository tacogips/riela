# c5pt-02-cron-core: CronSchedule.previousOccurrence

```json
{
  "planId": "c5pt-02-cron-core",
  "planPath": "impl-plans/active/crypto5-prevtick-02-cron-core.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "Sources/RielaCore/CronSchedule.swift",
    "Tests/RielaCoreTests/CronSchedulePreviousOccurrenceTests.swift",
    "impl-plans/progress/c5pt-02-cron-core.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Cron ticks must carry the previous scheduled occurrence. It is deterministic
and DST-correct, and it is computed only from the schedule and timezone
(design §2.2). This plan adds the RielaCore primitive. c5pt-06 wires it into
the envelope.

Existing code (`Sources/RielaCore/CronSchedule.swift`):

- `CronSchedule` has six-field `Set<Int>` fields plus `dayOfMonthRestricted`
  and `dayOfWeekRestricted`.
- `matches(_:calendar:)` checks second, minute, hour and month membership,
  then the day rule. The day rule is the dom/dow OR rule when both fields are
  restricted, dom-only or dow-only when one is restricted, and always true
  when neither is (lines 75-98). The cron weekday is
  `Calendar.weekday - 1`.
- `maximumCatchUpSeconds = 3_600` stays unchanged.

Continuation note (session 519): c5pt-01 has already landed (`35a910d5`), so
this plan has no in-run dependency and runs in wave 1. The plans running
alongside it are c5pt-03, c5pt-04 and c5pt-05. Their `writePaths` do not
overlap with this plan's. Concurrent `swift test` runs can contend for the
`.build` lock; follow the peer-breakage retry rule in
`impl-plans/active/crypto5-prevtick.md`.

Non-goals: no change to `dueTicks`, `maximumCatchUpSeconds`,
`EventLiveServe+Cron.swift` (owned by c5pt-06) or any other file.

## Contract (pinned; c5pt-06 depends on it)

```swift
public func previousOccurrence(before date: Date, calendar: Calendar) -> Date?
```

The result is the latest whole-second instant `t` with `t < date` and
`matches(t, calendar: calendar) == true`. It returns `nil` when no such `t`
exists at or after `calendar.date(byAdding: .year, value: -9, to: date)`.

## File-level changes

`Sources/RielaCore/CronSchedule.swift`:

1. Factor the per-field checks of `matches` into small private helpers on
   `CronSchedule`, for example `dayMatches(day:cronWeekday:) -> Bool`. Then
   `matches` and the new scan use the same predicates. `matches` must keep
   identical results. Do not change its signature or its use of
   `calendar.dateComponents([.second, .minute, .hour, .day, .month, .weekday], …)`.
2. Add `previousOccurrence(before:calendar:)` as a bounded skip-scan, with
   a short doc comment stating the contract. The steps:
   - Start at the largest whole second strictly before `date`:
     `t = ceil(date.timeIntervalSince1970) - 1`. For the integral
     `scheduledAt` values that `dueTicks` produces, this equals the design's
     `floor(before) - 1`. The `ceil` form also keeps fractional inputs exact.
   - Loop while `t >= horizon`. Decompose `t`, then:
     1. month not in `months`: `t = start(.month, t) - 1`;
     2. else `!dayMatches`: `t = start(.day, t) - 1`;
     3. else hour not in `hours`: `t = start(.hour, t) - 1`;
     4. else minute not in `minutes`: `t = start(.minute, t) - 1`;
     5. else second not in `seconds`: `t -= 1`;
     6. else return `t`.
   - `start(unit, t)` is `calendar.dateInterval(of: unit, for: t)!.start`.
     Use `guard let`, and return `nil` if the calendar returns nil; never
     force-unwrap.
   - After the loop, return `nil`.

## Key pitfalls

- **Do not** scan backward second by second over the whole range. A yearly or
  Feb 29 schedule would take millions to billions of iterations. **Do not**
  call `dueTicks`. Its window is capped at `maximumCatchUpSeconds`.
- **Do not** step with fixed durations such as `-3600` or `-86400` to skip an
  hour or day. Use `dateInterval(of:for:)` so jumps follow DST:
  - a 23-hour or 25-hour day;
  - a repeated fall-back hour, which is visited twice. Both 01:30 instances
    match, the same as with `dueTicks`;
  - a spring-forward gap, where the missing wall time simply has no
    occurrence.
- **Do not** reimplement the dom/dow OR rule. Reuse the helper that
  `matches` uses.
- The calendar's `timeZone` is set by the caller. Do not replace it.
- The function must be pure. No `Date()`, no global state.

## Test cases (`Tests/RielaCoreTests/CronSchedulePreviousOccurrenceTests.swift`, XCTest, `import RielaCore`)

Build the calendar as a Gregorian `Calendar` with a fixed
`TimeZone(identifier:)`. Build instants from ISO strings with
`ISO8601DateFormatter`.

| Schedule | Timezone | Before | Expected |
|---|---|---|---|
| `0 55 * * * *` | Asia/Tokyo | `2026-10-27T14:55:00+09:00` | `2026-10-27T13:55:00+09:00` |
| daily `0 0 3 * * *` | Asia/Tokyo | `2026-10-27T03:00:00+09:00` | `2026-10-26T03:00:00+09:00` |
| weekly `0 0 9 * * 1` | Asia/Tokyo | Mon `2026-10-26T09:00:00+09:00` | Mon `2026-10-19T09:00:00+09:00` |
| hourly `0 0 * * * *` (spring-forward) | America/New_York | `2026-03-08T07:00:00Z` | `2026-03-08T06:00:00Z` |
| daily `0 30 2 * * *` (spring-forward) | America/New_York | `2026-03-09T06:30:00Z` | `2026-03-07T07:30:00Z`, since 02:30 does not exist on 03-08 |
| `0 30 1 * * *` (fall-back) | America/New_York | `2026-11-01T06:30:00Z` (01:30 EST) | `2026-11-01T05:30:00Z` (01:30 EDT) |
| `*/15 * * * * *` | UTC | `2026-10-27T10:00:00Z` | `2026-10-27T09:59:45Z` |
| `30 0 * * * *` | UTC | `2026-10-27T10:00:30Z` | `2026-10-27T09:00:30Z` |
| `0 0 0 29 2 *` | UTC | `2028-02-29T00:00:00Z` | `2024-02-29T00:00:00Z` |
| `0 0 0 31 2 *` (impossible) | UTC | `2026-10-27T00:00:00Z` | `nil`. The bounded scan must make the test finish in well under a second; no timing assertion is needed |

More cases:

- dom/dow OR: `0 0 0 1 * 1` UTC, before Mon `2026-10-26T00:00:00Z`
  (the 26th). Expected: the latest of the previous Monday
  `2026-10-19T00:00:00Z` and the 1st `2026-10-01`, which is `2026-10-19`.
- Fractional input: `before = 10:00:00.5` with `* * * * * *` gives
  `10:00:00`, the largest whole second strictly less than `before`. Also,
  `before = 10:00:00` gives `09:59:59`.
- Equivalence: for `*/7 * * * * *`, `0 */13 * * * *` and `15 0-5 * * * 2`, in
  Asia/Tokyo and America/New_York, for 20 seeded `before` instants spread
  across `2026-03-07…2026-03-09` and `2026-10-31…2026-11-02`, the result
  equals a brute-force helper. The helper scans backward second by second with
  `matches`, limited to 8 days.

## Verification (commands → required evidence)

```
arch -arm64 /bin/zsh -lc "swift test --filter 'CronSchedulePreviousOccurrenceTests|EventLiveServeCronTests' > tmp/crypto5-prevtick/c5pt-02-cron-core/test.log 2>&1; echo exit=\$?"
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache Sources/RielaCore/CronSchedule.swift Tests/RielaCoreTests/CronSchedulePreviousOccurrenceTests.swift > tmp/crypto5-prevtick/c5pt-02-cron-core/lint.log 2>&1; echo exit=$?'
```

Required results: test `exit=0`, `testsRun ≥ 12`, `failureCount 0`. The
existing `EventLiveServeCronTests` still pass, which shows `matches` is
unchanged. Lint `exit=0`.

## Done criteria

- `grep -n 'public func previousOccurrence(before date: Date, calendar: Calendar) -> Date?' Sources/RielaCore/CronSchedule.swift`
  returns 1 line.
- `grep -n 'maximumCatchUpSeconds = 3_600' Sources/RielaCore/CronSchedule.swift`
  is unchanged.
- The progress log has test and lint records with exit statuses.
