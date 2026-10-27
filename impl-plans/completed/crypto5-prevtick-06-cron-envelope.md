# c5pt-06-cron-envelope: previous-tick keys in the cron.tick envelope

```json
{
  "planId": "c5pt-06-cron-envelope",
  "planPath": "impl-plans/active/crypto5-prevtick-06-cron-envelope.md",
  "dependsOn": ["c5pt-02-cron-core", "c5pt-05-docs-fixtures"],
  "wave": 2,
  "writePaths": [
    "Sources/RielaCLI/EventLiveServe+Cron.swift",
    "Tests/RielaCLITests/EventLiveServeCronTests.swift",
    "impl-plans/progress/c5pt-06-cron-envelope.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

`dispatchCronTick` in `Sources/RielaCLI/EventLiveServe+Cron.swift` builds the
only runtime `cron.tick` envelope. Its `input` currently has `scheduledAt`,
`scheduledLocalTime`, `firedAt` and `timezone`, formatted by the file-private
`cronISOTimestamp` and `cronLocalTimestamp`.

Several paths reuse that envelope as-is (design §2.3):

- read-only receipts (`recordReadOnlyEventIfNeeded`);
- the overlap dispatcher (`CronOverlapFire.envelope`);
- `events replay` (the stored envelope).

So adding the keys here makes every runtime producer agree.

This plan adds `previousScheduledAt` and `previousScheduledLocalTime`
(design §2.1), using
`CronSchedule.previousOccurrence(before:calendar:)` from c5pt-02.

## File-level changes (`Sources/RielaCLI/EventLiveServe+Cron.swift`)

1. In `struct CronScheduleSource`, add
   `func previousTick(before scheduledAt: Date) -> Date?`. It mirrors
   `dueTicks(after:until:)`:
   - parse `schedule` with `try? CronSchedule.parse`, returning `nil` on
     failure;
   - build a Gregorian calendar with `resolvedTimeZone`;
   - return `parsed.previousOccurrence(before:calendar:)`.
2. In `dispatchCronTick`, build the `input` `JSONObject` as today. Then, if
   `source.previousTick(before: scheduledAt)` returns a value, set:
   - `"previousScheduledAt"` to `cronISOTimestamp(previous)`;
   - `"previousScheduledLocalTime"` to
     `cronLocalTimestamp(previous, timeZone: timeZone)`.

   If it returns `nil`, add neither key; no sentinel or empty string. Pass
   the finished object to `ExternalEventEnvelope(input:)`.

## Key pitfalls

- The value depends only on `(source.schedule, source.resolvedTimeZone,
  scheduledAt)`. Do **not** use `firedAt`, `cronLastCheckedAt`, the previous
  element of `ticks`, receipts, the dispatcher or `isLatestDueTick`. With a
  coalesced batch `[t1, t2, t3]`, t3's previous value is the schedule
  occurrence before t3, which is t2 for a dense schedule. It is not "the last
  run".
- Reuse the existing formatters so the formats match the existing keys
  byte for byte. Do not add a new formatter.
- Do not change `eventId`, `dedupeKey`, the event type, `dueTicks`,
  `maximumCatchUpSeconds`, `EventCronOverlapDispatcher.swift`,
  `EventLiveServe.swift` or `ScopedParityCommands*.swift`.
- `timezone` stays `source.timezone ?? "UTC"`, and the previous value uses
  the same `resolvedTimeZone`.

## Test cases (add to `Tests/RielaCLITests/EventLiveServeCronTests.swift`)

Reuse the file's helpers: `writeCronEventConfig`, the shared
`assertReadOnlyEventReceipt` from `EventReadOnlyPolicyTests.swift`, and the
pattern of `testReadOnlyCronRetainsFixedClockEnvelopeWithoutDispatchOrRoutineCompletion`.

1. **Envelope, Tokyo.** A `CronScheduleSource(id: "cron-live", schedule: "0 55 * * * *", timezone: "Asia/Tokyo")`
   with `scheduledAt` `2026-10-27T05:55:00Z`, dispatched in read-only mode.
   The receipt envelope input has:
   - `previousScheduledAt == "2026-10-27T04:55:00.000Z"`;
   - `previousScheduledLocalTime == "2026-10-27 13:55:00"`;
   - `scheduledLocalTime == "2026-10-27 14:55:00"`.

   The cron source/binding config must contain a binding that matches
   `cron-live`. If `writeCronEventConfig` hard-codes the schedule, pass the
   `CronScheduleSource` directly, as the existing test does. The envelope is
   built from the `source` argument, not from the file.
2. **Envelope, New York spring-forward.** Schedule `0 0 * * * *`,
   America/New_York, scheduled at `2026-03-08T07:00:00Z`. Expected:
   `previousScheduledAt == "2026-03-08T06:00:00.000Z"` and
   `previousScheduledLocalTime == "2026-03-08 01:00:00"`.
3. **Binding template.** Build an `EventDryRunRequest` with:
   - a binding whose `inputMapping` is `.template`, with `windowStart`
     `{{event.input.previousScheduledAt}}`, `windowStartLocal`
     `{{event.input.previousScheduledLocalTime}}` and `windowEnd`
     `{{event.input.scheduledAt}}`;
   - the envelope from case 1, either taken from the receipt or built
     through `dispatchCronTick` read-only.

   `DeterministicEventDryRunTrigger().dryRun(…)` gives one trigger whose
   `runtimeVariables` contain the three rendered values. For
   `EventBindingContract` / `EventInputMapping` construction, imitate
   `RoutineService.eventBinding(for:storeRoot:)`.
4. **`previousTick` unit check.** `CronScheduleSource(id:"x", schedule:"*/30 * * * * *", timezone:"UTC").previousTick(before: t)`
   returns `t - 30`. An invalid schedule string returns `nil`.
5. **Fixture agreement.** For each pair below, decode the payload JSON and
   the source JSON, which is `CronScheduleSource`-decodable. Assert that
   `input.previousScheduledAt` and `previousScheduledLocalTime` equal the
   values formatted from
   `source.previousTick(before: ISO8601(input.scheduledAt))`. Format them the
   same way the envelope does; build the strings through `dispatchCronTick`
   or compare after parsing.

   | Payload | Source |
   |---|---|
   | `examples/event-sources/payloads/gmail-latest-mail-hourly-cron.json` | `examples/event-sources/.riela-events/sources/gmail-latest-mail-hourly-cron.json` |
   | `examples/event-sources/payloads/x-follower-ai-business-hourly-cron.json` | `examples/event-sources/.riela-events/sources/x-follower-ai-business-hourly-cron.json` |
   | `examples/wrike-project-kanban-agent/payloads/wrike-kanban-cron-tick.json` | `examples/wrike-project-kanban-agent/.riela-events/sources/wrike-kanban-30s-cron.json` |

   Resolve the repository root the way existing CLI tests that read
   `examples/` do:
   `URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()`
   (`Tests/RielaCLITests/CollectionGatewayWorkflowTests.swift:26`). Do not
   hard-code `/Users/...`.

   The fixture values come from c5pt-05 (wave 1, re-applied held patch). If
   a fixture lacks `previousScheduledAt` when this plan runs, c5pt-05 has not
   finished or failed. Do not edit the fixture, which c5pt-05 owns. Log it as
   peer drift and mark the plan `blocked`.

## Verification (commands → required evidence)

```
arch -arm64 /bin/zsh -lc "swift test --filter 'EventLiveServeCronTests|EventCronOverlapTests|EventCronOverlapServeTests|EventRoutineBindingTests|TimeSignalAddonTests|EventReadOnlyPolicyTests' > tmp/crypto5-prevtick/c5pt-06-cron-envelope/test.log 2>&1; echo exit=\$?"
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache Sources/RielaCLI/EventLiveServe+Cron.swift Tests/RielaCLITests/EventLiveServeCronTests.swift > tmp/crypto5-prevtick/c5pt-06-cron-envelope/lint.log 2>&1; echo exit=$?'
```

Required results: test `exit=0`, `testsRun > 0`, `failureCount 0`, with all
new test names passing and the existing overlap and serve tests still passing.
Lint `exit=0`.

## Done criteria

- `grep -c 'previousScheduled' Sources/RielaCLI/EventLiveServe+Cron.swift`
  is at least 2.
- `grep -n 'func previousTick(before' Sources/RielaCLI/EventLiveServe+Cron.swift`
  returns 1 line.
- `git diff --stat` touches only this plan's `writePaths`.
